@testable import SakuraCord
import CoreGraphics
import Testing

typealias UnreadDividerGapGeometry = NativeTimelineUnreadDividerGapGeometry

struct UnreadDividerGapCase: Sendable, CustomTestStringConvertible {
    let name: String
    let isAppearing: Bool
    let space: CGFloat
    let startGap: CGFloat
    let startBeforeShift: CGFloat
    let atStart: UnreadDividerGapGeometry.Frame
    let atEnd: UnreadDividerGapGeometry.Frame

    var testDescription: String { name }

    func frame(progress: CGFloat) -> UnreadDividerGapGeometry.Frame {
        UnreadDividerGapGeometry.frame(
            isAppearing: isAppearing, spaceHeight: space, startGap: startGap,
            startBeforeShift: startBeforeShift, progress: progress
        )
    }
}

let unreadDividerGapCases: [UnreadDividerGapCase] = [
    // The static layout holds the divider, so the gap opens from nothing.
    UnreadDividerGapCase(
        name: "opening", isAppearing: true, space: 29, startGap: 0, startBeforeShift: 29,
        atStart: .init(gap: 0, shiftBefore: 29, shiftAfter: 0),
        atEnd: .init(gap: 29, shiftBefore: 0, shiftAfter: 0)
    ),
    // The static layout has no divider, so later rows are pushed down until it lands.
    UnreadDividerGapCase(
        name: "closing", isAppearing: false, space: 29, startGap: 29, startBeforeShift: 0,
        atStart: .init(gap: 29, shiftBefore: 0, shiftAfter: 29),
        atEnd: .init(gap: 0, shiftBefore: 0, shiftAfter: 0)
    ),
    // Closing was interrupted with 10 points still open, then the divider returns.
    UnreadDividerGapCase(
        name: "reversing", isAppearing: true, space: 29, startGap: 10, startBeforeShift: 0,
        atStart: .init(gap: 10, shiftBefore: 0, shiftAfter: -19),
        atEnd: .init(gap: 29, shiftBefore: 0, shiftAfter: 0)
    ),
    // Pinned to the bottom, the viewport follows the row's growth, so rows
    // before it moved up on screen by the space and rows after it did not.
    UnreadDividerGapCase(
        name: "added at the bottom of a pinned timeline", isAppearing: true, space: 21,
        startGap: 0, startBeforeShift: 21,
        atStart: .init(gap: 0, shiftBefore: 21, shiftAfter: 0),
        atEnd: .init(gap: 21, shiftBefore: 0, shiftAfter: 0)
    ),
]

@MainActor @Test(arguments: unreadDividerGapCases)
func `a divider gap starts on the picture before the update and lands on the static layout`(
    _ gap: UnreadDividerGapCase
) {
    #expect(gap.frame(progress: 0) == gap.atStart)
    #expect(gap.frame(progress: 1) == gap.atEnd)
}

@MainActor @Test func `the divider's space is how much its row changed`() {
    // The first message of a group loses its group spacing under the divider,
    // so the row grows by less than the divider itself.
    #expect(UnreadDividerGapGeometry.spaceHeight(
        isAppearing: true, dividerHeight: 29, heightBefore: 60, heightAfter: 81
    ) == 21)
    #expect(UnreadDividerGapGeometry.spaceHeight(
        isAppearing: false, dividerHeight: 29, heightBefore: 81, heightAfter: 60
    ) == 21)
    #expect(UnreadDividerGapGeometry.spaceHeight(
        isAppearing: true, dividerHeight: 29, heightBefore: 60, heightAfter: 89
    ) == 29)
    // A divider breaks a message group, so the row may also gain an author
    // header, and the space holds that too.
    #expect(UnreadDividerGapGeometry.spaceHeight(
        isAppearing: true, dividerHeight: 29, heightBefore: 40, heightAfter: 90
    ) == 50)
    #expect(UnreadDividerGapGeometry.spaceHeight(
        isAppearing: false, dividerHeight: 29, heightBefore: 90, heightAfter: 40
    ) == 50)
    // The row changed some other way, or in the wrong direction.
    #expect(UnreadDividerGapGeometry.spaceHeight(
        isAppearing: true, dividerHeight: 29, heightBefore: 60, heightAfter: 200
    ) == nil)
    #expect(UnreadDividerGapGeometry.spaceHeight(
        isAppearing: true, dividerHeight: 29, heightBefore: 60, heightAfter: 60
    ) == nil)
    #expect(UnreadDividerGapGeometry.spaceHeight(
        isAppearing: false, dividerHeight: 29, heightBefore: 60, heightAfter: 89
    ) == nil)
}

