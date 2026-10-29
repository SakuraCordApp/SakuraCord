import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    /// The visible file cards in a message row, attachment cards first.
    private func fileCards(at index: Int, messageID: MessageID) -> [NativeTimelineFileCard] {
        let layout = layouts[index]
        let attachments = layout.fileCards.filter { !isConcealedSpoiler($0.attachment, in: messageID) }
        let components = layout.componentLayouts.flatMap { component -> [NativeTimelineFileCard] in
            guard !component.files.isEmpty else { return [] }
            let hiddenContainers = NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(
                in: component, messageID: messageID, store: spoilerRevealStore
            )
            return component.files.filter { region in
                !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                    region.frame, hiddenContainerFrames: hiddenContainers
                ) && !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                    messageID: messageID, contentID: region.componentID,
                    isSpoiler: region.isSpoiler, store: spoilerRevealStore
                )
            }.map(\.card)
        }
        return attachments + components
    }

    func fileCardPointerHit(at local: CGPoint, rowIndex: Int, rowOrigin: CGFloat, message: Message)
        -> ComponentButtonPointerHit? {
        for card in fileCards(at: rowIndex, messageID: message.id) {
            let state = model?.attachmentDownloads.states[card.attachment.id]
            let part = NativeTimelineFileCard.Part.allCases.lazy
                .compactMap { part in card.frame(of: part, state: state).map { (part, $0) } }
                .first { $0.1.contains(local) }
            guard part != nil || card.frame.contains(local) else { continue }
            return ComponentButtonPointerHit(
                target: .fileCard(messageID: message.id, attachmentID: card.attachment.id, part: part?.0),
                rowIndex: rowIndex, message: message, kind: .fileCard(card, part: part?.0),
                frame: (part?.1 ?? card.frame).offsetBy(dx: 0, dy: rowOrigin)
            )
        }
        return nil
    }

    func installFileCardCursors(at index: Int, rowOrigin: CGFloat) {
        guard let messageID = items[index].messageID else { return }
        for card in fileCards(at: index, messageID: messageID) {
            let state = model?.attachmentDownloads.states[card.attachment.id]
            for part in NativeTimelineFileCard.Part.allCases {
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
        func showsFile(_ item: NativeMessageTimelineItem) -> Bool {
            guard let message = item.messageRow?.message else { return false }
            return message.attachments.contains { $0.id == attachmentID }
                || NativeTimelineFileCard.isUnresolvedFileID(attachmentID, in: message)
        }
        // Bitmaps survive navigation, so cached rows elsewhere need it too.
        for (identifier, cached) in bitmapCache where showsFile(cached.item) {
            invalidateBitmap(identifier)
        }
        setNeedsDisplay(visibleRect)
        // Starting, finishing, or failing moves the card's clickable parts;
        // a progress tick does not.
        if case let .downloading(fraction)? = downloads.states[attachmentID], fraction > 0 { return }
        window?.invalidateCursorRects(for: self)
        items.filter(showsFile).forEach { rebuildAccessibilityProxy(for: $0.identifier) }
    }

    /// What activating a file card does in its current download state.
    func fileCardActionDescription(_ attachment: Attachment, name: String) -> String {
        switch model?.attachmentDownloads.states[attachment.id] {
        case .downloading: "Cancel downloading \(name)"
        case .finished: "Show \(name) in Finder"
        case .failed: "Retry downloading \(name)"
        case nil: "Download \(name)"
        }
    }
}
