import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    /// The text previews in a message row that are not hidden as spoilers.
    private func textPreviews(at index: Int, messageID: MessageID) -> [NativeTimelineTextPreview] {
        layouts[index].textPreviews.filter { !isConcealedSpoiler($0.attachment, in: messageID) }
    }

    /// Whether an attachment still hides behind its spoiler cover.
    func isConcealedSpoiler(_ attachment: Attachment, in messageID: MessageID) -> Bool {
        attachment.isSpoiler && !spoilerRevealStore.isMediaRevealed(.attachment(messageID: messageID, attachmentID: attachment.id))
    }

    func textPreviewPointerHit(at local: CGPoint, rowIndex: Int, rowOrigin: CGFloat, message: Message)
        -> ComponentButtonPointerHit? {
        for preview in textPreviews(at: rowIndex, messageID: message.id) where preview.frame.contains(local) {
            let part = NativeTimelineTextPreview.Part.allCases.first { preview.frame(of: $0)?.contains(local) == true }
            return ComponentButtonPointerHit(
                target: .textPreview(messageID: message.id, attachmentID: preview.attachment.id, part: part),
                rowIndex: rowIndex, message: message, kind: .textPreview(preview, part: part),
                frame: (part.flatMap(preview.frame(of:)) ?? preview.frame).offsetBy(dx: 0, dy: rowOrigin)
            )
        }
        return nil
    }

    func installTextPreviewCursors(at index: Int, rowOrigin: CGFloat) {
        guard let messageID = items[index].messageID else { return }
        for preview in textPreviews(at: index, messageID: messageID) {
            for frame in NativeTimelineTextPreview.Part.allCases.compactMap(preview.frame(of:)) {
                addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
            }
        }
    }

    func activateTextPreview(
        _ preview: NativeTimelineTextPreview,
        part: NativeTimelineTextPreview.Part,
        message: Message,
        rowIndex: Int
    ) {
        guard let model else { return }
        switch part {
        case .expand:
            model.attachmentTextPreviews.toggleExpanded(preview.attachment, in: message)
        case .language:
            showTextPreviewLanguageMenu(preview, message: message, rowIndex: rowIndex)
        case .viewWholeFile:
            guard let text = preview.preview else { return }
            model.textFilePresentation = TextFilePresentation(
                attachment: preview.attachment, preview: text, language: preview.presentation.language,
                isMarkdown: preview.isMarkdown
            )
        case .more:
            showTextPreviewMenu(preview, message: message, rowIndex: rowIndex)
        }
    }

    /// Discord's More menu: download, and how the text is shown.
    private func showTextPreviewMenu(_ preview: NativeTimelineTextPreview, message: Message, rowIndex: Int) {
        guard let model else { return }
        let attachment = preview.attachment
        let menu = NSMenu()
        menu.autoenablesItems = false
        let download: (title: String, symbol: String) = switch model.attachmentDownloads.states[attachment.id] {
        case .downloading: ("Cancel Download", "xmark")
        case .finished: ("Show in Finder", "folder")
        case .failed, nil: ("Download", "arrow.down.to.line")
        }
        menu.addItem(actionItem(download.title, systemImage: download.symbol) { [weak model] in
            model?.attachmentDownloads.activate(attachment)
        })
        let wrap = actionItem("Wrap Text", systemImage: "text.word.spacing") { [weak model] in
            model?.attachmentTextPreviews.toggleWrapping(attachment, in: message.id)
        }
        wrap.state = preview.presentation.wrapsText ? .on : .off
        menu.addItem(wrap)
        if preview.presentation.isMarkdownLanguage {
            let markdown = actionItem("Render Markdown", systemImage: "doc.richtext") { [weak model] in
                model?.attachmentTextPreviews.toggleMarkdown(attachment, in: message.id)
            }
            markdown.state = preview.presentation.rendersMarkdown ? .on : .off
            menu.addItem(markdown)
        }
        popUp(menu, below: preview.moreFrame, rowIndex: rowIndex)
    }

    /// Discord's language picker: every language a preview can show as.
    private func showTextPreviewLanguageMenu(_ preview: NativeTimelineTextPreview, message: Message, rowIndex: Int) {
        guard let model else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for language in Attachment.textPreviewLanguages {
            let action = NativeTimelineMenuAction { [weak model] in
                model?.attachmentTextPreviews.setLanguage(language, for: preview.attachment, in: message.id)
            }
            let item = NSMenuItem(title: language, action: #selector(NativeTimelineMenuAction.performAction), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            item.state = language == preview.presentation.language ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, below: preview.languageFrame, rowIndex: rowIndex)
    }

    private func popUp(_ menu: NSMenu, below frame: CGRect, rowIndex: Int) {
        let anchor = frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: rowIndex))
        menu.popUp(positioning: nil, at: CGPoint(x: anchor.minX, y: anchor.maxY + InterfaceScale.metric(4)), in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        if !scrollTextPreview(with: event) { super.scrollWheel(with: event) }
    }

    /// Scrolls an expanded preview whose text runs past its box. Like a web
    /// view, a gesture stays with the preview it began over, and a mouse
    /// wheel turn moves the timeline once the preview reaches its end.
    private func scrollTextPreview(with event: NSEvent) -> Bool {
        let isWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        if isWheel || event.phase.contains(.began) {
            textPreviewScrollTarget = scrollableTextPreview(at: convert(event.locationInWindow, from: nil))?.attachment.id
        }
        guard let target = textPreviewScrollTarget,
              let previews = model?.attachmentTextPreviews,
              let index = visibleTextPreviewRow(containing: target),
              let preview = layouts[index].textPreviews.first(where: { $0.attachment.id == target })
        else { return false }
        // Momentum follows the gesture, so the preview keeps it until then.
        if event.momentumPhase.contains(.ended) { textPreviewScrollTarget = nil }
        let maximum = preview.maximumScroll
        let stored = previews.scrollOffsets[target] ?? .zero
        let current = CGPoint(x: min(stored.x, maximum.x), y: min(stored.y, maximum.y))
        let lineStep = event.hasPreciseScrollingDeltas ? 1 : InterfaceScale.metric(16)
        let next = CGPoint(
            x: min(max(current.x - event.scrollingDeltaX * lineStep, 0), maximum.x),
            y: min(max(current.y - event.scrollingDeltaY * lineStep, 0), maximum.y)
        )
        if next == current { return !isWheel }
        previews.setScrollOffset(next, for: target)
        invalidateBitmap(items[index].identifier)
        setNeedsDisplay(rowFrame(at: index))
        return true
    }

    private func scrollableTextPreview(at point: CGPoint) -> NativeTimelineTextPreview? {
        guard let index = rowIndex(at: point.y), layouts.indices.contains(index),
              let messageID = items[index].messageID
        else { return nil }
        let local = CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index))
        return textPreviews(at: index, messageID: messageID).first {
            $0.boxFrame.contains(local) && $0.maximumScroll != .zero
        }
    }

    private func visibleTextPreviewRow(containing attachmentID: String) -> Int? {
        guard var index = rowIndex(at: max(0, visibleRect.minY)) else { return nil }
        while items.indices.contains(index), layouts.indices.contains(index), displayedRowOrigin(at: index) < visibleRect.maxY {
            if layouts[index].textPreviews.contains(where: { $0.attachment.id == attachmentID }) { return index }
            index += 1
        }
        return nil
    }
}
