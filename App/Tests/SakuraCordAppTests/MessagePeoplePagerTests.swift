import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
struct MessagePeoplePagerTests {
    @Test func `unknown tallies load and cursor pages deduplicate without losing retry progress`() async throws {
        let pager = MessagePeoplePager<Int>()
        await pager.load(1, count: nil, after: nil, isCurrent: { true }) { after in
            #expect(after == nil)
            return MessagePeoplePage(users: [user(1), user(2)], hasMore: true)
        }?.value
        await pager.load(1, count: nil, after: UserID(rawValue: 2), isCurrent: { true }) { _ in
            throw PageFailure()
        }?.value
        #expect(pager.errors[1] != nil)
        #expect(pager.pages[1]?.users.map(\.id.rawValue) == [1, 2])
        await pager.load(1, count: nil, after: pager.pages[1]?.cursor, isCurrent: { true }) { after in
            #expect(after?.rawValue == 2)
            return MessagePeoplePage(users: [user(2), user(3)], hasMore: false)
        }?.value
        #expect(pager.pages[1]?.users.map(\.id.rawValue) == [1, 2, 3])
        #expect(pager.pages[1]?.cursor?.rawValue == 3)
        #expect(pager.pages[1]?.hasMore == false)
        #expect(pager.errors[1] == nil)
        // A changed tally starts over, rather than appending to old identities.
        await pager.load(1, count: 1, after: UserID(rawValue: 3), isCurrent: { true }) { after in
            #expect(after == nil)
            return MessagePeoplePage(users: [user(4)], hasMore: false)
        }?.value
        #expect(pager.pages[1]?.users.map(\.id.rawValue) == [4])
    }

    @Test func `invalidated responses cannot erase a replacement or stop another category`() async {
        let pager = MessagePeoplePager<String>()
        let started = AsyncStream<Void>.makeStream()
        let oldGate = AsyncStream<Void>.makeStream()
        let newGate = AsyncStream<Void>.makeStream()
        func suspended(_ gate: AsyncStream<Void>, id: UInt64) async -> MessagePeoplePage {
            started.continuation.yield(())
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return MessagePeoplePage(users: [user(id)], hasMore: false)
        }
        let old = pager.load("a", count: 1, after: nil, isCurrent: { true }) { _ in await suspended(oldGate.stream, id: 1) }
        let other = pager.load("b", count: 1, after: nil, isCurrent: { true }) { _ in await suspended(oldGate.stream, id: 2) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        pager.invalidate("a")
        let replacement = pager.load("a", count: 1, after: nil, isCurrent: { true }) { _ in await suspended(newGate.stream, id: 3) }
        _ = await iterator.next()
        oldGate.continuation.finish()
        await old?.value
        await other?.value
        newGate.continuation.finish()
        await replacement?.value
        started.continuation.finish()
        #expect(pager.pages["a"]?.users.map(\.id.rawValue) == [3])
        #expect(pager.pages["b"]?.users.map(\.id.rawValue) == [2])
    }

    @Test(arguments: [false, true])
    func `closed popovers and changed account sessions discard pending pages`(closesPopover: Bool) async {
        let pager = MessagePeoplePager<Int>()
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let session = SessionState()
        let load = pager.load(1, count: 1, after: nil, isCurrent: { session.isCurrent }) { _ in
            started.continuation.yield(())
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            return MessagePeoplePage(users: [user(1)], hasMore: false)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        if closesPopover { pager.reset() } else { session.isCurrent = false }
        gate.continuation.finish()
        await load?.value
        started.continuation.finish()
        #expect(pager.pages.isEmpty)
        #expect(pager.errors.isEmpty)
    }

    private func user(_ id: UInt64) -> User {
        User(id: UserID(rawValue: id), username: "user\(id)", displayName: "User \(id)")
    }

    private struct PageFailure: Error {}

    @MainActor private final class SessionState {
        var isCurrent = true
    }
}
