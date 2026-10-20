import Foundation
import Observation
import SakuraCordModels

/// A parent channel's archived threads, loaded in Discord's 25-record pages
/// and kept current with live thread records. Discord orders the pages by
/// latest activity; offsets count its raw records.
nonisolated struct ThreadBrowserListing: Equatable, Sendable {
    private(set) var threads: [ForumPost] = []
    /// The next raw-record offset, or nil once Discord reported no more.
    private(set) var nextOffset: Int? = 0
    private(set) var hasLoadedFirstPage = false
    /// The oldest activity among loaded page records: older threads belong to
    /// pages not yet loaded.
    private var oldestPagedActivity: Date?

    var hasMore: Bool { nextOffset != nil }

    /// Appends the page requested at `requestedOffset`. A page for another
    /// offset is stale and ignored; threads already listed are not repeated,
    /// since a thread archived meanwhile shifts Discord's offsets.
    /// `departedCount` page records left the archive while the page was in
    /// flight, moving later records back; the next offset follows them.
    @discardableResult
    mutating func append(_ page: ForumPostPage, requestedOffset: Int, departedCount: Int = 0) -> Bool {
        guard requestedOffset == nextOffset else { return false }
        var listed = Set(threads.map(\.id))
        for post in page.posts where post.thread.isArchived && listed.insert(post.id).inserted {
            threads.append(post)
        }
        if let oldest = page.posts.map(\.lastActivityAt).min() {
            oldestPagedActivity = min(oldestPagedActivity ?? oldest, oldest)
        }
        nextOffset = page.hasMore ? page.nextOffset.map { max(requestedOffset, $0 - departedCount) } : nil
        hasLoadedFirstPage = true
        return true
    }

    /// Applies the parent's current thread records. A record replaces its row,
    /// so renames and lock changes show; a reopened thread leaves the archive;
    /// a thread archived within the loaded range joins it. A thread missing
    /// from the records is not removed: absence is not deletion.
    mutating func reconcile(with records: [ForumPost]) {
        guard hasLoadedFirstPage else { return }
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let loadedCount = threads.count
        threads = threads.compactMap { post in
            guard let record = recordsByID[post.id] else { return post }
            return record.thread.isArchived ? record : nil
        }
        shiftNextOffset(by: threads.count - loadedCount)
        let oldestLoadedActivity = hasMore ? oldestPagedActivity : nil
        var listed = Set(threads.map(\.id))
        for record in records where record.thread.isArchived && listed.insert(record.id).inserted {
            if let oldestLoadedActivity, record.lastActivityAt < oldestLoadedActivity { continue }
            let index = threads.firstIndex { $0.lastActivityAt < record.lastActivityAt } ?? threads.endIndex
            threads.insert(record, at: index)
        }
    }

    mutating func remove(_ threadID: ChannelID) {
        let loadedCount = threads.count
        threads.removeAll { $0.id == threadID }
        shiftNextOffset(by: threads.count - loadedCount)
    }

    /// A loaded thread leaving Discord's archived results moves every later
    /// record back by one; the next page follows so none is skipped. A thread
    /// entering them only repeats a record, which `append` drops.
    private mutating func shiftNextOffset(by delta: Int) {
        guard delta < 0, let offset = nextOffset else { return }
        nextOffset = max(0, offset + delta)
    }
}

/// The browser's three sections. Every thread appears once: an active thread
/// is never listed among older threads.
nonisolated struct ThreadBrowserSections: Equatable, Sendable {
    var joined: [ForumPost] = []
    var otherActive: [ForumPost] = []
    var older: [ForumPost] = []

    var isEmpty: Bool { joined.isEmpty && otherActive.isEmpty && older.isEmpty }

    static func make(records: [ForumPost], listing: ThreadBrowserListing?) -> Self {
        let active = records.filter { !$0.thread.isArchived }.sorted(by: Self.newestActivityFirst)
        let activeIDs = Set(active.map(\.id))
        return ThreadBrowserSections(
            joined: active.filter { $0.thread.notificationSettings != nil },
            otherActive: active.filter { $0.thread.notificationSettings == nil },
            older: (listing?.threads ?? []).filter { !activeIDs.contains($0.id) }
        )
    }

    /// Keeps only the threads the user can open, so a private thread they
    /// left or were removed from disappears.
    func filtered(_ isReadable: (ForumPost) -> Bool) -> Self {
        ThreadBrowserSections(
            joined: joined.filter(isReadable),
            otherActive: otherActive.filter(isReadable),
            older: older.filter(isReadable)
        )
    }

    static func newestActivityFirst(_ lhs: ForumPost, _ rhs: ForumPost) -> Bool {
        lhs.lastActivityAt != rhs.lastActivityAt ? lhs.lastActivityAt > rhs.lastActivityAt : lhs.id > rhs.id
    }
}

