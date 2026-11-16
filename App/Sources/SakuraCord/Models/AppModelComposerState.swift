import DiscordProtocol
import Foundation
import SakuraCordModels
import SakuraCordPersistence

extension AppModel {
    /// The conversation a composer can send to right now; unlike
    /// `composerChannelID(in:)`, nil while the user may not send there.
    func composerSendChannelID(in destination: MessageComposerDestination) -> ChannelID? {
        switch destination {
        case .channel: selectedConversationAccess.canSend ? selectedChannelID : nil
        case .thread: openThreadAccess.canSend ? openThread?.id : nil
        }
    }

    var replyingTo: Message? {
        get { composer.replyingTo }
        set { composer.replyingTo = newValue }
    }
    var threadReplyingTo: Message? {
        get { composer.threadReplyingTo }
        set { composer.threadReplyingTo = newValue }
    }
    var replyMentionsAuthor: Bool {
        composer.replyMentionsAuthorChoice
            && (replyingTo == nil || replyingTo?.author.id != currentUser?.id)
    }
    var threadReplyMentionsAuthor: Bool {
        composer.replyMentionsAuthorChoice
            && (threadReplyingTo == nil || threadReplyingTo?.author.id != currentUser?.id)
    }
    func replyingTo(in destination: MessageComposerDestination) -> Message? {
        switch destination {
        case .channel: replyingTo
        case .thread: threadReplyingTo
        }
    }
    func setReplyingTo(_ message: Message?, in destination: MessageComposerDestination) {
        switch destination {
        case .channel: replyingTo = message
        case .thread: threadReplyingTo = message
        }
    }
    func replyMentionsAuthor(in destination: MessageComposerDestination) -> Bool {
        switch destination {
        case .channel: replyMentionsAuthor
        case .thread: threadReplyMentionsAuthor
        }
    }
    var draft: String {
        get { composer.draft }
        set { composer.draft = newValue }
    }
    var threadDraft: String {
        get { composer.threadDraft }
        set { composer.threadDraft = newValue }
    }
    /// The conversation a composer writes to.
    func composerChannelID(in destination: MessageComposerDestination) -> ChannelID? {
        switch destination {
        case .channel: selectedChannelID
        case .thread: openThread?.id
        }
    }

    func messages(in destination: MessageComposerDestination) -> [Message] {
        switch destination {
        case .channel: messages
        case .thread: threadMessages
        }
    }

    func draft(in destination: MessageComposerDestination) -> String {
        switch destination {
        case .channel: draft
        case .thread: threadDraft
        }
    }
    var channelComposerAttachments: [StagedAttachment] {
        get { composer.channelAttachments }
        set { composer.channelAttachments = newValue }
    }
    var threadComposerAttachments: [StagedAttachment] {
        get { composer.threadAttachments }
        set { composer.threadAttachments = newValue }
    }
    var isSendQueueFullAlertPresented: Bool {
        get { composer.isSendQueueFullAlertPresented }
        set { composer.isSendQueueFullAlertPresented = newValue }
    }

    func reply(to message: Message) {
        guard guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil else { return }
        let destination: MessageComposerDestination
        if message.channelID == selectedChannelID {
            replyingTo = message
            destination = .channel
        } else if message.channelID == openThread?.id {
            threadReplyingTo = message
            destination = .thread
        } else {
            return
        }
        NotificationCenter.default.post(
            name: .sakuracordFocusComposer,
            object: destination
        )
    }

    @discardableResult
    func navigateReplySelection(
        in destination: MessageComposerDestination,
        direction: MessageReplyNavigationDirection
    ) -> Bool {
        let availableMessages = messages(in: destination)
        let currentReply = replyingTo(in: destination)
        guard !availableMessages.isEmpty else { return false }

        let nextIndex: Int
        if let currentReply,
           let currentIndex = availableMessages.firstIndex(where: { $0.id == currentReply.id })
        {
            switch direction {
            case .older:
                nextIndex = currentIndex > availableMessages.startIndex
                    ? availableMessages.index(before: currentIndex)
                    : currentIndex
            case .newer:
                nextIndex = currentIndex < availableMessages.index(before: availableMessages.endIndex)
                    ? availableMessages.index(after: currentIndex)
                    : currentIndex
            }
        } else {
            nextIndex = availableMessages.index(before: availableMessages.endIndex)
        }
        if currentReply?.id == availableMessages[nextIndex].id {
            return true
        }
        reply(to: availableMessages[nextIndex])
        replyRevealRequestID &+= 1
        replyRevealRequest = ReplyRevealRequest(requestID: replyRevealRequestID, destination: destination)
        return true
    }

    func cancelReply(in destination: MessageComposerDestination = .channel) {
        setReplyingTo(nil, in: destination)
        NotificationCenter.default.post(
            name: .sakuracordFocusComposer,
            object: destination
        )
    }

