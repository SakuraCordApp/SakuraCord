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
    /// Messages being sent now or cancelled; they leave the list on success.
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

    func setScheduledSendDate(_ date: Date?, in destination: MessageComposerDestination) {
        guard let channelID = composerSendChannelID(in: destination) else { return }
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
        guard let channelID = composerSendChannelID(in: destination),
              let date = scheduledMessages.sendDates[channelID],
              !scheduledMessages.submittingChannelIDs.contains(channelID)
        else { return }
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
        let session = accountSession()
        scheduledMessages.submittingChannelIDs.insert(channelID)
        defer { scheduledMessages.submittingChannelIDs.remove(channelID) }
        do {
            let scheduled = try await session.provider.scheduleMessage(outgoing, at: date)
            guard isCurrentAccountSession(session) else { return }
            scheduledMessages.messages.append(scheduled)
            scheduledMessages.messages.sort { $0.sendAt > $1.sendAt }
            scheduledMessages.sendDates[channelID] = nil
            if composerSendChannelID(in: destination) == channelID {
                stopLocalTyping(clearThrottle: true)
                switch destination {
                case .channel:
                    replyingTo = nil
                    updateDraft("")
                case .thread:
                    threadReplyingTo = nil
                    updateThreadDraft("")
                }
                translation.resetDraft(destination)
                setComposerAttachments([], for: destination)
            }
            showScheduledConfirmation(scheduled.sendAt, in: channelID)
        } catch ChatProviderError.scheduledMessageLimitReached {
            guard isCurrentAccountSession(session) else { return }
            scheduledMessages.isLimitAlertPresented = true
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = "Failed to schedule message. \(error.localizedDescription)"
        }
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
        guard !content.isEmpty, content != message.content else { return }
        updateScheduledMessage(message) {
            try await $0.editScheduledMessage(message.id, content: content, flags: message.flags)
        }
    }

    private func updateScheduledMessage(
        _ message: ScheduledMessage,
        _ update: @escaping (any ChatProvider) async throws -> ScheduledMessage
    ) {
        let session = accountSession()
        Task { [weak self] in
            do {
                let updated = try await update(session.provider)
                guard let self, isCurrentAccountSession(session) else { return }
                if let index = scheduledMessages.messages.firstIndex(where: { $0.id == updated.id }) {
                    scheduledMessages.messages[index] = updated
                }
                scheduledMessages.messages.sort { $0.sendAt > $1.sendAt }
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
            } catch {
                guard let self, isCurrentAccountSession(session) else { return }
                scheduledMessages.errorMessage = "\(failure) \(error.localizedDescription)"
            }
            self?.scheduledMessages.pendingIDs.remove(message.id)
        }
    }
}
