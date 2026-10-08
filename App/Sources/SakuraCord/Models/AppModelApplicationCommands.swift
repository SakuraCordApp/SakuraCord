import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func loadApplicationCommands(in destination: MessageComposerDestination = .channel) {
        let commandComposer = commandComposer(for: destination)
        guard supportedCapabilities.contains(.slashCommands),
              let context = commandContext(for: destination)
        else {
            commandComposer.failLoading(
                ChatProviderError.capabilityDisabled(.slashCommands).localizedDescription
            )
            return
        }
        let channel = context.channel
        let generation = commandComposer.conversationGeneration
        let contextTarget = ApplicationCommandAvailability.contextIndexTarget(for: channel)
        let targets = Set([contextTarget, .user].compactMap { $0 })
        commandComposer.beginLoading(targets: targets)
        commandComposer.locale = Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
        loadCommandFrecencyIfNeeded()
        commandComposer.loadTask?.cancel()
        let account = accountSession()
        commandComposer.loadTask = Task { [weak self] in
            guard let self,
                  !Task.isCancelled,
                  isCurrentAccountSession(account)
            else { return }
            do {
                async let contextCatalog: ApplicationCommandCatalog? = {
                    guard let contextTarget else { return nil }
                    return try? await account.provider.applicationCommandCatalog(for: contextTarget)
                }()
                async let user: ApplicationCommandCatalog? =
                    try? account.provider.applicationCommandCatalog(
                        for: .user
                    )
                let catalogs = await [contextCatalog, user].compactMap(\.self)
                guard !catalogs.isEmpty else {
                    throw ChatProviderError.invalidRequest(
                        "Discord did not return an application command index for this conversation."
                    )
                }
                guard !Task.isCancelled,
                      isCurrentAccountSession(account),
                      commandContext(for: destination)?.channelID == context.channelID,
                      commandComposer.conversationGeneration == generation
                else { return }
                let roleIDs = Set(
                    (snapshot?.currentUser.id).flatMap { membersByID[$0] }?.roles.map(\.id) ?? []
                )
                commandComposer.replaceCatalogs(
                    catalogs,
                    channel: channel,
                    currentUserID: snapshot?.currentUser.id,
                    memberRoleIDs: roleIDs,
                    builtInContext: builtInCommandContext(for: channel, in: destination)
                )
                commandComposer.refreshApplicationIdentities { membersByID[$0]?.user }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(account),
                      commandContext(for: destination)?.channelID == context.channelID,
                      commandComposer.conversationGeneration == generation
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                commandComposer.failLoading(error.localizedDescription)
            }
        }
    }

    /// Requests remote choices for the focused field when its query changed.
    /// Discord answers through the Gateway; results correlate by nonce.
    func refreshApplicationCommandAutocomplete(in destination: MessageComposerDestination = .channel) {
        let commandComposer = commandComposer(for: destination)
        guard let context = commandContext(for: destination) else { return }
        let request = commandComposer.autocompleteRequest(channelID: context.channelID, guildID: context.channel.guildID)
        if let nonce = commandComposer.autocompleteDebounceNonce,
           !commandComposer.isAutocompleteRequestCurrent(nonce) {
            cancelApplicationCommandAutocompleteTask(in: destination, resetTiming: false)
        }
        guard let request else { return }
        let session = accountSession()
        // Discord's desktop picker uses a 500 ms leading/trailing debounce:
        // an isolated query starts immediately, a burst sends its latest value
        // after typing settles. Keep dispatched requests alive for nonce routing.
        let now = ContinuousClock.now
        let delay: Duration = commandComposer.autocompleteLastQueryTime.map {
            $0.duration(to: now) < .milliseconds(500) ? .milliseconds(500) : .zero
        } ?? .zero
        commandComposer.autocompleteLastQueryTime = now
        commandComposer.autocompleteDebounceNonce = request.nonce
        commandComposer.autocompleteTask = startAccountChildTask(account: session) { model, session in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                guard commandComposer.isAutocompleteRequestCurrent(request.nonce) else {
                    commandComposer.abandonAutocomplete(nonce: request.nonce, message: "")
                    return
                }
                commandComposer.autocompleteDebounceNonce = nil
                commandComposer.autocompleteTask = nil
                try await AppPerformanceSignposts.measure("CommandAutocompleteRequest") {
                    try await session.provider.requestApplicationCommandAutocomplete(request)
                }
            } catch is CancellationError {
                guard model.isCurrentAccountSession(session) else { return }
                commandComposer.abandonAutocomplete(nonce: request.nonce, message: "")
                return
            } catch {
                guard model.isCurrentAccountSession(session) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                commandComposer.abandonAutocomplete(
                    nonce: request.nonce, message: "Loading options failed"
                )
            }
        }
    }

    func cancelApplicationCommandAutocompleteTask(in destination: MessageComposerDestination = .channel, resetTiming: Bool = true) {
        let commandComposer = commandComposer(for: destination)
        if resetTiming { commandComposer.autocompleteLastQueryTime = nil }
        commandComposer.autocompleteTask?.cancel()
        commandComposer.autocompleteTask = nil
        if let nonce = commandComposer.autocompleteDebounceNonce {
            commandComposer.abandonAutocomplete(nonce: nonce, message: "")
        }
        commandComposer.autocompleteDebounceNonce = nil
    }

    func requestApplicationCommandMemberSearch(query: String, in destination: MessageComposerDestination = .channel) {
        let commandComposer = commandComposer(for: destination)
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let option = commandComposer.draft?.focusedField?.option,
              option.type == .user || option.type == .mentionable,
              let guildID = commandContext(for: destination)?.channel.guildID,
              !normalized.isEmpty
        else {
            cancelApplicationCommandMemberSearch(in: destination)
            return
        }
        let key = CommandMemberQuery(guildID: guildID, query: normalized.lowercased())
        if let cached = commandComposer.memberSearchCache[key] {
            commandComposer.memberSearchTask?.cancel()
            commandComposer.memberSearchTask = nil
            commandComposer.memberSearchQuery = nil
            commandComposer.memberResults = cached
            return
        }
        guard commandComposer.memberSearchQuery != key else { return }
        commandComposer.memberSearchTask?.cancel()
        commandComposer.memberSearchQuery = key
        commandComposer.memberResults = []
        let session = accountSession()
        commandComposer.memberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let results = try await session.provider.searchMembers(
                    in: guildID, query: normalized, limit: 20
                )
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      commandComposer.memberSearchQuery == key,
                      commandContext(for: destination)?.channel.guildID == guildID
                else { return }
                commandComposer.memberSearchCache[key] = results
                commandComposer.memberResults = results
                commandComposer.memberSearchQuery = nil
                commandComposer.memberSearchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isCurrentAccountSession(session),
                      commandComposer.memberSearchQuery == key
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                commandComposer.memberSearchQuery = nil
                commandComposer.memberSearchTask = nil
                commandComposer.memberResults = []
            }
        }
    }

    func cancelApplicationCommandMemberSearch(in destination: MessageComposerDestination = .channel) {
        let commandComposer = commandComposer(for: destination)
        commandComposer.memberSearchTask?.cancel()
        commandComposer.memberSearchTask = nil
        commandComposer.memberSearchQuery = nil
        commandComposer.memberResults = []
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
            mentionMemberSearchTask?.cancel()
            mentionMemberSearchTask = nil
            mentionMemberSearchQuery = nil
            mentionMemberResults = cached.members
            return
        }
        mentionMemberSearchCache[key] = nil
        guard mentionMemberSearchQuery != key else { return }
        mentionMemberSearchTask?.cancel()
        mentionMemberSearchQuery = key
        mentionMemberResults = []
        let session = accountSession()
        mentionMemberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                let results = try await session.provider.searchMembers(
                    in: guildID, query: key.query, limit: 10
                )
                let roles = try? await session.provider.roles(in: guildID)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      mentionMemberSearchQuery == key,
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
                guard isCurrentAccountSession(session),
                      mentionMemberSearchQuery == key
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
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

    func showMembers(withRole roleID: RoleID, in guildID: GuildID?) {
        roleMemberTask?.cancel()
        roleMemberResult = nil
        roleMemberErrorMessage = nil
        isLoadingRoleMembers = false
        guard let guildID else {
            roleMemberErrorMessage = "Role members are only available inside a server."
            return
        }
        isLoadingRoleMembers = true
        let session = accountSession()
        roleMemberTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.provider.members(withRole: roleID, in: guildID)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                roleMemberResult = result
                for member in result.members {
                    membersByGuildID[guildID, default: [:]][member.id] = member
                    if selectedGuildID == guildID { knownMentionMembers[member.id] = member }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                roleMemberErrorMessage = error.localizedDescription
            }
            if isCurrentAccountSession(session) {
                isLoadingRoleMembers = false
            }
        }
    }

    /// Sends the composed command. Like Discord, the composer clears at once
    /// and a private placeholder row tracks the app's answer.
    func executeApplicationCommand(in destination: MessageComposerDestination = .channel) {
        AppPerformanceSignposts.measureSync("CommandSubmit") { submitApplicationCommand(in: destination) }
    }

    private func submitApplicationCommand(in destination: MessageComposerDestination) {
        let commandComposer = commandComposer(for: destination)
        guard let context = commandContext(for: destination),
              let channelID = composerSendChannelID(in: destination),
              commandComposer.prepareSubmission(),
              let invocation = commandComposer.invocation(
                  channelID: channelID, guildID: context.channel.guildID
              )
        else { return }
        let isBuiltIn = DiscordBuiltInCommands.isBuiltIn(invocation.command)
        let isNicknameChange = isBuiltIn && invocation.command.name == "nick"
        guard isNicknameChange || allowSlowmodeSubmission(in: channelID) else { return }
        if isBuiltIn, Self.builtInMessageText(command: invocation.command.name, message: "") != nil {
            guard allowOutgoingQueueSubmission() else { return }
        }
        cancelApplicationCommandAutocompleteTask(in: destination)
        let submittedDraft = commandComposer.draft
        stopLocalTyping(clearThrottle: true)
        commandComposer.recordUse(of: invocation.command, guildID: invocation.guildID)
        for composer in commandComposers where composer !== commandComposer { composer.refreshFrecency() }
        commandComposer.cancelActiveCommand()
        switch destination {
        case .channel: updateDraft("")
        case .thread: updateThreadDraft("")
        }
        if DiscordBuiltInCommands.isBuiltIn(invocation.command) {
            runBuiltInCommand(invocation)
        } else {
            runApplicationCommand(invocation, restoringDraftOnFailure: submittedDraft, in: destination)
        }
    }

    /// Runs a user or message context-menu command against its target.
    func runContextMenuCommand(_ command: ApplicationCommand, targetID: String, in channelID: ChannelID) {
        guard supportedCapabilities.contains(.slashCommands) else { return }
        let destination = commandDestination(in: channelID)
        let guildID = (openThread?.id == channelID ? openThread?.guildID ?? openThreadParentChannel?.guildID : nil)
            ?? visibleChannels.first { $0.id == channelID }?.guildID
            ?? snapshot?.channels.first { $0.id == channelID }?.guildID
        let commandComposer = commandComposer(for: destination)
        commandComposer.recordUse(of: command, guildID: guildID)
        for composer in commandComposers where composer !== commandComposer { composer.refreshFrecency() }
        runApplicationCommand(ApplicationCommandInvocation(
            command: command, channelID: channelID, guildID: guildID, values: [], targetID: targetID
        ), in: destination)
    }

    private func runApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        restoringDraftOnFailure submittedDraft: ApplicationCommandDraft? = nil,
        in destination: MessageComposerDestination = .channel
    ) {
        let commandComposer = commandComposer(for: destination)
        let generation = commandComposer.conversationGeneration
        let nonce = invocation.nonce
        let channelID = invocation.channelID
        trackInteraction(
            PendingInteractionRecord(kind: .command(
                channelID: channelID,
                commandName: invocation.command.displayName,
                application: invocation.command.application
            )),
            nonce: nonce
        )
        appendInteractionPlaceholder(for: invocation)
        let session = accountSession()
        let attachmentURLs = invocation.values.compactMap { value -> URL? in
            guard case let .attachment(url) = value.argument else { return nil }
            return url
        }
        // Lease before yielding: changing channels may prune the cleared draft.
        beginUsingOwnedPromisedFiles(attachmentURLs)
        startAccountChildTask(account: session) { [weak self] _, session in
            guard let self else { return }
            let uploadsAttachments = !attachmentURLs.isEmpty
            if uploadsAttachments { activeAttachmentUploadCount += 1 }
            defer { if uploadsAttachments { activeAttachmentUploadCount -= 1 } }
            let scoped = attachmentURLs.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                endUsingOwnedPromisedFiles(attachmentURLs)
            }
            do {
                try await session.provider.executeApplicationCommand(invocation) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCurrentAccountSession(session) else { return }
                        self.updateInteractionPlaceholder(
                            nonce: nonce, channelID: channelID, progress: progress
                        )
                    }
                }
                guard isCurrentAccountSession(session) else { return }
                for value in invocation.values {
                    if case let .string(text) = value.argument { recordMessageEmojiUsage(text) }
                }
                startInteractionDeadline(nonce: nonce)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccountSession(session), finishPendingInteraction(nonce) != nil else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                // A definite request failure is final; it is never replayed.
                failInteractionPlaceholder(
                    nonce: nonce, channelID: channelID, message: error.localizedDescription
                )
                // Keep failed input available for editing without replacing a
                // newer draft or automatically repeating the account action.
                if let submittedDraft, commandContext(for: destination)?.channelID == channelID,
                   commandComposer.conversationGeneration == generation,
                   (destination == .thread ? threadDraft : draft).isEmpty, commandComposer.draft == nil {
                    commandComposer.activate(submittedDraft.command)
                    commandComposer.applyEditorDraft(submittedDraft, caret: nil)
                }
            }
        }
    }

    /// Context-menu commands need the same catalogues as the slash picker.
    func ensureApplicationCommandsLoaded(in destination: MessageComposerDestination = .channel) {
        let commandComposer = commandComposer(for: destination)
        guard !commandComposer.hasLoadedCatalogs, !commandComposer.isLoading else { return }
        loadApplicationCommands(in: destination)
    }

    /// What decides which Discord built-ins this conversation offers.
    func builtInCommandContext(for channel: Channel, in destination: MessageComposerDestination = .channel) -> DiscordBuiltInCommands.Context {
        let channelPermissions = effectiveMessagePermissions(in: channel)
        let guildPermissions = channel.guildID.flatMap { guildID -> UInt64? in
            guard let basis = conversationPermissionBasis(for: guildID) else { return nil }
            return basis.guild.isOwnedByCurrentUser == true ? .max : basis.resolvedBasePermissions
        }
        let createPublicThreads: UInt64 = 1 << 35
        let threadable = channel.kind == .text || channel.kind == .announcement
        let canCreateThread = threadable && channel.guildID != nil
            && (channelPermissions.map { $0 & (createPublicThreads | DiscordBuiltInCommands.Permission.administrator) != 0 } ?? false)
        return DiscordBuiltInCommands.Context(
            isPrivate: channel.guildID == nil,
            isGroupDirectMessage: channel.kind == .groupDirectMessage,
            channelPermissions: channelPermissions,
            guildPermissions: guildPermissions,
            canCreatePublicThread: destination == .channel && canCreateThread,
            allowsTTSCommand: true
        )
    }

    // MARK: Discord built-ins

    /// Runs one of Discord's client-side commands the way the official client
    /// does: most become an ordinary message; none reach an application.
    func runBuiltInCommand(_ invocation: ApplicationCommandInvocation) {
        let session = accountSession()
        let channelID = invocation.channelID
        func string(_ name: String) -> String {
            for value in invocation.values where value.name == name {
                if case let .string(text) = value.argument { return text }
            }
            return ""
        }
        func user(_ name: String) -> UserID? {
            for value in invocation.values where value.name == name {
                if case let .user(id) = value.argument { return id }
            }
            return nil
        }
        let message = string("message")
        if let text = Self.builtInMessageText(command: invocation.command.name, message: message) {
            _ = enqueueChannelMessage(
                channelID: channelID, content: text, replyTo: nil, replyPreview: nil,
                attachments: [], clearsComposer: false, isTTS: invocation.command.name == "tts"
            )
            return
        }
        switch invocation.command.name {
        case "nick":
            runNicknameCommand(string("new_nick"), invocation: invocation)
        case "msg":
            guard let recipient = user("user") else { return }
            startAccountChildTask(account: session) { [weak self] _, session in
                do {
                    let channel = try await session.provider.ensurePrivateChannel(for: recipient)
                    guard let self, !Task.isCancelled, isCurrentAccountSession(session) else { return }
                    _ = try await session.provider.send(SendMessageDraft(channelID: channel.id, content: message))
                    recordMessageEmojiUsage(message, session: session)
                } catch {
                    guard let self, isCurrentAccountSession(session) else { return }
                    appendBuiltInNotice("Your message could not be delivered.", in: channelID)
                }
            }
        case "thread":
            let name = string("name")
            startAccountChildTask(account: session) { [weak self] _, session in
                do {
                    let thread = try await session.provider.createThread(CreateThreadDraft(channelID: channelID, name: name))
                    guard let self, !Task.isCancelled, isCurrentAccountSession(session) else { return }
                    _ = try await session.provider.send(SendMessageDraft(channelID: thread.id, content: message))
                    recordMessageEmojiUsage(message, session: session)
                } catch {
                    guard let self, isCurrentAccountSession(session) else { return }
                    appendBuiltInNotice("The thread could not be created.", in: channelID)
                }
            }
        case "gif":
            builtInExpressionPickerRequest = BuiltInExpressionPickerRequest(channelID: channelID, kind: .gif, query: string("query"))
        case "sticker":
            builtInExpressionPickerRequest = BuiltInExpressionPickerRequest(channelID: channelID, kind: .sticker, query: string("query"))
        default:
            appendBuiltInNotice("/\(invocation.command.name) isn’t available in SakuraCord yet.", in: channelID)
        }
    }

    private func runNicknameCommand(_ nickname: String, invocation: ApplicationCommandInvocation) {
        guard let guildID = invocation.guildID else { return }
        let session = accountSession()
        let channelID = invocation.channelID
        startAccountChildTask(account: session) { [weak self] _, session in
            do {
                let saved = try await session.provider.setNickname(nickname, in: guildID)
                guard let self, !Task.isCancelled, isCurrentAccountSession(session) else { return }
                appendBuiltInNotice(saved.map { "Your nickname has been changed to \($0)." }
                    ?? "Your nickname has been reset.", in: channelID, isFailure: false)
            } catch is CancellationError {
                return
            } catch {
                guard let self, isCurrentAccountSession(session) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                appendBuiltInNotice("Nickname change: \(error.localizedDescription)", in: channelID)
            }
        }
    }

    /// The message Discord's text built-ins send, or nil for other built-ins.
    static func builtInMessageText(command: String, message: String) -> String? {
        switch command {
        case "shrug": "\(message) ¯\\_(ツ)_/¯".trimmingCharacters(in: .whitespacesAndNewlines)
        case "tableflip": "\(message) (╯°□°)╯︵ ┻━┻".trimmingCharacters(in: .whitespacesAndNewlines)
        case "unflip": "\(message) ┬─┬ノ( º _ ºノ)".trimmingCharacters(in: .whitespacesAndNewlines)
        case "me": "_\(message)_"
        case "spoiler": "||\(message)||"
        case "tts": message
        default: nil
        }
    }

    /// A private notice from a built-in, like Discord's local bot messages.
    func appendBuiltInNotice(_ text: String, in channelID: ChannelID, isFailure: Bool = true) {
        appendInteractionNotice(
            nonce: ClientNonce.make(), channelID: channelID, application: DiscordBuiltInCommands.application,
            commandName: nil, message: text, isFailure: isFailure
        )
    }
}

struct BuiltInExpressionPickerRequest: Equatable {
    enum Kind { case gif, sticker }
    var channelID: ChannelID
    var kind: Kind
    var query: String
    var id = UUID()
}
