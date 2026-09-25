import AppKit
import CoreText
import SakuraCordModels

/// What a message row shows below its body for an in-memory translation.
struct NativeTimelineTranslationPresentation {
    enum Kind: Equatable {
        case loading
        case translated
        case failed
    }

    let kind: Kind
    let caption: String
    let actionTitle: String?
    let text: NativeTimelineTextPresentation.Value?

    static func make(
        row: MessageRowPresentation,
        model: AppModel?,
        isOutgoingBubble: Bool
    ) -> Self? {
        guard row.searchContext == nil, row.pinnedAt == nil, !row.isResource,
              let entry = model?.messageTranslationPresentation(for: row.message)
        else { return nil }
        switch entry.status {
        case .loading:
            return Self(kind: .loading, caption: "Translating…", actionTitle: nil, text: nil)
        case let .failed(message):
            return Self(kind: .failed, caption: "Couldn’t translate: \(message)", actionTitle: "Dismiss", text: nil)
        case let .translated(result):
            let caption = TranslationLanguage.sourceDisplayName(result.detectedSourceLanguage)
                .map { "Translated from \($0)" } ?? "Translated"
            let visibleText = LinkedImagePresentation(content: result.text).visibleText
            let plan = NativeTimelineTextPlan(
                preparedText: visibleText.isEmpty ? nil : RichMessageAttributedText.prepare(source: visibleText),
                linkedImages: [],
                attributedText: nil,
                baseFontSize: 15
            )
            let value = NativeTimelineTextPresentation.make(message: row.message, plan: plan, model: model)
            return Self(
                kind: .translated,
                caption: caption,
                actionTitle: "Show original",
                text: isOutgoingBubble ? NativeTimelineTextPresentation.outgoingBubble(value) : value
            )
        }
    }

    /// The widest line this block needs, so message bubbles can fit it.
    func preferredWidth(maximumWidth: CGFloat) -> CGFloat {
        let font = NativeTimelineRowLayout.translationCaptionFont
        var captionWidth = 17 + NativeTimelineRowLayout.measuredTextWidth(caption, font: font)
        if let actionTitle {
            captionWidth += 8 + NativeTimelineRowLayout.measuredTextWidth("• \(actionTitle)", font: font)
        }
        guard let attributed = text?.attributedContent, attributed.length > 0 else {
            return min(maximumWidth, captionWidth)
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let textWidth = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        return min(maximumWidth, max(captionWidth, textWidth))
    }
}

extension NativeTimelineRowLayout {
    struct TranslationRegion {
        let messageID: MessageID
        let kind: NativeTimelineTranslationPresentation.Kind
        let isOutgoingBubble: Bool
        let frame: CGRect
        let iconFrame: CGRect
        let caption: String
        let captionFrame: CGRect
        let actionTitle: String?
        let actionFrame: CGRect?
        let textFrame: CGRect?
        let attributedText: NSAttributedString?
        let framesetter: CTFramesetter?
    }

    static var translationCaptionFont: NSFont {
        NSFont.preferredFont(forTextStyle: .caption1)
    }

    static func translation(
        _ presentation: NativeTimelineTranslationPresentation,
        messageID: MessageID,
        isOutgoingBubble: Bool,
        origin: CGPoint,
        width: CGFloat
    ) -> TranslationRegion {
        let font = translationCaptionFont
        let maxX = origin.x + width
        let iconFrame = CGRect(x: origin.x, y: origin.y + 1, width: 13, height: 13)
        let actionWidth = presentation.actionTitle.map { measuredTextWidth("• \($0)", font: font) } ?? 0
        let reservedWidth = actionWidth > 0 ? actionWidth + 4 : 0
        let captionX = iconFrame.maxX + 4
        let captionFrame = CGRect(
            x: captionX,
            y: origin.y,
            width: min(measuredTextWidth(presentation.caption, font: font), max(0, maxX - captionX - reservedWidth)),
            height: 15
        )
        let actionFrame = presentation.actionTitle.map { _ in
            CGRect(x: captionFrame.maxX + 4, y: origin.y, width: min(actionWidth, max(0, maxX - captionFrame.maxX - 4)), height: 15)
        }
        var textFrame: CGRect?
        var bottom = origin.y + 15
        if let attributed = presentation.text?.attributedContent, let framesetter = presentation.text?.framesetter {
            let height = measuredTextHeight(framesetter, value: attributed, length: attributed.length, width: width)
            textFrame = CGRect(x: origin.x, y: bottom + 2, width: width, height: height)
            bottom += 2 + height
        }
        return TranslationRegion(
            messageID: messageID,
            kind: presentation.kind,
            isOutgoingBubble: isOutgoingBubble,
            frame: CGRect(x: origin.x, y: origin.y, width: width, height: bottom - origin.y),
            iconFrame: iconFrame,
            caption: presentation.caption,
            captionFrame: captionFrame,
            actionTitle: presentation.actionTitle,
            actionFrame: actionFrame,
            textFrame: textFrame,
            attributedText: presentation.text?.attributedContent,
            framesetter: presentation.text?.framesetter
        )
    }
}

extension NativeTimelineRowPainter {
    static func drawMessageTranslation(_ input: NativeTimelineMessageDrawInput) {
        guard let region = input.layout.translationRegion else { return }
        let font = NativeTimelineRowLayout.translationCaptionFont
        let secondary: NSColor = region.isOutgoingBubble ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
        let accent: NSColor = region.isOutgoingBubble ? .white : .sakuraCordAccentColor
        let symbol = region.kind == .failed ? "exclamationmark.triangle" : "translate"
        systemSymbol(symbol, in: region.iconFrame, color: region.kind == .failed ? .systemRed : secondary, inset: 0)
        text(region.caption, in: region.captionFrame, font: font, color: secondary)
        if let actionTitle = region.actionTitle, let actionFrame = region.actionFrame {
            text("• \(actionTitle)", in: actionFrame, font: font, color: accent)
        }
        guard let textFrame = region.textFrame,
              let attributed = region.attributedText,
              let framesetter = region.framesetter
        else { return }
        attributedText(
            attributed,
            framesetter: framesetter,
            in: NativeTimelineTextGeometry.messageContentDrawingFrame(textFrame),
            model: input.model
        )
    }
}
