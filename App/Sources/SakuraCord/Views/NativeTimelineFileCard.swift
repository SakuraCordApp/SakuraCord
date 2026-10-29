import AppKit
import SakuraCordModels

/// A file attachment's card, shared by message attachments and Components V2
/// file components: the geometry that painting, hit testing, and cursors
/// agree on. Outside a bubble it is a capsule like a plain voice message's;
/// inside one it sits straight on the bubble, as a voice message does. The
/// file's Finder icon leads, and a round button at the end downloads it. An
/// audio file leads with its play button instead, has a smaller download
/// button, and keeps its player's seek row below the name.
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
    var isAudio = false
    /// A message's text or code file, which opens in the media viewer; only
    /// its button downloads.
    var opensInViewer = false

    /// The name row's height; an audio card adds its seek row below.
    static func height(isInBubble: Bool, isAudio: Bool = false) -> CGFloat {
        InterfaceScale.metric(isInBubble ? 44 : 52) + (isAudio ? InterfaceScale.metric(32) : 0)
    }

    /// The capsule's padding around its icon and button, which keeps the
    /// button concentric with the capsule's end.
    private static func inset(isInBubble: Bool) -> CGFloat { isInBubble ? 0 : InterfaceScale.metric(8) }
    private static var iconSide: CGFloat { InterfaceScale.metric(40) }
    private static var buttonDiameter: CGFloat { InterfaceScale.metric(36) }
    private static var textGap: CGFloat { InterfaceScale.metric(10) }

    /// The width that fits the name and size, which a bubble also grows to.
    static func fittedWidth(for attachment: Attachment, isInBubble: Bool, maximumWidth: CGFloat) -> CGFloat {
        let text = max(
            NativeTimelineRowLayout.measuredTextWidth(attachment.filename, font: nameFont),
            NativeTimelineRowLayout.measuredTextWidth(sizeText(attachment.size), font: detailFont)
        )
        let width = inset(isInBubble: isInBubble) * 2 + iconSide + buttonDiameter + textGap * 2 + text
        // An audio card's seek row needs room to scrub.
        let minimum = attachment.mediaKind == .audio ? InterfaceScale.metric(320) : minimumWidth
        return min(maximumWidth, Self.maximumWidth, max(minimum, ceil(width)))
    }

    /// The name row, which is the whole card unless it plays audio.
    private var nameRow: CGRect {
        var row = frame
        row.size.height = Self.height(isInBubble: isInBubble)
        return row
    }

    /// The file type's Finder icon.
    var iconFrame: CGRect {
        let side = Self.iconSide
        return CGRect(x: frame.minX + Self.inset(isInBubble: isInBubble) - InterfaceScale.metric(2), y: nameRow.midY - side / 2, width: side, height: side)
    }

    /// An audio card's play button, where other cards show their icon.
    var playFrame: CGRect {
        let inset = (Self.iconSide - Self.buttonDiameter) / 2
        return iconFrame.insetBy(dx: inset, dy: inset)
    }

    /// The round download button, like a voice message's play button, or
    /// an audio card's smaller one beside its play button.
    var buttonFrame: CGRect {
        let slot = Self.buttonDiameter
        let diameter = isAudio ? InterfaceScale.metric(28) : slot
        return CGRect(
            x: frame.maxX - Self.inset(isInBubble: isInBubble) - (slot + diameter) / 2, y: nameRow.midY - diameter / 2,
            width: diameter, height: diameter
        )
    }

    /// What acts on the file: the whole card, a text file's button, or an
    /// audio card's name row with its Show in Finder or Retry link and button.
    var actionFrame: CGRect {
        isAudio ? nameFrame.union(detailFrame).union(buttonFrame) : opensInViewer ? buttonFrame : frame
    }

    /// An audio card's seek row, under the name and ending with the card.
    var playerRowFrame: CGRect {
        let minX = nameFrame.minX
        return CGRect(
            x: minX, y: nameRow.maxY - InterfaceScale.metric(isInBubble ? 2 : 6),
            width: max(1, buttonFrame.maxX - minX), height: InterfaceScale.metric(28)
        )
    }

    /// Where the card draws, including its hover highlight in a bubble.
    var highlightFrame: CGRect { frame.insetBy(dx: -InterfaceScale.metric(6), dy: -InterfaceScale.metric(4)) }

    var nameFrame: CGRect {
        let minX = iconFrame.maxX + Self.textGap
        return CGRect(
            x: minX, y: nameRow.midY - InterfaceScale.metric(17),
            width: max(1, buttonFrame.minX - Self.textGap - minX),
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
}

extension NativeTimelineComponentButtonTarget {
    /// The hover and press target of a file card.
    nonisolated static func fileCard(messageID: MessageID, attachmentID: String) -> Self {
        .init(messageID: messageID, componentID: "file:\(attachmentID)")
    }
}
