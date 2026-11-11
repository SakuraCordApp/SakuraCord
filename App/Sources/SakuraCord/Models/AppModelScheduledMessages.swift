import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

/// The account's scheduled messages and the composers' chosen send times.
/// Discord sends no Gateway event for them, so the list is read when shown.
@MainActor
@Observable
final class ScheduledMessagesState {
    var messages: [ScheduledMessage] = []
    var isLoading = false
    var hasLoaded = false
    /// Messages with a change in flight; sent and cancelled ones leave the list on success.
    var pendingIDs: Set<ScheduledMessageID> = []
    var errorMessage: String?
    /// Send times picked in a composer, by conversation, until it is sent or cleared.
    var sendDates: [ChannelID: Date] = [:]
    /// Conversations whose message is being scheduled right now.
    var submittingChannelIDs: Set<ChannelID> = []
    /// The send time just confirmed for a conversation, shown briefly in its composer.
    var confirmations: [ChannelID: Date] = [:]
    var isLimitAlertPresented = false
    @ObservationIgnored var loadTask: Task<Void, Never>?

    func clear() {
        loadTask?.cancel()
        loadTask = nil
        messages = []
        isLoading = false
        hasLoaded = false
        pendingIDs = []
        errorMessage = nil
        sendDates = [:]
        submittingChannelIDs = []
        confirmations = [:]
        isLimitAlertPresented = false
    }
}

extension AppModel {
    var scheduledMessageLimit: Int {
        ScheduledMessagePolicy.limit(premiumType: currentUser?.premiumType ?? 0)
    }

    func scheduledSendDate(in destination: MessageComposerDestination) -> Date? {
        composerSendChannelID(in: destination).flatMap { scheduledMessages.sendDates[$0] }
    }

    /// Whether the conversation's message is on its way to Discord; until it
    /// is answered, its time stays and nothing else leaves the composer.
    func isSchedulingMessage(in destination: MessageComposerDestination) -> Bool {
        composerSendChannelID(in: destination).map(scheduledMessages.submittingChannelIDs.contains) ?? false
    }

    func setScheduledSendDate(_ date: Date?, in destination: MessageComposerDestination) {
        guard let channelID = composerSendChannelID(in: destination),
              !scheduledMessages.submittingChannelIDs.contains(channelID)
        else { return }
        scheduledMessages.sendDates[channelID] = date
        scheduledMessages.confirmations[channelID] = nil
    }