    @discardableResult
    func consumeEscapeForReply(
        in destination: MessageComposerDestination
    ) -> Bool {
        guard replyingTo(in: destination) != nil else { return false }
        cancelReply(in: destination)
        return true
    }

    func setReplyMentionsAuthor(
        _ mentionsAuthor: Bool,
        in destination: MessageComposerDestination
    ) {
        guard let reply = replyingTo(in: destination), reply.author.id != currentUser?.id else { return }
        composer.rememberReplyMentionsAuthor(mentionsAuthor)
    }

    func updateDraft(_ value: String) {
        let previous = draft
        draft = value
        reconcileDraftTranslationText(value, in: .channel)
        if value.hasPrefix("/") || commandComposer.activeCommand != nil {
            stopLocalTyping(clearThrottle: false)
        } else {
            scheduleLocalTyping(for: value)
        }
        guard let channelID = selectedChannelID else { return }
        persistDraft(value, replacing: previous, in: channelID)
    }

    /// Saves a composer's text as its conversation's draft, which returning
    /// to the conversation restores.
    private func persistDraft(_ value: String, replacing previous: String, in channelID: ChannelID) {
        LocalStorageBudgetCoordinator.shared.scheduleAdjustment(
            draftByteDelta: Int64(value.utf8.count - previous.utf8.count)
        )
        quickSwitcherDraftChannelIDs.removeAll { $0 == channelID }
        if !value.isEmpty {
            quickSwitcherDraftChannelIDs.insert(channelID, at: 0)
        }
        let session = accountSession()
        guard isCurrentAccountSession(session) else { return }
        composer.persistDraft(value, channelID: channelID, database: session.database)
    }

    func storedDraft(
        in channelID: ChannelID,
        account: AppModelAccountSession
    ) async -> String {
        guard isCurrentAccountSession(account), let database = account.database else { return "" }
        return (try? await composer.storedDraft(in: channelID, database: database)) ?? ""
    }

    func updateDraft(_ value: String, in destination: MessageComposerDestination) {
        switch destination {
        case .channel: updateDraft(value)
        case .thread: updateThreadDraft(value)
        }
    }

    func updateThreadDraft(_ value: String) {
        guard threadCreation?.isSubmitting != true else { return }
        let previous = threadDraft
        threadDraft = value
        reconcileDraftTranslationText(value, in: .thread)
        guard let thread = openThread else {
            stopLocalTyping(clearThrottle: value.isEmpty)
            return
        }
        scheduleLocalTyping(for: value, channelID: thread.id)
        persistDraft(value, replacing: previous, in: thread.id)
    }

    func scheduleLocalTyping(for value: String, channelID: ChannelID? = nil) {
        let destination: (id: ChannelID, supportsTyping: Bool)? =
            if let channelID {
                (channelID, true)
            } else if let selectedChannel {
                (selectedChannel.id, Self.supportsTyping(selectedChannel.kind))
            } else {
                nil
            }
        guard privacySafetySettings.sendsTypingIndicators,
              !value.isEmpty,
              connectionState == .ready,
              let destination,
              destination.supportsTyping
        else {
            stopLocalTyping(clearThrottle: value.isEmpty)
            return
        }
        if localTypingTask != nil, localTypingChannelID == destination.id {
            return
        }
        stopLocalTyping(clearThrottle: false)
        localTypingGeneration &+= 1
        let generation = localTypingGeneration
        localTypingChannelID = destination.id
        let now = Date.now
        let debounce = Self.seconds(localTypingTiming.debounce)
        let remainingThrottle =
            lastTypingRequestAt[destination.id]
                .map { max(0, Self.seconds(localTypingTiming.throttle) - now.timeIntervalSince($0)) }
                ?? 0
        let delay = max(debounce, remainingThrottle)
        localTypingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.performLocalTyping(
                channelID: destination.id,
                generation: generation
            )
        }
    }

    func performLocalTyping(channelID: ChannelID, generation: UInt64) async {
        let isActiveChannelDraft = selectedChannelID == channelID
            && !draft.isEmpty
        let isActiveThreadDraft = openThread?.id == channelID
            && !threadDraft.isEmpty
        guard privacySafetySettings.sendsTypingIndicators,
              generation == localTypingGeneration,
              localTypingChannelID == channelID,
              isActiveChannelDraft || isActiveThreadDraft,
              connectionState == .ready,
              guildTimeoutUntil(in: channelID) == nil
        else { return }
        localTypingTask = nil
        localTypingChannelID = nil
        // Count the attempt, not only a successful response. A failed mutation is
        // not immediately retried by subsequent keystrokes.
        lastTypingRequestAt[channelID] = .now
        let session = accountSession()
        do {
            try await session.provider.sendTyping(in: channelID)
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
}
