import AppKit
import CoreText
import SakuraCordModels

enum NativeTimelineSemanticColor {
    static func opacity(
        _ color: NSColor,
        _ multiplier: CGFloat
    ) -> NSColor {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        return resolved.withAlphaComponent(
            resolved.alphaComponent * min(max(multiplier, 0), 1)
        )
    }
}

enum NativeTimelinePostStarterDividerMetrics {
    static var rowHeight: CGFloat { InterfaceScale.metric(25) }
}

enum NativeTimelineDateSeparatorMetrics {
    static var rowHeight: CGFloat { InterfaceScale.metric(37) }
    static var verticalPadding: CGFloat { InterfaceScale.metric(12) }
    static var lineSpacing: CGFloat { InterfaceScale.metric(10) }
    static var labelHeight: CGFloat { InterfaceScale.metric(13) }

    static var font: NSFont {
        .interfaceSystemFont(ofSize: 10, weight: .semibold)
    }

    static func labelWidth(_ label: String) -> CGFloat {
        let attributed = NSAttributedString(
            string: label,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(
            CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        )
    }

    static func labelFrame(
        for label: String,
        in frame: CGRect
    ) -> CGRect {
        let width = labelWidth(label)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.minY + verticalPadding,
            width: width,
            height: labelHeight
        )
    }
}

enum NativeTimelineUnreadSeparatorMetrics {
    static var rowHeight: CGFloat { InterfaceScale.metric(29) }
    static var capsuleHeight: CGFloat { InterfaceScale.metric(19) }
}

enum NativeTimelineReplyMetrics {
    nonisolated static var lineHeight: CGFloat { InterfaceScale.metric(24) }
    static var horizontalSpacing: CGFloat { InterfaceScale.metric(5) }

    static var authorFont: NSFont {
        .messageSystemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption2
            ).pointSize + 2,
            weight: .medium
        )
    }

    static var summaryFont: NSFont {
        .messageSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 2)
    }

    nonisolated static var avatarDiameter: CGFloat { InterfaceScale.metric(15) }

    nonisolated static func avatarFrame(in replyContentFrame: CGRect) -> CGRect {
        CGRect(
            x: replyContentFrame.minX,
            y: replyContentFrame.minY + (lineHeight - avatarDiameter) / 2,
            width: avatarDiameter,
            height: avatarDiameter
        )
    }

    /// The media symbol's width and its gap from the summary.
    static var mediaSymbolReserve: CGFloat { InterfaceScale.metric(26) }

    static func summary(
        for preview: MessageReplyPreview,
        in message: Message,
        model source: AppModel?
    ) -> MessageReplySummary.Prepared {
        if let source {
            MessageReplySummary.summary(
                content: preview.content,
                mentionLabel: MessageMentionResolver(model: source, message: message).label
            )
        } else {
            MessageReplySummary.summary(content: preview.content)
        }
    }

    static func authorDisplayName(_ author: User, in message: Message) -> String {
        message.mentionedUsers.contains { $0.id == author.id }
            ? "@\(author.displayName)" : author.displayName
    }

    static func mediaSymbol(for preview: MessageReplyPreview) -> String? {
        switch preview.mediaKind {
        case .image, .animatedImage: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .file: "paperclip"
        case nil: nil
        }
    }

    static var unavailableFont: NSFont { summaryFont.italic }

    static let unavailableText = "Message could not be loaded"

    /// The natural width of a one-line reply preview, from its avatar to the
    /// end of its summary or media symbol.
    static func previewWidth(
        _ preview: MessageReplyPreview?,
        in message: Message,
        source: AppModel?
    ) -> CGFloat {
        guard let preview else {
            return textWidth(unavailableText, font: unavailableFont)
        }
        let presentation = source?.authorPresentation(for: preview, in: message)
        let author = presentation?.user ?? preview.author
        let authorFont = ProfileNameFontLoader.shared.resolvedFont(for: author, fallback: authorFont)
        let showsIndicator = source?.roleColorDisplay == .nextToNames
            && presentation?.roleColorHex != nil
        let summary = summary(for: preview, in: message, model: source).text
        return avatarDiameter
            + horizontalSpacing
            + (showsIndicator ? InterfaceScale.metric(16) : 0)
            + textWidth(authorDisplayName(author, in: message), font: authorFont)
            + horizontalSpacing
            + textWidth(summary, font: summaryFont)
            + (mediaSymbol(for: preview) == nil ? 0 : mediaSymbolReserve)
    }

    static func textWidth(
        _ value: String,
        font: NSFont
    ) -> CGFloat {
        let attributed = NSAttributedString(
            string: value,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(
            CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        )
    }
}