    /// Reads the list again each time it is shown, as the official Inbox does.
    func loadScheduledMessages() {
        scheduledMessages.loadTask?.cancel()
        scheduledMessages.isLoading = true
        scheduledMessages.errorMessage = nil
        let session = accountSession()
        scheduledMessages.loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let messages = try await session.provider.scheduledMessages()
                guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
                // Discord lists the latest send time first.
                scheduledMessages.messages = messages.sorted { $0.sendAt > $1.sendAt }
                scheduledMessages.hasLoaded = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
                scheduledMessages.errorMessage = error.localizedDescription
            }
            scheduledMessages.isLoading = false
        }
    }

    /// Posts the composer's message for later. The composer keeps everything
    /// until Discord accepts it, so a refusal loses nothing.
    func scheduleComposerMessage(
        in destination: MessageComposerDestination,
        attachments: [ForumPostAttachment]
    ) async {
        guard let channelID = composerSendChannelID(in: destination) else { return }
        let content = (destination == .channel ? draft : threadDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty, validateAttachmentCount(attachments) else { return }
        let reply = destination == .channel ? replyingTo : threadReplyingTo
        let outgoing = SendMessageDraft(
            channelID: channelID,
            content: content,
            replyTo: reply?.id,
            mentionsRepliedUser: destination == .channel ? replyMentionsAuthor : threadReplyMentionsAuthor,
            attachments: attachments
        )
        guard await submitSchedule(outgoing) else { return }
        await removeScheduledDraft(outgoing, reply: reply, from: destination, session: accountSession())
    }

    /// Like the official composer, a GIF or sticker picked while a send time is
    /// set is scheduled for it rather than sent; the typed draft stays.
    func schedulePickedMessage(
        content: String, stickerIDs: [String] = [], in destination: MessageComposerDestination
    ) async -> Bool {
        guard let channelID = composerSendChannelID(in: destination) else { return false }
        let reply = destination == .channel ? replyingTo : threadReplyingTo
        let outgoing = SendMessageDraft(
            channelID: channelID,
            content: content,
            replyTo: reply?.id,
            mentionsRepliedUser: destination == .channel ? replyMentionsAuthor : threadReplyMentionsAuthor,
            stickerIDs: stickerIDs
        )
        guard await submitSchedule(outgoing) else { return false }
        switch destination {
        case .channel: if replyingTo?.id == reply?.id { replyingTo = nil }
        case .thread: if threadReplyingTo?.id == reply?.id { threadReplyingTo = nil }
        }
        return true
    }

    /// One create at a time per conversation; returns whether Discord accepted it.
    private func submitSchedule(_ outgoing: SendMessageDraft) async -> Bool {
        let channelID = outgoing.channelID
        guard let date = scheduledMessages.sendDates[channelID],
              scheduledMessages.submittingChannelIDs.insert(channelID).inserted
        else { return false }
        defer { scheduledMessages.submittingChannelIDs.remove(channelID) }
        let session = accountSession()
        do {
            let scheduled = try await session.provider.scheduleMessage(outgoing, at: date)
            guard isCurrentAccountSession(session) else { return false }
            // A read that finished meanwhile may already list it.
            scheduledMessages.messages.removeAll { $0.id == scheduled.id }
            scheduledMessages.messages.append(scheduled)
            scheduledMessages.messages.sort { $0.sendAt > $1.sendAt }
            scheduledMessages.sendDates[channelID] = nil
            reloadScheduledMessagesIfLoading()
            showScheduledConfirmation(scheduled.sendAt, in: channelID)
            return true
        } catch ChatProviderError.scheduledMessageLimitReached {
            guard isCurrentAccountSession(session) else { return false }
            scheduledMessages.isLimitAlertPresented = true
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            errorMessage = "Failed to schedule message. \(error.localizedDescription)"
        }
        return false
    }

    /// Takes what Discord accepted out of the composer, keeping anything typed or
    /// attached meanwhile, including after the user left the conversation.
    private func removeScheduledDraft(
        _ outgoing: SendMessageDraft,
        reply: Message?,
        from destination: MessageComposerDestination,
        session: AppModelAccountSession
    ) async {
        let channelID = outgoing.channelID
        let sent = Set(outgoing.attachments.map(\.id))
        guard composerSendChannelID(in: destination) == channelID else {
            if var kept = composer.keptDrafts[channelID] {
                kept.attachments.removeAll { sent.contains($0.id) }
                composer.keptDrafts[channelID] = kept.isEmpty ? nil : kept
            }
            if let database = session.database,
               (try? await composer.storedDraft(in: channelID, database: database))?
               .trimmingCharacters(in: .whitespacesAndNewlines) == outgoing.content
            {
                composer.persistDraft("", channelID: channelID, database: database)
            }
            return
        }
        setComposerAttachments(composerAttachments(for: destination).filter { !sent.contains($0.id) }, for: destination)
        // Text typed meanwhile stays; a draft restored unchanged on return does not.
        switch destination {
        case .channel:
            if replyingTo?.id == reply?.id { replyingTo = nil }
            guard draft.trimmingCharacters(in: .whitespacesAndNewlines) == outgoing.content else { return }
            updateDraft("")
        case .thread:
            if threadReplyingTo?.id == reply?.id { threadReplyingTo = nil }
            guard threadDraft.trimmingCharacters(in: .whitespacesAndNewlines) == outgoing.content else { return }
            updateThreadDraft("")
        }
        stopLocalTyping(clearThrottle: true)
        translation.resetDraft(destination)
    }

    /// A read already under way may predate a change Discord just accepted.
    private func reloadScheduledMessagesIfLoading() {
        if scheduledMessages.isLoading { loadScheduledMessages() }
    }

    private func showScheduledConfirmation(_ date: Date, in channelID: ChannelID) {
        scheduledMessages.confirmations[channelID] = date
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, scheduledMessages.confirmations[channelID] == date else { return }
            scheduledMessages.confirmations[channelID] = nil
        }
    }

    func rescheduleMessage(_ message: ScheduledMessage, at date: Date) {
        updateScheduledMessage(message) { try await $0.rescheduleMessage(message.id, at: date) }
    }

    func editScheduledMessage(_ message: ScheduledMessage, content: String) {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // The official editor cancels a message saved without text, files or not:
        // its preview lists no attachments.
        guard !content.isEmpty else { return cancelScheduledMessage(message) }
        guard content != message.content else { return }
        updateScheduledMessage(message) {
            try await $0.editScheduledMessage(message.id, content: content, flags: message.flags)
        }
    }

    /// One change per message at a time, so an older answer cannot land last.
    private func updateScheduledMessage(
        _ message: ScheduledMessage,
        _ update: @escaping (any ChatProvider) async throws -> ScheduledMessage
    ) {
        guard scheduledMessages.pendingIDs.insert(message.id).inserted else { return }
        let session = accountSession()
        Task { [weak self] in
            defer { self?.scheduledMessages.pendingIDs.remove(message.id) }
            do {
                let updated = try await update(session.provider)
                guard let self, isCurrentAccountSession(session) else { return }
                if let index = scheduledMessages.messages.firstIndex(where: { $0.id == updated.id }) {
                    scheduledMessages.messages[index] = updated
                }
                scheduledMessages.messages.sort { $0.sendAt > $1.sendAt }
                reloadScheduledMessagesIfLoading()
            } catch {
                guard let self, isCurrentAccountSession(session) else { return }
                scheduledMessages.errorMessage = "Failed to update message. \(error.localizedDescription)"
            }
        }
    }

    func sendScheduledMessageNow(_ message: ScheduledMessage) {
        removeScheduledMessage(message, failure: "Failed to send scheduled message.") {
            try await $0.sendScheduledMessageNow(message.id)
        }
    }

    func cancelScheduledMessage(_ message: ScheduledMessage) {
        removeScheduledMessage(message, failure: "Failed to cancel scheduled message.") {
            try await $0.cancelScheduledMessage(message.id)
        }
    }

    /// The row stays, marked pending, until Discord confirms, as in the official list.
    private func removeScheduledMessage(
        _ message: ScheduledMessage,
        failure: String,
        _ operation: @escaping (any ChatProvider) async throws -> Void
    ) {
        guard scheduledMessages.pendingIDs.insert(message.id).inserted else { return }
        let session = accountSession()
        Task { [weak self] in
            do {
                try await operation(session.provider)
                guard let self, isCurrentAccountSession(session) else { return }
                scheduledMessages.messages.removeAll { $0.id == message.id }
                reloadScheduledMessagesIfLoading()
            } catch {
                guard let self, isCurrentAccountSession(session) else { return }
                scheduledMessages.errorMessage = "\(failure) \(error.localizedDescription)"
            }
            self?.scheduledMessages.pendingIDs.remove(message.id)
        }
    }
}
