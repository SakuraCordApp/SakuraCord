import AppKit
import SwiftUI

nonisolated extension NSBezierPath {
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
}
