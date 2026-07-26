import AppKit
import Foundation
@testable import SakuraCord
import Testing

@MainActor
private func measured(_ value: String, width: CGFloat) -> CGFloat {
    RichMessageTextMeasurer.height(
        of: NSAttributedString(
            string: value,
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        ),
        width: width,
        minimumHeight: MessageRowLayoutMetrics.compactContentHeight
    )
}

@MainActor @Test func `message text measurement never returns less than a compact row`() {
    #expect(measured("", width: 400) == MessageRowLayoutMetrics.compactContentHeight)
    #expect(measured("hi", width: 400) >= MessageRowLayoutMetrics.compactContentHeight)
}

@MainActor @Test func `message text measurement grows with wrapped lines`() {
    let single = measured("short", width: 400)
    let wrapped = measured(String(repeating: "wrapping message content ", count: 40), width: 400)
    #expect(wrapped > single * 3)
}

@MainActor @Test func `narrower width wraps to a taller measurement`() {
    let content = String(repeating: "some conversational message text ", count: 8)
    #expect(measured(content, width: 200) > measured(content, width: 600))
}

/// The row height cache is only sound if measuring is free of side effects.
/// This previously ran against the displayed `NSTextView`, mutating its frame
/// and text container, so repeated or interleaved queries could disagree.
@MainActor @Test func `measurement is repeatable and order independent`() {
    let first = String(repeating: "alpha beta gamma ", count: 12)
    let second = String(repeating: "delta ", count: 3)

    let firstAt300 = measured(first, width: 300)
    let secondAt300 = measured(second, width: 300)

    #expect(measured(first, width: 300) == firstAt300)
    _ = measured(second, width: 500)
    _ = measured(first, width: 120)
    #expect(measured(first, width: 300) == firstAt300)
    #expect(measured(second, width: 300) == secondAt300)
}

@MainActor @Test func `ideal width collapses content onto one unbounded line`() {
    let content = String(repeating: "measure me ", count: 20)
    let value = NSAttributedString(
        string: content,
        attributes: [.font: NSFont.systemFont(ofSize: 15)]
    )
    let idealWidth = RichMessageTextMeasurer.idealWidth(of: value)

    #expect(idealWidth > 400)
    #expect(idealWidth <= RichMessageTextMeasurement.maximumWidth)

    let height = RichMessageTextMeasurer.height(
        of: value,
        width: idealWidth,
        minimumHeight: MessageRowLayoutMetrics.compactContentHeight
    )
    #expect(height < measured(content, width: 200))
}
