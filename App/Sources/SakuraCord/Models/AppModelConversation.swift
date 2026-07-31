import CoreAudio
import CoreText
import DiscordProtocol
import Foundation
import ImageIO
import MediaPipeline
import MessageRendering
import OSLog
import Observation
import SakuraCordModels
import SakuraCordPersistence
import UniformTypeIdentifiers
import UserNotifications

extension AppModel {
    func removeForumPost(_ postID: ChannelID) {
        guard let index = forumCatalogueIndexByID.removeValue(forKey: postID) else { return }
        forumCataloguePosts.remove(at: index)
        if index < forumCataloguePosts.endIndex {
            for updatedIndex in index ..< forumCataloguePosts.endIndex {
                forumCatalogueIndexByID[forumCataloguePosts[updatedIndex].id] = updatedIndex
            }
        }
        applyForumPresentation()
    }

    func beginSelectedChannelLoad() {
        channelLoadTask?.cancel()
        channelLoadGeneration &+= 1
        let generation = channelLoadGeneration
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        isLoadingEarlier = false
        hasCompletedInitialMessageLoad = false
        stopLocalTyping(clearThrottle: true)
        replyingTo = nil

        guard let channelID = selectedChannelID,
              selectedChannel?.kind != .voice || isVoiceChatOpen
        else {
            replaceSelectedMessages(with: [])
            draft = ""
            hasMoreMessages = false
            isLoadingMessages = false
            hasCompletedInitialMessageLoad = true
            return
        }

        let cachedMessages = takeCachedMessages(for: channelID)
        replaceSelectedMessages(with: cachedMessages)
        hasMoreMessages = hasMoreCache[channelID] ?? false
        // Cached rows are immediately presentable, but the newest-page
        // request is still in flight and the older-history boundary is
        // unknown until it answers. Keeping this true suppresses a false
        // channel beginning and exposes compact progress above cached rows.
        isLoadingMessages = true
        preserveUnreadDividerIfNeeded(channelID: channelID)
        draft = ""
        channelLoadTask = Task { [weak self] in
            await self?.loadSelectedChannel(
                channelID,
                generation: generation
            )
        }
    }

