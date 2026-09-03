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
        outgoingMessages.stickerUploadSourceURLByNonce[nonce] = nil
        removeOutgoingMessage(
            nonce: nonce,
            channelID: message.channelID
        )
        pruneOwnedPromisedAttachmentFiles()
    }

    func outgoingMediaPresentationPreserving(
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
        if !existing.attachments.isEmpty {
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
                let preservedPreviewURL: URL? = if let proxyURL = previous?.proxyURL {
                    proxyURL
                } else if previous?.url.isFileURL == true {
                    previous?.url
                } else {
                    nil
                }
                if let preservedPreviewURL, !attachment.url.isFileURL {
                    resolved.attachments[index].proxyURL = preservedPreviewURL
                }
            }
        }
        if !existing.stickers.isEmpty {
            for index in resolved.stickers.indices {
                let sticker = resolved.stickers[index]
                let previous = existing.stickers.first(where: {
                    $0.id == sticker.id
                }) ?? (existing.stickers.indices.contains(index)
                    ? existing.stickers[index]
                    : nil)
                if let mediaURL = previous?.mediaURL {
                    resolved.stickers[index].assetURL = mediaURL
                }
            }
        }
        return resolved
    }
}
