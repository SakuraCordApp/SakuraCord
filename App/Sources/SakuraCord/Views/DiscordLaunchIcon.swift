import AppKit

/// Discord's external-link ("launch") icon, drawn from the exact SVG path data
/// of the official client's `launchIcon` (24 x 24 viewBox, filled with the
/// button's `currentColor`).
enum DiscordLaunchIcon {
    private static let viewBox: CGFloat = 24
    private static let pathData = [
        "M15 2a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v6a1 1 0 1 1-2 0V4.41l-4.3 4.3a1 1 0 1 1-1.4-1.42L19.58 3H16a1 1 0 0 1-1-1Z",
        "M5 2a3 3 0 0 0-3 3v14a3 3 0 0 0 3 3h14a3 3 0 0 0 3-3v-6a1 1 0 1 0-2 0v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h6a1 1 0 1 0 0-2H5Z"
    ]
    private static let path = SVGPath.bezierPath(pathData.joined())

    /// Fills the icon into `frame` of a flipped (top-left origin) canvas.
    static func draw(in frame: CGRect, color: NSColor) {
        var transform = AffineTransform(translationByX: frame.minX, byY: frame.minY)
        transform.scale(frame.width / viewBox)
        guard let shape = path.copy() as? NSBezierPath else { return }
        shape.transform(using: transform)
        color.setFill()
        shape.fill()
    }
}

/// Parses SVG path data made of absolute and relative `M L H V A Z` commands.
private enum SVGPath {
    static func bezierPath(_ data: String) -> NSBezierPath {
        var scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t")
        let path = NSBezierPath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"
        let commandLetters = CharacterSet(charactersIn: "MmLlHhVvAa")
        while !scanner.isAtEnd {
            if scanner.scanString("Z") != nil || scanner.scanString("z") != nil {
                path.close()
                current = start
                continue
            }
            if let letter = scanner.scanCharacters(from: commandLetters)?.first {
                command = letter
            }
            let relative = command.isLowercase
            let origin = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                current = CGPoint(x: origin.x + number(&scanner), y: origin.y + number(&scanner))
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"
            case "L":
                current = CGPoint(x: origin.x + number(&scanner), y: origin.y + number(&scanner))
                path.line(to: current)
            case "H":
                current.x = origin.x + number(&scanner)
                path.line(to: current)
            case "V":
                current.y = origin.y + number(&scanner)
                path.line(to: current)
            default:
                let radius = CGSize(width: number(&scanner), height: number(&scanner))
                _ = number(&scanner) // x-axis rotation; the launch icon's arcs are circular
                let large = flag(&scanner)
                let sweep = flag(&scanner)
                let end = CGPoint(x: origin.x + number(&scanner), y: origin.y + number(&scanner))
                addArc(to: path, from: current, end: end, radius: radius, large: large, sweep: sweep)
                current = end
            }
        }
        return path
    }

    private static func number(_ scanner: inout Scanner) -> CGFloat {
        CGFloat(scanner.scanDouble() ?? 0)
    }

    /// Arc flags are single characters and may abut the next number.
    private static func flag(_ scanner: inout Scanner) -> Bool {
        scanner.scanCharacter() == "1"
    }

    /// SVG endpoint arc to cubic Béziers (SVG 1.1 implementation notes F.6.5, no rotation).
    private static func addArc(
        to path: NSBezierPath,
        from start: CGPoint,
        end: CGPoint,
        radius: CGSize,
        large: Bool,
        sweep: Bool
    ) {
        var rx = abs(radius.width)
        var ry = abs(radius.height)
        guard rx > 0, ry > 0 else { return path.line(to: end) }
        let halfX = (start.x - end.x) / 2
        let halfY = (start.y - end.y) / 2
        let lambda = halfX * halfX / (rx * rx) + halfY * halfY / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * halfY * halfY - ry * ry * halfX * halfX
        let denominator = rx * rx * halfY * halfY + ry * ry * halfX * halfX
        let sign: CGFloat = large == sweep ? -1 : 1
        let factor = sign * max(0, numerator / denominator).squareRoot()
        let centerOffset = CGPoint(x: factor * rx * halfY / ry, y: -factor * ry * halfX / rx)
        let center = CGPoint(
            x: centerOffset.x + (start.x + end.x) / 2,
            y: centerOffset.y + (start.y + end.y) / 2
        )
        let startAngle = atan2((halfY - centerOffset.y) / ry, (halfX - centerOffset.x) / rx)
        let endAngle = atan2((-halfY - centerOffset.y) / ry, (-halfX - centerOffset.x) / rx)
        var sweepAngle = endAngle - startAngle
        if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }
        if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }

        let segments = Int((abs(sweepAngle) / (.pi / 2)).rounded(.up))
        let step = sweepAngle / CGFloat(segments)
        let handle = 4 / 3 * tan(step / 4)
        func point(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
        }
        func tangent(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(angle), y: ry * cos(angle))
        }
        for index in 0 ..< segments {
            let from = startAngle + step * CGFloat(index)
            let to = from + step
            let origin = point(from)
            let target = index == segments - 1 ? end : point(to)
            let startTangent = tangent(from)
            let endTangent = tangent(to)
            path.curve(
                to: target,
                controlPoint1: CGPoint(x: origin.x + handle * startTangent.x, y: origin.y + handle * startTangent.y),
                controlPoint2: CGPoint(x: target.x - handle * endTangent.x, y: target.y - handle * endTangent.y)
            )
        }
    }
}
