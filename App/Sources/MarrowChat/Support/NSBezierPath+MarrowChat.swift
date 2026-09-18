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
}
