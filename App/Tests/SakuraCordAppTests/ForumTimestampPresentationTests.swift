import Foundation
import SakuraCordModels
@testable import SakuraCord
import Testing

@Test func `forum card message counter includes the starter post`() {
    let starterOnly = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 100),
            name: "Starter only",
            messageCount: 1
        )
    )
    let activeThread = ForumPost(
        thread: MessageThreadSummary(
            id: ChannelID(rawValue: 101),
            name: "Active thread",
            messageCount: 12
        )
    )

    #expect(starterOnly.replyCount == 0)
    #expect(
        ForumPostMessageCountPresentation.count(
            threadMessageCount: starterOnly.thread.messageCount
        ) == 1
    )
    #expect(activeThread.replyCount == 11)
    #expect(
        ForumPostMessageCountPresentation.count(
            threadMessageCount: activeThread.thread.messageCount
        ) == 12
    )
    #expect(
        ForumPostMessageCountPresentation.count(threadMessageCount: -1) == 0
    )
}

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
