import Foundation
import SakuraCordModels

extension AppModel {
    func discardFailedOutgoingMessage(_ message: Message) {
        guard message.outboxState == .failed,
              let nonce = message.nonce,
              outgoingState(
                nonce: nonce,
                channelID: message.channelID
              ) == .failed
        else { return }
        outgoingMessages.draftsByNonce[nonce] = nil
        removeOutgoingMessage(
            nonce: nonce,
            channelID: message.channelID
        )
        pruneOwnedPromisedAttachmentFiles()
    }

    func outgoingAttachmentPresentationPreserving(
        _ incoming: Message
    ) -> Message {
        let existing: Message? = {
            let matches: (Message) -> Bool = { message in
                message.id == incoming.id
                    || (incoming.nonce != nil && message.nonce == incoming.nonce)
            }
            if incoming.channelID == openThread?.id,
               let message = threadMessages.first(where: matches)
            {
                return message
            }
            if incoming.channelID == selectedChannelID,
               let message = messages.first(where: matches)
            {
                return message
            }
            return messageCache[incoming.channelID]?.first(where: matches)
        }()
        guard let existing else { return incoming }

        var resolved = incoming
        resolved.nonce = resolved.nonce ?? existing.nonce
        guard !existing.attachments.isEmpty else { return resolved }
        for index in resolved.attachments.indices {
            let attachment = resolved.attachments[index]
            guard attachment.mediaKind == .image
                    || attachment.mediaKind == .animatedImage
            else { continue }
            let previous = existing.attachments.first(where: {
                $0.id == attachment.id
            }) ?? (existing.attachments.indices.contains(index)
                ? existing.attachments[index]
                : nil)
            let localPreviewURL: URL? = if previous?.proxyURL?.isFileURL == true {
                previous?.proxyURL
            } else if previous?.url.isFileURL == true {
                previous?.url
            } else {
                nil
            }
            if let localPreviewURL, !attachment.url.isFileURL {
                resolved.attachments[index].proxyURL = localPreviewURL
            }
        }
        return resolved
    }
}
