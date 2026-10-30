import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    /// Whether an attachment still hides behind its spoiler cover.
    func isConcealedSpoiler(_ attachment: Attachment, in messageID: MessageID) -> Bool {
        attachment.isSpoiler && !spoilerRevealStore.isMediaRevealed(.attachment(messageID: messageID, attachmentID: attachment.id))
    }

    /// The visible file cards in a message row, attachment cards first. A
    /// message still being sent has only local files, which act through
    /// their upload rings, if any, rather than as downloads.
    private func fileCards(at index: Int, messageID: MessageID) -> [NativeTimelineFileCard] {
        let layout = layouts[index]
        let isLocalSend = items[index].messageRow?.message.isUnconfirmedLocalSend == true
        let attachments = isLocalSend ? [] : layout.fileCards.filter { !isConcealedSpoiler($0.attachment, in: messageID) }
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
            setNeedsDisplay(visibleRect)
            items.filter(showsFile).forEach { rebuildAccessibilityProxy(for: $0.identifier) }
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
        if let region = layout.componentLayouts.lazy.flatMap(\.files).first(where: { $0.frame == card.frame }) {
            _ = activateComponentMedia(
                id: region.componentID, openURL: region.openURL, isSpoiler: region.isSpoiler,
                layout: layout, message: message, rowIndex: rowIndex
            )
        } else {
            _ = activateAttachment(card.attachment, in: message, rowIndex: rowIndex)
        }
    }

    /// The tooltip of the timeline's buttons that have no label.
    func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?) -> String {
        guard let index = rowIndex(at: point.y), items.indices.contains(index), let messageID = items[index].messageID else { return "" }
        let local = CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index))
        guard let card = fileCards(at: index, messageID: messageID).first(where: { $0.buttonFrame.contains(local) }) else { return "" }
        return switch model?.attachmentDownloads.states[card.attachment.id] {
        case .downloading: "Cancel Download"
        case .finished: "Show in Finder"
        case .failed: "Retry Download"
        case nil: "Download"
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

extension DangerousDownloadPolicy {
    /// Asks with Discord's warning before a potentially dangerous download,
    /// as a sheet on `window` or, over the media viewer, which sits above
    /// sheets, as its own panel; true to download.
    @MainActor static func confirm(in window: NSWindow?) async -> Bool {
        guard window?.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Potentially Dangerous Download"
        alert.informativeText = """
            Whoa there! While programs downloaded from the internet may be beneficial, this type of file can damage \
            your device or steal your personal data. Make sure to only run executables from developers that you trust!
            """
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Continue to Download").hasDestructiveAction = true
        guard let window else {
            await Task.yield()
            return alert.runModal() == .alertSecondButtonReturn
        }
        return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
    }
}
