import AppKit
import SakuraCordModels

/// Pointer state for the thread card: hover, press and cursor. Each change
/// invalidates only the card, not its row.
extension NativeTimelineCanvasView {
    func threadCardPointerHit(at point: CGPoint) -> MessageID? {
        messageID(at: point) { layouts[$0].threadFrame }
    }

    func setHoveredThreadMessageID(_ value: MessageID?) {
        guard pointer.hoveredThreadMessageID != value else { return }
        let old = pointer.hoveredThreadMessageID
        pointer.hoveredThreadMessageID = value
        for messageID in [old, value].compactMap({ $0 }) {
            invalidateThreadCard(messageID: messageID)
        }
    }

    func invalidateThreadCard(messageID: MessageID) {
        guard let index = items.firstIndex(where: { $0.messageID == messageID }),
              layouts.indices.contains(index),
              let frame = layouts[index].threadFrame
        else { return }
        setNeedsDisplay(frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: index)).insetBy(dx: -1, dy: -1))
    }

    func invalidatePressedThreadCard(
        _ old: NativeTimelinePointerActivationTarget?,
        _ new: NativeTimelinePointerActivationTarget?
    ) {
        for case let .thread(messageID, _)? in [old, new] {
            invalidateThreadCard(messageID: messageID)
        }
    }

    func threadCardInteraction(forMessageID messageID: MessageID?) -> NativeTimelineThreadCard.Interaction {
        guard let messageID, pointer.hoveredThreadMessageID == messageID else { return .idle }
        if case let .thread(pressedID, _)? = pressedActivationTarget, pressedID == messageID { return .pressed }
        return .hovered
    }

    func installThreadCardCursor(at index: Int, rowOrigin: CGFloat) {
        guard let frame = layouts[index].threadFrame else { return }
        addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
    }

    /// What the card shows beneath its name, for VoiceOver.
    func threadLastMessageSummary(_ thread: MessageThreadSummary) -> String {
        guard let preview = NativeTimelineThreadCard.shownPreview(
            for: thread, from: model?.threadPreviewMessages[thread.id]
        ) else { return NativeTimelineThreadCard.emptyText(for: thread) }
        let presented = MessageReplyPreview.presenting(preview)
        let summary = accessibilityResolvedText(presented.content, message: preview)
        return "\(presented.author.displayName): \(summary)"
    }
}
