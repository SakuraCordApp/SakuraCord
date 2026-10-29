import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    /// The visible file cards in a message row, attachment cards first.
    private func fileCards(at index: Int, messageID: MessageID) -> [NativeTimelineFileCard] {
        let layout = layouts[index]
        let attachments = layout.fileCards.filter {
            !$0.attachment.isSpoiler
                || spoilerRevealStore.isMediaRevealed(.attachment(messageID: messageID, attachmentID: $0.attachment.id))
        }
        let components = layout.componentLayouts.flatMap { component in
            let hiddenContainers = component.containers.filter {
                $0.isSpoiler && !spoilerRevealStore.isMediaRevealed(
                    NativeTimelineComponentRevealKey(messageID: messageID, componentID: $0.componentID)
                )
            }.map(\.frame)
            return component.files.filter { region in
                !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                    region.frame, hiddenContainerFrames: hiddenContainers
                ) && (!region.isSpoiler || spoilerRevealStore.isMediaRevealed(
                    NativeTimelineComponentRevealKey(messageID: messageID, componentID: region.componentID)
                ))
            }.map(\.card)
        }
        return attachments + components
    }

    func fileCardPointerHit(at local: CGPoint, rowIndex: Int, rowOrigin: CGFloat, message: Message)
        -> ComponentButtonPointerHit? {
        for card in fileCards(at: rowIndex, messageID: message.id) {
            let state = model?.attachmentDownloads.states[card.attachment.id]
            let part = [NativeTimelineFileCard.Part.action, .name, .detailLink].first {
                card.frame(of: $0, state: state)?.contains(local) == true
            }
            guard part != nil || card.frame.contains(local) else { continue }
            return ComponentButtonPointerHit(
                target: .fileCard(messageID: message.id, attachmentID: card.attachment.id, part: part),
                rowIndex: rowIndex, message: message, kind: .fileCard(card, part: part),
                frame: (part.flatMap { card.frame(of: $0, state: state) } ?? card.frame).offsetBy(dx: 0, dy: rowOrigin)
            )
        }
        return nil
    }

    func installFileCardCursors(at index: Int, rowOrigin: CGFloat) {
        guard let messageID = items[index].messageID else { return }
        for card in fileCards(at: index, messageID: messageID) {
            let state = model?.attachmentDownloads.states[card.attachment.id]
            for part in [NativeTimelineFileCard.Part.name, .action, .detailLink] {
                if let frame = card.frame(of: part, state: state) {
                    addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
                }
            }
        }
    }

    @objc func attachmentDownloadsDidChange(_ notification: Notification) {
        guard let downloads = model?.attachmentDownloads, notification.object as AnyObject === downloads,
              let attachmentID = notification.userInfo?[AttachmentDownloadStore.attachmentIDKey] as? String
        else { return }
        // Bitmaps survive navigation, so cached rows elsewhere need it too.
        let identifiers = bitmapCache.compactMap { identifier, cached in
            guard let message = cached.item.messageRow?.message else { return nil as NativeMessageTimelineItem.Identifier? }
            return message.attachments.contains { $0.id == attachmentID }
                || NativeTimelineFileCard.isUnresolvedFileID(attachmentID, in: message) ? identifier : nil
        }
        identifiers.forEach(invalidateBitmap)
        setNeedsDisplay(visibleRect)
        // The cancel button replaces the hover button while downloading.
        window?.invalidateCursorRects(for: self)
    }
}
