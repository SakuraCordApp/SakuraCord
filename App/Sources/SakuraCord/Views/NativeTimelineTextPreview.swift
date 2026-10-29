import AppKit
import CoreText
import MessageRendering
import SakuraCordModels

/// Discord's inline preview of a text file attachment: the file's first
/// lines in a box above a footer with its name, size, and controls. Laid out
/// once with its row; the text is shaped here so drawing only clips it.
struct NativeTimelineTextPreview {
    /// The footer's clickable parts.
    enum Part: String, CaseIterable {
        case expand
        case language
        case viewWholeFile
        case more
    }

    static var maximumWidth: CGFloat { InterfaceScale.metric(720) }
    static var collapsedLineCount: Int { 6 }
    static var expandedLineCount: Int { 100 }
    static var nameFont: NSFont { .interfaceSystemFont(ofSize: 14) }
    static var sizeFont: NSFont { .interfaceSystemFont(ofSize: 12) }

    let frame: CGRect
    let attachment: Attachment
    let messageID: MessageID
    let presentation: AttachmentTextPreviewStore.Presentation
    let boxFrame: CGRect
    let footerFrame: CGRect
    /// The whole shaped text, positioned for no scrolling; nil while loading.
    let text: CTFrame?
    let textFrame: CGRect
    /// Code draws on the app's code-block colours; rendered Markdown on the
    /// timeline's.
    let isMarkdown: Bool
    let lineCount: Int
    let expandFrame: CGRect?
    let nameFrame: CGRect
    let sizeFrame: CGRect
    let languageFrame: CGRect
    let viewWholeFileFrame: CGRect?
    let moreFrame: CGRect

    var isExpanded: Bool { presentation.isExpanded }
    var preview: AttachmentTextPreviewStore.Preview? {
        if case let .loaded(preview) = presentation.state { preview } else { nil }
    }

    /// How far the expanded box's text can scroll.
    var maximumScroll: CGFloat {
        guard isExpanded else { return 0 }
        return max(0, textFrame.height + InterfaceScale.metric(26) - boxFrame.height)
    }

    func frame(of part: Part) -> CGRect? {
        switch part {
        case .expand: expandFrame
        case .language: languageFrame
        case .viewWholeFile: viewWholeFileFrame
        case .more: moreFrame
        }
    }

    /// The expand button's label, as Discord's tooltip words it.
    var expandLabel: String {
        let lines = "\(lineCount) \(lineCount == 1 ? "line" : "lines")"
        let count = preview?.bytesLeft == 0 ? lines : "More than \(lines)"
        return "\(isExpanded ? "Collapse" : "Expand") (\(count))"
    }

