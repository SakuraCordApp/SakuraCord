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
    /// Conversations whose message is being scheduled right now, each marked by
    /// its request: an account switch clears them, and the next account may share
    /// a channel, so a request only ever removes its own mark.
    var submissions: [ChannelID: UUID] = [:]
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
        submissions = [:]
        confirmations = [:]
        isLimitAlertPresented = false
    }

    /// Discord lists the latest send time first.
    func sortLatestFirst() {
        messages.sort { $0.sendAt > $1.sendAt }
    }
}

extension AppModel {
    var scheduledMessageLimit: Int {
        ScheduledMessagePolicy.limit(premiumType: currentUser?.premiumType ?? 0)
    }

    func scheduledSendDate(in destination: MessageComposerDestination) -> Date? {
        // The composer asks on every keystroke; most never have a time set.
        guard !scheduledMessages.sendDates.isEmpty else { return nil }
        return composerSendChannelID(in: destination).flatMap { scheduledMessages.sendDates[$0] }
    }

    /// Whether the conversation's message is on its way to Discord; until it
    /// is answered, its time stays and nothing else leaves the composer.
    func isSchedulingMessage(in destination: MessageComposerDestination) -> Bool {
        guard !scheduledMessages.submissions.isEmpty else { return false }
        return composerSendChannelID(in: destination).map { scheduledMessages.submissions[$0] != nil } ?? false
    }

    func setScheduledSendDate(_ date: Date?, in destination: MessageComposerDestination) {
        guard let channelID = composerSendChannelID(in: destination),
              scheduledMessages.submissions[channelID] == nil
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
                scheduledMessages.messages = messages
                scheduledMessages.sortLatestFirst()
                scheduledMessages.hasLoaded = true
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
        let content = (destination == .channel ? draft : threadDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty, validateAttachmentCount(attachments),
              let (outgoing, reply) = scheduledDraft(content: content, attachments: attachments, in: destination),
              await submitSchedule(outgoing)
        else { return }
        await removeScheduledDraft(outgoing, reply: reply, from: destination, session: accountSession())
    }

    /// Like the official composer, a GIF or sticker picked while a send time is
    /// set is scheduled for it rather than sent; the typed draft stays. A
    /// sticker sent as an image goes as its file, fetched by `attachments` after
    /// the conversation and reply are taken, so leaving meanwhile changes neither.
    func schedulePickedMessage(
        content: String,
        stickerIDs: [String] = [],
        in destination: MessageComposerDestination,
        attachments: () async -> [ForumPostAttachment]? = { [] }
    ) async -> Bool {
        guard var (outgoing, reply) = scheduledDraft(content: content, stickerIDs: stickerIDs, in: destination),
              let files = await attachments()
        else { return false }
        outgoing.attachments = files
        guard await submitSchedule(outgoing) else { return false }
        clearReply(reply, in: destination)
        return true
    }

    /// The composer's reply goes with whatever it schedules.
    private func scheduledDraft(
        content: String,
        attachments: [ForumPostAttachment] = [],
        stickerIDs: [String] = [],
        in destination: MessageComposerDestination
    ) -> (SendMessageDraft, reply: Message?)? {
        guard let channelID = composerSendChannelID(in: destination) else { return nil }
        let reply = destination == .channel ? replyingTo : threadReplyingTo
        let outgoing = SendMessageDraft(
            channelID: channelID,
            content: content,
            replyTo: reply?.id,
            mentionsRepliedUser: destination == .channel ? replyMentionsAuthor : threadReplyMentionsAuthor,
            attachments: attachments,
            stickerIDs: stickerIDs
        )
        return (outgoing, reply)
    }

    /// Clears the reply that was scheduled, unless another was chosen meanwhile.
    private func clearReply(_ reply: Message?, in destination: MessageComposerDestination) {
        switch destination {
        case .channel: if replyingTo?.id == reply?.id { replyingTo = nil }
        case .thread: if threadReplyingTo?.id == reply?.id { threadReplyingTo = nil }
        }
    }

    /// One create at a time per conversation; returns whether Discord accepted it.
    private func submitSchedule(_ outgoing: SendMessageDraft) async -> Bool {
        let channelID = outgoing.channelID
        guard let date = scheduledMessages.sendDates[channelID], scheduledMessages.submissions[channelID] == nil
        else { return false }
        let submission = UUID()
        scheduledMessages.submissions[channelID] = submission
        defer {
            if scheduledMessages.submissions[channelID] == submission { scheduledMessages.submissions[channelID] = nil }
        }
        let session = accountSession()
        do {
            let scheduled = try await session.provider.scheduleMessage(outgoing, at: date)
            guard isCurrentAccountSession(session) else { return false }
            // A read that finished meanwhile may already list it.
            scheduledMessages.messages.removeAll { $0.id == scheduled.id }
            scheduledMessages.messages.append(scheduled)
            scheduledMessages.sortLatestFirst()
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
        clearReply(reply, in: destination)
        // Text typed meanwhile stays; a draft restored unchanged on return does not.
        let text = destination == .channel ? draft : threadDraft
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) == outgoing.content else { return }
        if destination == .channel { updateDraft("") } else { updateThreadDraft("") }
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
        changeScheduledMessage(message, failure: "Failed to update message.") {
            try await $0.rescheduleMessage(message.id, at: date)
        }
    }

    func editScheduledMessage(_ message: ScheduledMessage, content: String) {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // The official editor cancels a message saved without text, files or not:
        // its preview lists no attachments.
        guard !content.isEmpty else { return cancelScheduledMessage(message) }
        guard content != message.content else { return }
        changeScheduledMessage(message, failure: "Failed to update message.") {
            try await $0.editScheduledMessage(message.id, content: content, flags: message.flags)
        }
    }

    func sendScheduledMessageNow(_ message: ScheduledMessage) {
        changeScheduledMessage(message, failure: "Failed to send scheduled message.") {
            try await $0.sendScheduledMessageNow(message.id)
            return nil
        }
    }

    func cancelScheduledMessage(_ message: ScheduledMessage) {
        changeScheduledMessage(message, failure: "Failed to cancel scheduled message.") {
            try await $0.cancelScheduledMessage(message.id)
            return nil
        }
    }

    /// One change per message at a time, so an older answer cannot land last.
    /// The row stays, marked pending, until Discord confirms, as in the official
    /// list; a change answered with no message removes it.
    private func changeScheduledMessage(
        _ message: ScheduledMessage,
        failure: String,
        _ change: @escaping (any ChatProvider) async throws -> ScheduledMessage?
    ) {
        guard scheduledMessages.pendingIDs.insert(message.id).inserted else { return }
        let session = accountSession()
        Task { [weak self] in
            defer { self?.scheduledMessages.pendingIDs.remove(message.id) }
            do {
                let updated = try await change(session.provider)
                guard let self, isCurrentAccountSession(session) else { return }
                if let updated {
                    if let index = scheduledMessages.messages.firstIndex(where: { $0.id == updated.id }) {
                        scheduledMessages.messages[index] = updated
                    }
                    scheduledMessages.sortLatestFirst()
                } else {
                    scheduledMessages.messages.removeAll { $0.id == message.id }
                }
                reloadScheduledMessagesIfLoading()
            } catch {
                guard let self, isCurrentAccountSession(session) else { return }
                scheduledMessages.errorMessage = "\(failure) \(error.localizedDescription)"
            }
        }
    }
}