@MainActor @Test func `an update that also scrolled the timeline is not a divider gap`() {
    #expect(UnreadDividerGapGeometry.isFeasible(spaceHeight: 21, startBeforeShift: 21))
    #expect(UnreadDividerGapGeometry.isFeasible(spaceHeight: 21, startBeforeShift: -21))
    #expect(!UnreadDividerGapGeometry.isFeasible(spaceHeight: 21, startBeforeShift: 400))
}

@MainActor @Test func `the divider shows only down to the message below its gap`() {
    #expect(UnreadDividerGapGeometry.overlayHeight(gap: 0, spaceHeight: 21, dividerHeight: 29) == 8)
    #expect(UnreadDividerGapGeometry.overlayHeight(gap: 21, spaceHeight: 21, dividerHeight: 29) == 29)
    #expect(UnreadDividerGapGeometry.overlayHeight(gap: 10, spaceHeight: 29, dividerHeight: 29) == 10)
}

@MainActor @Test func `a closing divider that took its header is a picture of the whole gap`() {
    // The space is a 29 point divider and a 21 point header.
    #expect(UnreadDividerGapGeometry.includesHeader(spaceHeight: 50, dividerHeight: 29))
    #expect(!UnreadDividerGapGeometry.includesHeader(spaceHeight: 29, dividerHeight: 29))
    #expect(!UnreadDividerGapGeometry.includesHeader(spaceHeight: 21, dividerHeight: 29))
    for gap in stride(from: CGFloat(0), through: 50, by: 10) {
        #expect(UnreadDividerGapGeometry.overlayHeight(
            gap: gap, spaceHeight: 50, dividerHeight: 29, showsSpaceSnapshot: true
        ) == gap)
    }
    // An opening divider shows only down to the header, which the row paints.
    #expect(UnreadDividerGapGeometry.overlayHeight(gap: 10, spaceHeight: 50, dividerHeight: 29) == 0)
    #expect(UnreadDividerGapGeometry.overlayHeight(gap: 40, spaceHeight: 50, dividerHeight: 29) == 19)
    #expect(UnreadDividerGapGeometry.overlayHeight(gap: 50, spaceHeight: 50, dividerHeight: 29) == 29)
}

@MainActor @Test func `a closing avatar hangs below the picture of the space`() throws {
    let context = try #require(CGContext(
        data: nil, width: 200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let picture = NativeTimelineUnreadDividerSnapshot(
        image: try #require(context.makeImage()), scale: 2,
        // A 38 point avatar that starts under a 29 point divider.
        avatarExtent: CGSize(width: 50, height: 67)
    )
    let space = try #require(picture.top(50))
    #expect(space.height == 50)
    #expect(space.image.width == 200)
    let tail = try #require(picture.avatarTail(below: 50))
    #expect(tail.height == 17)
    #expect(tail.image.width == 100)
    // A header-only space with no avatar below it has no tail.
    #expect(picture.avatarTail(below: 70) == nil)
    #expect(UnreadDividerGapGeometry.overlayHeight(
        gap: 20, spaceHeight: 50, dividerHeight: 29, showsSpaceSnapshot: true, snapshotTailHeight: 17
    ) == 37)
}

@MainActor @Test func `rows before the divider start where they were on screen`() {
    let shift = UnreadDividerGapGeometry.startBeforeShift(topInViewport: 120, viewportMinY: 1000, staticTop: 1091)
    #expect(shift == 29)
    // Pinned to the bottom, the viewport followed the row's 21 points of growth.
    #expect(UnreadDividerGapGeometry.startBeforeShift(topInViewport: 500, viewportMinY: 1021, staticTop: 1500) == 21)
}