/// A submitted name search: active and archived matches as one flat list.
nonisolated struct ThreadBrowserSearch: Equatable, Sendable {
    var query: String
    var results: [ForumPost] = []
    var hasLoaded = false

    /// Live records rename or re-state matches in place; only deletion removes them.
    mutating func reconcile(with records: [ForumPost]) {
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        results = results.map { recordsByID[$0.id] ?? $0 }
    }

    mutating func remove(_ threadID: ChannelID) {
        results.removeAll { $0.id == threadID }
    }
}

/// The Threads browser for one text or announcement channel. Its archived
/// listings are cached for the connection: a fresh READY or an account change
/// clears them.
@MainActor
@Observable
final class ThreadBrowserState {
    var isPresented = false
    private(set) var parentID: ChannelID?
    /// The presented parent's thread records, from local state and live events.
    var records: [ChannelID: ForumPost] = [:]
    var listings: [ChannelID: ThreadBrowserListing] = [:]
    var isLoadingArchived = false
    var archivedErrorMessage: String?
    var searchText = ""
    var search: ThreadBrowserSearch?
    var searchErrorMessage: String?
    @ObservationIgnored var archivedTask: Task<Void, Never>?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var recordsTask: Task<Void, Never>?
    @ObservationIgnored var generation: UInt64 = 0
    /// Advances with every live change; a request records it when it begins.
    @ObservationIgnored private(set) var liveSequence: UInt64 = 0
    @ObservationIgnored private var liveChanges: [ChannelID: LiveChange] = [:]

    private struct LiveChange {
        var sequence: UInt64
        var isDeleted: Bool
    }

    var listing: ThreadBrowserListing? { parentID.flatMap { listings[$0] } }

    var sections: ThreadBrowserSections {
        ThreadBrowserSections.make(records: Array(records.values), listing: listing)
    }

    var isSearching: Bool { search.map { !$0.hasLoaded } ?? false }

    func present(parentID: ChannelID) {
        cancelWork()
        if self.parentID != parentID { records = [:] }
        self.parentID = parentID
        isPresented = true
        archivedErrorMessage = nil
        searchText = ""
        search = nil
        searchErrorMessage = nil
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        cancelWork()
    }

    /// Applies a parent's current thread records from the provider.
    func receive(parentID: ChannelID, records posts: [ForumPost]) {
        listings[parentID]?.reconcile(with: posts)
        guard parentID == self.parentID else { return }
        // A snapshot republishes every thread; only those that differ changed.
        recordLiveChanges(posts.filter { records[$0.id] != $0 }.map(\.id), isDeleted: false)
        // A snapshot updates the threads it carries. One it lacks, such as an
        // active thread a search found, stays: deletion arrives separately.
        for post in posts { records[post.id] = post }
        search?.reconcile(with: posts)
    }

    func remove(threadID: ChannelID) {
        recordLiveChanges([threadID], isDeleted: true)
        records[threadID] = nil
        for parentID in listings.keys { listings[parentID]?.remove(threadID) }
        search?.remove(threadID)
    }

    /// A response's records, corrected for live changes made after its request
    /// began at `sequence`: a thread deleted since is dropped, and one changed
    /// since keeps its current record.
    func reconciling(_ posts: [ForumPost], since sequence: UInt64) -> [ForumPost] {
        posts.compactMap { post in
            guard let change = liveChanges[post.id], change.sequence > sequence else { return post }
            return change.isDeleted ? nil : records[post.id] ?? post
        }
    }

    private func recordLiveChanges(_ threadIDs: [ChannelID], isDeleted: Bool) {
        liveSequence &+= 1
        for threadID in threadIDs {
            liveChanges[threadID] = LiveChange(sequence: liveSequence, isDeleted: isDeleted)
        }
    }

    /// A new connection may have missed archive changes; reload on demand.
    func invalidateArchivedListings() {
        archivedTask?.cancel()
        archivedTask = nil
        isLoadingArchived = false
        listings = [:]
        generation &+= 1
    }

    func clear() {
        dismiss()
        parentID = nil
        records = [:]
        listings = [:]
        liveChanges = [:]
        searchText = ""
        search = nil
        archivedErrorMessage = nil
        searchErrorMessage = nil
    }

    private func cancelWork() {
        archivedTask?.cancel()
        searchTask?.cancel()
        recordsTask?.cancel()
        archivedTask = nil
        searchTask = nil
        recordsTask = nil
        isLoadingArchived = false
        generation &+= 1
    }
}
