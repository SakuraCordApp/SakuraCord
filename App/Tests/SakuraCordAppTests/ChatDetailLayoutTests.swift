import CoreGraphics
@testable import SakuraCord
import Testing

@Test func `composer keeps a rounded fallback away from window corners`() {
    #expect(ChatChromeMetrics.composerMinimumCornerRadius == 12)
}

@Test func `timeline reserves the measured compact floating footer height`() {
    let compactFooterHeight: CGFloat = 86

    #expect(
        ChatDetailLayoutPolicy.bottomContentInset(
            measuredFooterHeight: compactFooterHeight
        ) == compactFooterHeight
    )
    #expect(
        ChatDetailLayoutPolicy.newMessagesButtonBottomPadding(
            bottomContentInset: compactFooterHeight
        ) == compactFooterHeight + ChatDetailLayoutPolicy.newMessagesButtonSpacing
    )
}

@Test func `timeline follows an expanded composer without changing the viewport`() {
    let expandedFooterHeight: CGFloat = 224

    #expect(
        ChatDetailLayoutPolicy.bottomContentInset(
            measuredFooterHeight: expandedFooterHeight
        ) == expandedFooterHeight
    )
}

@Test func `small and large windows keep the full timeline viewport`() {
    #expect(ChatDetailLayoutPolicy.timelineMinimumContentHeight(viewportHeight: 320) == 320)
    #expect(ChatDetailLayoutPolicy.timelineMinimumContentHeight(viewportHeight: 1_000) == 1_000)
}

@Test func `timeline uses a safe initial footer inset before measurement`() {
    #expect(
        ChatDetailLayoutPolicy.bottomContentInset(measuredFooterHeight: 0)
            == ChatDetailLayoutPolicy.defaultFloatingFooterHeight
    )
    #expect(
        ChatDetailLayoutPolicy.bottomContentInset(measuredFooterHeight: .nan)
            == ChatDetailLayoutPolicy.defaultFloatingFooterHeight
    )
}
