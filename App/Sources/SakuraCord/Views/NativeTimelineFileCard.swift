import AppKit
import SakuraCordModels

/// A file attachment's card, shared by message attachments and Components V2
/// file components: the geometry that painting, hit testing, and cursors
/// agree on. Outside a bubble it is a capsule like a plain voice message's;
/// inside one it sits straight on the bubble, as a voice message does.
struct NativeTimelineFileCard {
    static var spacing: CGFloat { InterfaceScale.metric(8) }
    static var minimumWidth: CGFloat { InterfaceScale.metric(220) }
    static var maximumWidth: CGFloat { InterfaceScale.metric(400) }
    static var nameFont: NSFont {
        .interfaceSystemFont(ofSize: InterfaceTypographyMetrics.messageTextSize, weight: .medium)
    }
    static var detailFont: NSFont { .interfaceMonospacedDigitSystemFont(ofSize: 12, weight: .regular) }

    let frame: CGRect
    let attachment: Attachment
    let isInBubble: Bool

    static func height(isInBubble: Bool) -> CGFloat { InterfaceScale.metric(isInBubble ? 44 : 52) }

    /// The capsule's padding around the badge, which keeps the badge
    /// concentric with the capsule's ends.
    private static func inset(isInBubble: Bool) -> CGFloat { isInBubble ? 0 : InterfaceScale.metric(8) }
    private static var badgeDiameter: CGFloat { InterfaceScale.metric(36) }
    private static var textGap: CGFloat { InterfaceScale.metric(10) }
    private static func trailingPadding(isInBubble: Bool) -> CGFloat { InterfaceScale.metric(isInBubble ? 4 : 18) }

    /// The width that fits the name and size, which a bubble also grows to.
    static func fittedWidth(for attachment: Attachment, isInBubble: Bool, maximumWidth: CGFloat) -> CGFloat {
        let text = max(
            NativeTimelineRowLayout.measuredTextWidth(attachment.filename, font: nameFont),
            NativeTimelineRowLayout.measuredTextWidth(sizeText(attachment.size), font: detailFont)
        )
        let width = inset(isInBubble: isInBubble) + badgeDiameter + textGap + text + trailingPadding(isInBubble: isInBubble)
        return min(maximumWidth, Self.maximumWidth, max(minimumWidth, ceil(width)))
    }

    /// The round badge that shows the file's type and is its action button,
    /// like a voice message's play button.
    var badgeFrame: CGRect {
        let diameter = Self.badgeDiameter
        return CGRect(
            x: frame.minX + Self.inset(isInBubble: isInBubble), y: frame.midY - diameter / 2,
            width: diameter, height: diameter
        )
    }

    var nameFrame: CGRect {
        let minX = badgeFrame.maxX + Self.textGap
        return CGRect(
            x: minX, y: frame.midY - InterfaceScale.metric(17),
            width: max(1, frame.maxX - Self.trailingPadding(isInBubble: isInBubble) - minX),
            height: InterfaceScale.metric(18)
        )
    }

    var detailFrame: CGRect {
        var line = nameFrame
        line.origin.y = line.maxY
        line.size.height = InterfaceScale.metric(16)
        return line
    }

    /// The detail line's text and its trailing link, if any, for a state.
    static func detail(
        for state: AttachmentDownloadStore.State?,
        size: Int
    ) -> (text: String, link: String?) {
        // A component file missing from the message's attachments has no size.
        let sizeText = size > 0 ? sizeText(size) : ""
        return switch state {
        case nil: (sizeText, nil)
        case let .downloading(fraction):
            ("\(Int(fraction * 100))%" + (sizeText.isEmpty ? "" : " of \(sizeText)"), nil)
        case .finished: (sizeText.isEmpty ? "" : "\(sizeText) · ", "Show in Finder")
        case .failed: ("Download failed · ", "Retry")
        }
    }

    /// Download identity for a file component whose media names no message
    /// attachment.
    static func unresolvedFileID(componentID: String, in message: Message) -> String {
        "\(message.id):\(componentID)"
    }

    static func isUnresolvedFileID(_ id: String, in message: Message) -> Bool {
        id.hasPrefix("\(message.id):")
    }

    /// Discord's `filesize`: bytes below 1 KB, then two decimals in 1024 steps.
    static func sizeText(_ bytes: Int) -> String {
        guard bytes >= 1_024 else { return "\(bytes.formatted()) bytes" }
        var value = Double(bytes)
        var unit = "B"
        for next in ["KB", "MB", "GB", "TB"] where value >= 1_024 {
            value /= 1_024
            unit = next
        }
        return value.formatted(.number.precision(.fractionLength(2))) + " " + unit
    }

    /// The SF Symbol for the file's type, from Discord's file-type classes.
    static func symbolName(for attachment: Attachment) -> String {
        let type = attachment.mediaType?.lowercased() ?? ""
        let name = attachment.filename.lowercased()
        if type.hasPrefix("image/vnd.adobe.photoshop") { return "paintbrush.pointed.fill" }
        if type.hasPrefix("image/svg+xml") { return "chevron.left.forwardslash.chevron.right" }
        if type.hasPrefix("image/") { return "photo.fill" }
        if type.hasPrefix("video/") { return "film.fill" }
        let pathExtension = (name as NSString).pathExtension
        if pathExtension == "pdf" { return "doc.richtext.fill" }
        if name.hasSuffix(".tar.gz") { return "doc.zipper" }
        return extensionSymbols.first { $0.extensions.contains(pathExtension) }?.symbol ?? "doc.fill"
    }

    private static let extensionSymbols: [(symbol: String, extensions: Set<String>)] = [
        ("paintbrush.pointed.fill", ["sketch", "ai", "psd", "aep"]),
        ("doc.zipper", ["rar", "zip", "7z", "tar", "gz"]),
        ("chevron.left.forwardslash.chevron.right", [
            "c++", "cpp", "cc", "c", "h", "hpp", "mm", "m", "json", "js", "ts", "rb", "rake", "py", "asm", "fs",
            "pyc", "dtd", "cgi", "bat", "rss", "java", "graphml", "idb", "lua", "o", "gml", "prl", "sls", "conf",
            "cmake", "make", "sln", "vbe", "cxx", "wbf", "vbs", "r", "wml", "php", "bash", "applescript", "fcgi",
            "yaml", "ex", "exs", "sh", "ml", "actionscript", "swift",
            "html", "xhtml", "htm", "xml", "xsd", "css", "styl",
        ]),
        ("doc.text.fill", ["txt", "rtf", "doc", "docx", "md", "pages", "log"]),
        ("rectangle.on.rectangle.angled.fill", ["ppt", "pptx", "pptm", "key"]),
        ("tablecells.fill", ["xls", "xlsx", "numbers", "csv"]),
        ("waveform", ["mp3", "ogg", "opus", "wav", "aiff", "flac", "m4a"]),
    ]
}

extension NativeTimelineComponentButtonTarget {
    /// The hover and press target of a file card.
    nonisolated static func fileCard(messageID: MessageID, attachmentID: String) -> Self {
        .init(messageID: messageID, componentID: "file:\(attachmentID)")
    }
}
