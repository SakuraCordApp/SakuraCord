import AppKit
import CoreText
import MessageRendering
import SakuraCordModels

/// The inline preview of a text file attachment, as Discord shows it: the
/// file's first lines in a box above a footer with its name, size, and
/// controls. Laid out once with its row; the text is shaped here so drawing
/// only clips it. Outside a bubble the box and footer share a file card's
/// surface; inside one they sit on the bubble.
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
    let frame: CGRect
    let isInBubble: Bool
    let attachment: Attachment
    let messageID: MessageID
    let presentation: AttachmentTextPreviewStore.Presentation
    let boxFrame: CGRect
    let footerFrame: CGRect
    struct ShapedText {
        let value: NSAttributedString
        let framesetter: CTFramesetter
        let frame: CTFrame
    }

    /// The whole shaped text, positioned for no scrolling; nil while loading.
    let text: ShapedText?
    let textFrame: CGRect
    /// The width the text shows at once; unwrapped lines can run past it.
    let visibleTextWidth: CGFloat
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

    /// How far the box's text can scroll: sideways past unwrapped lines,
    /// and down once expanded.
    var maximumScroll: CGPoint {
        CGPoint(
            x: max(0, textFrame.width - visibleTextWidth),
            y: isExpanded ? max(0, textFrame.height + Self.textInset * 2 - boxFrame.height) : 0
        )
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

    /// The text's margin inside its box.
    static var textInset: CGFloat { InterfaceScale.metric(12) }

    static func make(
        attachment: Attachment,
        message: Message,
        presentation: AttachmentTextPreviewStore.Presentation,
        origin: CGPoint,
        width: CGFloat,
        isInBubble: Bool
    ) -> Self {
        let inset = textInset
        // The surface's padding, which keeps the box concentric with it.
        let padding = isInBubble ? 0 : InterfaceScale.metric(6)
        let preview: AttachmentTextPreviewStore.Preview? =
            if case let .loaded(preview) = presentation.state { preview } else { nil }
        let lineCount = preview?.lines.count ?? 0
        let isMarkdown = presentation.showsMarkdown
        // Discord keeps a stable scrollbar gutter right of the text.
        let textWidth = max(1, width - padding * 2 - inset * 2 - InterfaceScale.metric(8))
        var text: ShapedText?
        var textSize = CGSize(width: textWidth, height: 0)
        if let preview {
            let value = attributedText(
                preview,
                shownLines: presentation.isExpanded ? expandedLineCount : collapsedLineCount,
                wrapsText: presentation.wrapsText,
                language: presentation.language,
                isMarkdown: isMarkdown
            )
            let framesetter = CTFramesetterCreateWithAttributedString(value)
            func suggestedSize(width: CGFloat) -> CGSize {
                CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil
                )
            }
            // Unwrapped code keeps its longest line, which scrolls sideways.
            if !presentation.wrapsText, !isMarkdown {
                textSize.width = max(textWidth, ceil(suggestedSize(width: .greatestFiniteMagnitude).width))
            }
            textSize.height = ceil(suggestedSize(width: textSize.width).height)
            text = ShapedText(value: value, framesetter: framesetter, frame: CTFramesetterCreateFrame(
                framesetter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: textSize), transform: nil), nil
            ))
        }
        let textHeight = textSize.height
        // The box holds at least 100 points of text between its margins, at
        // most 500 points expanded, and six lines' worth collapsed.
        let naturalHeight = max(InterfaceScale.metric(100), textHeight) + inset * 2
        let boxHeight = min(
            naturalHeight,
            presentation.isExpanded && preview != nil ? InterfaceScale.metric(500) : InterfaceScale.metric(122)
        )
        let boxFrame = CGRect(x: origin.x + padding, y: origin.y + padding, width: width - padding * 2, height: boxHeight)
        let showsExpand = preview != nil && (presentation.isExpanded || lineCount > collapsedLineCount)
        let footerFrame = CGRect(
            x: origin.x, y: boxFrame.maxY, width: width, height: NativeTimelineFileCard.height(isInBubble: isInBubble)
        )
        // Round chips, inset like a file card's badge.
        let edge = isInBubble ? 0 : InterfaceScale.metric(8)
        let expandSize = InterfaceScale.metric(36)
        let expandFrame = showsExpand
            ? CGRect(x: footerFrame.minX + edge, y: footerFrame.midY - expandSize / 2, width: expandSize, height: expandSize)
            : nil
        let chip = NativeTimelineFileCard.chipDiameter
        let moreFrame = CGRect(
            x: footerFrame.maxX - edge - chip, y: footerFrame.midY - chip / 2, width: chip, height: chip
        )
        let step = chip + InterfaceScale.metric(4)
        let viewWholeFileFrame = preview.map { _ in moreFrame.offsetBy(dx: -step, dy: 0) }
        let languageFrame = (viewWholeFileFrame ?? moreFrame).offsetBy(dx: -step, dy: 0)
        let nameMinX = expandFrame.map { $0.maxX + InterfaceScale.metric(10) } ?? footerFrame.minX + edge + InterfaceScale.metric(6)
        let nameWidth = max(1, languageFrame.minX - InterfaceScale.metric(10) - nameMinX)
        let nameFrame = CGRect(x: nameMinX, y: footerFrame.midY - InterfaceScale.metric(17), width: nameWidth, height: InterfaceScale.metric(18))
        return Self(
            frame: CGRect(origin: origin, size: CGSize(width: width, height: footerFrame.maxY - origin.y)),
            isInBubble: isInBubble,
            attachment: attachment,
            messageID: message.id,
            presentation: presentation,
            boxFrame: boxFrame,
            footerFrame: footerFrame,
            text: text,
            textFrame: CGRect(origin: CGPoint(x: boxFrame.minX + inset, y: boxFrame.minY + inset), size: textSize),
            visibleTextWidth: textWidth,
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
