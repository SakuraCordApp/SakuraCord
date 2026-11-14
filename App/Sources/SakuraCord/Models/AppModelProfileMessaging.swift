import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func sendProfileMessage(to userID: UserID, content: String, nonce: String = ClientNonce.make()) async -> Bool {
        // Like Discord's composer, the text is trimmed and a bare `@silent`
        // clears it without sending anything.
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentContent = SilentMessagePrefix.split(content).content
        guard userID != currentUser?.id, !content.isEmpty, !composer.outbox.hasPendingDelivery(nonce: nonce)
        else { return false }
        guard !sentContent.isEmpty else { return true }
        let existing = snapshot?.channels.first {
            $0.kind == .directMessage && $0.recipients.contains { $0.id == userID }
        }
        if let existing, outgoingState(nonce: nonce, channelID: existing.id) == .confirmed {
            releaseProfileMessage(nonce: nonce)
            return true
        }
        guard let reservation = composer.outbox.reserveSubmission(nonce: nonce) else {
            composer.isSendQueueFullAlertPresented = true
            return false
        }
        defer { composer.outbox.releaseSubmission(reservation) }
        composer.outbox.retainReceipt(nonce: nonce)
        let session = accountSession()
        do {
            let channel: Channel
            if let existing {
                channel = existing
            } else {
                channel = try await session.provider.ensurePrivateChannel(for: userID)
            }
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return false }
            if snapshot?.channels.contains(where: { $0.id == channel.id }) == false {
                snapshot?.channels.append(channel)
                forwardSearchSourceRevision &+= 1
            }
            if outgoingState(nonce: nonce, channelID: channel.id) == .confirmed {
                releaseProfileMessage(nonce: nonce)
                return true
            }
            // Replace the preparation reservation synchronously with the delivery
            // turn, preserving capacity while DM creation is suspended.
            composer.outbox.releaseSubmission(reservation)
            if let outgoing = composer.outbox.draftsByNonce[nonce] {
                guard outgoing.channelID == channel.id, outgoing.content == sentContent,
                      outgoingState(nonce: nonce, channelID: channel.id) == .failed,
                      allowSlowmodeSubmission(in: channel.id)
                else { return false }
                updateOutgoingState(.sending, nonce: nonce, channelID: channel.id)
                let sent = await performOutgoingSend(outgoing, isRetry: true)
                if isCurrentAccountSession(session), sent { releaseProfileMessage(nonce: nonce) }
                return sent
            }
            let sent = await sendChannelMessage(
                channelID: channel.id,
                content: content,
                replyTo: nil,
                replyPreview: nil,
                attachments: [],
                clearsComposer: false,
                nonce: nonce
            )
            if isCurrentAccountSession(session), sent { releaseProfileMessage(nonce: nonce) }
            return sent
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
            return false
        }
    }

    func releaseProfileMessage(nonce: String) {
        if let outgoing = composer.outbox.draftsByNonce[nonce],
           outgoingState(nonce: nonce, channelID: outgoing.channelID) == .confirmed
        {
            composer.outbox.draftsByNonce[nonce] = nil
        }
        composer.outbox.releaseReceipt(nonce: nonce)
    }

    /// Opens the DM after a profile-card send, unless the account that sent
    /// it is no longer active.
    func profileMessageConversationOpener(for user: User) -> () -> Void {
        let session = accountSession()
        return { [weak self] in
            guard let self, isCurrentAccountSession(session) else { return }
            openDirectMessage(with: user)
        }
    }
}
