import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    /// Whether an attachment still hides behind its spoiler cover.
    func isConcealedSpoiler(_ attachment: Attachment, in messageID: MessageID) -> Bool {
        attachment.isSpoiler && !spoilerRevealStore.isMediaRevealed(.attachment(messageID: messageID, attachmentID: attachment.id))
    }

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

    /// Where a file's cards draw, including their bubble hover highlight, so
    /// a press animation redraws them alone rather than their row. Cards of
    /// one file share a target, so all of them are included.
    func fileCardDisplayFrame(_ target: NativeTimelineComponentButtonTarget, at index: Int) -> CGRect? {
        guard target.componentID.hasPrefix("file:") else { return nil }
        var frame: CGRect?
        for card in fileCards(at: index, messageID: target.messageID)
        where .fileCard(messageID: target.messageID, attachmentID: card.attachment.id) == target {
            frame = frame?.union(card.highlightFrame) ?? card.highlightFrame
        }
        return frame?.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
    }

    func installFileCardCursors(at index: Int, rowOrigin: CGFloat) {
        guard let messageID = items[index].messageID else { return }
        for card in fileCards(at: index, messageID: messageID) {
            // A text file's body opens the viewer, so the whole card points.
            addCursorRect((card.isAudio ? card.actionFrame : card.frame).offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
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
        // A progress tick changes only the badge's ring and the detail line.
        forEachDisplayedRow(in: visibleRect) { index in
            guard let messageID = items[index].messageID, showsFile(items[index]),
                  let frame = fileCardDisplayFrame(.fileCard(messageID: messageID, attachmentID: attachmentID), at: index)
            else { return }
            setNeedsDisplay(frame)
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
