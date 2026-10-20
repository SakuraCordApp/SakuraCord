import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

private let now = Date(timeIntervalSince1970: 1_791_295_000)

private func snowflake(at date: Date) -> UInt64 {
    UInt64(date.timeIntervalSince1970 * 1_000 - 1_420_070_400_000) << 22
}

private func candidate(
    _ name: String,
    lastActivity: Date,
    joinedAt: Date,
    autoArchiveMinutes: Int = 10_080,
    hasUnread: Bool = false,
    mentions: Int = 0,
    isMuted: Bool = false,
    flags: UInt64 = 0
) -> SidebarThreadPolicy.Candidate {
    let id = snowflake(at: lastActivity.addingTimeInterval(-60))
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: id),
        guildID: GuildID(rawValue: 1),
        parentID: ChannelID(rawValue: 7),
        name: name,
        lastMessageID: MessageID(rawValue: snowflake(at: lastActivity)),
        flags: flags,
        archiveTimestamp: lastActivity.addingTimeInterval(-60),
        autoArchiveDuration: autoArchiveMinutes,
        notificationSettings: ThreadNotificationSettings(
            flags: 1,
            isMuted: isMuted,
            joinedAt: joinedAt
        )
    )
    return SidebarThreadPolicy.Candidate(
        thread: thread,
        latestMessageID: thread.lastMessageID,
        hasUnread: hasUnread,
        showsUnread: hasUnread && !isMuted,
        mentionCount: mentions
    )
}

private let day: TimeInterval = 86_400

@Test func `sidebar keeps only relevant joined threads, newest join first`() {
    let candidates = [
        candidate("recent, joined early", lastActivity: now - 2 * day, joinedAt: now - 4 * day),
        candidate("stale", lastActivity: now - 20 * day, joinedAt: now - 1 * day),
        candidate("recent, joined late", lastActivity: now - 3 * day, joinedAt: now - 2 * day),
        candidate("stale unread", lastActivity: now - 30 * day, joinedAt: now - 30 * day, hasUnread: true),
        candidate("stale muted unread", lastActivity: now - 30 * day, joinedAt: now - 30 * day, hasUnread: true, isMuted: true),
        candidate("stale muted mention", lastActivity: now - 30 * day, joinedAt: now - 31 * day, hasUnread: true, mentions: 1, isMuted: true),
        candidate("stale pinned", lastActivity: now - 30 * day, joinedAt: now - 32 * day, flags: 1 << 1),
    ]

    let rows = SidebarThreadPolicy.rows(for: candidates, openThread: nil, unreadOnly: false, now: now)

    #expect(rows.map(\.thread.name) == [
        "recent, joined late", "recent, joined early", "stale unread",
        "stale muted mention", "stale pinned",
    ])
}

@Test func `collapsed parents keep unread threads and the open thread stays first`() {
    let recent = candidate("recent", lastActivity: now - day, joinedAt: now - day)
    let unread = candidate("unread", lastActivity: now - 30 * day, joinedAt: now - 30 * day, hasUnread: true)
    let open = candidate("open", lastActivity: now - 40 * day, joinedAt: now - 40 * day)

    let rows = SidebarThreadPolicy.rows(
        for: [recent, unread, open],
        openThread: open,
        unreadOnly: true,
        now: now
    )

    #expect(rows.map(\.thread.name) == ["open", "unread"])
}

@Test func `timed relevance expires after the auto archive window`() throws {
    let thread = candidate("short", lastActivity: now - 3_000, joinedAt: now, autoArchiveMinutes: 60)
    let deadline = try #require(SidebarThreadPolicy.relevanceDeadline(for: thread))

    #expect(abs(deadline.timeIntervalSince(now + 600)) < 1)
    #expect(SidebarThreadPolicy.isRelevant(thread, now: deadline - 1))
    #expect(!SidebarThreadPolicy.isRelevant(thread, now: deadline))
}

@Test func `hide muted retains mentions and non-message activity extends relevance`() {
    let muted = candidate("muted", lastActivity: now - day, joinedAt: now, isMuted: true)
    let mentioned = candidate("mentioned", lastActivity: now - day, joinedAt: now, mentions: 1, isMuted: true)
    let rows = SidebarThreadPolicy.rows(for: [muted, mentioned], openThread: nil, unreadOnly: false, hideMuted: true, now: now)
    #expect(rows.map(\.thread.name) == ["mentioned"])
    var thread = candidate("old", lastActivity: now - 30 * day, joinedAt: now).thread
    thread.lastNonMessageActivityAt = now
    let updated = SidebarThreadPolicy.Candidate(thread: thread, latestMessageID: thread.lastMessageID,
        hasUnread: false, showsUnread: false, mentionCount: 0)
    #expect(SidebarThreadPolicy.relevanceDeadline(for: updated) == now + 7 * day)
}
