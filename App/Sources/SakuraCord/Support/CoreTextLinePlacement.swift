import CoreGraphics
import CoreText

/// One line of CoreText as timeline and forum card text draws it: vertically
/// centered in its frame and aligned across it.
nonisolated struct CoreTextLinePlacement {
    let line: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    /// The line's origin, from the frame's leading edge and its bottom edge.
    let horizontalPosition: CGFloat
    let baseline: CGFloat

    init(_ line: CTLine, in frame: CGRect, alignment: CTTextAlignment) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        self.line = line
        self.width = width
        self.ascent = ascent
        self.descent = descent
        horizontalPosition = switch alignment {
        case .center: max(0, (frame.width - width) / 2)
        case .right: max(0, frame.width - width)
        default: 0
        }
        baseline = max(descent, (frame.height - ascent - descent - leading) / 2 + descent)
    }

    /// `line`, `width` wide, truncated to `maximumWidth` when it is wider and
    /// a truncation is given.
    static func truncating(
        _ line: CTLine,
        width: CGFloat,
        to maximumWidth: CGFloat,
        truncation: CTLineTruncationType?,
        token: () -> CTLine
    ) -> CTLine {
        guard width > maximumWidth, let truncation else { return line }
        return CTLineCreateTruncatedLine(line, Double(maximumWidth), truncation, token()) ?? line
    }

    func draw(in frame: CGRect, context: CGContext) {
        context.drawCoreText(in: frame) { context in
            context.textPosition = CGPoint(x: horizontalPosition, y: baseline)
            CTLineDraw(line, context)
        }
    }
}

nonisolated extension CGContext {
    /// Runs `draw` with CoreText's origin at `frame`'s bottom-left corner in
    /// this flipped context.
    func drawCoreText(in frame: CGRect, _ draw: (CGContext) -> Void) {
        saveGState()
        translateBy(x: frame.minX, y: frame.maxY)
        scaleBy(x: 1, y: -1)
        textMatrix = .identity
        draw(self)
        restoreGState()
    }
}
