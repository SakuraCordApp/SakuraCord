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

    let requestID: UUID
    let kind: Kind
    let caption: String
    let actionTitle: String?
    let text: NativeTimelineTextPresentation.Value?

    static func make(
        row: MessageRowPresentation,
        source model: AppModel?,
        isOutgoingBubble: Bool
    ) -> Self? {
        guard row.isConversationRow,
              let entry = model?.messageTranslationPresentation(for: row.message)
        else { return nil }
        switch entry.status {
        case .loading:
            return Self(requestID: entry.requestID, kind: .loading, caption: "Translating…", actionTitle: nil, text: nil)
        case let .failed(message):
            return Self(requestID: entry.requestID, kind: .failed, caption: "Couldn’t translate: \(message)", actionTitle: "Dismiss", text: nil)
        case let .translated(result):
            let caption = TranslationLanguage.sourceDisplayName(result.detectedSourceLanguage)
                .map { "Translated from \($0)" } ?? "Translated"
            let visibleText = LinkedImagePresentation(content: result.text).visibleText
            let plan = NativeTimelineTextPlan(
                preparedText: visibleText.isEmpty ? nil : RichMessageAttributedText.prepare(source: visibleText),
                linkedImages: [],
                attributedText: nil,
                baseFontSize: InterfaceTypographyMetrics.messageTextSize
            )
            let value = NativeTimelineTextPresentation.make(message: row.message, plan: plan, source: model)
            return Self(
                requestID: entry.requestID,
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
        var captionWidth = InterfaceScale.metric(13) + 4 + NativeTimelineRowLayout.measuredTextWidth(caption, font: font)
        if let actionTitle {
            captionWidth += 8 + NativeTimelineRowLayout.measuredTextWidth("•", font: font)
                + NativeTimelineRowLayout.measuredTextWidth(actionTitle, font: font)
        }
        guard let attributed = text?.content?.value, attributed.length > 0 else {
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
        let regionID: NativeTimelineTextRegion
        let kind: NativeTimelineTranslationPresentation.Kind
        let isOutgoingBubble: Bool
        let frame: CGRect
        let iconFrame: CGRect
        let caption: String
        let captionFrame: CGRect
        let bulletFrame: CGRect?
        let actionTitle: String?
        let actionFrame: CGRect?
        let textFrame: CGRect?
        let text: NativeTimelineAttributedTextBox?
    }

    static var translationCaptionFont: NSFont {
        NSFont.interfacePreferredFont(forTextStyle: .caption1)
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
        let iconFrame = CGRect(x: origin.x, y: origin.y + 1, width: InterfaceScale.metric(13), height: InterfaceScale.metric(13))
        let actionWidth = presentation.actionTitle.map { measuredTextWidth($0, font: font) } ?? 0
        let bulletWidth = measuredTextWidth("•", font: font)
        let reservedWidth = actionWidth > 0 ? actionWidth + bulletWidth + 8 : 0
        let captionX = iconFrame.maxX + 4
        let captionFrame = CGRect(
            x: captionX,
            y: origin.y,
            width: min(measuredTextWidth(presentation.caption, font: font), max(0, maxX - captionX - reservedWidth)),
            height: InterfaceScale.metric(15)
        )
        let bulletFrame = presentation.actionTitle.map { _ in
            CGRect(x: captionFrame.maxX + 4, y: origin.y, width: bulletWidth, height: InterfaceScale.metric(15))
        }
        let actionFrame = bulletFrame.map { bullet in
            CGRect(x: bullet.maxX + 4, y: origin.y, width: min(actionWidth, max(0, maxX - bullet.maxX - 4)), height: InterfaceScale.metric(15))
        }
        var textFrame: CGRect?
        var bottom = origin.y + InterfaceScale.metric(15)
        if let text = presentation.text?.content {
            let height = measuredTextHeight(text.framesetter, value: text.value, length: text.value.length, width: width)
            bottom += 2 + NativeTimelineMarkdownChromeMetrics.leadingVisualInset(in: text.value)
            textFrame = CGRect(x: origin.x, y: bottom, width: width, height: height)
            bottom += height
        }
        return TranslationRegion(
            messageID: messageID,
            regionID: .translation(presentation.requestID),
            kind: presentation.kind,
            isOutgoingBubble: isOutgoingBubble,
            frame: CGRect(x: origin.x, y: origin.y, width: width, height: bottom - origin.y),
            iconFrame: iconFrame,
            caption: presentation.caption,
            captionFrame: captionFrame,
            bulletFrame: bulletFrame,
            actionTitle: presentation.actionTitle,
            actionFrame: actionFrame,
            textFrame: textFrame,
            text: presentation.text?.content
        )
    }
}

extension NativeTimelineRowPainter {
    static func drawMessageTranslation(_ input: NativeTimelineMessageDrawInput) {
        guard let region = input.layout.translationRegion else { return }
        let font = NativeTimelineRowLayout.translationCaptionFont
        let secondary: NSColor = region.isOutgoingBubble ? .sakuraCordLabelOnAccentColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let accent: NSColor = region.isOutgoingBubble ? .sakuraCordLabelOnAccentColor : .sakuraCordAccentColor
        let symbol = region.kind == .failed ? "exclamationmark.triangle" : "translate"
        systemSymbol(symbol, in: region.iconFrame, color: region.kind == .failed ? .systemRed : secondary, inset: 0)
        text(region.caption, in: region.captionFrame, font: font, color: secondary)
        if let bulletFrame = region.bulletFrame {
            text("•", in: bulletFrame, font: font, color: secondary)
        }
        if let actionTitle = region.actionTitle, let actionFrame = region.actionFrame {
            text(actionTitle, in: actionFrame, font: font, color: accent, isInteractiveHovered: input.interaction.isTranslationActionHovered)
        }
        guard let textFrame = region.textFrame, let text = region.text else { return }
        attributedText(
            text,
            in: NativeTimelineTextGeometry.messageContentDrawingFrame(textFrame),
            region: region.regionID,
            bubble: input.layout.bubbleRegion,
            input: input
        )
    }
}
