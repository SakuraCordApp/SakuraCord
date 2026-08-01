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
        queuedAcknowledgements.removeAll()
        acknowledgementQueueOrder.removeAll()
    }

    func resetChannelNotificationMutations() {
        channelNotificationMutationGeneration &+= 1
        channelNotificationMutationTasks.values.forEach { $0.cancel() }
        channelNotificationMutationTasks.removeAll()
        forumNotificationMutationGeneration &+= 1
        forumNotificationMutationTasks.values.forEach { $0.cancel() }
        forumNotificationMutationTasks.removeAll()
    }

    func refreshUnreadPresentation() {
        guard var value = snapshot else {
            notificationService.setDockBadge(
                readState.totalMentions,
                enabled: notificationPreferences.showsDockBadge
            )
            return
        }
        // Permission resolution walks guild roles and channel overwrites. Resolve
        // once per channel and share the result with unread and sidebar projection.
        var accessByChannelID = [ChannelID: ConversationAccess](
            minimumCapacity: value.channels.count
        )
        var accessibilityByChannelID = [ChannelID: Bool](
            minimumCapacity: value.channels.count
        )
        for channel in value.channels {
            let access = conversationAccess(for: channel)
            accessByChannelID[channel.id] = access
            switch access {
            case .hidden:
                accessibilityByChannelID[channel.id] = false
            case .readable:
                accessibilityByChannelID[channel.id] = true
            case .checking:
                break
            }
        }
        readState.applyAccessibility(accessibilityByChannelID)
        let projectedChannels = value.channels.map { channel in
            var channel = channel
            channel.unreadCount =
                channel.kind == .forum
                ? readState.forumNewPostCount(channelID: channel.id)
                : (readState.unread(channelID: channel.id) ? 1 : 0)
            channel.mentionCount = readState.mentions(channelID: channel.id)
            return channel
        }
        let projectedGuilds = value.guilds.map { guild in
            var guild = guild
            guild.unreadCount = readState.guildUnread(guild.id) ? 1 : 0
            guild.mentionCount = readState.guildMentions(guild.id)
            return guild
        }
        if UnreadPresentationPublicationPolicy.shouldPublish(
            snapshot: value,
            channels: projectedChannels,
            guilds: projectedGuilds
        ) {
            value.channels = projectedChannels
            value.guilds = projectedGuilds
            snapshot = value
        }
        let projectedGuildsByID = Dictionary(
            uniqueKeysWithValues: projectedGuilds.map { ($0.id, $0) }
        )
        if projectedGuildsByID != serverRailGuildsByID {
            serverRailGuildsByID = projectedGuildsByID
        }
        let selectedGuildChannels: [Channel]
        if let selectedGuildID {
            selectedGuildChannels = projectedChannels.filter {
                $0.guildID == selectedGuildID && accessByChannelID[$0.id] != .hidden
            }
        } else {
            selectedGuildChannels = projectedChannels.filter {
                $0.guildID == nil && accessByChannelID[$0.id] != .hidden
            }
        }
        if selectedGuildChannels != visibleChannels {
            visibleChannels = selectedGuildChannels
        }
        if let selectedChannelID,
           !selectedGuildChannels.contains(where: { $0.id == selectedChannelID })
        {
            self.selectedChannelID = Self.preferredInitialChannelID(
                in: selectedGuildChannels
            )
        }
        let projectedSelectedChannel =
            selectedChannelID.flatMap { id in
                projectedChannels.first { $0.id == id }
            }
                ?? selectedChannel
        if projectedSelectedChannel != selectedChannel {
            selectedChannel = projectedSelectedChannel
        }
        notificationService.setDockBadge(
            readState.totalMentions,
            enabled: notificationPreferences.showsDockBadge
        )
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
        Task {
            await notificationService.deliver(
                message: message,
                channel: channel,
                guild: guild,
                accountID: accountID,
                preferences: notificationPreferences
            )
        }
    }

    func cancelNativeNotifications(channelID: ChannelID) {
        guard !runsChatPerformanceBenchmark else { return }
        let accountID = readState.accountID ?? "offline"
        Task {
            await notificationService.cancel(accountID: accountID, channelID: channelID)
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
        guard !Task.isCancelled else { return }
        consumeImmediately(event, preparedTextPlan: preparedTextPlan)
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
        preparedTextPlan: NativeTimelineTextPlan? = nil
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
            consumeWorkspaceEvent(event)
        }
    }

    func consumeWorkspaceEvent(_ event: ClientEvent) {
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
        case .forumPageLoaded(let channelID, let query, let page):
            consumeForumPageLoaded(channelID: channelID, query: query, page: page)
        case .membersChanged(let guildID, let value, let groups):
            consumeMembersChanged(guildID: guildID, members: value, groups: groups)
        default:
            consumePresenceAndCommandEvent(event)
        }
    }

    func consumePresenceAndCommandEvent(_ event: ClientEvent) {
        switch event {
        case .privateMembersChanged(let value):
            guard selectedGuildID == nil else { return }
            members = value
        case .currentUserRolesChanged(let guildID, let roleIDs):
            let roleIDs = Set(roleIDs)
            currentUserRoleIDsByGuild[guildID] = roleIDs
            readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
            refreshUnreadPresentation()
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
        case .guildChanged(let guild):
            consumeGuildChanged(guild)
        case .guildLayoutChanged(let guilds, let railItems):
            consumeGuildLayoutChanged(guilds: guilds, railItems: railItems)
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

    func consumeConnectionChange(_ state: ConnectionState) {
        connectionState = state
        if state != .ready {
            stopLocalTyping(clearThrottle: true)
            typingState.clearAll()
        } else if let channel = selectedChannel,
                  channel.kind == .directMessage || channel.kind == .groupDirectMessage
        {
            Task { [weak self] in
                await self?.observePrivateCall(in: channel)
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
        persist(message)
        if message.channelID == openThread?.id {
            reconcileThread(message)
        }
        if message.channelID == selectedChannelID {
            reconcile(message, preparedTextPlan: preparedTextPlan)
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
        persist(reactionConfirmedSnapshot(message))
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
        clearReactionReactorLoadState(channelID: channelID, messageID: messageID)
        clearReactionMutationState(channelID: channelID, messageID: messageID)
        Task { try? await database?.deleteMessage(messageID) }
        if replyingTo?.id == messageID {
            replyingTo = nil
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
        if var value = snapshot {
            value.channels.removeAll { $0.guildID == guildID }
            value.channels.append(contentsOf: channels)
            snapshot = value
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
        refreshUnreadPresentation()
    }

    func consumeForumPostsChanged(channelID: ChannelID, posts: [ForumPost]) {
        readState.replaceThreads(parentID: channelID, with: posts.map(\.thread))
        refreshUnreadPresentation()
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
        for post in posts { readState.merge(thread: post.thread) }
        refreshUnreadPresentation()
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
        refreshUnreadPresentation()
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

    func consumeMembersChanged(
        guildID: GuildID,
        members value: [Member],
        groups: [GuildMemberListGroup]
    ) {
        updateCurrentUserRoles(from: value, guildID: guildID)
        guard guildID == selectedGuildID else { return }
        memberListGroups = groups
        members = value
        refreshMentionAutocompleteMembers(from: value)
        refreshPresentedMembers(from: value)
    }

    func updateCurrentUserRoles(from members: [Member], guildID: GuildID) {
        guard let currentUserID = snapshot?.currentUser.id,
              let currentMember = members.first(where: { $0.id == currentUserID })
        else { return }
        let roleIDs = Set(currentMember.roles.map(\.id))
        currentUserRoleIDsByGuild[guildID] = roleIDs
        readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
        refreshUnreadPresentation()
    }

    func refreshMentionAutocompleteMembers(from members: [Member]) {
        if mentionAutocompleteMembers.isEmpty {
            // A guild activation can finish before Discord's lazy member list
            // has delivered its first store snapshot. Seed the dedicated
            // autocomplete store from that first Gateway update.
            mentionAutocompleteMembers = members
        } else {
            // Refresh known values without letting visual member-list sorting
            // reorder or expand the autocomplete store.
            let updatesByID = Dictionary(
                members.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            mentionAutocompleteMembers = mentionAutocompleteMembers.map {
                updatesByID[$0.id] ?? $0
            }
        }
    }

    func refreshPresentedMembers(from members: [Member]) {
        if let selectedMember,
           let updated = members.first(where: { $0.id == selectedMember.id })
        {
            inspectorProfilePresentation?.member = updated
            if var profile = inspectorProfilePresentation?.profile {
                profile.status = updated.status
                profile.customStatus = updated.customStatus
                inspectorProfilePresentation?.profile = profile
            }
        }
        if let contextualMember = contextualProfilePresentation?.member,
           let updated = members.first(where: { $0.id == contextualMember.id })
        {
            contextualProfilePresentation?.member = updated
            if var profile = contextualProfilePresentation?.profile {
                profile.status = updated.status
                profile.customStatus = updated.customStatus
                contextualProfilePresentation?.profile = profile
            }
        }
    }

    func consumeVoiceStateChanged(_ state: VoiceParticipantState) {
        let effects = VoiceStateSoundPolicy.effects(
            previous: voiceStates[state.userID],
            current: state,
            activeChannelID: activeVoiceChannel?.id,
            currentUserID: snapshot?.currentUser.id
        )
        voiceStates[state.userID] = state.channelID == nil ? nil : state
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
                Task { [weak self] in
                    await self?.leaveVoice()
                }
            }
        }
        endLocalOutgoingPrivateCallRing(channelID: channelID)
    }

    func consumeSnapshotChanged(_ value: BootstrapSnapshot) {
        snapshot = value
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
        updateServerRail(from: value)
        refreshUnreadPresentation()
        selectGuild(selectedGuildID)
    }

    func consumeGuildChanged(_ guild: Guild) {
        guard var value = snapshot,
              let index = value.guilds.firstIndex(where: { $0.id == guild.id })
        else { return }
        value.guilds[index] = guild
        snapshot = value
        readState.merge(guilds: [guild])
    }

    func consumeGuildLayoutChanged(guilds: [Guild], railItems: [GuildRailItem]) {
        guard var value = snapshot else { return }
        value.guilds = guilds
        value.guildRailItems = railItems
        snapshot = value
        readState.retainGuilds(Set(guilds.map(\.id)))
        readState.merge(guilds: guilds)
        updateServerRail(from: value)
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
        serverRailGuildsByID = Dictionary(uniqueKeysWithValues: snapshot.guilds.map { ($0.id, $0) })
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

    func requestUnreadPresentationRefresh() {
        guard !liveScrollingConversationIDs.isEmpty else {
            refreshUnreadPresentation()
            return
        }
        guard unreadPresentationRefreshTask == nil else { return }
        unreadPresentationRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            self?.flushUnreadPresentationRefresh()
        }
    }

    func flushUnreadPresentationRefresh() {
        unreadPresentationRefreshTask?.cancel()
        unreadPresentationRefreshTask = nil
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

    func replaceSelectedMessages(with newMessages: [Message]) {
        let oldMessages = messages
        messages = newMessages
        rebuildSelectedMessageIndexes()
        messageRows = MessageGrouping.updating(
            existing: messageRows,
            oldMessages: oldMessages,
            newMessages: newMessages
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
        let preparedInsertedRows = await Task.detached(priority: .utility) {
            await MessageGrouping.rowsCooperatively(for: earlier)
        }.value
        guard !Task.isCancelled, selectedChannelID == channelID else {
            return false
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
        preparedTextPlans: [MessageID: NativeTimelineTextPlan] = [:]
    ) {
        guard !appendedMessages.isEmpty else { return }
        let insertionStart = messageRows.count
        var appendedRows: [MessageRowPresentation] = []
        appendedRows.reserveCapacity(appendedMessages.count)
        var previous = messages.last
        let appendedByID = Dictionary(
            appendedMessages.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        for message in appendedMessages {
            let replyPreview =
                message.replyTo.flatMap { replyID in
                    (
                        appendedByID[replyID]
                            ?? selectedMessageIndex(for: replyID).map {
                                messages[$0]
                            }
                    ).map {
                        MessageReplyPreview(message: $0)
                    }
                } ?? message.replyPreview
            let isReplyAvailable =
                replyPreview.map { preview in
                    appendedByID[preview.messageID] != nil
                        || selectedMessageIDs.contains(preview.messageID)
                } ?? false
            let row = MessageGrouping.appendingRow(
                for: message,
                after: previous,
                replyPreview: replyPreview,
                isReplyAvailable: isReplyAvailable,
                textPlan: preparedTextPlans[message.id]
            )
            appendedRows.append(row)
            previous = message
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
        messageRows.append(contentsOf: appendedRows)
        publishMessageRowsUpdate(
            change: .insert(
                IndexSet(
                    integersIn:
                        insertionStart ..< insertionStart + appendedRows.count
                )
            ),
            insertedMessageIDs: appendedRows.map(\.id)
        )
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

    func reconcileVisibleOrCached(_ message: Message) {
        let message = reactionPresentationPreserving(message)
        if message.channelID == openThread?.id {
            reconcileThread(message)
        }
        if message.channelID == selectedChannelID {
            reconcile(message)
        } else {
            cache(message)
        }
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

    func persist(_ message: Message) {
        guard !message.flags.contains(.ephemeral) else { return }
        messagePersistenceSink.enqueue(message, database: database)
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
            hasMoreCache[evicted] = nil
        }
    }

    func takeCachedMessages(for channelID: ChannelID) -> [Message] {
        messageCacheOrder.removeAll { $0 == channelID }
        return messageCache.removeValue(forKey: channelID) ?? []
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
