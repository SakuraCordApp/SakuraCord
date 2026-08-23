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
    func logReadAcknowledgementSending(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        let channel = channelID.rawValue
        let message = mutation.messageID.rawValue
        Self.unreadDiagnosticsLogger.info(
            "Read ack send c=\(channel, privacy: .public) m=\(message, privacy: .public) manual=\(mutation.manual, privacy: .public)"
        )
    }

    func logReadAcknowledgementAccepted(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        let channel = channelID.rawValue
        let message = mutation.messageID.rawValue
        Self.unreadDiagnosticsLogger.info(
            "Read ack accepted c=\(channel, privacy: .public) m=\(message, privacy: .public)"
        )
    }

    func logReadAcknowledgementFailed(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        let channel = channelID.rawValue
        let message = mutation.messageID.rawValue
        Self.unreadDiagnosticsLogger.error(
            "Read ack failed c=\(channel, privacy: .public) m=\(message, privacy: .public) manual=\(mutation.manual, privacy: .public)"
        )
    }

    func readStateMutation(
        channelID: ChannelID,
        messageID: MessageID,
        manual: Bool,
        mentionCount: Int?
    ) -> ReadStateMutation {
        let metadata = readState.acknowledgementMetadata(channelID: channelID)
        return ReadStateMutation(
            messageID: messageID,
            manual: manual,
            mentionCount: mentionCount,
            flags: metadata.flags,
            lastViewed: metadata.lastViewed
        )
    }

    func resetAcknowledgementWork() {
        acknowledgementGeneration &+= 1
        acknowledgementTasks.values.forEach { $0.cancel() }
        acknowledgementTasks.removeAll()
        acknowledgementProcessorTask?.cancel()
        acknowledgementProcessorTask = nil
        guildAcknowledgementTasks.values.forEach { $0.cancel() }
        guildAcknowledgementTasks.removeAll()
        categoryAcknowledgementTasks.values.forEach { $0.cancel() }
        categoryAcknowledgementTasks.removeAll()
        queuedAcknowledgements.removeAll()
        acknowledgementQueueOrder.removeAll()
    }

    func resetChannelNotificationMutations() {
        channelNotificationMutationGeneration &+= 1
        guildNotificationMutationTasks.values.forEach { $0.cancel() }
        guildNotificationMutationTasks.removeAll()
        channelNotificationMutationTasks.values.forEach { $0.cancel() }
        channelNotificationMutationTasks.removeAll()
        categoryCollapseMutationTasks.values.forEach { $0.cancel() }
        categoryCollapseMutationTasks.removeAll()
        categoryCollapseMutationStates.removeAll()
        optimisticCategoryCollapsedByID.removeAll()
        forumNotificationMutationGeneration &+= 1
        forumNotificationMutationTasks.values.forEach { $0.cancel() }
        forumNotificationMutationTasks.removeAll()
    }

    func deliverNativeNotification(for message: Message) {
        // The offline timeline benchmark measures event ingestion, layout,
        // drawing, and scroll scheduling. Enqueuing thousands of synthetic
        // UNUserNotificationCenter requests measures an unrelated XPC queue
        // and eventually starves the main run loop in periodic bursts.
        guard !runsChatPerformanceBenchmark else { return }
        guard !readState.isActivelyPresentedAtNewest(message.channelID) else { return }
        let channel =
            snapshot?.channels.first { $0.id == message.channelID }
                ?? visibleChannels.first { $0.id == message.channelID }
        let guildID = message.guildID ?? channel?.guildID
        let guild = guildID.flatMap { serverRailGuildsByID[$0] }
        let accountID = readState.accountID ?? "offline"
        if notificationPreferences.isEnabled,
           notificationPreferences.playsSound,
           !notificationPreferences.isQuiet()
        {
            // Apple's notification sound facility does not support MP3. Play
            // Discord's exact message asset through the same retained audio
            // path as the voice sounds, and let Notification Center own only
            // the banner/list presentation.
            soundPlayer.play(.message)
        }
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            await model.notificationService.deliver(
                message: message,
                channel: channel,
                guild: guild,
                accountID: accountID,
                preferences: model.notificationPreferences
            )
        }
    }

    func cancelNativeNotifications(channelID: ChannelID) {
        guard !runsChatPerformanceBenchmark else { return }
        let accountID = readState.accountID ?? "offline"
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            await model.notificationService.cancel(
                accountID: accountID,
                channelID: channelID
            )
        }
    }

    func consume(_ event: ClientEvent) async {
        if case let .messageCreated(message) = event {
            let preparedTextPlan: NativeTimelineTextPlan? =
                if message.channelID == selectedChannelID {
                    await Task.detached(priority: .utility) {
                        NativeTimelineTextPlan.make(for: message)
                    }.value
                } else {
                    nil
                }
            guard !Task.isCancelled else { return }
            pendingCreatedMessages.append(
                PreparedCreatedMessage(
                    message: message,
                    textPlan: preparedTextPlan
                )
            )
            guard createdMessageFlushTask == nil else { return }
            createdMessageFlushTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return
                }
                self?.flushPendingCreatedMessages(
                    maximumCount: self?.maximumCreatedMessagesPerFlush ?? 4
                )
            }
            return
        }
        flushPendingCreatedMessages()
        let preparedTextPlan: NativeTimelineTextPlan? =
            if case let .messageUpdated(message) = event,
               message.channelID == selectedChannelID
            {
                await Task.detached(priority: .userInitiated) {
                    NativeTimelineTextPlan.make(for: message)
                }.value
            } else {
                nil
        }
        let preparedMemberListPresentation: PreparedMemberListPresentation? =
            if case let .membersChanged(guildID, members, groups) = event,
               guildID == selectedGuildID
            {
                await AppPerformanceSignposts.measure(
                    "MemberListEventPreparation"
                ) {
                    let roles = guildRoles
                    let priority: TaskPriority = AppScrollWorkGate.isActive
                        ? .background
                        : .utility
                    return await Task.detached(priority: priority) {
                        PreparedMemberListPresentation.make(
                            guildID: guildID,
                            members: members,
                            groups: groups,
                            roles: roles
                        )
                    }.value
                }
            } else {
                nil
            }
        guard !Task.isCancelled else { return }
        consumeImmediately(
            event,
            preparedTextPlan: preparedTextPlan,
            preparedMemberListPresentation: preparedMemberListPresentation
        )
    }

    func flushPendingCreatedMessages(
        maximumCount: Int = .max
    ) {
        guard !pendingCreatedMessages.isEmpty else {
            createdMessageFlushTask = nil
            return
        }
        createdMessageFlushTask?.cancel()
        createdMessageFlushTask = nil
        let flushCount = min(
            max(1, maximumCount),
            pendingCreatedMessages.count
        )
        let pending = Array(pendingCreatedMessages.prefix(flushCount))
        pendingCreatedMessages.removeFirst(flushCount)
        isFlushingCreatedMessageBatch = true
        for prepared in pending {
            consumeImmediately(
                .messageCreated(prepared.message),
                preparedTextPlan: prepared.textPlan
            )
        }
        commitBatchedSelectedMessages()
        isFlushingCreatedMessageBatch = false
        flushBatchedCreatedMessageSideEffects()
        if !pendingCreatedMessages.isEmpty {
            // A display or AppKit transaction can occasionally delay the
            // eight-millisecond timer long enough for dozens of gateway
            // creates to accumulate. Never turn that scheduling delay into
            // one giant main-actor layout burst; drain bounded chunks while
            // yielding between them.
            createdMessageFlushTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.flushPendingCreatedMessages(
                    maximumCount: self.maximumCreatedMessagesPerFlush
                )
            }
        }
    }

    func resetPendingCreatedMessages() {
        createdMessageFlushTask?.cancel()
        createdMessageFlushTask = nil
        pendingCreatedMessages.removeAll(keepingCapacity: false)
        batchedSelectedMessages.removeAll(keepingCapacity: false)
        batchedSelectedTextPlansByID.removeAll(keepingCapacity: false)
        batchedUnreadPresentationNeedsRefresh = false
        batchedAcknowledgementChannelIDs.removeAll(keepingCapacity: false)
        isFlushingCreatedMessageBatch = false
    }

    func flushBatchedCreatedMessageSideEffects() {
        if batchedUnreadPresentationNeedsRefresh {
            batchedUnreadPresentationNeedsRefresh = false
            requestUnreadPresentationRefresh()
        }
        let acknowledgementChannelIDs = batchedAcknowledgementChannelIDs
        batchedAcknowledgementChannelIDs.removeAll(keepingCapacity: true)
        for channelID in acknowledgementChannelIDs {
            acknowledgeIfEligible(channelID: channelID)
        }
    }

    func consumeImmediately(
        _ event: ClientEvent,
        preparedTextPlan: NativeTimelineTextPlan? = nil,
        preparedMemberListPresentation: PreparedMemberListPresentation? = nil
    ) {
        switch event {
        case .connectionChanged(let state):
            consumeConnectionChange(state)
        case .emojisChanged(let guildID, let emojis):
            applyEmojis(emojis, to: guildID)
        case .emojisUpdated(let guildID, let upserted, let deletedIDs):
            applyEmojiUpdate(upserted: upserted, deletedIDs: deletedIDs, to: guildID)
        case .messageCreated(var message):
            consumeMessageCreated(&message, preparedTextPlan: preparedTextPlan)
        case .messageUpdated(let incoming):
            consumeMessageUpdated(incoming, preparedTextPlan: preparedTextPlan)
        case .messageReactionUpdated(let update):
            applyReactionUpdate(update)
        case .messageDeleted(let channelID, let messageID):
            consumeMessageDeleted(channelID: channelID, messageID: messageID)
        case .readStateSnapshot(let states, let version):
            consumeReadStateSnapshot(states, version: version)
        case .readStateChanged(let state):
            consumeReadStateChange(state)
        default:
            consumeWorkspaceEvent(
                event,
                preparedMemberListPresentation: preparedMemberListPresentation
            )
        }
    }

    func consumeWorkspaceEvent(
        _ event: ClientEvent,
        preparedMemberListPresentation: PreparedMemberListPresentation? = nil
    ) {
        switch event {
        case .notificationModeChanged(let usesNewNotifications):
            readState.updateNotificationMode(
                usesNewNotifications: usesNewNotifications
            )
            if var value = snapshot {
                value.usesNewNotifications = usesNewNotifications
                snapshot = value
            }
            refreshUnreadPresentation()
        case .notificationSettingsChanged(let settings):
            applyNotificationSettings(settings)
            refreshUnreadPresentation()
        case .typing(let channelID, let user):
            typingState.receive(
                channelID: channelID,
                user: user,
                currentUserID: snapshot?.currentUser.id
            )
        case .channelsChanged(let guildID, let channels):
            consumeChannelsChanged(guildID: guildID, channels: channels)
        case .forumPostsChanged(let channelID, let posts):
            consumeForumPostsChanged(channelID: channelID, posts: posts)
        case .forumPostPreviewsChanged(let channelID, let posts):
            consumeForumPostPreviewsChanged(channelID: channelID, posts: posts)
        case .activeJoinedThreadsChanged(let threads):
            if var value = snapshot {
                value.activeJoinedThreads = threads
                snapshot = value
                forwardSearchSourceRevision &+= 1
            }
        case .forumPageLoaded(let channelID, let query, let page):
            consumeForumPageLoaded(channelID: channelID, query: query, page: page)
        case .membersChanged(let guildID, let value, let groups):
            consumeMembersChanged(
                guildID: guildID,
                members: value,
                groups: groups,
                preparedPresentation: preparedMemberListPresentation
            )
        default:
            consumePresenceAndCommandEvent(event)
        }
    }

    func consumePresenceAndCommandEvent(_ event: ClientEvent) {
        if consumeForwardSearchPeopleEvent(event) { return }
        if consumeApplicationStreamEvent(event) { return }
        switch event {
        case .currentUserRolesChanged, .currentUserRolesSnapshot:
            consumeCurrentUserRoleEvent(event)
        case .voiceStateChanged(let state):
            consumeVoiceStateChanged(state)
        case .privateCallChanged(var call):
            consumePrivateCallChanged(&call)
        case .privateCallDeleted(let channelID, let unavailable):
            consumePrivateCallDeleted(channelID: channelID, unavailable: unavailable)
        case .voiceServerChanged(let info):
            scheduleVoiceServerMigration(to: info)
        case .snapshotChanged(let value):
            consumeSnapshotChanged(value)
        case .guildChanged, .guildLayoutChanged, .guildRolesChanged,
             .currentUserChanged:
            consumeGatewayWorkspaceStateEvent(event)
        case .applicationCommandIndexInvalidated(let target):
            if commandComposer.invalidated(target) {
                loadApplicationCommands()
            }
        case .applicationCommandAutocomplete(let result):
            commandComposer.receiveAutocomplete(result)
        case .interaction(let event):
            consumeInteraction(event)
        default:
            break
        }
    }

    func consumeGatewayWorkspaceStateEvent(_ event: ClientEvent) {
        switch event {
        case .guildChanged(let guild):
            consumeGuildChanged(guild)
        case .guildLayoutChanged(let guilds, let railItems):
            consumeGuildLayoutChanged(guilds: guilds, railItems: railItems)
        case .guildRolesChanged(let guildID, let roles):
            applyGuildRoles(roles, to: guildID)
        case .currentUserChanged(let user):
            consumeCurrentUserChanged(user)
        default:
            break
        }
    }

    func consumeCurrentUserRoleEvent(_ event: ClientEvent) {
        switch event {
        case .currentUserRolesChanged(let guildID, let roleIDs):
            consumeCurrentUserRolesChanged(guildID: guildID, roleIDs: roleIDs)
        case .currentUserRolesSnapshot(let roleIDsByGuild):
            consumeCurrentUserRolesSnapshot(roleIDsByGuild)
        default:
            break
        }
    }

    func consumeCurrentUserRolesChanged(
        guildID: GuildID,
        roleIDs values: [RoleID]
    ) {
        let roleIDs = Set(values)
        guard currentUserRoleIDsByGuild[guildID] != roleIDs else { return }
        currentUserRoleIDsByGuild[guildID] = roleIDs
        readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
        guard selectedGuildID == guildID else { return }
        refreshUnreadPresentation(
            appliesAccessImmediately: true,
            accessAffectedGuildIDs: [guildID]
        )
    }

    func consumeCurrentUserRolesSnapshot(
        _ roleIDsByGuild: [GuildID: [RoleID]]
    ) {
        let replacement = roleIDsByGuild.mapValues(Set.init)
        guard currentUserRoleIDsByGuild != replacement else { return }
        let previous = currentUserRoleIDsByGuild
        let affectedGuildIDs = Self.changedCurrentUserRoleGuildIDs(
            from: previous,
            to: replacement
        )
        currentUserRoleIDsByGuild = replacement
        for guildID in affectedGuildIDs {
            readState.updateCurrentUserRoles(
                replacement[guildID] ?? [],
                guildID: guildID
            )
        }
        refreshUnreadAccessAfterCurrentRoleSnapshot(
            affectedGuildIDs: affectedGuildIDs
        )
    }

    func consumeConnectionChange(_ state: ConnectionState) {
        let previousState = connectionState
        connectionState = state
        handleApplicationStreamsForGatewayState(state)
        if state != .ready {
            if previousState == .ready {
                // A resumed session can reconcile missed messages through the
                // Gateway, but a failed resume followed by a fresh Ready cannot:
                // Ready contains channel boundaries, not message history. Keep
                // the bounded rows for immediate presentation while forcing one
                // authoritative newest-page refresh per reopened conversation.
                hasMoreCache.removeAll(keepingCapacity: true)
            }
            stopLocalTyping(clearThrottle: true)
            typingState.clearAll()
        } else {
            if previousState != .ready, activeVoiceChannel != nil {
                let account = accountSession()
                let generation = voiceMigrationGeneration
                startAccountChildTask(account: account) { model, account in
                    await model.publishVoiceState(
                        account: account,
                        generation: generation
                    )
                }
            }
            if previousState != .ready,
               selectedChannelID != nil,
               hasCompletedInitialMessageLoad
            {
                refreshSelectedChannelPreservingHistory()
            }
            if let channel = selectedChannel,
               channel.kind == .directMessage || channel.kind == .groupDirectMessage
            {
                let account = accountSession()
                startAccountChildTask(account: account) { model, account in
                    await model.observePrivateCall(in: channel, account: account)
                }
            }
        }
    }

    func consumeMessageCreated(
        _ message: inout Message,
        preparedTextPlan: NativeTimelineTextPlan?
    ) {
        typingState.clear(userID: message.author.id, in: message.channelID)
        if let nonce = message.nonce {
            commandComposer.enrichInteractionResponse(
                &message, currentUser: snapshot?.currentUser
            )
            commandComposer.interactionSucceeded(nonce: nonce)
        }
        recordAuthoritativeMessageUpsert(message)
        if message.channelID == openThread?.id {
            reconcileThread(message)
        }
        if message.channelID == selectedChannelID {
            if !hasMoreLaterMessages
                || selectedMessageIDs.contains(message.id)
            {
                reconcile(message, preparedTextPlan: preparedTextPlan)
            }
        } else {
            cache(message)
        }
        reconcileForumMessage(message)
        guard let currentUserID = snapshot?.currentUser.id else { return }
        let disposition = readState.receive(message, currentUserID: currentUserID)
        guard disposition.accepted else { return }
        if message.channelID == selectedChannelID || message.channelID == openThread?.id {
            preserveUnreadDividerIfNeeded(channelID: message.channelID)
        }
        if isFlushingCreatedMessageBatch {
            batchedUnreadPresentationNeedsRefresh = true
        } else {
            refreshUnreadPresentation()
        }
        if disposition.shouldNotify {
            deliverNativeNotification(for: message)
        }
        if isFlushingCreatedMessageBatch {
            batchedAcknowledgementChannelIDs.insert(message.channelID)
        } else {
            acknowledgeIfEligible(channelID: message.channelID)
        }
    }

    func consumeMessageUpdated(
        _ incoming: Message,
        preparedTextPlan: NativeTimelineTextPlan?
    ) {
        let message = reactionPresentationPreserving(incoming)
        recordAuthoritativeMessageUpsert(message)
        if message.channelID == openThread?.id {
            reconcileThreadUpdate(message)
        }
        if message.channelID == selectedChannelID {
            reconcileSelectedMessageUpdate(message, preparedTextPlan: preparedTextPlan)
        } else {
            reconcileCachedMessageUpdate(message)
        }
        reconcileForumMessage(message)
    }

    func consumeMessageDeleted(channelID: ChannelID, messageID: MessageID) {
        recordConversationRefreshMutation(
            .delete,
            messageID: messageID,
            channelID: channelID
        )
        clearReactionReactorLoadState(channelID: channelID, messageID: messageID)
        clearReactionMutationState(channelID: channelID, messageID: messageID)
        if replyingTo?.id == messageID {
            replyingTo = nil
        }
        if threadReplyingTo?.id == messageID {
            threadReplyingTo = nil
        }
        if channelID == openThread?.id {
            threadMessages.removeAll { $0.id == messageID }
        }
        if channelID == selectedChannelID {
            removeSelectedMessage(id: messageID)
        } else {
            messageCache[channelID]?.removeAll { $0.id == messageID }
        }
    }

    func consumeReadStateSnapshot(_ states: [ChannelReadState], version: Int?) {
        let incomingVersion = version ?? states.compactMap(\.version).max()
        let incomingVersionDescription = incomingVersion.map(String.init) ?? "none"
        let pendingCount = readState.entries.values.count {
            $0.pendingAcknowledgementID != nil
        }
        Self.unreadDiagnosticsLogger.info(
            "Read-state snapshot received; states=\(states.count), version=\(incomingVersionDescription, privacy: .public), pending=\(pendingCount)"
        )
        readState.replaceReadStates(states, version: incomingVersion)
        if let selectedChannelID {
            _ = readState.updatePresentation(
                channelID: selectedChannelID,
                isPresented: true,
                initialHistoryLoaded: !isLoadingMessages && messageLoadError == nil,
                windowIsActive: mainWindowIsActive
            )
        }
        if let threadID = openThread?.id {
            _ = readState.updatePresentation(
                channelID: threadID,
                isPresented: true,
                initialHistoryLoaded: !isLoadingThread && threadErrorMessage == nil,
                windowIsActive: mainWindowIsActive
            )
        }
        refreshUnreadPresentation()
        if let selectedChannelID { acknowledgeIfEligible(channelID: selectedChannelID) }
        if let threadID = openThread?.id { acknowledgeIfEligible(channelID: threadID) }
    }

    func consumeReadStateChange(_ state: ChannelReadState) {
        if readState.applyRemote(state) {
            refreshUnreadPresentation()
            if !readState.unread(channelID: state.channelID) {
                cancelNativeNotifications(channelID: state.channelID)
            }
        } else {
            let messageID = state.lastAcknowledgedMessageID?.rawValue ?? 0
            let channelID = state.channelID.rawValue
            let versionDescription = state.version.map(String.init) ?? "none"
            Self.unreadDiagnosticsLogger.info(
                "Read event ignored c=\(channelID, privacy: .public) m=\(messageID, privacy: .public) v=\(versionDescription, privacy: .public)"
            )
        }
    }

    func consumeChannelsChanged(guildID: GuildID?, channels: [Channel]) {
        let previousChannels = snapshot?.channels ?? []
        if var value = snapshot {
            if let firstIndex = value.channels.firstIndex(where: { $0.guildID == guildID }) {
                value.channels.removeAll { $0.guildID == guildID }
                value.channels.insert(contentsOf: channels, at: firstIndex)
            } else {
                value.channels.append(contentsOf: channels)
            }
            snapshot = value
            forwardSearchSourceRevision &+= 1
        }
        if guildID == selectedGuildID {
            visibleChannels = channels
            if let selectedChannelID {
                if let updated = channels.first(where: { $0.id == selectedChannelID }) {
                    selectedChannel = updated
                } else if guildID == nil {
                    self.selectedChannelID = channels.first?.id
                }
            }
        }
        readState.replaceChannels(in: guildID, with: channels)
        refreshUnreadAccessAfterChannelsChanged(
            guildID: guildID,
            channels: channels,
            previousChannels: previousChannels
        )
    }

    func consumeForumPostsChanged(channelID: ChannelID, posts: [ForumPost]) {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "ForumPostsChanged"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "ForumPostsChanged",
                interval
            )
        }
        let threads = AppPerformanceSignposts.measureSync(
            "ForumThreadProjection"
        ) {
            posts.map(\.thread)
        }
        AppPerformanceSignposts.measureSync(
            "ForumForwardDestinationReplacement"
        ) {
            replaceForwardDestinationThreads(
                parentID: channelID,
                with: threads
            )
        }
        AppPerformanceSignposts.measureSync(
            "ForumReadStateReplacement"
        ) {
            readState.replaceThreads(parentID: channelID, with: threads)
        }
        AppPerformanceSignposts.measureSync("ForumUnreadRefreshRequest") {
            requestCoalescedUnreadPresentationRefresh()
        }
        guard channelID == selectedChannelID, selectedChannel?.kind == .forum else { return }
        replaceForumCatalogue(with: posts)
        applyForumPresentation()
        if let openThread, openThread.parentID == channelID,
           !posts.contains(where: { $0.id == openThread.id })
        {
            closeThread()
        }
    }

    func consumeForumPostPreviewsChanged(channelID: ChannelID, posts: [ForumPost]) {
        mergeForwardDestinationThreads(posts.map(\.thread))
        for post in posts { readState.merge(thread: post.thread) }
        requestCoalescedUnreadPresentationRefresh()
        guard channelID == selectedChannelID, selectedChannel?.kind == .forum else { return }
        mergeForumCatalogue(posts)
        applyForumPresentation()
    }

    func consumeForumPageLoaded(
        channelID: ChannelID,
        query: ForumPostQuery,
        page: ForumPostPage
    ) {
        for post in page.posts { readState.merge(thread: post.thread) }
        requestCoalescedUnreadPresentationRefresh()
        guard channelID == selectedChannelID,
              selectedChannel?.kind == .forum,
              forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query
              == ForumPostQuery(
                  scope: .active,
                  sortOrder: forumSortOrder,
                  selectedTagIDs: forumSelectedTagIDs,
                  tagMatch: forumTagMatch,
                  offset: 0,
                  limit: 25
              )
        else { return }
        replaceForumCatalogue(with: page.posts)
        applyForumPresentation()
        forumNextOffset = page.nextOffset
        hasMoreForumPosts = page.hasMore
    }

    func replaceForwardDestinationThreads(
        parentID: ChannelID,
        with threads: [MessageThreadSummary]
    ) {
        guard var value = snapshot else { return }
        value.threads.removeAll { $0.parentID == parentID }
        value.threads.append(contentsOf: threads)
        snapshot = value
    }

    func mergeForwardDestinationThreads(_ threads: [MessageThreadSummary]) {
        guard var value = snapshot, !threads.isEmpty else { return }
        var indicesByID = Dictionary(
            value.threads.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for thread in threads {
            if let index = indicesByID[thread.id] {
                value.threads[index] = thread
            } else {
                indicesByID[thread.id] = value.threads.count
                value.threads.append(thread)
            }
        }
        snapshot = value
    }

    func consumeVoiceStateChanged(_ state: VoiceParticipantState) {
        let effects = VoiceStateSoundPolicy.effects(
            previous: voiceStates[state.userID],
            current: state,
            activeChannelID: activeVoiceChannel?.id,
            currentUserID: snapshot?.currentUser.id
        )
        voiceStates[state.userID] = state.channelID == nil ? nil : state
        reconcileApplicationStreamWatchSuppression(for: state)
        watchAvailableDirectMessageStreamsAutomatically()
        if !state.isVideoEnabled {
            voiceVideoFrames[String(state.userID.rawValue)] = nil
        }
        if state.guildID == nil {
            reconcilePrivateCallVoiceState(state)
        }
        for effect in effects {
            soundPlayer.play(effect)
        }
    }

    func consumePrivateCallChanged(_ call: inout PrivateCall) {
        if call.voiceStates == nil {
            call.voiceStates = privateCallsByChannel[call.channelID]?.voiceStates
        }
        privateCallsByChannel[call.channelID] = call
        if let currentUserID = snapshot?.currentUser.id,
           call.ongoingRings.contains(where: {
               $0.senderID == currentUserID && $0.recipientID != currentUserID
           })
        {
            endLocalOutgoingPrivateCallRing(channelID: call.channelID)
        } else {
            reconcilePrivateCallSounds()
        }
    }

    func consumePrivateCallDeleted(channelID: ChannelID, unavailable: Bool) {
        if unavailable, var call = privateCallsByChannel[channelID] {
            call.isUnavailable = true
            call.ongoingRings = []
            privateCallsByChannel[channelID] = call
        } else {
            privateCallsByChannel[channelID] = nil
            if activeVoiceChannel?.id == channelID {
                let account = accountSession()
                let voiceOperation = currentVoiceOperationIdentity()
                startAccountChildTask(account: account) { model, account in
                    await model.leaveVoice(
                        account: account,
                        expectedOperation: voiceOperation
                    )
                }
            }
        }
        endLocalOutgoingPrivateCallRing(channelID: channelID)
    }

    func consumeSnapshotChanged(_ value: BootstrapSnapshot) {
        let previousSnapshot = snapshot
        let previousChannelsByID = Dictionary(
            uniqueKeysWithValues: (previousSnapshot?.channels ?? []).map { ($0.id, $0) }
        )
        let previousGuildsByID = serverRailGuildsByID
        let previousAccessEvidence = readState.authoritativeAccessEvidenceChannelIDs()
        snapshot = value
        forwardSearchSourceRevision &+= 1
        readState.configure(
            accountID: readState.accountID,
            guilds: value.guilds,
            channels: value.channels,
            readStates: value.readStates,
            notificationSettings: value.notificationSettings,
            usesNewNotifications: value.usesNewNotifications
        )
        for thread in value.threads {
            readState.merge(thread: thread)
        }
        refreshUnreadAccessAfterSnapshotChanged(
            previousSnapshot: previousSnapshot,
            previousGuildsByID: previousGuildsByID,
            previousAccessEvidence: previousAccessEvidence,
            currentSnapshot: value
        )
        // A Gateway snapshot carries protocol models whose unread fields are
        // intentionally zero. Keep existing presentation values, and resolve
        // only genuinely new IDs synchronously after access has been applied.
        // The account-wide projection remains coalesced onto the next bounded
        // turn, avoiding a transient visible zero without restoring the old
        // access-plus-projection main-actor stall.
        if var projected = snapshot {
            for index in projected.channels.indices {
                let channelID = projected.channels[index].id
                if let previous = previousChannelsByID[channelID] {
                    projected.channels[index].unreadCount = previous.unreadCount
                    projected.channels[index].mentionCount = previous.mentionCount
                } else {
                    projected.channels[index].unreadCount =
                        projected.channels[index].kind == .forum
                        ? readState.forumNewPostCount(channelID: channelID)
                        : (readState.unread(channelID: channelID) ? 1 : 0)
                    projected.channels[index].mentionCount = readState.mentions(
                        channelID: channelID
                    )
                }
            }
            for index in projected.guilds.indices {
                let guildID = projected.guilds[index].id
                if let previous = previousGuildsByID[guildID] {
                    projected.guilds[index].unreadCount = previous.unreadCount
                    projected.guilds[index].mentionCount = previous.mentionCount
                } else {
                    projected.guilds[index].unreadCount =
                        readState.guildUnread(guildID) ? 1 : 0
                    projected.guilds[index].mentionCount = readState.guildMentions(
                        guildID
                    )
                }
            }
            snapshot = projected
            updateServerRail(from: projected)
        }
        selectGuild(selectedGuildID)
    }

    func consumeGuildChanged(_ guild: Guild) {
        guard var value = snapshot,
              let index = value.guilds.firstIndex(where: { $0.id == guild.id })
        else { return }
        var projectedGuild = guild
        if let previous = serverRailGuildsByID[guild.id] {
            projectedGuild.unreadCount = previous.unreadCount
            projectedGuild.mentionCount = previous.mentionCount
        }
        value.guilds[index] = projectedGuild
        snapshot = value
        updateServerRailGuild(projectedGuild)
        forwardSearchSourceRevision &+= 1
        readState.merge(guilds: [guild])
        // Gateway guild payloads do not carry SakuraCord's presentation-only
        // unread and mention counts. Re-project them after every metadata
        // update instead of replacing the rail entry with raw zero values.
        refreshUnreadPresentation(
            appliesAccessImmediately: true,
            accessAffectedGuildIDs: [guild.id]
        )
    }

    func consumeGuildLayoutChanged(guilds: [Guild], railItems: [GuildRailItem]) {
        guard var value = snapshot else { return }
        let previousGuildsByID = serverRailGuildsByID
        let retainedGuildIDs = Set(guilds.map(\.id))
        value.guilds = guilds.map { guild in
            guard let previous = serverRailGuildsByID[guild.id] else {
                return guild
            }
            var projected = guild
            projected.unreadCount = previous.unreadCount
            projected.mentionCount = previous.mentionCount
            return projected
        }
        value.guildRailItems = railItems
        snapshot = value
        forwardSearchSourceRevision &+= 1
        currentUserRoleIDsByGuild = currentUserRoleIDsByGuild.filter {
            retainedGuildIDs.contains($0.key)
        }
        readState.retainGuilds(retainedGuildIDs)
        readState.merge(guilds: guilds)
        updateServerRail(from: value)
        // Layout events likewise contain raw guild models. Preserve the
        // account read-state projection when rebuilding the server rail.
        refreshUnreadAccessAfterGuildLayoutChanged(
            previousGuildsByID: previousGuildsByID,
            currentGuilds: guilds
        )
        if let selectedGuildID,
           !guilds.contains(where: { $0.id == selectedGuildID })
        {
            selectGuild(guilds.first?.id)
        }
    }

    func consumeCurrentUserChanged(_ user: User) {
        guard var value = snapshot else { return }
        value.currentUser = user
        snapshot = value
        if let index = members.firstIndex(where: { $0.id == user.id }) {
            members[index].user = user
        }
    }

    func consumeInteraction(_ event: InteractionEvent) {
        switch event {
        case .created(let nonce, let interactionID):
            commandComposer.interactionCreated(nonce: nonce, interactionID: interactionID)
        case .succeeded(let nonce):
            commandComposer.interactionSucceeded(nonce: nonce)
            if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                pendingComponentControls.remove(key)
                componentErrors[key] = nil
            }
            interactionErrorMessage = nil
        case .failed(let nonce, let message):
            let commandHandled = commandComposer.interactionFailed(nonce: nonce, message: message)
            if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                pendingComponentControls.remove(key)
                componentErrors[key] = message
            } else if !commandHandled {
                interactionErrorMessage = message
            }
        case .presentModal(let nonce, let modal):
            interactionModalNonce = nonce
            if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                pendingComponentControls.remove(key)
            }
            presentedInteractionModal = modal
            interactionErrorMessage = nil
        }
    }

    func updateServerRail(from snapshot: BootstrapSnapshot) {
        replaceServerRailGuilds(
            Dictionary(
                uniqueKeysWithValues: snapshot.guilds.map { ($0.id, $0) }
            )
        )
        serverRailItems = snapshot.guildRailItems
    }

    func reconcile(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        if message.nonce == nil,
           let index = selectedMessageIndex(for: message.id)
        {
            replaceSelectedMessage(
                message,
                at: index,
                preparedTextPlan: preparedTextPlan
            )
            return
        }
        let previousMessage = batchedSelectedMessages.last ?? messages.last
        if message.nonce == nil,
           previousMessage.map({
               $0.id < message.id && !Self.messagePrecedes(message, $0)
           }) ?? true
        {
            if isFlushingCreatedMessageBatch {
                batchedSelectedMessages.append(message)
                if let preparedTextPlan {
                    batchedSelectedTextPlansByID[message.id] =
                        preparedTextPlan
                }
            } else {
                appendSelectedMessage(
                    message,
                    preparedTextPlan: preparedTextPlan
                )
            }
            return
        }
        commitBatchedSelectedMessages()
        var updated = messages
        var resolved = message
        let replacementIndex =
            message.nonce.flatMap { nonce in
                updated.firstIndex(where: { $0.nonce == nonce })
            } ?? selectedMessageIndex(for: message.id)
        if let index = replacementIndex {
            resolved.replyTo = resolved.replyTo ?? updated[index].replyTo
            resolved.replyPreview = resolved.replyPreview ?? updated[index].replyPreview
            updated.remove(at: index)
            if let duplicateIndex = updated.firstIndex(where: { $0.id == resolved.id }) {
                updated.remove(at: duplicateIndex)
            }
            Self.insert(resolved, intoSorted: &updated)
        } else {
            Self.insert(resolved, intoSorted: &updated)
        }
        if updated != messages {
            replaceSelectedMessages(with: updated)
        }
    }

    func reconcileSelectedMessageUpdate(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        commitBatchedSelectedMessages()
        guard let index = selectedMessageIndex(for: message.id) else { return }
        replaceSelectedMessage(
            message,
            at: index,
            preparedTextPlan: preparedTextPlan
        )
    }

    func replaceSelectedMessage(
        _ incoming: Message,
        at index: Int,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        guard messages.indices.contains(index),
              messageRows.indices.contains(index)
        else { return }
        var resolved = incoming
        resolved.replyTo = resolved.replyTo ?? messages[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? messages[index].replyPreview
        guard resolved != messages[index] else { return }
        let previousReplyTarget = messages[index].replyTo
        if previousReplyTarget != resolved.replyTo {
            if let previousReplyTarget {
                selectedReplyMessageIDsByTarget[previousReplyTarget]?.remove(
                    resolved.id
                )
                if selectedReplyMessageIDsByTarget[previousReplyTarget]?.isEmpty
                    == true
                {
                    selectedReplyMessageIDsByTarget[previousReplyTarget] = nil
                }
            }
            if let replyTarget = resolved.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(resolved.id)
            }
        }
        messages[index] = resolved
        let changedIndexes = MessageGrouping.reconcileChangedMessage(
            id: resolved.id,
            replacement: resolved,
            messages: messages,
            availableMessageIDs: selectedMessageIDs,
            rows: &messageRows,
            messageIndex: selectedMessageIndex(for:),
            replyingMessageIDs:
                selectedReplyMessageIDsByTarget[resolved.id] ?? [],
            replacementTextPlan: preparedTextPlan
        )
        publishMessageRowsUpdate(
            change: .replace(changedIndexes),
            changedMessageIDs: Set(changedIndexes.map { messageRows[$0].id })
        )
        messageRowsNonAppendRevision &+= 1
    }

    func removeSelectedMessage(id: MessageID) {
        guard let index = selectedMessageIndex(for: id),
              messageRows.indices.contains(index)
        else { return }
        let removedReplyTarget = messages[index].replyTo
        messages.remove(at: index)
        messageRows.remove(at: index)
        selectedMessageIDs.remove(id)
        selectedMessageStoredIndexByID[id] = nil
        if index < messages.endIndex {
            for shiftedIndex in index ..< messages.endIndex {
                setSelectedMessageIndex(
                    shiftedIndex,
                    for: messages[shiftedIndex].id
                )
            }
        }
        if let removedReplyTarget {
            selectedReplyMessageIDsByTarget[removedReplyTarget]?.remove(id)
            if selectedReplyMessageIDsByTarget[removedReplyTarget]?.isEmpty
                == true
            {
                selectedReplyMessageIDsByTarget[removedReplyTarget] = nil
            }
        }
        let changedIndexes = MessageGrouping.reconcileChangedMessage(
            id: id,
            replacement: nil,
            messages: messages,
            availableMessageIDs: selectedMessageIDs,
            rows: &messageRows,
            neighborIndex: index,
            messageIndex: selectedMessageIndex(for:),
            replyingMessageIDs:
                selectedReplyMessageIDsByTarget[id] ?? []
        )
        publishMessageRowsUpdate(
            change: .remove(
                removedIndexes: IndexSet(integer: index),
                changedIndexes: changedIndexes
            ),
            changedMessageIDs: Set(changedIndexes.map { messageRows[$0].id }),
            removedMessageIDs: [id]
        )
        messageRowsNonAppendRevision &+= 1
    }

    func publishMessageRowsUpdate(
        change: MessageRowsUpdateHint.Change? = nil,
        insertedMessageIDs: [MessageID] = [],
        changedMessageIDs: Set<MessageID> = [],
        removedMessageIDs: Set<MessageID> = [],
        invalidatesAllRows: Bool = false
    ) {
        let nextRevision = latestMessageRowsRevision &+ 1
        latestMessageRowsRevision = nextRevision
        messageRowsUpdateHint = change.map {
            MessageRowsUpdateHint(revision: nextRevision, change: $0)
        }
        messageRowsUpdateJournal.append(
            MessageRowsUpdateRecord(
                revision: nextRevision,
                change: change,
                insertedMessageIDs: insertedMessageIDs,
                changedMessageIDs: changedMessageIDs,
                removedMessageIDs: removedMessageIDs,
                invalidatesAllRows: invalidatesAllRows
            )
        )
        messageRowsRevision = nextRevision
        NotificationCenter.default.post(
            name: .sakuracordMessageRowsDidChange,
            object: self
        )
    }

    func invalidateTimelinePresentation() {
        timelinePresentationRevision &+= 1
        NotificationCenter.default.post(
            name: .sakuracordMessageRowsDidChange,
            object: self
        )
    }

    func publishTimelineMemberPresentationChanges(
        from oldMembers: [UserID: Member],
        to newMembers: [UserID: Member],
        publishesCurrentRows: Bool = true
    ) {
        let changedUserIDs = AppPerformanceSignposts.measureSync(
            "TimelineMemberPresentationImpact"
        ) {
            var referencedUserIDs = TimelineMemberPresentationImpact
                .referencedUserIDs(in: messages)
            referencedUserIDs.formUnion(
                TimelineMemberPresentationImpact.referencedUserIDs(
                    in: threadMessages
                )
            )
            for cachedMessages in messageCache.values {
                referencedUserIDs.formUnion(
                    TimelineMemberPresentationImpact.referencedUserIDs(
                        in: cachedMessages
                    )
                )
            }
            guard !referencedUserIDs.isEmpty else { return Set<UserID>() }
            return TimelineMemberPresentationImpact.changedUserIDs(
                from: oldMembers,
                to: newMembers,
                guildRoles: guildRoles,
                candidates: referencedUserIDs
            )
        }
        guard !changedUserIDs.isEmpty else { return }

        let channelMessageIDs = TimelineMemberPresentationImpact
            .affectedMessageIDs(
                in: messages,
                changedUserIDs: changedUserIDs
            )
        let threadMessageIDs = TimelineMemberPresentationImpact
            .affectedMessageIDs(
                in: threadMessages,
                changedUserIDs: changedUserIDs
            )
        let affectsCachedConversation = messageCache.values.contains {
            !TimelineMemberPresentationImpact.affectedMessageIDs(
                in: $0,
                changedUserIDs: changedUserIDs
            ).isEmpty
        }

        // A recent off-screen conversation owns validated layouts and row
        // bitmaps inside the shared coordinator. Its model storage is not the
        // currently published row journal, so use the global revision only
        // when one of those cached rows genuinely depends on this member.
        if affectsCachedConversation {
            AppPerformanceSignposts.signposter.emitEvent(
                "TimelineInvalidationCachedMemberPresentation"
            )
            invalidateTimelinePresentation()
            return
        }
        guard publishesCurrentRows else { return }
        if !channelMessageIDs.isEmpty {
            publishMessageRowsUpdate(changedMessageIDs: channelMessageIDs)
        }
        if !threadMessageIDs.isEmpty {
            publishThreadMessageRowsPresentationUpdate(
                changedMessageIDs: threadMessageIDs
            )
        }
    }

    func applySelectedHistoryMemberHydration(
        _ hydratedMessages: [Message],
        presentationMessageIDs: Set<MessageID>
    ) {
        guard messages.count == hydratedMessages.count,
              messageRows.count == hydratedMessages.count,
              zip(messages, hydratedMessages).allSatisfy({
                  $0.id == $1.id
              }),
              zip(messageRows, hydratedMessages).allSatisfy({
                  $0.id == $1.id
              })
        else {
            replaceSelectedMessages(with: hydratedMessages)
            return
        }

        messages = hydratedMessages
        var replacedIndexes = IndexSet()
        for index in hydratedMessages.indices
        where presentationMessageIDs.contains(hydratedMessages[index].id) {
            let previousRow = messageRows[index]
            let hydratedMessage = hydratedMessages[index]
            guard previousRow.message != hydratedMessage else { continue }
            messageRows[index] = MessageRowPresentation(
                message: hydratedMessage,
                startsGroup: previousRow.startsGroup,
                startsDay: previousRow.startsDay,
                replyPreview:
                    hydratedMessage.replyPreview
                    ?? previousRow.replyPreview,
                isReplyAvailable: previousRow.isReplyAvailable,
                textPlan: previousRow.textPlan
            )
            replacedIndexes.insert(index)
        }

        guard !presentationMessageIDs.isEmpty else { return }
        publishMessageRowsUpdate(
            change:
                replacedIndexes.isEmpty
                ? nil
                : .replace(replacedIndexes),
            changedMessageIDs: presentationMessageIDs
        )
    }

    func publishThreadMessageRowsPresentationUpdate(
        changedMessageIDs: Set<MessageID>
    ) {
        guard !changedMessageIDs.isEmpty else { return }
        let nextRevision = threadMessageRowsRevision &+ 1
        threadMessageRowsUpdateHint = nil
        threadMessageRowsUpdateJournal.append(
            MessageRowsUpdateRecord(
                revision: nextRevision,
                change: nil,
                insertedMessageIDs: [],
                changedMessageIDs: changedMessageIDs,
                removedMessageIDs: [],
                invalidatesAllRows: false
            )
        )
        threadMessageRowsRevision = nextRevision
        NotificationCenter.default.post(
            name: .sakuracordMessageRowsDidChange,
            object: self
        )
    }

    func requestUnreadPresentationRefresh() {
        guard liveScrollingConversationIDs.isEmpty,
              !isAppScrollDeferringUnread
        else {
            requestCoalescedUnreadPresentationRefresh()
            return
        }
        refreshUnreadPresentation()
    }

    func requestCoalescedUnreadPresentationRefresh() {
        hasDeferredUnreadPresentationRefresh = true
        guard unreadPresentationRefreshTask == nil
        else { return }
        AppPerformanceSignposts.signposter.emitEvent(
            "UnreadPresentationRefreshScheduled"
        )
        let account = accountSession()
        unreadPresentationRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentAccountSession(account)
            else { return }
            while !self.liveScrollingConversationIDs.isEmpty
                || self.isAppScrollDeferringUnread
            {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
            }
            self.unreadPresentationRefreshTask = nil
            self.flushUnreadPresentationRefresh()
        }
    }

    func flushUnreadPresentationRefresh() {
        guard hasDeferredUnreadPresentationRefresh else { return }
        hasDeferredUnreadPresentationRefresh = false
        refreshUnreadPresentation()
    }

    func selectedMessageIndex(for id: MessageID) -> Int? {
        selectedMessageStoredIndexByID[id].map {
            $0 - selectedMessageIndexOrigin
        }
    }

    func setSelectedMessageIndex(
        _ index: Int,
        for id: MessageID
    ) {
        selectedMessageStoredIndexByID[id] =
            index + selectedMessageIndexOrigin
    }

    func rebuildSelectedMessageIndexes() {
        selectedMessageIDs = Set(messages.lazy.map(\.id))
        selectedMessageIndexOrigin = 0
        selectedMessageStoredIndexByID.removeAll(keepingCapacity: true)
        selectedMessageStoredIndexByID.reserveCapacity(messages.count)
        selectedReplyMessageIDsByTarget.removeAll(keepingCapacity: true)
        for (index, message) in messages.enumerated() {
            setSelectedMessageIndex(index, for: message.id)
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
    }

    func replaceSelectedMessages(
        with newMessages: [Message],
        preparedRows: [MessageRowPresentation]? = nil
    ) {
        let commit = AppPerformanceSignposts.signposter.beginInterval(
            "MessageStateCommit"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "MessageStateCommit",
                commit
            )
        }
        let oldMessages = messages
        messages = newMessages
        rebuildSelectedMessageIndexes()
        let rows = AppPerformanceSignposts.signposter.beginInterval(
            "MessageRowPreparation"
        )
        if let preparedRows,
           Self.rows(preparedRows, match: newMessages)
        {
            messageRows = preparedRows
        } else {
            messageRows = MessageGrouping.updating(
                existing: messageRows,
                oldMessages: oldMessages,
                newMessages: newMessages
            )
        }
        AppPerformanceSignposts.signposter.endInterval(
            "MessageRowPreparation",
            rows
        )
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    func mutateSelectedMessages(
        _ mutation: (inout [Message]) -> Void
    ) {
        let oldMessages = messages
        mutation(&messages)
        rebuildSelectedMessageIndexes()
        messageRows = MessageGrouping.updating(
            existing: messageRows,
            oldMessages: oldMessages,
            newMessages: messages
        )
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    func prependSelectedMessages(
        _ earlier: [Message],
        channelID: ChannelID
    ) async -> Bool {
        guard !earlier.isEmpty else { return true }
        // History preparation performs Markdown/CoreText setup for an entire
        // page. Running it at userInitiated priority lets it contend with the
        // main thread for font and attributed-string internals precisely
        // while the display link is trying to present the next scroll frame.
        // The page is prefetched thousands of points ahead, so utility
        // priority preserves that headroom without priority-inverting UI
        // presentation on every pagination boundary.
        let preparationPriority: TaskPriority = AppScrollWorkGate.isActive
            ? .background
            : .utility
        let preparedInsertedRows = await AppPerformanceSignposts.measure(
            "EarlierHistoryRowPreparation"
        ) {
            await prepareTimelineRows(
                for: earlier,
                priority: preparationPriority
            )
        }
        guard !Task.isCancelled, selectedChannelID == channelID else {
            return false
        }
        let stateCommit = AppPerformanceSignposts.signposter.beginInterval(
            "EarlierHistoryStateCommit",
            id: AppPerformanceSignposts.signposter.makeSignpostID()
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "EarlierHistoryStateCommit", stateCommit
            )
        }
        let commitStart = ProcessInfo.processInfo.systemUptime
        var potentiallyChangedMessageIDs = Set<MessageID>()
        if let firstExistingID = messageRows.first?.id {
            potentiallyChangedMessageIDs.insert(firstExistingID)
        }
        for message in earlier {
            potentiallyChangedMessageIDs.formUnion(
                selectedReplyMessageIDsByTarget[message.id] ?? []
            )
        }
        var previousRowsByID: [MessageID: MessageRowPresentation] = [:]
        previousRowsByID.reserveCapacity(potentiallyChangedMessageIDs.count)
        for id in potentiallyChangedMessageIDs {
            if let oldIndex = selectedMessageIndex(for: id),
               messageRows.indices.contains(oldIndex)
            {
                previousRowsByID[id] = messageRows[oldIndex]
            }
        }
        MessageGrouping.prependRows(
            for: earlier,
            into: &messageRows,
            preparedInsertedRows: preparedInsertedRows,
            existingMessageIndex: selectedMessageIndex(for:),
            replyingMessageIDsByTarget:
                selectedReplyMessageIDsByTarget
        )
        let changedMessageIDs = Set(
            potentiallyChangedMessageIDs.filter { id in
                guard let oldIndex = selectedMessageIndex(for: id),
                      let previousRow = previousRowsByID[id],
                      messageRows.indices.contains(earlier.count + oldIndex)
                else { return false }
                return previousRow
                    != messageRows[earlier.count + oldIndex]
            }
        )
        messages.insert(contentsOf: earlier, at: 0)
        selectedMessageIndexOrigin -= earlier.count
        selectedMessageIDs.formUnion(earlier.lazy.map(\.id))
        selectedMessageStoredIndexByID.reserveCapacity(messages.count)
        for (index, message) in earlier.enumerated() {
            setSelectedMessageIndex(index, for: message.id)
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
        publishMessageRowsUpdate(
            change: .insert(
                IndexSet(integersIn: 0 ..< earlier.count)
            ),
            insertedMessageIDs: earlier.map(\.id),
            changedMessageIDs: changedMessageIDs
        )
        messageRowsNonAppendRevision &+= 1
        if runsChatPerformanceBenchmark {
            let commitMilliseconds =
                (ProcessInfo.processInfo.systemUptime - commitStart) * 1_000
            if commitMilliseconds >= 4 {
                NSLog(
                    "SakuraCord history commit: %.2f ms (%d rows)",
                    commitMilliseconds,
                    messageRows.count
                )
            }
        }
        return true
    }

    func appendSelectedMessage(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        appendSelectedMessages(
            [message],
            preparedTextPlans:
                preparedTextPlan.map { [message.id: $0] } ?? [:]
        )
    }

    func appendSelectedMessages(
        _ appendedMessages: [Message],
        preparedTextPlans: [MessageID: NativeTimelineTextPlan] = [:],
        preparedRows: [MessageRowPresentation]? = nil
    ) {
        guard !appendedMessages.isEmpty else { return }
        let insertionStart = messageRows.count
        let preparedRows = preparedRows?.map { row in
            guard let textPlan = preparedTextPlans[row.id] else { return row }
            return MessageRowPresentation(
                message: row.message,
                startsGroup: row.startsGroup,
                startsDay: row.startsDay,
                replyPreview: row.replyPreview,
                isReplyAvailable: row.isReplyAvailable,
                textPlan: textPlan
            )
        }
        MessageGrouping.appendRows(
            for: appendedMessages,
            into: &messageRows,
            after: messages.last,
            preparedInsertedRows: preparedRows,
            existingMessage: { [self] id in
                selectedMessageIndex(for: id).map { messages[$0] }
            }
        )
        if preparedRows == nil, !preparedTextPlans.isEmpty {
            for index in insertionStart ..< messageRows.count {
                let row = messageRows[index]
                guard let textPlan = preparedTextPlans[row.id] else { continue }
                messageRows[index] = MessageRowPresentation(
                    message: row.message,
                    startsGroup: row.startsGroup,
                    startsDay: row.startsDay,
                    replyPreview: row.replyPreview,
                    isReplyAvailable: row.isReplyAvailable,
                    textPlan: textPlan
                )
            }
        }
        messages.append(contentsOf: appendedMessages)
        selectedMessageIDs.formUnion(appendedMessages.lazy.map(\.id))
        for (offset, message) in appendedMessages.enumerated() {
            setSelectedMessageIndex(
                insertionStart + offset,
                for: message.id
            )
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
        publishMessageRowsUpdate(
            change: .insert(
                IndexSet(
                    integersIn:
                        insertionStart ..< insertionStart + appendedMessages.count
                )
            ),
            insertedMessageIDs: appendedMessages.map(\.id)
        )
    }

    func appendSelectedHistoryMessages(
        _ later: [Message],
        channelID: ChannelID
    ) async -> Bool {
        guard !later.isEmpty else { return true }
        let preparationPriority: TaskPriority = AppScrollWorkGate.isActive
            ? .background
            : .utility
        let preparedRows = await AppPerformanceSignposts.measure(
            "LaterHistoryRowPreparation"
        ) {
            await prepareTimelineRows(
                for: later,
                priority: preparationPriority
            )
        }
        guard !Task.isCancelled, selectedChannelID == channelID else {
            return false
        }
        AppPerformanceSignposts.measureSync("LaterHistoryStateCommit") {
            appendSelectedMessages(later, preparedRows: preparedRows)
        }
        return true
    }

    func commitBatchedSelectedMessages() {
        guard !batchedSelectedMessages.isEmpty else { return }
        let pending = batchedSelectedMessages
        batchedSelectedMessages.removeAll(keepingCapacity: true)
        let preparedTextPlans = batchedSelectedTextPlansByID
        batchedSelectedTextPlansByID.removeAll(keepingCapacity: true)
        appendSelectedMessages(
            pending,
            preparedTextPlans: preparedTextPlans
        )
    }

    @discardableResult
    func reconcileVisibleOrCached(_ incoming: Message) -> Message {
        let message = reactionPresentationPreserving(incoming)
        if message.channelID == openThread?.id {
            reconcileThread(message)
        }
        if message.channelID == selectedChannelID {
            reconcile(message)
        } else {
            cache(message)
        }
        return message
    }

    func reactionPresentationPreserving(_ incoming: Message) -> Message {
        var result = incoming
        let lookupKey = ReactionMutationKey(
            channelID: incoming.channelID,
            messageID: incoming.id,
            reactionID: ""
        )
        if let existing = reactionMessage(for: lookupKey) {
            result = result.preservingReactionReactors(from: existing)
        }

        guard let currentUserID = snapshot?.currentUser.id else { return result }
        let currentUserReactor = knownReactionReactor(for: currentUserID)
        for (key, mutation) in reactionMutations
        where key.channelID == result.channelID && key.messageID == result.id {
            let currentlyReacted =
                result.reactions.first(where: { $0.id == key.reactionID })?
                    .didCurrentUserReact ?? false
            guard currentlyReacted != mutation.desiredReacted else { continue }
            let update: MessageReactionUpdate =
                mutation.desiredReacted
                ? .add(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
                : .remove(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
            _ = result.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: currentUserReactor
            )
        }
        return result
    }

    func reactionConfirmedSnapshot(_ message: Message) -> Message {
        guard let currentUserID = snapshot?.currentUser.id else { return message }
        var result = message
        let currentUserReactor = knownReactionReactor(for: currentUserID)
        for (key, mutation) in reactionMutations
        where key.channelID == result.channelID && key.messageID == result.id {
            let currentlyReacted =
                result.reactions.first(where: { $0.id == key.reactionID })?
                    .didCurrentUserReact ?? false
            guard currentlyReacted != mutation.confirmedReacted else { continue }
            let update: MessageReactionUpdate =
                mutation.confirmedReacted
                ? .add(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
                : .remove(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
            _ = result.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: currentUserReactor
            )
        }
        return result
    }

    func updateOutgoingState(_ state: OutboxState, nonce: String, channelID: ChannelID) {
        if selectedChannelID == channelID,
           let index = messages.firstIndex(where: { $0.nonce == nonce })
        {
            mutateSelectedMessages {
                $0[index].outboxState = state
            }
            return
        }
        guard var cached = messageCache[channelID],
              let index = cached.firstIndex(where: { $0.nonce == nonce })
        else { return }
        cached[index].outboxState = state
        messageCache[channelID] = cached
    }

    func removeOutgoingMessage(nonce: String, channelID: ChannelID) {
        if selectedChannelID == channelID {
            mutateSelectedMessages {
                $0.removeAll { $0.nonce == nonce }
            }
            return
        }
        guard var cached = messageCache[channelID] else { return }
        cached.removeAll { $0.nonce == nonce }
        messageCache[channelID] = cached
    }

    func outgoingState(nonce: String, channelID: ChannelID) -> OutboxState? {
        if selectedChannelID == channelID {
            return messages.first { $0.nonce == nonce }?.outboxState
        }
        return messageCache[channelID]?.first { $0.nonce == nonce }?.outboxState
    }

    func reconcileThread(_ message: Message) {
        var updated = threadMessages
        if let index = updated.firstIndex(where: {
            $0.id == message.id || ($0.nonce != nil && $0.nonce == message.nonce)
        }) {
            updated.remove(at: index)
            if let duplicateIndex = updated.firstIndex(where: {
                $0.id == message.id
            }) {
                updated.remove(at: duplicateIndex)
            }
        }
        Self.insert(message, intoSorted: &updated)
        guard updated != threadMessages else { return }
        threadMessages = updated
    }

    func reconcileThreadUpdate(_ message: Message) {
        guard let index = threadMessages.firstIndex(where: {
            $0.id == message.id
        }) else { return }
        var updated = threadMessages
        var resolved = message
        resolved.replyTo = resolved.replyTo ?? updated[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? updated[index].replyPreview
        guard resolved != updated[index] else { return }
        updated[index] = resolved
        threadMessages = updated
    }

    static func insert(_ message: Message, intoSorted messages: inout [Message]) {
        guard let last = messages.last, !messagePrecedes(message, last) else {
            let index = insertionIndex(for: message, in: messages)
            messages.insert(message, at: index)
            return
        }
        messages.append(message)
    }

    static func insertionIndex(for message: Message, in messages: [Message]) -> Int {
        var lowerBound = messages.startIndex
        var upperBound = messages.endIndex
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if messagePrecedes(messages[midpoint], message) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    static func messagePrecedes(_ lhs: Message, _ rhs: Message) -> Bool {
        lhs.timestamp != rhs.timestamp ? lhs.timestamp < rhs.timestamp : lhs.id < rhs.id
    }

    func cache(_ message: Message) {
        let current = messageCache[message.channelID] ?? []
        storeCachedMessages(
            Self.merging(current: current, fresh: [message]),
            for: message.channelID
        )
    }

    func storeCachedMessages(
        _ messages: [Message],
        for channelID: ChannelID
    ) {
        let retained = ChannelMessageCachePolicy.retainedMessages(from: messages)
        messageCache[channelID] = retained
        if let cachedRows = messageRowCache[channelID],
           !Self.rows(cachedRows, match: retained)
        {
            messageRowCache[channelID] = nil
            messageRowCacheOrder.removeAll { $0 == channelID }
        }
        messageCacheOrder.removeAll { $0 == channelID }
        messageCacheOrder.append(channelID)
        if retained.count < messages.count {
            hasMoreCache[channelID] = true
        }
        while messageCacheOrder.count
            > ChannelMessageCachePolicy.maximumChannelCount
        {
            let evicted = messageCacheOrder.removeFirst()
            messageCache[evicted] = nil
            messageRowCache[evicted] = nil
            messageRowCacheOrder.removeAll { $0 == evicted }
            hasMoreCache[evicted] = nil
        }
    }

    func storeCachedMessageRows(
        _ rows: [MessageRowPresentation],
        for channelID: ChannelID
    ) {
        guard let cachedMessages = messageCache[channelID]
        else {
            messageRowCache[channelID] = nil
            messageRowCacheOrder.removeAll { $0 == channelID }
            return
        }
        let retainedRows = Array(rows.suffix(cachedMessages.count))
        guard Self.rows(retainedRows, match: cachedMessages) else {
            messageRowCache[channelID] = nil
            messageRowCacheOrder.removeAll { $0 == channelID }
            return
        }
        messageRowCache[channelID] = retainedRows
        messageRowCacheOrder.removeAll { $0 == channelID }
        messageRowCacheOrder.append(channelID)
        while messageRowCacheOrder.count
            > ChannelMessageCachePolicy.maximumPreparedChannelCount
        {
            let evicted = messageRowCacheOrder.removeFirst()
            messageRowCache[evicted] = nil
        }
    }

    func takeCachedMessages(for channelID: ChannelID) -> [Message] {
        messageCacheOrder.removeAll { $0 == channelID }
        return messageCache.removeValue(forKey: channelID) ?? []
    }

    func takeCachedMessageRows(
        for channelID: ChannelID
    ) -> [MessageRowPresentation]? {
        messageRowCacheOrder.removeAll { $0 == channelID }
        return messageRowCache.removeValue(forKey: channelID)
    }

    static func rows(
        _ rows: [MessageRowPresentation],
        match messages: [Message]
    ) -> Bool {
        rows.count == messages.count
            && zip(rows, messages).allSatisfy {
                $0.message == $1
            }
    }

    func restoreSelectedMessages(
        _ restoredMessages: [Message],
        preparedRows: [MessageRowPresentation]?
    ) {
        let oldMessages = messages
        messages = restoredMessages
        rebuildSelectedMessageIndexes()
        if let preparedRows,
           Self.rows(preparedRows, match: restoredMessages)
        {
            messageRows = preparedRows
        } else {
            messageRows = MessageGrouping.updating(
                existing: messageRows,
                oldMessages: oldMessages,
                newMessages: restoredMessages
            )
        }
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    func reconcileCachedMessageUpdate(_ message: Message) {
        guard var cached = messageCache[message.channelID],
              let index = cached.firstIndex(where: { $0.id == message.id })
        else { return }
        var resolved = message
        resolved.replyTo = resolved.replyTo ?? cached[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? cached[index].replyPreview
        guard resolved != cached[index] else { return }
        cached[index] = resolved
        messageCache[message.channelID] = cached
    }
}
