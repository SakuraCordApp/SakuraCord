import AppKit

extension NativeTimelineCanvasView {
    func drawMessageJumpHighlight(at index: Int) {
        guard let presentation = messageJumpHighlightPresentation(at: index)
        else { return }
        NSColor.sakuraCordAccentColor.withAlphaComponent(
            0.12 * presentation.opacity
        ).setFill()
        if let bubble = layouts[index].bubbleRegion {
            let rowFrame = rowFrame(at: index)
            NativeTimelineBubbleDrawing.path(for: NativeTimelineBubbleRegion(
                frame: bubble.frame.offsetBy(
                    dx: rowFrame.minX,
                    dy: rowFrame.minY
                ),
                isOutgoing: bubble.isOutgoing,
                showsTail: bubble.showsTail
            )).fill()
        } else {
            presentation.frame.fill()
        }
    }
}
