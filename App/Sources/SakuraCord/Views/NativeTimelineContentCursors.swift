import AppKit

extension NativeTimelineCanvasView {
    /// A message's media, reply preview and voice message controls take the
    /// pointing hand at the frames their clicks use, as does a search or
    /// inbox result, which opens anywhere. Installed before the text's own
    /// rects, which keep their I-beam where text can be selected.
    func installContentCursors(at index: Int, rowOrigin: CGFloat) {
        guard case let .message(row, _, _) = items[index] else { return }
        let layout = layouts[index]
        var frames: [CGRect] = []
        if actions?.openMessage != nil, let card = NativeTimelineResultActivationPolicy.frame(
            for: messageInteractionContext,
            searchCardFrame: layout.searchCardFrame,
            highlightFrame: layout.highlightFrame
        ) {
            frames.append(card)
        }
        if row.replyMessageID != nil, let reply = layout.replyFrame {
            frames.append(reply)
        }
        frames += layout.linkedImageRegions.map(\.frame)
        frames += layout.attachmentRegions.map(\.frame)
        frames += layout.embedRegions.compactMap(\.mediaFrame)
        for component in layout.componentLayouts {
            frames += component.images.map(\.frame) + component.media.map(\.frame)
            frames += component.containers.filter {
                $0.isSpoiler && !spoilerRevealStore.isMediaRevealed(
                    NativeTimelineComponentRevealKey(messageID: row.id, componentID: $0.componentID)
                )
            }.map(\.frame)
        }
        if let voice = layout.voiceMessageRegion {
            frames += [voice.playHitFrame, voice.speedHitFrame, voice.waveformHitFrame]
        }
        for frame in frames {
            addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
        }
    }
}