    static func make(
        attachment: Attachment,
        message: Message,
        presentation: AttachmentTextPreviewStore.Presentation,
        origin: CGPoint,
        width: CGFloat
    ) -> Self {
        let inset = InterfaceScale.metric(17)
        let preview: AttachmentTextPreviewStore.Preview? =
            if case let .loaded(preview) = presentation.state { preview } else { nil }
        let lineCount = preview?.lines.count ?? 0
        let isMarkdown = presentation.showsMarkdown
        // Discord keeps a stable scrollbar gutter right of the text.
        let textWidth = max(1, width - inset * 2 - InterfaceScale.metric(8))
        var text: CTFrame?
        var textHeight: CGFloat = 0
        if let preview {
            let framesetter = CTFramesetterCreateWithAttributedString(
                attributedText(
                    preview,
                    shownLines: presentation.isExpanded ? expandedLineCount : collapsedLineCount,
                    wrapsText: presentation.wrapsText,
                    language: presentation.language,
                    isMarkdown: isMarkdown
                )
            )
            textHeight = ceil(CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(), nil, CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil
            ).height)
            text = CTFramesetterCreateFrame(
                framesetter, CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: textWidth, height: textHeight), transform: nil), nil
            )
        }
        // The box holds at least 100 points of text between its margins, at
        // most 500 points expanded, and six lines' worth collapsed.
        let naturalHeight = max(InterfaceScale.metric(100), textHeight) + InterfaceScale.metric(26)
        let boxHeight = min(
            naturalHeight,
            presentation.isExpanded && preview != nil ? InterfaceScale.metric(500) : InterfaceScale.metric(122)
        )
        let boxFrame = CGRect(x: origin.x, y: origin.y, width: width, height: boxHeight)
        let showsExpand = preview != nil && (presentation.isExpanded || lineCount > collapsedLineCount)
        let footerFrame = CGRect(
            x: origin.x, y: boxFrame.maxY, width: width,
            height: InterfaceScale.metric(showsExpand ? 65 : 59)
        )
        let controlMidY = footerFrame.minY + InterfaceScale.metric(12) + (footerFrame.height - InterfaceScale.metric(25)) / 2
        let expandFrame = showsExpand
            ? CGRect(x: footerFrame.minX + InterfaceScale.metric(13), y: controlMidY - InterfaceScale.metric(20),
                     width: InterfaceScale.metric(40), height: InterfaceScale.metric(40))
            : nil
        let icon = InterfaceScale.metric(18)
        let moreFrame = CGRect(x: footerFrame.maxX - InterfaceScale.metric(17) - icon, y: controlMidY - icon / 2, width: icon, height: icon)
        let step = icon + InterfaceScale.metric(16)
        let viewWholeFileFrame = preview.map { _ in moreFrame.offsetBy(dx: -step, dy: 0) }
        let languageFrame = (viewWholeFileFrame ?? moreFrame).offsetBy(dx: -step, dy: 0)
        let nameMinX = expandFrame.map { $0.maxX + InterfaceScale.metric(8) } ?? footerFrame.minX + InterfaceScale.metric(13)
        let nameMaxX = languageFrame.minX - InterfaceScale.metric(16)
        let nameWidth = max(1, min(
            nameMaxX - nameMinX,
            max(
                NativeTimelineRowLayout.measuredTextWidth(attachment.filename, font: nameFont),
                NativeTimelineRowLayout.measuredTextWidth(sizeText(attachment.size), font: sizeFont)
            )
        ))
        let nameFrame = CGRect(x: nameMinX, y: controlMidY - InterfaceScale.metric(17), width: nameWidth, height: InterfaceScale.metric(18))
        return Self(
            frame: boxFrame.union(footerFrame),
            attachment: attachment,
            messageID: message.id,
            presentation: presentation,
            boxFrame: boxFrame,
            footerFrame: footerFrame,
            text: text,
            textFrame: CGRect(x: boxFrame.minX + inset, y: boxFrame.minY + inset, width: textWidth, height: textHeight),
            isMarkdown: isMarkdown,
            lineCount: lineCount,
            expandFrame: expandFrame,
            nameFrame: nameFrame,
            sizeFrame: CGRect(x: nameMinX, y: nameFrame.maxY, width: nameWidth, height: InterfaceScale.metric(16)),
            languageFrame: languageFrame,
            viewWholeFileFrame: viewWholeFileFrame,
            moreFrame: moreFrame
        )
    }

    /// The first `shownLines` lines, or all, with Discord's notice of what
    /// was left out: the bytes never fetched, or the remaining line count of
    /// an expanded whole file.
    static func displayedText(_ preview: AttachmentTextPreviewStore.Preview, shownLines: Int?) -> String {
        let lines = preview.lines
        let shown = shownLines ?? lines.count
        var notice = ""
        if preview.bytesLeft > 0 {
            notice = "... (\(sizeText(preview.bytesLeft)) left)"
        } else if shown == expandedLineCount, lines.count > shown {
            let left = lines.count - shown
            notice = "\n... (\(left) \(left == 1 ? "line" : "lines") left)"
        }
        return lines.prefix(shown).joined(separator: "\n") + notice
    }

    /// The text a preview shows, highlighted as a message's code block, or
    /// rendered as message Markdown.
    static func attributedText(
        _ preview: AttachmentTextPreviewStore.Preview,
        shownLines: Int?,
        wrapsText: Bool,
        language: String?,
        isMarkdown: Bool
    ) -> NSAttributedString {
        let text = displayedText(preview, shownLines: shownLines)
        guard !isMarkdown else {
            return NativeTimelineCoreText.scaledMarkdown(
                DiscordMarkdown.appKitPlan(text), baseFontSize: InterfaceScale.fontSize(InterfaceTypographyMetrics.messageTextSize)
            )
        }
        let output = NSMutableAttributedString(attributedString: NativeTimelineCoreText.scaledMarkdown(
            DiscordMarkdown.appKitCodePlan(text, language: language), baseFontSize: InterfaceScale.fontSize(14)
        ))
        let font = output.length > 0 ? output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = InterfaceScale.metric(16)
        paragraph.maximumLineHeight = InterfaceScale.metric(16)
        paragraph.lineBreakMode = wrapsText ? .byWordWrapping : .byClipping
        // Discord sets tabs four characters wide.
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * (font.map { (" " as NSString).size(withAttributes: [.font: $0]).width } ?? 8)
        output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
        return output
    }

    /// Discord's preview sizes: whole kilobytes rounded up below a megabyte,
    /// then whole megabytes rounded up, in steps of 1,000.
    static func sizeText(_ bytes: Int) -> String {
        let kilobytes = Double(bytes) / 1_000
        guard kilobytes >= 1_000 else { return "\(Int(kilobytes.rounded(.up))) KB" }
        let megabytes = (kilobytes / 1_000).rounded(.up)
        guard megabytes >= 1_000 else { return "\(Int(megabytes)) MB" }
        return "\(((megabytes / 1_000) * 10).rounded() / 10) GB"
    }
}

extension NativeTimelineComponentButtonTarget {
    /// The hover target of a text preview's body or one of its footer parts.
    nonisolated static func textPreview(
        messageID: MessageID,
        attachmentID: String,
        part: NativeTimelineTextPreview.Part?
    ) -> Self {
        .init(messageID: messageID, componentID: "text:\(attachmentID)" + (part.map { ":\($0.rawValue)" } ?? ""))
    }
}
