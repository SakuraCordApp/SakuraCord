import AppKit

/// The external-link icon on link buttons: Discord's box, open at its
/// top-right corner, with an arrow leaving through the gap, drawn as an SF
/// Symbol would draw it. The stroke and corner radius are SF Symbols' medium
/// weight, the weight of the button's label, in a 24-unit grid.
enum DiscordLaunchIcon {
    private static let grid: CGFloat = 24
    private static let strokeWidth: CGFloat = 2.09
    private static let path: NSBezierPath = {
        let path = NSBezierPath()
        let radius: CGFloat = 2.03
        path.move(to: CGPoint(x: 10, y: 3))
        path.appendArc(from: CGPoint(x: 3, y: 3), to: CGPoint(x: 3, y: 21), radius: radius)
        path.appendArc(from: CGPoint(x: 3, y: 21), to: CGPoint(x: 21, y: 21), radius: radius)
        path.appendArc(from: CGPoint(x: 21, y: 21), to: CGPoint(x: 21, y: 14), radius: radius)
        path.line(to: CGPoint(x: 21, y: 14))
        // The arrowhead's arms continue the box's top and right edges.
        path.move(to: CGPoint(x: 14, y: 3))
        path.line(to: CGPoint(x: 21, y: 3))
        path.line(to: CGPoint(x: 21, y: 10))
        path.move(to: CGPoint(x: 21, y: 3))
        path.line(to: CGPoint(x: 12, y: 12))
        return path
    }()

    /// Strokes the icon into `frame` of a flipped (top-left origin) canvas.
    static func draw(in frame: CGRect, color: NSColor) {
        let scale = frame.width / grid
        var transform = AffineTransform(translationByX: frame.minX, byY: frame.minY)
        transform.scale(scale)
        guard let shape = path.copy() as? NSBezierPath else { return }
        shape.transform(using: transform)
        shape.lineWidth = strokeWidth * scale
        shape.lineCapStyle = .round
        shape.lineJoinStyle = .round
        color.setStroke()
        shape.stroke()
    }
}
