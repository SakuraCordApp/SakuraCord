import AppKit
import CoreText
import SakuraCordModels

nonisolated func coreTextLine(_ value: Any) -> CTLine {
    let object = value as AnyObject
    precondition(CFGetTypeID(object) == CTLineGetTypeID())
    return unsafeDowncast(object, to: CTLine.self)
}

nonisolated enum NativeTimelineSemanticColor {
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

nonisolated enum TimelineInlineVideoPolicy {
    static func canvasOwnsLoadingSurface(
        mediaIsVideo: Bool,
        autoplaysInline: Bool
    ) -> Bool {
        !mediaIsVideo || !autoplaysInline
    }
}

enum NativeTimelineDateSeparatorMetrics {
    nonisolated static var rowHeight: CGFloat { InterfaceScale.metric(37) }
    nonisolated static var verticalPadding: CGFloat { InterfaceScale.metric(12) }
    nonisolated static var lineSpacing: CGFloat { InterfaceScale.metric(10) }
    nonisolated static var labelHeight: CGFloat { InterfaceScale.metric(13) }

    nonisolated static var font: NSFont {
        .interfaceSystemFont(ofSize: 10, weight: .semibold)
    }

    nonisolated static func labelWidth(_ label: String) -> CGFloat {
        let attributed = NSAttributedString(
            string: label,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(
            CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        )
    }

    nonisolated static func labelFrame(
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

nonisolated enum NativeTimelineUnreadSeparatorMetrics {
    static var rowHeight: CGFloat { InterfaceScale.metric(29) }
    static var capsuleHeight: CGFloat { InterfaceScale.metric(19) }
    static var verticalPadding: CGFloat { InterfaceScale.metric(5) }
}

/// Text rules for the timeline thread card, matching Discord's client.
nonisolated enum NativeTimelineThreadCard {
    static var height: CGFloat { InterfaceScale.metric(54) }
    /// Discord capped message counts at 50 for threads created before July 2022.
    private static let cappedCountCutoff = Date(timeIntervalSince1970: 1_656_712_657)

    static func countText(_ thread: MessageThreadSummary) -> String {
        let count = thread.messageCount
        guard count > 0 else { return "See Thread" }
        guard count > 1 else { return "1 Message" }
        return "\(shownCount(thread)) Messages"
    }

    /// The count alone, for cards too narrow for the full label.
    static func compactCountText(_ thread: MessageThreadSummary) -> String? {
        thread.messageCount > 0 ? shownCount(thread) : nil
    }

    private static func shownCount(_ thread: MessageThreadSummary) -> String {
        let count = thread.messageCount
        return if count >= 100_000 {
            "100k+"
        } else if count >= 50, thread.id.createdAt <= cappedCountCutoff {
            "50+"
        } else {
            "\(count)"
        }
    }

    static func activityText(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let day: TimeInterval = 86_400
        return switch seconds {
        case ..<3_600: "\(max(1, Int(seconds / 60)))m ago"
        case ..<day: "\(Int(seconds / 3_600))h ago"
        case ..<(30 * day): "\(Int(seconds / day))d ago"
        case ..<(360 * day): ">30d ago"
        default: date.formatted(date: .long, time: .omitted)
        }
    }
}

nonisolated enum NativeTimelineReplyMetrics {
    nonisolated static var lineHeight: CGFloat { InterfaceScale.metric(24) }
    static var horizontalSpacing: CGFloat { InterfaceScale.metric(5) }

    static var authorFont: NSFont {
        .interfaceSystemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption2
            ).pointSize + 2,
            weight: .medium
        )
    }

    static var summaryFont: NSFont {
        .interfaceSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 2)
    }

    nonisolated static var avatarDiameter: CGFloat { InterfaceScale.metric(15) }

    /// The media symbol's width and its gap from the summary.
    static var mediaSymbolReserve: CGFloat { InterfaceScale.metric(26) }

    @MainActor static func summary(
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

    static var unavailableFont: NSFont {
        let baseFont = summaryFont
        return NSFont(
            descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
            size: baseFont.pointSize
        ) ?? baseFont
    }

    static let unavailableText = "Message could not be loaded"

    /// The natural width of a one-line reply preview, from its avatar to the
    /// end of its summary or media symbol.
    @MainActor static func previewWidth(
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
