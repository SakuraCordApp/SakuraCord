import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    /// Whether a spoiler hides an upload's ring: it still hides its file
    /// card's button, but not the cover over an image.
    func hidesUploadRing(_ ring: NativeTimelineRowLayout.UploadRing, of message: Message) -> Bool {
        guard ring.mediaFrame == nil,
              let attachment = message.attachments.first(where: { $0.id == ring.attachmentID })
        else { return false }
        return spoilerRevealStore.isConcealed(attachment, in: message.id)
    }

    /// The visible file cards in a message row, attachment cards first. A
    /// message still being sent has only local files, which act through
    /// their upload rings, if any, rather than as downloads.
    func fileCards(at index: Int, messageID: MessageID) -> [NativeTimelineFileCard] {
        let layout = layouts[index]
        let isLocalSend = items[index].messageRow?.message.isUnconfirmedLocalSend == true
        let attachments = isLocalSend ? [] : layout.fileCards.filter {
            !spoilerRevealStore.isConcealed($0.attachment, in: messageID)
        }
        let components = layout.componentLayouts.flatMap { component -> [NativeTimelineFileCard] in
            let files = component.mediaRegions.filter { $0.fileCard != nil }
            guard !files.isEmpty else { return [] }
            let hiddenContainers = NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(
                in: component, messageID: messageID, store: spoilerRevealStore
            )
            return files.filter { region in
                !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                    region.frame, hiddenContainerFrames: hiddenContainers
                ) && !spoilerRevealStore.isConcealed(
                    messageID: messageID, contentID: region.componentID,
                    isSpoiler: region.isSpoiler
                )
            }.compactMap(\.fileCard)
        }
        return attachments + components
    }

    func fileCardPointerHit(at local: CGPoint, rowIndex: Int, rowOrigin: CGFloat, message: Message)
        -> ComponentButtonPointerHit? {
        let states = model?.attachmentDownloads.states
        for card in fileCards(at: rowIndex, messageID: message.id) {
            guard let part = card.part(at: local, state: states?[card.attachment.id]) else { continue }
            return ComponentButtonPointerHit(
                target: .fileCard(messageID: message.id, attachmentID: card.attachment.id, part: part),
                rowIndex: rowIndex, message: message, kind: .fileCard(card),
                frame: card.actionFrame.offsetBy(dx: 0, dy: rowOrigin)
            )
        }
        return nil
    }

    /// Where a file's cards draw, including their bubble hover highlight, so
    /// a hover or press redraws them alone rather than their row. Cards of
    /// one file share targets, so all of them are included.
    func fileCardDisplayFrame(_ target: NativeTimelineComponentButtonTarget, at index: Int) -> CGRect? {
        guard target.componentID.hasPrefix("file:") else { return nil }
        var frame: CGRect?
        for card in fileCards(at: index, messageID: target.messageID)
        where card.part(of: target, messageID: target.messageID) != nil {
            frame = frame?.union(card.highlightFrame) ?? card.highlightFrame
        }
        return frame?.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
    }

    func installFileCardCursors(at index: Int, rowOrigin: CGFloat) {
        guard let messageID = items[index].messageID else { return }
        for card in fileCards(at: index, messageID: messageID) {
            // The body previews and the button downloads, so both point; the
            // button names what it does.
            addCursorRect(card.frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
            addToolTip(card.buttonFrame.offsetBy(dx: 0, dy: rowOrigin), owner: self, userData: nil)
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
            let fileItems = items.filter(showsFile)
            if case .finished = downloads.states[attachmentID] {
                for messageID in fileItems.compactMap(\.messageID) {
                    fadeFileCardFinish(.fileCard(messageID: messageID, attachmentID: attachmentID, part: .button))
                }
            }
            setNeedsDisplay(visibleRect)
            fileItems.forEach { rebuildAccessibilityProxy(for: $0.identifier) }
            return
        }
        // A progress tick changes only the button's ring and the detail line.
        forEachDisplayedRow(in: visibleRect) { index in
            guard let messageID = items[index].messageID, showsFile(items[index]),
                  let frame = fileCardDisplayFrame(
                      .fileCard(messageID: messageID, attachmentID: attachmentID, part: .card), at: index
                  )
            else { return }
            setNeedsDisplay(frame)
        }
    }

    /// A file card's action. A download Discord deems potentially dangerous
    /// asks first, with Discord's warning.
    func activateFileCard(_ attachment: Attachment) {
        guard let downloads = model?.attachmentDownloads else { return }
        guard downloads.startsDownload(attachment), DangerousDownloadPolicy.isPotentiallyDangerous(attachment.url) else {
            downloads.activate(attachment)
            return
        }
        Task { @MainActor [weak self] in
            guard let window = self?.window, await DangerousDownloadPolicy.confirm(in: window) else { return }
            downloads.activate(attachment)
        }
    }

    /// A file card's body: previews the file in the media viewer.
    func previewFileCard(_ card: NativeTimelineFileCard, message: Message, rowIndex: Int) {
        let layout = layouts[rowIndex]
        if let region = layout.componentLayouts.lazy.flatMap(\.mediaRegions).first(where: {
            $0.fileCard != nil && $0.frame == card.frame
        }) {
            _ = activateComponentMedia(region, layout: layout, message: message, rowIndex: rowIndex)
        } else {
            _ = activateAttachment(card.attachment, in: message, rowIndex: rowIndex)
        }
    }

    /// What activating a file card does in its current download state.
    func fileCardAction(_ attachment: Attachment, name: String) -> (title: String, description: String) {
        switch model?.attachmentDownloads.states[attachment.id] {
        case .downloading: ("Cancel Download", "Cancel downloading \(name)")
        case .finished: ("Show in Finder", "Show \(name) in Finder")
        case .failed: ("Retry Download", "Retry downloading \(name)")
        case nil: ("Download", "Download \(name)")
        }
    }
}
