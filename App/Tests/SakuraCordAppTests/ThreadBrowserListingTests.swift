import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

private func thread(
    _ id: UInt64, name: String? = nil, archived: Bool = true, joined: Bool = false, daysAgo: Double
) -> ForumPost {
    ForumPost(thread: MessageThreadSummary(
        id: ChannelID(rawValue: id), guildID: GuildID(rawValue: 1), parentID: ChannelID(rawValue: 7),
        name: name ?? "Thread \(id)", isArchived: archived,
        archiveTimestamp: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
        notificationSettings: joined ? ThreadNotificationSettings() : nil
    ))
}

@Test func `archived pages advance by offset, ignore stale pages and do not repeat threads`() {
    var listing = ThreadBrowserListing()
    listing.append(
        ForumPostPage(posts: [thread(1, daysAgo: 1), thread(2, daysAgo: 2)], hasMore: true, nextOffset: 25),
        requestedOffset: 0
    )
    // A page for an offset that is no longer next is stale.
    listing.append(ForumPostPage(posts: [thread(9, daysAgo: 9)], hasMore: false, nextOffset: nil), requestedOffset: 0)
    #expect(listing.threads.map(\.id.rawValue) == [1, 2])
    #expect(listing.nextOffset == 25)

    // A thread archived meanwhile shifts Discord's offsets, repeating thread 2.
    listing.append(
        ForumPostPage(posts: [thread(2, daysAgo: 2), thread(3, daysAgo: 3)], hasMore: false, nextOffset: nil),
        requestedOffset: 25
    )
    #expect(listing.threads.map(\.id.rawValue) == [1, 2, 3])
    #expect(!listing.hasMore)
}

@Test func `records that left the archive in flight move the next page back`() {
    var listing = ThreadBrowserListing()
    // Two of the page's 25 raw records were deleted or reopened in flight.
    listing.append(
        ForumPostPage(posts: [thread(1, daysAgo: 1)], hasMore: true, nextOffset: 25),
        requestedOffset: 0, departedCount: 2
    )
    #expect(listing.nextOffset == 23)
    // It never moves back past the page it was requested from.
    listing.append(ForumPostPage(posts: [], hasMore: true, nextOffset: 48), requestedOffset: 23, departedCount: 40)
    #expect(listing.nextOffset == 23)
}

@Test func `live records update archived threads without treating absence as deletion`() {
    var listing = ThreadBrowserListing()
    listing.append(
        ForumPostPage(posts: [thread(1, daysAgo: 1), thread(2, daysAgo: 3)], hasMore: true, nextOffset: 25),
        requestedOffset: 0
    )

    listing.reconcile(with: [
        thread(1, name: "Renamed", daysAgo: 1),
        thread(2, archived: false, daysAgo: 0), // reopened: active again
        thread(4, daysAgo: 2), // archived within the loaded range
        thread(5, daysAgo: 30), // older than the loaded pages
    ])
    #expect(listing.threads.map(\.id.rawValue) == [1, 4])
    #expect(listing.threads.first?.thread.name == "Renamed")

    // Missing from the records is not deleted; only deletion removes a row.
    listing.reconcile(with: [])
    #expect(listing.threads.map(\.id.rawValue) == [1, 4])
    listing.remove(ChannelID(rawValue: 4))
    #expect(listing.threads.map(\.id.rawValue) == [1])

    // Reopening 2 and deleting 4 move later records back; archiving 4 only
    // repeats a record, which the next page drops.
    #expect(listing.nextOffset == 23)

    // Once the last page has arrived, every archived record belongs.
    listing.append(ForumPostPage(posts: [], hasMore: false, nextOffset: nil), requestedOffset: 23)
    listing.reconcile(with: [thread(5, daysAgo: 30)])
    #expect(listing.threads.map(\.id.rawValue) == [1, 5])
}

@Test func `sections list each thread once and split joined from other active threads`() {
    var listing = ThreadBrowserListing()
    listing.append(
        ForumPostPage(posts: [thread(1, daysAgo: 1), thread(2, daysAgo: 2)], hasMore: false, nextOffset: nil),
        requestedOffset: 0
    )
    let sections = ThreadBrowserSections.make(
        records: [
            thread(1, archived: false, joined: true, daysAgo: 0), // active again, still on the page
            thread(3, archived: false, daysAgo: 4),
            thread(2, daysAgo: 2),
        ],
        listing: listing
    )

    #expect(sections.joined.map(\.id.rawValue) == [1])
    #expect(sections.otherActive.map(\.id.rawValue) == [3])
    #expect(sections.older.map(\.id.rawValue) == [2])
}

@Test func `private threads the user cannot read leave every section`() {
    var left = thread(4, archived: false, daysAgo: 1)
    left.thread.isPrivate = true
    var joined = thread(5, archived: false, joined: true, daysAgo: 2)
    joined.thread.isPrivate = true
    var archivedPrivate = thread(6, daysAgo: 3)
    archivedPrivate.thread.isPrivate = true
    var listing = ThreadBrowserListing()
    listing.append(ForumPostPage(posts: [archivedPrivate], hasMore: false, nextOffset: nil), requestedOffset: 0)
    let permissions = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
    let canRead = { (post: ForumPost) in
        ThreadActionPolicy(
            thread: post.thread, currentUserID: UserID(rawValue: 9),
            parentPermissions: permissions, parentKind: .text
        ).canRead
    }

    let sections = ThreadBrowserSections.make(records: [left, joined, thread(7, archived: false, daysAgo: 4)], listing: listing)
        .filtered(canRead)

    // Without Manage Threads, a private thread needs membership.
    #expect(sections.joined.map(\.id.rawValue) == [5])
    #expect(sections.otherActive.map(\.id.rawValue) == [7])
    #expect(sections.older.isEmpty)
}

@MainActor
@Test func `responses keep live changes made while they were in flight`() {
    let browser = ThreadBrowserState()
    browser.present(parentID: ChannelID(rawValue: 7))
    browser.receive(parentID: ChannelID(rawValue: 7), records: [
        thread(1, archived: false, daysAgo: 1), thread(4, archived: false, daysAgo: 4),
    ])
    let since = browser.liveSequence

    // While the request is in flight, thread 1 is renamed and thread 2 deleted;
    // thread 4 is republished unchanged by the same snapshot.
    browser.receive(parentID: ChannelID(rawValue: 7), records: [
        thread(1, name: "Renamed", archived: false, daysAgo: 1), thread(4, archived: false, daysAgo: 4),
    ])
    browser.remove(threadID: ChannelID(rawValue: 2))

    let response = [
        thread(1, archived: false, daysAgo: 1), thread(2, archived: false, daysAgo: 2), thread(3, daysAgo: 3),
        thread(4, name: "Fresh", archived: false, daysAgo: 4),
    ]
    let reconciled = browser.reconciling(response, since: since)
    #expect(reconciled.map(\.id.rawValue) == [1, 3, 4])
    #expect(reconciled.first?.thread.name == "Renamed")
    #expect(reconciled.last?.thread.name == "Fresh")
}
