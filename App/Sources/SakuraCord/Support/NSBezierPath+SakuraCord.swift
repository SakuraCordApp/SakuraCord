import AppKit
import SwiftUI

extension NSBezierPath {
    convenience init(
        concentricRoundedRect rect: CGRect,
        cornerRadius: CGFloat
    ) {
        let path = ConcentricRectangle(
            corners: .fixed(cornerRadius),
            isUniform: true
        )
        .path(in: rect)
        self.init(cgPath: path.cgPath)
    }

    /// Strokes a one-point border just inside `rect` in the current stroke
    /// colour, its corners concentric with `cornerRadius`.
    static func strokeHairline(_ rect: CGRect, cornerRadius: CGFloat) {
        let border = NSBezierPath(
            concentricRoundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: max(0, cornerRadius - 0.5)
        )
        border.lineWidth = 1
        border.stroke()
    }
}
