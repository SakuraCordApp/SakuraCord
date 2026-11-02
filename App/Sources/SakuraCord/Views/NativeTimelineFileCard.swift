import AppKit
import SakuraCordModels

/// A file attachment's card, shared by message attachments and Components V2
/// file components: the geometry that painting, hit testing, and cursors
/// agree on. Outside a bubble it is a capsule like a plain voice message's;
/// inside one it sits straight on the bubble, as a voice message does. The
/// file's Finder icon leads, and a round button at the end downloads it; the
/// rest of the card previews the file in the media viewer. An audio file's
/// card adds Discord's mini player below: a play glyph under the icon and a
/// seek bar.
struct NativeTimelineFileCard {
    static var spacing: CGFloat { InterfaceScale.metric(8) }
    static var minimumWidth: CGFloat { InterfaceScale.metric(220) }
    static var maximumWidth: CGFloat { InterfaceScale.metric(400) }
    static var nameFont: NSFont {
        .interfaceSystemFont(ofSize: InterfaceTypographyMetrics.messageTextSize, weight: .medium)
    }
    static var detailFont: NSFont { .interfaceMonospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    static var linkFont: NSFont { .interfaceSystemFont(ofSize: 12, weight: .semibold) }

    let frame: CGRect
    let attachment: Attachment
    let isInBubble: Bool

    /// The name row's height; an audio card adds its player row below.
    static func height(isInBubble: Bool, isAudio: Bool = false) -> CGFloat {
        InterfaceScale.metric(isInBubble ? 44 : 52) + (isAudio ? playerRowHeight : 0)
    }

    /// Discord's 32-pixel audio controls.
    private static var playerRowHeight: CGFloat { DiscordRichMessageMetrics.px(32) }

    /// The capsule's padding around its icon and button, which keeps the
    /// button concentric with the capsule's end.
    private static func inset(isInBubble: Bool) -> CGFloat { isInBubble ? 0 : InterfaceScale.metric(8) }
    static var iconSide: CGFloat { InterfaceScale.metric(40) }
    private static var buttonDiameter: CGFloat { InterfaceScale.metric(36) }
    private static var textGap: CGFloat { InterfaceScale.metric(10) }

    /// The width that fits the name and size, which a bubble also grows to.
    static func fittedWidth(for attachment: Attachment, isInBubble: Bool, maximumWidth: CGFloat) -> CGFloat {
        // Saved and failed files add Show in Finder or Retry to the detail line.
        let states: [AttachmentDownloadStore.State?] = [nil, .finished(attachment.url, folder: nil), .failed]
        let details = states.map { state in
            let detail = detail(for: state, size: attachment.size)
            return NativeTimelineRowLayout.measuredTextWidth(detail.text, font: detailFont)
                + NativeTimelineRowLayout.measuredTextWidth(detail.link ?? "", font: linkFont)
        }
        let text = max(NativeTimelineRowLayout.measuredTextWidth(attachment.filename, font: nameFont), details.max() ?? 0)
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

    /// The round download button, like a voice message's play button.
    var buttonFrame: CGRect {
        let diameter = Self.buttonDiameter
        return CGRect(
            x: frame.maxX - Self.inset(isInBubble: isInBubble) - diameter, y: nameRow.midY - diameter / 2,
            width: diameter, height: diameter
        )
    }

    /// The download button, which alone downloads the file.
    var actionFrame: CGRect { buttonFrame }

    /// The card's outline, which its snapshot zooms out of into the viewer.
    var cornerRadius: CGFloat {
        isInBubble ? InterfaceScale.metric(12) : Self.height(isInBubble: false) / 2
    }

    /// The parts of a card that take the pointer, each with its own hover
    /// and press: the body previews the file, and the button and link act
    /// on its download.
    nonisolated enum Part: String, CaseIterable {
        case card
        case button
        case link
    }

    /// The part under a point. The button takes only its circle, and the
    /// link only its words; the rest of the card is its body.
    func part(at point: CGPoint, state: AttachmentDownloadStore.State?) -> Part? {
        // An audio card's player row belongs to its player.
        guard frame.contains(point), !(hasPlayerRow && playerRowFrame.contains(point)) else { return nil }
        let button = buttonFrame
        if hypot(point.x - button.midX, point.y - button.midY) <= button.width / 2 { return .button }
        let detail = Self.detail(for: state, size: attachment.size)
        if let link = detail.link, linkFrame(after: detail.text, link: link).contains(point) { return .link }
        return .card
    }

    /// The part of this card that a hover or press target names.
    func part(of target: NativeTimelineComponentButtonTarget?, messageID: MessageID) -> Part? {
        guard let target, target.messageID == messageID else { return nil }
        return Part.allCases.first { target == .fileCard(messageID: messageID, attachmentID: attachment.id, part: $0) }
    }

    /// The detail line's Show in Finder or Retry link, as wide as its words.
    func linkFrame(after text: String, link: String) -> CGRect {
        var frame = detailFrame
        frame.origin.x += NativeTimelineRowLayout.measuredTextWidth(text, font: Self.detailFont)
        frame.size.width = min(
            NativeTimelineRowLayout.measuredTextWidth(link, font: Self.linkFont), max(0, detailFrame.maxX - frame.minX)
        )
        return frame
    }

    /// An audio card's player row, under the name row and spanning the
    /// icon to the download button. It starts just under the icon, as
    /// Discord's controls follow its metadata.
    /// Only a message's own audio card is laid out with a player row; a
    /// component's audio file card keeps the plain card height.
    var hasPlayerRow: Bool {
        frame.height > Self.height(isInBubble: isInBubble) + 0.5
    }

    var playerRowFrame: CGRect {
        CGRect(
            x: iconFrame.minX, y: nameRow.maxY - InterfaceScale.metric(2),
            width: max(1, buttonFrame.maxX - iconFrame.minX), height: Self.playerRowHeight
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
    /// The hover and press target of a part of a file card.
    nonisolated static func fileCard(
        messageID: MessageID, attachmentID: String, part: NativeTimelineFileCard.Part
    ) -> Self {
        .init(messageID: messageID, componentID: "file:\(part.rawValue):\(attachmentID)")
    }
}
