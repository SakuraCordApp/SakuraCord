import Foundation
@testable import SakuraCord
import Testing

@Test func `forum timestamps use one rounded relative unit`() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    #expect(relativeText(secondsAgo: 15, now: now) == "now")
    #expect(relativeText(secondsAgo: 90, now: now) == "1m ago")
    #expect(relativeText(secondsAgo: 3_599, now: now) == "59m ago")
    #expect(relativeText(secondsAgo: 7_200, now: now) == "2h ago")
    #expect(relativeText(secondsAgo: 6 * 86_400, now: now) == "6d ago")
    #expect(relativeText(secondsAgo: 8 * 86_400, now: now) == "1w ago")
    #expect(relativeText(secondsAgo: 75 * 86_400, now: now) == "2mo ago")
    #expect(relativeText(secondsAgo: 800 * 86_400, now: now) == "2y ago")
}

@Test func `future forum timestamps do not expose a negative duration`() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let future = now.addingTimeInterval(60)

    #expect(
        ForumTimestampPresentation.roundedRelativeText(for: future, relativeTo: now)
            == "now"
    )
}

private func relativeText(secondsAgo: TimeInterval, now: Date) -> String {
    ForumTimestampPresentation.roundedRelativeText(
        for: now.addingTimeInterval(-secondsAgo),
        relativeTo: now
    )
}
