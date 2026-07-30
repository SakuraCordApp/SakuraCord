import SwiftUI

extension ConcentricRectangle {
    init(
        cornerRadius: CGFloat,
        style _: RoundedCornerStyle = .continuous
    ) {
        self.init(
            corners: .concentric(
                minimum: .fixed(cornerRadius)
            ),
            isUniform: true
        )
    }
}
