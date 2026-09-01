@testable import SakuraCord
import CoreGraphics
import Testing

@MainActor
@Test func `voice grid uses vertical space instead of forcing a horizontal row`() {
    let layout = VoiceGridLayout.fitted(
        in: CGSize(width: 600, height: 900),
        participantCount: 3
    )

    #expect(layout.columns == 1)
    #expect(layout.rows == 3)
}

@MainActor
@Test func `voice grid centers an incomplete final row`() {
    let containerWidth: CGFloat = 1_200
    let layout = VoiceGridLayout.fitted(
        in: CGSize(width: containerWidth, height: 500),
        participantCount: 3
    )

    #expect(layout.columns == 2)
    #expect(layout.rows == 2)
    let finalRowOrigin = layout.horizontalOrigin(
        in: containerWidth,
        itemCount: 1
    )
    let finalCardCenter = finalRowOrigin + layout.tileSize.width / 2
    #expect(abs(finalCardCenter - containerWidth / 2) < 0.001)
}
