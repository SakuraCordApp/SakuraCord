import AppKit
import SakuraCordModels

/// Discord's file attachment card, shared by message attachments and
/// Components V2 file components: the geometry that painting, hit testing,
/// and cursors agree on.
struct NativeTimelineFileCard {
    /// The card's clickable parts. Each acts on the file the same way; the
    /// card's body only shows the hover button.
    enum Part: String {
        case name
        case action
        case detailLink
    }

    static var maximumWidth: CGFloat { InterfaceScale.metric(432) }
    static var height: CGFloat { InterfaceScale.metric(74) }
    static var spacing: CGFloat { InterfaceScale.metric(8) }
    static var cornerRadius: CGFloat { InterfaceScale.metric(8) }
    static var nameFont: NSFont { .interfaceSystemFont(ofSize: InterfaceTypographyMetrics.messageTextSize) }
    static var detailFont: NSFont { .interfaceSystemFont(ofSize: 12) }

    let frame: CGRect
    let attachment: Attachment

    /// The 16-point padding inside the 1-point border.
    private var inset: CGFloat { InterfaceScale.metric(17) }

    var iconFrame: CGRect {
        CGRect(
            x: frame.minX + inset, y: frame.midY - InterfaceScale.metric(20),
            width: InterfaceScale.metric(30), height: InterfaceScale.metric(40)
        )
    }

    /// The filename line; the progress or size line sits 20 points below.
    func nameLineFrame(isDownloading: Bool) -> CGRect {
        let minX = iconFrame.maxX + InterfaceScale.metric(8)
        let maxX = isDownloading ? cancelFrame.minX - InterfaceScale.metric(4) : frame.maxX - inset
        return CGRect(
            x: minX, y: frame.midY - InterfaceScale.metric(18),
            width: max(1, maxX - minX), height: InterfaceScale.metric(20)
        )
    }

    func detailLineFrame(isDownloading: Bool) -> CGRect {
        var line = nameLineFrame(isDownloading: isDownloading)
        line.origin.y = line.maxY
        line.size.height = InterfaceScale.metric(16)
        return line
    }

    /// The filename's own extent, which alone acts like a link.
    var nameFrame: CGRect {
        var line = nameLineFrame(isDownloading: false)
        line.size.width = min(line.width, NativeTimelineRowPainter.measuredTextWidth(attachment.filename, font: Self.nameFont))
        return line
    }

    /// Discord's hover button, overhanging the card's top trailing corner.
    var hoverButtonFrame: CGRect {
        CGRect(
            x: frame.maxX - InterfaceScale.metric(24), y: frame.minY - InterfaceScale.metric(8),
            width: InterfaceScale.metric(32), height: InterfaceScale.metric(32)
        )
    }

    /// The cancel button that replaces the hover button while downloading.
    var cancelFrame: CGRect {
        CGRect(
            x: frame.maxX - inset - InterfaceScale.metric(24), y: frame.midY - InterfaceScale.metric(12),
            width: InterfaceScale.metric(24), height: InterfaceScale.metric(24)
        )
    }

    func actionFrame(isDownloading: Bool) -> CGRect {
        isDownloading ? cancelFrame : hoverButtonFrame
    }

    /// The detail line's text and its trailing link, if any, for a state.
    static func detail(
        for state: AttachmentDownloadStore.State?,
        size: Int
    ) -> (text: String, link: String?) {
        switch state {
        case .finished: (sizeText(size), "Show in Finder")
        case .failed: ("Download failed", "Retry")
        case .downloading, nil: (sizeText(size), nil)
        }
    }

    func detailLinkFrame(for state: AttachmentDownloadStore.State?) -> CGRect? {
        let detail = Self.detail(for: state, size: attachment.size)
        guard let link = detail.link else { return nil }
        let line = detailLineFrame(isDownloading: false)
        let minX = line.minX + NativeTimelineRowPainter.measuredTextWidth(detail.text, font: Self.detailFont)
            + InterfaceScale.metric(8)
        let width = NativeTimelineRowPainter.measuredTextWidth(link, font: Self.detailFont)
        return CGRect(x: minX, y: line.minY, width: min(width, max(0, line.maxX - minX)), height: line.height)
    }

    func frame(of part: Part, state: AttachmentDownloadStore.State?) -> CGRect? {
        let isDownloading = if case .downloading = state { true } else { false }
        return switch part {
        case .name: nameFrame
        case .action: actionFrame(isDownloading: isDownloading)
        case .detailLink: detailLinkFrame(for: state)
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

    /// Discord's file-type classes, matched in the same order.
    static func iconName(for attachment: Attachment) -> String {
        let type = attachment.mediaType?.lowercased() ?? ""
        let name = attachment.filename.lowercased()
        if type.hasPrefix("image/vnd.adobe.photoshop") { return "ps" }
        if type.hasPrefix("image/svg+xml") { return "webcode" }
        if type.hasPrefix("image/") { return "image" }
        if type.hasPrefix("video/") { return "video" }
        let pathExtension = (name as NSString).pathExtension
        if pathExtension == "pdf" { return "acrobat" }
        if name.contains(".ae") { return "ae" }
        if name.hasSuffix(".tar.gz") { return "archive" }
        return extensionClasses.first { $0.extensions.contains(pathExtension) }?.name ?? "unknown"
    }

    private static let extensionClasses: [(name: String, extensions: Set<String>)] = [
        ("sketch", ["sketch"]),
        ("ai", ["ai"]),
        ("archive", ["rar", "zip", "7z", "tar"]),
        ("code", [
            "c++", "cpp", "cc", "c", "h", "hpp", "mm", "m", "json", "js", "ts", "rb", "rake", "py", "asm", "fs",
            "pyc", "dtd", "cgi", "bat", "rss", "java", "graphml", "idb", "lua", "o", "gml", "prl", "sls", "conf",
            "cmake", "make", "sln", "vbe", "cxx", "wbf", "vbs", "r", "wml", "php", "bash", "applescript", "fcgi",
            "yaml", "ex", "exs", "sh", "ml", "actionscript",
        ]),
        ("document", ["txt", "rtf", "doc", "docx", "md", "pages", "ppt", "pptx", "pptm", "key", "log"]),
        ("spreadsheet", ["xls", "xlsx", "numbers", "csv"]),
        ("webcode", ["html", "xhtml", "htm", "xml", "xsd", "css", "styl"]),
        ("audio", ["mp3", "ogg", "opus", "wav", "aiff", "flac"]),
    ]
}

extension NativeTimelineComponentButtonTarget {
    /// The hover target of a file card's body or one of its parts.
    nonisolated static func fileCard(
        messageID: MessageID,
        attachmentID: String,
        part: NativeTimelineFileCard.Part?
    ) -> Self {
        .init(messageID: messageID, componentID: "file:\(attachmentID)" + (part.map { ":\($0.rawValue)" } ?? ""))
    }
}
