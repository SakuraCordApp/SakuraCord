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
        let messageForTextPlan: Message? = switch event {
        case .messageUpdated(let message): message
        case .messagePatched(let update): applyingMessageUpdate(update)
        default: nil
        }
        let preparedTextPlan: NativeTimelineTextPlan? =
            if let message = messageForTextPlan,
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
            preparedTextPlanSource: messageForTextPlan,
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
        accessibilityMessageAnnouncer.cancel()
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
        preparedTextPlanSource: Message? = nil,
        preparedMemberListPresentation: PreparedMemberListPresentation? = nil
    ) {
        if consumeInboxEvent(event) { return }
        receiveGuideResourceEvent(event)
        switch event {
        case .connectionChanged(let state):
            consumeConnectionChange(state)
        case .emojisChanged(let guildID, let emojis):
            applyEmojis(emojis, to: guildID)
        case .emojisUpdated(let guildID, let upserted, let deletedIDs):
            applyEmojiUpdate(upserted: upserted, deletedIDs: deletedIDs, to: guildID)
        case .messageCreated(var message):
            consumeMessageCreated(&message, preparedTextPlan: preparedTextPlan)
            reconcileInboxMessage(message, isNew: true)
        case .messageUpdated(let incoming):
            invalidateMessageTranslation(incoming.id, content: incoming.content)
            let reconciled = applyingPendingPinIntent(to: incoming)
            consumeMessageUpdated(reconciled, preparedTextPlan: preparedTextPlan)
            reconcilePinnedMessage(reconciled)
            reconcileInboxMessage(reconciled)
        case .messagePatched(let update):
            if let content = update.content { invalidateMessageTranslation(update.messageID, content: content) }
            recordConversationRefreshMutation(.patch(update), messageID: update.messageID, channelID: update.channelID)
            if let message = applyingMessageUpdate(update) {
                let reconciled = applyingPendingPinIntent(to: message)
                consumeMessageUpdated(
                    reconciled, preparedTextPlan: preparedTextPlan,
                    recordsRefreshMutation: false, preparedTextPlanSource: preparedTextPlanSource
                )
                reconcilePinnedMessage(reconciled)
                reconcileInboxMessage(reconciled)
            }
        case .messageReactionUpdated(let update):
            applyReactionUpdate(update)
        case .messageDeleted(let channelID, let messageID):
            invalidateMessageTranslation(messageID)
            consumeMessageDeleted(channelID: channelID, messageID: messageID)
            removeDeletedPinnedMessage(channelID: channelID, messageID: messageID)
            removeInboxMessage(messageID, mentionsOnly: false)
        case .channelPinsInvalidated(let channelID):
            invalidatePinnedMessages(in: channelID)
        case .readStateSnapshot(let states, let version):
            consumeReadStateSnapshot(states, version: version)
            reconcileInboxReadState()
        case .readStateChanged(let state):
            consumeReadStateChange(state)
            reconcileInboxReadState()
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
            synchronizeVisibleCustomization(guildID: settings.guildID)
            reconcileSelectedOnboardingChannel()
            refreshUnreadPresentation()
            reconcileInboxEligibility()
        case .emojiUserSettingsChanged(let settings):
            applyDiscordEmojiSettings(settings)
            didAttemptDiscordEmojiSettings = true
            hasLoadedDiscordEmojiSettings = true
            forwardSearchSourceRevision &+= 1
        case .stickerUserSettingsChanged, .stickersChanged:
            consumeStickerEvent(event)
        case .soundboardUserSettingsChanged,
             .soundboardSoundsChanged,
             .voiceChannelEffect:
            consumeSoundboardEvent(event)
        case .typing(let channelID, let user):
            typingState.receive(
                channelID: channelID,
                user: user,
                currentUserID: snapshot?.currentUser.id
            )
        case .channelsChanged(let guildID, let channels):
            consumeChannelsChanged(guildID: guildID, channels: channels)
            reconcileInboxEligibility()
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
            reconcileInboxEligibility()
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
        if consumeProfileEvent(event) { return }
        switch event {
        case .currentUserRolesChanged, .currentUserRolesSnapshot:
            consumeCurrentUserRoleEvent(event)
        case .voiceStateChanged, .voiceStatesReceived:
            consumeVoiceStateEvent(event)
        case .privateCallChanged(var call):
            consumePrivateCallChanged(&call)
        case .privateCallDeleted(let channelID, let unavailable):
            consumePrivateCallDeleted(channelID: channelID, unavailable: unavailable)
        case .voiceServerChanged(let info):
            recordVoiceServerUpdateReceived(info)
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

    private func consumeProfileEvent(_ event: ClientEvent) -> Bool {
        switch event {
        case let .profileInvalidated(userID):
            profileCache = profileCache.filter { $0.key.userID != userID }
            if userID == snapshot?.currentUser.id {
                preparedProfileEditingSnapshot = nil
                profileInvalidationRevision = UUID()
            }
        case let .profileChanged(userID, scope, profile):
            consumeProfileChanged(userID: userID, scope: scope, value: profile)
        case let .profileCustomStatusChanged(userID, status):
            consumeProfileCustomStatusChanged(userID: userID, status: status)
        case let .profileWidgetConnectionsChanged(userID, connections):
            consumeProfileWidgetConnectionsChanged(userID: userID, connections: connections)
        default:
            return false
        }
        return true
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
        if state == .ready, previousState != .ready {
            refreshSelectedGuildOnboarding(force: true)
        }
        if state == .ready, previousState != .ready, inbox.isPresented { refreshInbox() }
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
        confirmSlowmodeMessage(message)
        receiveGuideMessage(message)
        message = outgoingMediaPresentationPreserving(message)
        typingState.clear(userID: message.author.id, in: message.channelID)
        if let nonce = message.nonce {
            commandComposer.enrichInteractionResponse(
                &message, currentUser: snapshot?.currentUser
            )
            commandComposer.interactionSucceeded(nonce: nonce)
            composer.outbox.draftsByNonce[nonce] = nil
            composer.outbox.stickerUploadSourceURLByNonce[nonce] = nil
            pruneOwnedPromisedAttachmentFiles()
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
        if message.author.id != currentUserID,
           accessibilitySettings.announcesNewMessages
        {
            accessibilityMessageAnnouncer.enqueue()
        }
        if message.channelID == selectedChannelID || message.channelID == openThread?.id {
            preserveUnreadDividerIfNeeded(channelID: message.channelID)
        }
        if isFlushingCreatedMessageBatch {
            batchedUnreadPresentationNeedsRefresh = true
        } else {
            refreshUnreadPresentation()
        }
        if disposition.shouldNotify {
            deliverNativeNotification(
                for: message,
                isMention: disposition.mentionKind != .none
                    && disposition.mentionKind != .directMessage
            )
        }
        if isFlushingCreatedMessageBatch {
            batchedAcknowledgementChannelIDs.insert(message.channelID)
        } else {
            acknowledgeIfEligible(channelID: message.channelID)
        }
    }

    func consumeMessageUpdated(
        _ incoming: Message,
        preparedTextPlan: NativeTimelineTextPlan?,
        recordsRefreshMutation: Bool = true,
        preparedTextPlanSource: Message? = nil
    ) {
        let message = reactionPresentationPreserving(
            outgoingMediaPresentationPreserving(incoming)
        )
        // Sparse updates are merged again after asynchronous preparation. A
        // history refresh or local reconciliation may have changed the source.
        let matchingTextPlan = recordsRefreshMutation || preparedTextPlanSource == message
            ? preparedTextPlan : nil
        if recordsRefreshMutation { recordAuthoritativeMessageUpsert(message) }
        if message.channelID == openThread?.id {
            reconcileThreadUpdate(message)
        }
        if message.channelID == selectedChannelID {
            reconcileSelectedMessageUpdate(message, preparedTextPlan: matchingTextPlan)
        } else {
            reconcileCachedMessageUpdate(message)
        }
        reconcileForumMessage(message)
        reconcilePollSearchMessage(message)
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
        composer.slowmode.updateIntervals(
            for: channels, replacing: previousChannels
        )
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
        reconcileInboxForumPosts(channelID: channelID, posts: posts, replacesAll: true)
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
        reconcileInboxForumPosts(channelID: channelID, posts: posts, replacesAll: false)
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
        for thread in threads where value.threads.first(where: { $0.id == thread.id })?.rateLimitPerUser != thread.rateLimitPerUser {
            composer.slowmode.updateInterval(in: thread.id, to: thread.rateLimitPerUser)
        }
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
                if value.threads[index].rateLimitPerUser != thread.rateLimitPerUser {
                    composer.slowmode.updateInterval(in: thread.id, to: thread.rateLimitPerUser)
                }
                value.threads[index] = thread
            } else {
                indicesByID[thread.id] = value.threads.count
                value.threads.append(thread)
            }
        }
        snapshot = value
    }

    func consumePrivateCallChanged(_ call: inout PrivateCall) {
        let previousCall = privateCallsByChannel[call.channelID]
        let currentUserID = snapshot?.currentUser.id
        let wasRingingCurrentUser = currentUserID.map {
            previousCall?.isRinging($0) == true
        } ?? false
        if call.voiceStates == nil {
            call.voiceStates = privateCallsByChannel[call.channelID]?.voiceStates
        }
        privateCallsByChannel[call.channelID] = call
        if let currentUserID,
           call.ongoingRings.contains(where: {
               $0.senderID == currentUserID && $0.recipientID != currentUserID
           })
        {
            endLocalOutgoingPrivateCallRing(channelID: call.channelID)
        } else {
            reconcilePrivateCallSounds()
        }
        let isRingingCurrentUser = currentUserID.map(call.isRinging) ?? false
        if !wasRingingCurrentUser, isRingingCurrentUser {
            deliverIncomingCallNotification(call)
        } else if wasRingingCurrentUser, !isRingingCurrentUser {
            cancelIncomingCallNotification(channelID: call.channelID)
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
        cancelIncomingCallNotification(channelID: channelID)
    }

    func consumeSnapshotChanged(_ value: BootstrapSnapshot) {
        let previousSnapshot = snapshot
        let previousChannelsByID = Dictionary(
            uniqueKeysWithValues: (previousSnapshot?.channels ?? []).map { ($0.id, $0) }
        )
        let previousGuildsByID = serverRailGuildsByID
        let previousAccessEvidence = readState.authoritativeAccessEvidenceChannelIDs()
        snapshot = value
        for (guildID, member) in value.currentMembersByGuildID {
            receiveOnboardingMember(member, guildID: guildID)
        }
        forwardSearchSourceRevision &+= 1
        readState.replaceSnapshot(value)
        composer.slowmode.updateIntervals(for: value.channels, replacing: previousSnapshot?.channels ?? [])
        visibleChannels = value.channels.filter { $0.guildID == selectedGuildID }
        if let selectedChannelID {
            selectedChannel = value.channels.first { $0.id == selectedChannelID }
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
        let retainedGuildID = selectedGuildID.flatMap { selected in
            value.guilds.contains { $0.id == selected } ? selected : value.guilds.first?.id
        }
        selectGuild(retainedGuildID)
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
        if var value = snapshot {
            value.currentUser = user
            snapshot = value
        }
        reconcileRetainedMessageIdentities(user)
        if let index = members.firstIndex(where: { $0.id == user.id }) {
            members[index].applyGlobalProfileUser(user)
        }
    }

    func consumeInteraction(_ event: InteractionEvent) {
        switch event {
        case .created(let nonce, let interactionID):
            commandComposer.interactionCreated(nonce: nonce, interactionID: interactionID)
        case .succeeded(let nonce):
            commandComposer.interactionSucceeded(nonce: nonce)
            if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                componentInteractionPresentation.pendingControls.remove(key)
                componentInteractionPresentation.errors[key] = nil
            }
            interactionErrorMessage = nil
        case .failed(let nonce, let message):
            let commandHandled = commandComposer.interactionFailed(nonce: nonce, message: message)
            if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                componentInteractionPresentation.pendingControls.remove(key)
                componentInteractionPresentation.errors[key] = message
            } else if !commandHandled {
                interactionErrorMessage = message
            }
        case .presentModal(let nonce, let modal):
            interactionModalNonce = nonce
            if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                componentInteractionPresentation.pendingControls.remove(key)
            }
            presentedInteractionModal = modal
            interactionErrorMessage = nil
        }
    }
}
