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
        guard let card = fileCards(at: rowIndex, messageID: message.id).first(where: { $0.actionFrame.contains(local) })
        else { return nil }
        return ComponentButtonPointerHit(
            target: .fileCard(messageID: message.id, attachmentID: card.attachment.id),
            rowIndex: rowIndex, message: message, kind: .fileCard(card),
            frame: card.actionFrame.offsetBy(dx: 0, dy: rowOrigin)
        )
    }

    /// Where a file card draws, including its bubble hover highlight, so
    /// its press animation redraws the card alone rather than its row.
    func fileCardDisplayFrame(_ target: NativeTimelineComponentButtonTarget, at index: Int) -> CGRect? {
        fileCards(at: index, messageID: target.messageID)
            .first { .fileCard(messageID: target.messageID, attachmentID: $0.attachment.id) == target }
            .map { $0.frame.insetBy(dx: -InterfaceScale.metric(6), dy: -InterfaceScale.metric(4)).offsetBy(dx: 0, dy: displayedRowOrigin(at: index)) }
    }

    func installFileCardCursors(at index: Int, rowOrigin: CGFloat) {
        guard let messageID = items[index].messageID else { return }
        for card in fileCards(at: index, messageID: messageID) {
            addCursorRect(card.actionFrame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
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
        let isProgressTick = if case let .downloading(fraction)? = downloads.states[attachmentID] { fraction > 0 } else { false }
        guard isProgressTick else {
            setNeedsDisplay(visibleRect)
            items.filter(showsFile).forEach { rebuildAccessibilityProxy(for: $0.identifier) }
            return
        }
        // A progress tick changes only a card's ring and detail line, or a
        // text preview's footer.
        guard var index = rowIndex(at: max(0, visibleRect.minY)) else { return }
        while items.indices.contains(index), displayedRowOrigin(at: index) < visibleRect.maxY {
            if let messageID = items[index].messageID, showsFile(items[index]) {
                let origin = displayedRowOrigin(at: index)
                let frames = fileCards(at: index, messageID: messageID).filter { $0.attachment.id == attachmentID }.map(\.frame)
                    + layouts[index].textPreviews.filter { $0.attachment.id == attachmentID }.map(\.footerFrame)
                for frame in frames {
                    setNeedsDisplay(frame.offsetBy(dx: 0, dy: origin))
                }
            }
            index += 1
        }
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