    func loadSelectedChannel(
        _ channelID: ChannelID,
        generation: Int
    ) async {
        async let cachedMessages = storedMessages(in: channelID)
        async let storedDraft = storedDraft(in: channelID)
        async let freshPage = provider.messages(
            in: channelID,
            before: nil,
            limit: 100
        )

        let cached = await cachedMessages
        guard isCurrentLoad(channelID, generation: generation) else { return }
        if messages.isEmpty, !cached.isEmpty {
            replaceSelectedMessages(with: cached)
            preserveUnreadDividerIfNeeded(channelID: channelID)
        }

        let savedDraft = await storedDraft
        guard isCurrentLoad(channelID, generation: generation) else { return }
        if draft.isEmpty {
            draft = savedDraft
        }

        do {
            let page = try await freshPage
            guard isCurrentLoad(channelID, generation: generation) else { return }
            let merged = Self.merging(
                current: messages,
                fresh: page.messages
            )
            if merged != messages {
                replaceSelectedMessages(with: merged)
            }
            await resolveSelectedHistoryMembers(
                channelID: channelID,
                generation: generation
            )
            guard isCurrentLoad(channelID, generation: generation) else { return }
            try await finishSelectedChannelLoad(
                channelID: channelID,
                hasMoreBefore: page.hasMoreBefore
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoad(channelID, generation: generation) else { return }
            messageLoadError = error.localizedDescription
            messageLoadErrorIsEarlierPage = false
            isLoadingMessages = false
            hasCompletedInitialMessageLoad = true
        }
    }

    func finishSelectedChannelLoad(
        channelID: ChannelID,
        hasMoreBefore: Bool
    ) async throws {
        hasMoreMessages = hasMoreBefore
        hasMoreCache[channelID] = hasMoreBefore
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        isLoadingMessages = false
        hasCompletedInitialMessageLoad = true
        readState.observeLoadedMessages(channelID: channelID, messages: messages)
        preserveUnreadDividerIfNeeded(channelID: channelID)
        reportConversationHistoryLoaded(channelID: channelID)
        try await database?.save(messages: messages)
    }

    func resolveSelectedHistoryMembers(
        channelID: ChannelID,
        generation: Int
    ) async {
        guard let guildID = selectedChannel?.guildID,
              selectedChannel?.id == channelID
        else { return }

        let requested = LocalHistoryMemberResolution.userIDs(
            in: messages,
            known: Set(membersByID.keys)
        )
        guard !requested.isEmpty else { return }

        do {
            let resolved = try await provider.resolveMembers(
                in: guildID,
                userIDs: requested
            )
            guard isCurrentLoad(channelID, generation: generation), !resolved.isEmpty else {
                return
            }
            let indexed = mergedMemberStore(with: resolved)
            if membersByID != indexed {
                membersByID = indexed
                invalidateTimelinePresentation()
            }
            let hydrated = LocalHistoryMemberResolution.hydrating(
                messages,
                with: indexed
            )
            if hydrated != messages {
                replaceSelectedMessages(with: hydrated)
            }
        } catch is CancellationError {
            return
        } catch {
            // Message history remains usable when Discord cannot resolve a
            // member. A later channel load retries unresolved authors.
        }
    }

    func loadEarlier() async {
        guard let channelID = selectedChannelID, let first = messages.first, hasMoreMessages,
              !isLoadingEarlier
        else { return }
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        isLoadingEarlier = true
        defer {
            if selectedChannelID == channelID {
                isLoadingEarlier = false
            }
        }
        do {
            let page = try await provider.messages(in: channelID, before: first.id, limit: 50)
            guard !Task.isCancelled, selectedChannelID == channelID else { return }
            let reconcileStart = ProcessInfo.processInfo.systemUptime
            let earlier = page.messages.filter {
                !selectedMessageIDs.contains($0.id)
            }
            let filterEnd = ProcessInfo.processInfo.systemUptime
            if !earlier.isEmpty {
                guard await prependSelectedMessages(
                    earlier,
                    channelID: channelID
                ) else { return }
            }
            let prependEnd = ProcessInfo.processInfo.systemUptime
            hasMoreMessages = page.hasMoreBefore
            hasMoreCache[channelID] = page.hasMoreBefore
            messageLoadError = nil
            messageLoadErrorIsEarlierPage = false
            let stateEnd = ProcessInfo.processInfo.systemUptime
            if runsChatPerformanceBenchmark {
                let milliseconds = (stateEnd - reconcileStart) * 1_000
                if milliseconds >= 4 {
                    NSLog(
                        "SakuraCord history phases: filter %.2f ms; prepend %.2f ms; state %.2f ms (%d rows)",
                        (filterEnd - reconcileStart) * 1_000,
                        (prependEnd - filterEnd) * 1_000,
                        (stateEnd - prependEnd) * 1_000,
                        messages.count
                    )
                }
            }
            try await database?.save(messages: page.messages)
        } catch is CancellationError {
            return
        } catch {
            guard selectedChannelID == channelID else { return }
            messageLoadError = error.localizedDescription
            messageLoadErrorIsEarlierPage = true
        }
    }

    func retryMessageLoad() {
        guard selectedChannelID != nil else { return }
        if messageLoadErrorIsEarlierPage {
            messageLoadError = nil
            messageLoadErrorIsEarlierPage = false
            Task { [weak self] in
                await self?.loadEarlier()
            }
            return
        }
        beginSelectedChannelLoad()
    }

    func reply(to message: Message) {
        guard message.channelID == selectedChannelID else { return }
        replyingTo = message
        NotificationCenter.default.post(name: .sakuracordFocusComposer, object: nil)
    }

    func cancelReply() {
        replyingTo = nil
        NotificationCenter.default.post(name: .sakuracordFocusComposer, object: nil)
    }

    func open(_ thread: MessageThreadSummary) {
        guard openThread?.id != thread.id else { return }
        let starter = messages.first { $0.thread?.id == thread.id }
        openThreadConversation(
            thread,
            starter: starter?.author,
            startedAt: starter?.timestamp,
            initialMessages: []
        )
    }

    func open(_ post: ForumPost) {
        guard openThread?.id != post.id else { return }
        readState.merge(forumPost: post)
        openThreadConversation(
            post.thread,
            starter: post.owner ?? post.firstMessage?.author,
            startedAt: post.firstMessage?.timestamp ?? post.createdAt,
            initialMessages: post.firstMessage.map { [$0] } ?? []
        )
    }

    func openThreadConversation(
        _ thread: MessageThreadSummary,
        starter: User?,
        startedAt: Date?,
        initialMessages: [Message]
    ) {
        threadLoadTask?.cancel()
        readState.merge(thread: thread)
        openThread = thread
        _ = readState.updatePresentation(
            channelID: thread.id,
            isPresented: true,
            initialHistoryLoaded: false,
            initialPositionEstablished: false,
            windowIsActive: mainWindowIsActive,
            hasReachedReadBoundary: false,
            blocksAutomaticAcknowledgement: false
        )
        openThreadStarter = starter
        openThreadStartedAt = startedAt
        threadMessages = initialMessages
        threadDraft = ""
        threadComposerAttachments = []
        hasMoreThreadMessages = false
        beginInitialThreadLoad(thread)
    }

    func beginInitialThreadLoad(
        _ thread: MessageThreadSummary
    ) {
        threadLoadTask?.cancel()
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingThread = true
        hasCompletedInitialThreadLoad = false
        threadLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await provider.messages(
                    in: thread.id,
                    before: nil,
                    limit: 100
                )
                guard !Task.isCancelled, openThread?.id == thread.id else { return }
                threadMessages = page.messages.sorted { $0.timestamp < $1.timestamp }
                hasMoreThreadMessages = page.hasMoreBefore
                threadErrorMessage = nil
                threadErrorScope = nil
                isLoadingThread = false
                hasCompletedInitialThreadLoad = true
                readState.observeLoadedMessages(
                    channelID: thread.id,
                    messages: threadMessages
                )
                reportConversationHistoryLoaded(channelID: thread.id)
                try await database?.save(messages: page.messages)
            } catch is CancellationError {
                return
            } catch {
                guard openThread?.id == thread.id else { return }
                threadErrorMessage = error.localizedDescription
                threadErrorScope = .initialPage
                isLoadingThread = false
                hasCompletedInitialThreadLoad = true
            }
        }
    }

    func closeThread() {
        if let threadID = openThread?.id {
            unreadDividerMessageIDs[threadID] = nil
            if conversationNewestRequest?.channelID == threadID {
                conversationNewestRequest = nil
            }
            _ = readState.updatePresentation(channelID: threadID, isPresented: false)
        }
        threadLoadTask?.cancel()
        threadLoadTask = nil
        openThread = nil
        openThreadStarter = nil
        openThreadStartedAt = nil
        threadMessages = []
        threadDraft = ""
        threadComposerAttachments = []
        isLoadingThread = false
        hasCompletedInitialThreadLoad = false
        isLoadingEarlierThread = false
        hasMoreThreadMessages = false
        threadErrorMessage = nil
        threadErrorScope = nil
    }

    func openVoiceChat(for channel: Channel) {
        guard channel.kind == .voice else { return }
        if selectedChannelID != channel.id {
            selectedChannelID = channel.id
        }
        guard selectedChannelID == channel.id, !isVoiceChatOpen else { return }
        isVoiceChatOpen = true
        beginSelectedChannelLoad()
    }

    func closeVoiceChat() {
        guard isVoiceChatOpen else { return }
        channelLoadTask?.cancel()
        channelLoadTask = nil
        channelLoadGeneration &+= 1
        isVoiceChatOpen = false
        isLoadingMessages = false
        isLoadingEarlier = false
        messageLoadError = nil
    }

    func loadEarlierThread() async {
        guard let thread = openThread, let first = threadMessages.first, hasMoreThreadMessages,
              !isLoadingEarlierThread
        else { return }
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingEarlierThread = true
        defer {
            if openThread?.id == thread.id {
                isLoadingEarlierThread = false
            }
        }
        do {
            let page = try await provider.messages(in: thread.id, before: first.id, limit: 50)
            guard !Task.isCancelled, openThread?.id == thread.id else { return }
            let ids = Set(threadMessages.map(\.id))
            threadMessages.insert(contentsOf: page.messages.filter { !ids.contains($0.id) }, at: 0)
            hasMoreThreadMessages = page.hasMoreBefore
            threadErrorMessage = nil
            threadErrorScope = nil
            try await database?.save(messages: page.messages)
        } catch is CancellationError {
            return
        } catch {
            guard openThread?.id == thread.id else { return }
            threadErrorMessage = error.localizedDescription
            threadErrorScope = .earlierPage
        }
    }

    func retryThreadLoad() {
        guard let thread = openThread else { return }
        switch threadErrorScope {
        case .initialPage:
            beginInitialThreadLoad(thread)
        case .earlierPage:
            threadErrorMessage = nil
            threadErrorScope = nil
            Task { [weak self] in
                await self?.loadEarlierThread()
            }
        case .action, nil:
            return
        }
    }

    @discardableResult
    func sendThreadMessage(attachments: [URL] = []) async -> Bool {
        await sendThreadComposerMessage(
            attachments: attachments.map { ForumPostAttachment(url: $0) }
        )
    }

    @discardableResult
    func sendThreadComposerMessage(attachments: [ForumPostAttachment]) async -> Bool {
        guard let thread = openThread, openThreadAccess.canSend else { return false }
        let content = threadDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return false }
        guard validateAttachmentCount(attachments) else { return false }
        return await sendThreadMessage(
            content: content,
            attachments: attachments,
            thread: thread,
            clearsComposer: true
        )
    }

    @discardableResult
    func sendThreadMessage(
        content: String,
        attachments: [ForumPostAttachment],
        thread: MessageThreadSummary,
        clearsComposer: Bool
    ) async -> Bool {
        let draft = SendMessageDraft(
            channelID: thread.id,
            content: content,
            attachments: attachments
        )
        threadErrorMessage = nil
        threadErrorScope = nil
        if clearsComposer {
            threadDraft = ""
        }
        do {
            let message = try await provider.send(draft)
            guard openThread?.id == thread.id else { return true }
            var updated = threadMessages
            updated.removeAll {
                $0.id == message.id || ($0.nonce != nil && $0.nonce == message.nonce)
            }
            Self.insert(message, intoSorted: &updated)
            if updated != threadMessages {
                threadMessages = updated
            }
            try await database?.save(messages: [message])
            completeConversationReadingAndAdvance(channelID: thread.id)
            return true
        } catch {
            guard openThread?.id == thread.id else { return false }
            if clearsComposer, threadDraft.isEmpty {
                threadDraft = content
            }
            threadErrorMessage = error.localizedDescription
            threadErrorScope = .action
            return false
        }
    }

    func updateDraft(_ value: String) {
        draft = value
        if value.hasPrefix("/") || commandComposer.activeCommand != nil {
            stopLocalTyping(clearThrottle: false)
        } else {
            scheduleLocalTyping(for: value)
        }
        guard let channelID = selectedChannelID else { return }
        Task { try? await database?.saveDraft(value, channelID: channelID) }
    }

    func loadApplicationCommands() {
        guard supportedCapabilities.contains(.slashCommands),
              let channel = selectedChannel,
              channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown
        else {
            commandComposer.failLoading(
                ChatProviderError.capabilityDisabled(.slashCommands).localizedDescription
            )
            return
        }
        let contextTarget: ApplicationCommandIndexTarget =
            channel.guildID.map {
                .guild($0)
            } ?? .channel(channel.id)
        let targets: Set<ApplicationCommandIndexTarget> = [contextTarget, .user]
        commandComposer.beginLoading(targets: targets)
        commandLoadTask?.cancel()
        commandLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let context: ApplicationCommandCatalog? =
                    try? provider.applicationCommandCatalog(
                        for: contextTarget
                    )
                async let user: ApplicationCommandCatalog? =
                    try? provider.applicationCommandCatalog(
                        for: .user
                    )
                let catalogs = await [context, user].compactMap(\.self)
                guard !catalogs.isEmpty else {
                    throw ChatProviderError.invalidRequest(
                        "Discord did not return an application command index for this conversation."
                    )
                }
                guard !Task.isCancelled, selectedChannelID == channel.id else { return }
                let roleIDs = Set(
                    (snapshot?.currentUser.id).flatMap { membersByID[$0] }?.roles.map(\.id) ?? []
                )
                commandComposer.replaceCatalogs(
                    catalogs,
                    channel: channel,
                    currentUserID: snapshot?.currentUser.id,
                    memberRoleIDs: roleIDs
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, selectedChannelID == channel.id else { return }
                commandComposer.failLoading(error.localizedDescription)
            }
        }
    }

    func requestApplicationCommandAutocomplete(
        for option: ApplicationCommandOption,
        query: String
    ) {
        guard option.usesAutocomplete, option.type.supportsAutocomplete,
              let channelID = selectedChannelID,
              let invocation = commandComposer.invocation(
                  channelID: channelID, guildID: selectedGuildID
              )
        else { return }
        let request = ApplicationCommandAutocompleteRequest(
            invocation: invocation, focusedOptionID: option.id, query: query
        )
        switch commandComposer.prepareAutocomplete(
            option: option, query: query, nonce: request.nonce
        ) {
        case .cached:
            commandAutocompleteTask?.cancel()
            commandAutocompleteTask = nil
            return
        case .pending:
            return
        case .request:
            commandAutocompleteTask?.cancel()
        }
        commandAutocompleteTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                try await provider.requestApplicationCommandAutocomplete(request)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                commandComposer.failAutocomplete(
                    nonce: request.nonce, message: error.localizedDescription
                )
            }
        }
    }

    func cancelApplicationCommandAutocompleteTask() {
        commandAutocompleteTask?.cancel()
        commandAutocompleteTask = nil
    }

    func requestApplicationCommandMemberSearch(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let option = commandComposer.focusedOption,
              option.type == .user || option.type == .mentionable,
              let guildID = selectedGuildID,
              !normalized.isEmpty
        else {
            cancelApplicationCommandMemberSearch()
            return
        }
        let key = CommandMemberQuery(guildID: guildID, query: normalized.lowercased())
        if let cached = commandMemberSearchCache[key] {
            commandMemberSearchTask?.cancel()
            commandMemberSearchTask = nil
            commandMemberSearchQuery = nil
            commandMemberResults = cached
            return
        }
        guard commandMemberSearchQuery != key else { return }
        commandMemberSearchTask?.cancel()
        commandMemberSearchQuery = key
        commandMemberResults = []
        commandMemberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let results = try await provider.searchMembers(
                    in: guildID, query: normalized, limit: 20
                )
                guard !Task.isCancelled, commandMemberSearchQuery == key,
                      selectedGuildID == guildID
                else { return }
                commandMemberSearchCache[key] = results
                commandMemberResults = results
                commandMemberSearchQuery = nil
                commandMemberSearchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard commandMemberSearchQuery == key else { return }
                commandMemberSearchQuery = nil
                commandMemberSearchTask = nil
                commandMemberResults = []
            }
        }
    }

    func cancelApplicationCommandMemberSearch() {
        commandMemberSearchTask?.cancel()
        commandMemberSearchTask = nil
        commandMemberSearchQuery = nil
        commandMemberResults = []
    }

    func requestMentionMemberSearch(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guildID = selectedGuildID, !normalized.isEmpty else {
            mentionMemberSearchTask?.cancel()
            mentionMemberSearchTask = nil
            mentionMemberSearchQuery = nil
            mentionMemberResults = []
            return
        }
        let key = CommandMemberQuery(guildID: guildID, query: normalized.lowercased())
        if let cached = mentionMemberSearchCache[key],
           Date().timeIntervalSince(cached.storedAt) < 60
        {
            mentionMemberResults = cached.members
            return
        }
        mentionMemberSearchCache[key] = nil
        guard mentionMemberSearchQuery != key else { return }
        mentionMemberSearchTask?.cancel()
        mentionMemberSearchQuery = key
        mentionMemberResults = []
        mentionMemberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                let results = try await provider.searchMembers(
                    in: guildID, query: key.query, limit: 10
                )
                let roles = try? await provider.roles(in: guildID)
                guard !Task.isCancelled, mentionMemberSearchQuery == key,
                      selectedGuildID == guildID
                else { return }
                if let roles { applyGuildRoles(roles, to: guildID) }
                mentionMemberSearchCache[key] = MentionMemberSearchCacheEntry(
                    members: results,
                    storedAt: Date()
                )
                mentionMemberResults = results
                mergeMentionAutocompleteMembers(results)
                for member in results { knownMentionMembers[member.id] = member }
                mentionMemberSearchQuery = nil
            } catch is CancellationError {
                return
            } catch {
                guard mentionMemberSearchQuery == key else { return }
                mentionMemberSearchQuery = nil
                mentionMemberResults = []
            }
        }
    }

    func rememberMentionMember(_ member: Member) {
        knownMentionMembers[member.id] = member
    }

    func mergeMentionAutocompleteMembers(_ updates: [Member]) {
        var positions = Dictionary(
            uniqueKeysWithValues: mentionAutocompleteMembers.indices.map {
                (mentionAutocompleteMembers[$0].id, $0)
            }
        )
        for member in updates {
            if let index = positions[member.id] {
                mentionAutocompleteMembers[index] = member
            } else {
                positions[member.id] = mentionAutocompleteMembers.count
                mentionAutocompleteMembers.append(member)
            }
        }
    }

    func showMembers(withRole roleID: RoleID) {
        roleMemberTask?.cancel()
        roleMemberResult = nil
        roleMemberErrorMessage = nil
        guard let guildID = selectedGuildID else {
            roleMemberErrorMessage = "Role members are only available inside a server."
            return
        }
        isLoadingRoleMembers = true
        roleMemberTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await provider.members(withRole: roleID, in: guildID)
                guard !Task.isCancelled, selectedGuildID == guildID else { return }
                roleMemberResult = result
                for member in result.members { knownMentionMembers[member.id] = member }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                roleMemberErrorMessage = error.localizedDescription
            }
            isLoadingRoleMembers = false
        }
    }

    func executeApplicationCommand() {
        guard commandExecutionTask == nil,
              let channelID = selectedChannelID,
              let invocation = commandComposer.invocation(
                  channelID: channelID, guildID: selectedGuildID
              )
        else { return }
        commandAutocompleteTask?.cancel()
        stopLocalTyping(clearThrottle: true)
        updateDraft("")
        commandExecutionTask = Task { [weak self] in
            guard let self else { return }
            defer { commandExecutionTask = nil }
            do {
                try await provider.executeApplicationCommand(invocation) { [weak self] progress in
                    Task { @MainActor in
                        self?.commandComposer.updateExecutionProgress(progress)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                commandComposer.failExecution(error.localizedDescription)
            }
        }
    }

    func searchGIFs(_ query: String) {
        gifSearchTask?.cancel()
        isLoadingGIFs = true
        gifErrorMessage = nil
        gifSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard await provider.supports(.gifs) else {
                    throw ChatProviderError.capabilityDisabled(.gifs)
                }
                let values =
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? try await provider.trendingGIFs()
                        : try await provider.searchGIFs(query: query)
                guard !Task.isCancelled else { return }
                gifResults = values
                isLoadingGIFs = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                gifResults = []
                gifErrorMessage = error.localizedDescription
                isLoadingGIFs = false
            }
        }
    }

    @discardableResult
    func sendGIF(_ gif: GIFSearchResult) async -> Bool {
        guard selectedChannelID != nil else { return false }
        let priorDraft = draft
        updateDraft(gif.url.absoluteString)
        let sent = await send()
        if !sent {
            updateDraft(priorDraft)
        }
        return sent
    }

    func loadStickersIfNeeded(in guildID: GuildID) {
        guard stickersByGuild[guildID] == nil, stickerLoadTasks[guildID] == nil else { return }
        stickerLoadTasks[guildID] = Task { [weak self] in
            guard let self else { return }
            defer { stickerLoadTasks[guildID] = nil }
            guard await provider.supports(.stickers) else {
                stickersByGuild[guildID] = []
                return
            }
            stickersByGuild[guildID] = await (try? provider.stickers(in: guildID)) ?? []
        }
    }

    @discardableResult
    func sendSticker(_ sticker: MessageSticker) async -> Bool {
        guard let channelID = selectedChannelID, await provider.supports(.stickerSending) else {
            return false
        }
        let draft = SendMessageDraft(channelID: channelID, content: "", stickerIDs: [sticker.id])
        do {
            let message = try await provider.send(draft)
            reconcile(message)
            try await database?.save(messages: [message])
            completeConversationReadingAndAdvance(channelID: channelID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func submitComponent(
        on message: Message, customID: String, kind: ComponentInteractionKind, values: [String] = []
    ) async {
        let key = ComponentControlKey(messageID: message.id, customID: customID)
        guard !pendingComponentControls.contains(key) else { return }
        guard supportedCapabilities.contains(.components) else {
            componentErrors[key] =
                ChatProviderError.capabilityDisabled(.components).localizedDescription
            return
        }
        let submission = ComponentInteractionSubmission(
            messageID: message.id, channelID: message.channelID, guildID: message.guildID,
            applicationID: message.applicationID, customID: customID, kind: kind, values: values
        )
        pendingComponentControls.insert(key)
        componentKeyByNonce[submission.nonce] = key
        componentErrors[key] = nil
        do {
            try await provider.submitComponentInteraction(submission)
        } catch {
            pendingComponentControls.remove(key)
            componentKeyByNonce[submission.nonce] = nil
            componentErrors[key] = error.localizedDescription
        }
    }

    func supportsCapability(_ capability: ChatCapability) -> Bool {
        supportedCapabilities.contains(capability)
    }

    func componentChoices(
        kind: ComponentSelectKind,
        query: String,
        guildID: GuildID?,
        channelID: ChannelID
    ) async throws -> [ComponentSelectOption] {
        guard supportedCapabilities.contains(.remoteComponentChoices) else {
            throw ChatProviderError.capabilityDisabled(
                .remoteComponentChoices
            )
        }
        return Array(
            try await provider.componentChoices(
                kind: kind,
                query: query,
                guildID: guildID,
                channelID: channelID
            ).prefix(25)
        )
    }

    func isComponentPending(messageID: MessageID, customID: String) -> Bool {
        pendingComponentControls.contains(
            ComponentControlKey(messageID: messageID, customID: customID))
    }

    func componentError(for messageID: MessageID) -> String? {
        componentErrors
            .filter { $0.key.messageID == messageID }
            .sorted { $0.key.customID < $1.key.customID }
            .first?.value
    }

    func dismissInteractionModal() {
        presentedInteractionModal = nil
        interactionModalNonce = nil
    }

    func submitModal(values: [String: [String]], fileURLs: [String: [URL]]) async -> Bool {
        guard let modal = presentedInteractionModal, let nonce = interactionModalNonce else {
            return false
        }
        do {
            try await provider.submitModal(
                ModalSubmission(customID: modal.customID, values: values, fileURLs: fileURLs),
                nonce: nonce
            )
            dismissInteractionModal()
            return true
        } catch {
            interactionErrorMessage = error.localizedDescription
            return false
        }
    }

    func scheduleLocalTyping(for value: String) {
        guard !value.isEmpty,
              connectionState == .ready,
              let channel = selectedChannel,
              Self.supportsTyping(channel.kind)
        else {
            stopLocalTyping(clearThrottle: value.isEmpty)
            return
        }
        if localTypingTask != nil, localTypingChannelID == channel.id {
            return
        }
        stopLocalTyping(clearThrottle: false)
        localTypingGeneration &+= 1
        let generation = localTypingGeneration
        localTypingChannelID = channel.id
        let now = Date.now
        let debounce = Self.seconds(localTypingTiming.debounce)
        let remainingThrottle =
            lastTypingRequestAt[channel.id]
                .map { max(0, Self.seconds(localTypingTiming.throttle) - now.timeIntervalSince($0)) }
                ?? 0
        let delay = max(debounce, remainingThrottle)
        localTypingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.performLocalTyping(channelID: channel.id, generation: generation)
        }
    }

    func performLocalTyping(channelID: ChannelID, generation: UInt64) async {
        guard generation == localTypingGeneration,
              localTypingChannelID == channelID,
              selectedChannelID == channelID,
              !draft.isEmpty,
              connectionState == .ready,
              let selectedChannel,
              Self.supportsTyping(selectedChannel.kind)
        else { return }
        localTypingTask = nil
        localTypingChannelID = nil
        // Count the attempt, not only a successful response. A failed mutation is
        // not immediately retried by subsequent keystrokes.
        lastTypingRequestAt[channelID] = .now
        do {
            try await provider.sendTyping(in: channelID)
        } catch is CancellationError {
            return
        } catch {
            // Typing is best-effort. The shared provider still applies its safety
            // circuit and mutation retry rules; composer input remains available.
        }
    }

    func stopLocalTyping(clearThrottle: Bool) {
        localTypingGeneration &+= 1
        localTypingTask?.cancel()
        localTypingTask = nil
        if clearThrottle {
            if let localTypingChannelID {
                lastTypingRequestAt[localTypingChannelID] = nil
            }
            if let selectedChannelID {
                lastTypingRequestAt[selectedChannelID] = nil
            }
        }
        localTypingChannelID = nil
    }

    static func supportsTyping(_ kind: ChannelKindValue) -> Bool {
        switch kind {
        case .text, .announcement, .directMessage, .groupDirectMessage: true
        case .forum, .voice, .unknown: false
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    @discardableResult
    func send(attachments: [URL] = []) async -> Bool {
        await sendComposerMessage(
            attachments: attachments.map { ForumPostAttachment(url: $0) }
        )
    }

    @discardableResult
    func sendComposerMessage(attachments: [ForumPostAttachment]) async -> Bool {
        guard let channelID = selectedChannelID, selectedConversationAccess.canSend else {
            return false
        }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return false }
        guard validateAttachmentCount(attachments) else { return false }
        let replyTo = replyingTo?.id
        let replyPreview = replyingTo.map {
            MessageReplyPreview(message: $0)
        }
        return await sendChannelMessage(
            channelID: channelID,
            content: content,
            replyTo: replyTo,
            replyPreview: replyPreview,
            attachments: attachments,
            clearsComposer: true
        )
    }

    @discardableResult
    func sendChannelMessage(
        channelID: ChannelID,
        content: String,
        replyTo: MessageID?,
        replyPreview: MessageReplyPreview?,
        attachments: [ForumPostAttachment],
        clearsComposer: Bool
    ) async -> Bool {
        let outgoing = SendMessageDraft(
            channelID: channelID, content: content, replyTo: replyTo, attachments: attachments
        )
        if clearsComposer {
            stopLocalTyping(clearThrottle: true)
        }
        let optimistic = Message(
            id: MessageID(rawValue: UInt64.max - UInt64(messages.count)), channelID: channelID,
            author: snapshot?.currentUser
                ?? User(id: UserID(rawValue: 1), username: "me", displayName: "Me"),
            content: content, replyTo: replyTo, replyPreview: replyPreview,
            attachments: attachments.enumerated().map {
                var presentation = OptimisticAttachmentPresentation.attachment(
                    for: $0.element.url,
                    index: $0.offset
                )
                presentation.filename = $0.element.filename
                presentation.description = $0.element.description
                presentation.isSpoiler = $0.element.isSpoiler
                return presentation
            }, nonce: outgoing.nonce, outboxState: .sending
        )
        appendSelectedMessage(optimistic)
        outgoingDraftsByNonce[outgoing.nonce] = outgoing
        if clearsComposer {
            replyingTo = nil
            updateDraft("")
        }
        let didSend = await performOutgoingSend(outgoing, isRetry: false)
        if didSend {
            completeConversationReadingAndAdvance(channelID: channelID)
        }
        return didSend
    }

    func composerAttachments(
        for destination: MessageComposerDestination
    ) -> [ForumPostAttachment] {
        switch destination {
        case .channel: channelComposerAttachments
        case .thread: threadComposerAttachments
        }
    }

    func isComposerDropEligible(_ destination: MessageComposerDestination) -> Bool {
        switch destination {
        case .channel:
            guard commandComposer.activeCommand == nil,
                  selectedConversationAccess.canSend,
                  let kind = selectedChannel?.kind
            else { return false }
            return Self.supportsTyping(kind)
        case .thread:
            return openThread != nil && openThreadAccess.canSend
        }
    }

    @discardableResult
    func addComposerAttachments(
        _ urls: [URL],
        to destination: MessageComposerDestination
    ) -> Bool {
        guard isComposerDropEligible(destination), !urls.isEmpty else { return false }
        var attachments = composerAttachments(for: destination)
        var seen = Set(attachments.map(\.url.standardizedFileURL))
        let unique = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        let remaining = max(0, SendMessageDraft.maximumAttachmentCount - attachments.count)
        attachments.append(
            contentsOf: unique.prefix(remaining).map { ForumPostAttachment(url: $0) }
        )
        setComposerAttachments(attachments, for: destination)
        if unique.count > remaining {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
        }
        return remaining > 0 && !unique.isEmpty
    }

    func removeComposerAttachment(
        _ url: URL,
        from destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        attachments.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        setComposerAttachments(attachments, for: destination)
    }

    func updateComposerAttachment(
        _ attachment: ForumPostAttachment,
        in destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        guard let index = attachments.firstIndex(where: { $0.url == attachment.url }) else {
            return
        }
        attachments[index] = attachment
        setComposerAttachments(attachments, for: destination)
    }

    func toggleComposerAttachmentSpoiler(
        _ url: URL,
        in destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        guard let index = attachments.firstIndex(where: { $0.url == url }) else { return }
        attachments[index].isSpoiler.toggle()
        setComposerAttachments(attachments, for: destination)
    }

    func clearComposerAttachments(for destination: MessageComposerDestination) {
        setComposerAttachments([], for: destination)
    }

    func restoreComposerAttachments(
        _ restoredAttachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) {
        let current = composerAttachments(for: destination)
        var seen = Set(current.map(\.url.standardizedFileURL))
        let restored = restoredAttachments.filter {
            seen.insert($0.url.standardizedFileURL).inserted
        }
        setComposerAttachments(
            Array((restored + current).prefix(SendMessageDraft.maximumAttachmentCount)),
            for: destination
        )
    }

    @discardableResult
    func sendAttachmentsImmediately(
        _ attachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) async -> Bool {
        guard isComposerDropEligible(destination), !attachments.isEmpty,
              validateAttachmentCount(attachments)
        else { return false }
        switch destination {
        case .channel:
            guard let channelID = selectedChannelID else { return false }
            return await sendChannelMessage(
                channelID: channelID,
                content: "",
                replyTo: nil,
                replyPreview: nil,
                attachments: attachments,
                clearsComposer: false
            )
        case .thread:
            guard let thread = openThread else { return false }
            return await sendThreadMessage(
                content: "",
                attachments: attachments,
                thread: thread,
                clearsComposer: false
            )
        }
    }

    func setComposerAttachments(
        _ attachments: [ForumPostAttachment],
        for destination: MessageComposerDestination
    ) {
        switch destination {
        case .channel:
            channelComposerAttachments = attachments
        case .thread:
            threadComposerAttachments = attachments
        }
    }

    func validateAttachmentCount(_ attachments: [ForumPostAttachment]) -> Bool {
        guard attachments.count <= SendMessageDraft.maximumAttachmentCount else {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
            return false
        }
        return true
    }

    @discardableResult
    func retrySending(_ message: Message) async -> Bool {
        guard message.outboxState == .failed,
              let nonce = message.nonce,
              outgoingState(nonce: nonce, channelID: message.channelID) == .failed
        else { return false }
        let outgoing =
            outgoingDraftsByNonce[nonce]
                ?? SendMessageDraft(
                    channelID: message.channelID,
                    content: message.content,
                    replyTo: message.replyTo,
                    attachmentURLs: message.attachments.map(\.url),
                    nonce: nonce,
                    stickerIDs: message.stickers.map(\.id)
                )
        outgoingDraftsByNonce[nonce] = outgoing
        updateOutgoingState(.sending, nonce: nonce, channelID: message.channelID)
        return await performOutgoingSend(outgoing, isRetry: true)
    }

    func performOutgoingSend(_ outgoing: SendMessageDraft, isRetry: Bool) async -> Bool {
        Self.messageSendLogger.info(
            """
            Message send started channel=\(outgoing.channelID.description, privacy: .public) \
            nonce=\(outgoing.nonce, privacy: .public) attachments=\(outgoing.attachmentURLs.count) \
            stickers=\(outgoing.stickerIDs.count) retry=\(isRetry)
            """
        )
        do {
            let confirmed = try await provider.send(outgoing)
            reconcileVisibleOrCached(confirmed)
            outgoingDraftsByNonce[outgoing.nonce] = nil
            do {
                try await database?.save(messages: [confirmed])
            } catch {
                let nsError = error as NSError
                Self.messageSendLogger.warning(
                    """
                    Message sent but local persistence failed \
                    channel=\(outgoing.channelID.description, privacy: .public) \
                    message=\(confirmed.id.description, privacy: .public) \
                    errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code)
                    """
                )
            }
            Self.messageSendLogger.info(
                """
                Message send succeeded channel=\(outgoing.channelID.description, privacy: .public) \
                nonce=\(outgoing.nonce, privacy: .public) \
                message=\(confirmed.id.description, privacy: .public) retry=\(isRetry)
                """
            )
            return true
        } catch {
            let state: OutboxState
            if (error as? URLError)?.code == .timedOut {
                state = .awaitingReconciliation
                updateOutgoingState(state, nonce: outgoing.nonce, channelID: outgoing.channelID)
            } else {
                state = .failed
                outgoingDraftsByNonce[outgoing.nonce] = nil
                removeOutgoingMessage(nonce: outgoing.nonce, channelID: outgoing.channelID)
            }
            errorMessage = error.localizedDescription
            let nsError = error as NSError
            Self.messageSendLogger.error(
                """
                Message send failed channel=\(outgoing.channelID.description, privacy: .public) \
                nonce=\(outgoing.nonce, privacy: .public) state=\(state.rawValue, privacy: .public) \
                retry=\(isRetry) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code) \
                details=\(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return false
        }
    }
}
