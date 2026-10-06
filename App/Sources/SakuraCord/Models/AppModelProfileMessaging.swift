import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func sendProfileMessage(to userID: UserID, content: String, nonce: String = ClientNonce.make()) async -> Bool {
        guard userID != currentUser?.id,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let session = accountSession()
        do {
            let channel: Channel
            if let existing = snapshot?.channels.first(where: {
                $0.kind == .directMessage && $0.recipients.contains(where: { $0.id == userID })
            }) {
                channel = existing
            } else {
                channel = try await session.provider.ensurePrivateChannel(for: userID)
            }
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return false }
            if snapshot?.channels.contains(where: { $0.id == channel.id }) == false {
                snapshot?.channels.append(channel)
                forwardSearchSourceRevision &+= 1
            }
            if outgoingState(nonce: nonce, channelID: channel.id) == .confirmed { return true }
            if let outgoing = composer.outbox.draftsByNonce[nonce] {
                guard outgoing.channelID == channel.id, outgoing.content == content,
                      outgoingState(nonce: nonce, channelID: channel.id) == .failed
                else { return false }
                updateOutgoingState(.sending, nonce: nonce, channelID: channel.id)
                return await performOutgoingSend(outgoing, isRetry: true)
            }
            return await sendChannelMessage(
                channelID: channel.id,
                content: content,
                replyTo: nil,
                replyPreview: nil,
                attachments: [],
                clearsComposer: false,
                nonce: nonce
            )
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
            return false
        }
    }
}
