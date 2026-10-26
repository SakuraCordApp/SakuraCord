#if SAKURACORD_MOTION_BENCHMARK
import Foundation
import SakuraCordModels

/// Offline side-chat animation benchmark fixture: active public threads under
/// #general (channel 210), each with a realistic conversation. The IDs live in
/// a dedicated range so they never collide with the other fixtures.
extension MockChatProvider {
    /// What the benchmark asks a new provider to seed.
    public struct MotionFixture: Sendable {
        public var threadCount: Int
        public var messageCount: Int
        public var historyDelay: Duration

        public init(threadCount: Int, messageCount: Int, historyDelay: Duration) {
            self.threadCount = threadCount
            self.messageCount = messageCount
            self.historyDelay = historyDelay
        }
    }

    /// Read by `init` and set by the app before it creates the provider, so
    /// the provider's initializer is the same with and without the benchmark.
    public nonisolated(unsafe) static var motionFixture: MotionFixture?

    static let motionThreadParentID = ChannelID(rawValue: 210)
    static let motionThreadFirstID: UInt64 = 7_100_001
    static let motionStarterFirstID: UInt64 = 7_200_000_001
    /// Thread `n` (1-based) owns the message IDs `base + n * 100_000 ..<`.
    static let motionMessageBase: UInt64 = 7_300_000_000
    static let motionMaximumMessageCount = 99_999

    /// Seeds the fixture `motionFixture` asks for, if any, and returns the
    /// thread IDs and the latency to simulate before their history is served.
    static func seedRequestedMotionFixture(
        authors: [User],
        messages: inout [ChannelID: [Message]]
    ) -> (threadIDs: Set<ChannelID>, historyDelay: Duration) {
        guard let fixture = motionFixture else { return ([], .zero) }
        let threadIDs = seedMotionThreads(
            count: fixture.threadCount, messageCount: fixture.messageCount,
            authors: authors, now: .now, guildID: GuildID(rawValue: 100), messages: &messages
        )
        return (threadIDs, fixture.historyDelay)
    }

    /// Appends one starter message per thread to the parent's history, fills
    /// each thread's history, and returns the thread IDs. The catalogue seed
    /// that runs afterwards picks the threads up from their starters.
    static func seedMotionThreads(
        count: Int,
        messageCount: Int,
        authors: [User],
        now: Date,
        guildID: GuildID,
        messages: inout [ChannelID: [Message]]
    ) -> Set<ChannelID> {
        guard count > 0, !authors.isEmpty else { return [] }
        let messageCount = min(max(0, messageCount), motionMaximumMessageCount)
        let parentID = motionThreadParentID
        let parentEnd = messages[parentID]?.last?.timestamp ?? now
        var threadIDs: Set<ChannelID> = []
        for number in 1 ... count {
            let threadID = ChannelID(rawValue: motionThreadFirstID + UInt64(number - 1))
            let owner = authors[mix(number, 1) % authors.count]
            let starterTime = parentEnd.addingTimeInterval(Double(number) * 20)
            let history = motionThreadMessages(
                threadID: threadID, number: number, count: messageCount,
                authors: authors, start: starterTime.addingTimeInterval(15), guildID: guildID
            )
            let thread = MessageThreadSummary(
                id: threadID, guildID: guildID, parentID: parentID,
                name: "Motion thread \(number)", messageCount: history.count,
                memberCount: 3 + number % 3, lastMessageID: history.last?.id,
                ownerID: owner.id, createdAt: starterTime, autoArchiveDuration: 1_440,
                totalMessageSent: history.count
            )
            messages[parentID, default: []].append(Message(
                id: MessageID(rawValue: motionStarterFirstID + UInt64(number - 1)),
                channelID: parentID, author: owner,
                content: motionStarterContent(number),
                timestamp: starterTime, guildID: guildID, thread: thread
            ))
            messages[threadID] = history
            threadIDs.insert(threadID)
        }
        return threadIDs
    }

    /// Gives the catalogue entries their owner and latest message, so the
    /// thread browser sorts them by their real activity.
    static func completeMotionThreadPosts(
        _ threadIDs: Set<ChannelID>,
        forumPosts: inout [ChannelID: [ForumPost]],
        messages: [ChannelID: [Message]]
    ) {
        guard !threadIDs.isEmpty else { return }
        let owners = Dictionary(
            (messages[motionThreadParentID] ?? []).compactMap { message in
                message.thread.map { ($0.id, message.author) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard var posts = forumPosts[motionThreadParentID] else { return }
        for index in posts.indices where threadIDs.contains(posts[index].id) {
            posts[index].owner = owners[posts[index].id]
            posts[index].mostRecentMessage = messages[posts[index].id]?.last
        }
        forumPosts[motionThreadParentID] = posts
    }

    /// Grouped runs by one author, mixed lengths and markdown, with replies,
    /// mentions, and a few reactions. Deterministic per thread and index.
    private static func motionThreadMessages(
        threadID: ChannelID,
        number: Int,
        count: Int,
        authors: [User],
        start: Date,
        guildID: GuildID
    ) -> [Message] {
        var result: [Message] = []
        result.reserveCapacity(count)
        let runLengths = [1, 3, 2, 1, 4, 2, 1, 2, 3, 1]
        let gaps: [Double] = [4, 9, 15, 22, 31, 7, 12, 3, 45, 18]
        var author = authors[0]
        var runRemaining = 0
        var runIndex = 0
        var timestamp = start
        for index in 0 ..< count {
            if runRemaining == 0 {
                runRemaining = runLengths[mix(number, runIndex) % runLengths.count]
                runIndex += 1
                var next = mix(number * 31, runIndex) % authors.count
                if authors.count > 1, authors[next].id == author.id {
                    next = (next + 1) % authors.count
                }
                author = authors[next]
                timestamp = timestamp.addingTimeInterval(gaps[mix(number, runIndex + 5) % gaps.count] * 2)
            } else {
                timestamp = timestamp.addingTimeInterval(gaps[mix(index, number) % gaps.count] / 2 + 1)
            }
            runRemaining -= 1
            let roll = mix(index, number) % 100
            let other = authors.filter { $0.id != author.id }
            let mentioned: User? = (46 ..< 52).contains(roll) && !other.isEmpty
                ? other[mix(index, number + 9) % other.count]
                : nil
            var message = Message(
                id: MessageID(rawValue: motionMessageBase + UInt64(number) * 100_000 + UInt64(index)),
                channelID: threadID, author: author,
                content: motionContent(roll: roll, index: index, number: number, mention: mentioned),
                timestamp: timestamp,
                reactions: motionReactions(index: index, number: number, authors: authors),
                guildID: guildID,
                mentionedUsers: mentioned.map { [$0] } ?? []
            )
            if roll >= 85, let target = result.last(where: { $0.author.id != author.id }) {
                message.replyTo = target.id
                message.replyPreview = MessageReplyPreview(message: target)
            }
            result.append(message)
        }
        return result
    }

    private static func motionStarterContent(_ number: Int) -> String {
        let topics = [
            "Opening a thread for the sidebar spacing review.",
            "Moving the composer focus discussion over here.",
            "Thread for the scroll anchoring regression from last night.",
            "Let's collect keyboard shortcut feedback in one place.",
            "Starting a thread about the new reaction picker.",
            "Taking the notification grouping debate to a thread.",
            "Thread for the voice message waveform polish.",
            "Collecting window restoration edge cases here.",
        ]
        return topics[(number - 1) % topics.count]
    }

    private static func motionContent(roll: Int, index: Int, number: Int, mention: User?) -> String {
        let seed = mix(index, number + 3)
        func pick(_ pool: [String]) -> String { pool[seed % pool.count] }
        switch roll {
        case 0 ..< 30:
            return pick([
                "lgtm", "yeah same here", "oh nice 🌸", "ship it", "ha, fair", "+1",
                "makes sense", "can confirm", "good catch", "wait, really?", "thanks!",
                "on it", "hm, not sure about that", "same on my end", "agreed", "😂",
            ])
        case 30 ..< 46:
            return pick([
                "I tried it at three window widths and the compact layout holds up fine.",
                "That matches what I saw in Instruments, the main thread was idle during the animation.",
                "Can you reproduce it on the latest nightly, or only on your machine?",
                "I'd keep the old behavior behind a setting until we've had a week of feedback.",
                "The spacing looks right now, but the divider still feels a touch heavy against the background.",
                "Not blocking, just noting that the focus ring clips for a frame when the pane opens.",
                "Good point, I hadn't thought about how that interacts with a narrow window.",
                "Merged the fix, give it a go when you get a chance and tell me if anything feels off.",
            ])
        case 46 ..< 52:
            let name = mention.map { "<@\($0.id.rawValue)>" } ?? "everyone"
            return pick([
                "\(name) could you take a look when you have a minute?",
                "\(name) this is the one I mentioned earlier",
                "thanks \(name), that fixed it",
                "\(name) any thoughts on the empty state?",
            ])
        case 52 ..< 60:
            return pick([
                "**Heads up:** the `sidebarWidth` default changed to 280, so old saved layouts will shift a little.",
                "Fixed in `ThreadPane` by moving the *measurement* out of the animation block. **Much** smoother now.",
                "Pinning this: __always__ test with a long history, the short fixtures hide the real cost.",
                "Quick summary: **three** fixes landed, `two` are visual and ~~one~~ turned out to be unrelated.",
            ])
        case 60 ..< 66:
            return pick([
                "Here's roughly what I changed:\n```swift\nwithAnimation(.smooth(duration: 0.3)) {\n    isPaneOpen.toggle()\n}\n```\nThe layout pass now happens once instead of per frame.",
                "This reproduces it:\n```swift\nlet rows = history.map(Row.init)\nawait MainActor.run { model.rows = rows }\n```",
                "```\nframe 12: layout 4.1ms\nframe 13: layout 9.8ms\nframe 14: layout 3.9ms\n```\nThat spike on frame 13 is the one that drops a frame.",
            ])
        case 66 ..< 72:
            return pick([
                "> The pane should feel attached to the window, not floating over it.\n\nYes, exactly this. That's the bar.",
                "> Nothing here should block the main thread.\n\nI'd put that on a sticky note for the whole team.",
                ">>> Step 1: open the pane\nStep 2: scroll quickly\nStep 3: close it mid-animation\n\nThat's the sequence that hiccups for me.",
            ])
        case 72 ..< 78:
            return pick([
                "Related reading: [the HIG on motion](https://example.com/design/motion) is worth a skim.",
                "Tracking this in [the issue](https://example.com/issues/1234), add anything I missed.",
                "Here's the [profiling notes](https://example.com/notes/profiling) from this morning.",
            ])
        case 78 ..< 85:
            return pick([
                "Longer one, because this deserves some context.\n\nThe pane used to measure every row up front, "
                    + "which is fine for a short chat but falls over once a thread has a couple hundred messages. The fix "
                    + "defers measurement until the row is about to appear.\n\nThe tradeoff is that the scroll indicator "
                    + "jitters a little while the estimated heights settle. I think that's acceptable, but I'd like a "
                    + "second opinion before we call it done.",
                "A few things I noticed while testing:\n\n- The open animation is smooth now, even on a cold "
                    + "start.\n- Closing it mid-animation still snaps for one frame.\n- Reopening the same thread keeps the "
                    + "scroll position, which is nice.\n\nThe closing snap is the only one I'd call a real bug.",
                "Writing this down so it doesn't get lost.\n\nFirst, the history arrives while the animation runs, so "
                    + "anything that blocks the main thread shows up as a dropped frame immediately.\n\nSecond, the first "
                    + "layout pass is the expensive one. Everything after that is cheap because the heights are "
                    + "cached.\n\nThird, we can hide most of the first pass behind the animation itself if we start it as "
                    + "soon as the pane opens.",
            ])
        default:
            return pick([
                "Replying to that: yes, I'd do it the same way.",
                "Good question, I think it depends on the window width.",
                "That was my first guess too, but it turned out to be the layout pass.",
                "I'd say go for it, it's easy to revert if it feels wrong.",
                "Sorry, missed this earlier. Looking now.",
            ])
        }
    }

    private static func motionReactions(index: Int, number: Int, authors: [User]) -> [Reaction] {
        guard mix(index, number + 17) % 11 == 0 else { return [] }
        let emoji = ["👍", "🌸", "✨", "🔥", "😂"][mix(index, number + 21) % 5]
        let reactors = authors.prefix(1 + mix(index, number + 25) % 3)
        return [
            Reaction(
                emoji: emoji, count: reactors.count,
                reactors: reactors.map(ReactionReactor.init(user:))
            )
        ]
    }

    /// A small deterministic hash, so a fixture is stable across launches.
    private static func mix(_ first: Int, _ second: Int) -> Int {
        var value = UInt64(truncatingIfNeeded: first) &* 0x9E37_79B9_7F4A_7C15
            ^ UInt64(truncatingIfNeeded: second) &* 0xBF58_476D_1CE4_E5B9
        value ^= value >> 29
        value = value &* 0x94D0_49BB_1331_11EB
        value ^= value >> 32
        return Int(value % 1_000_000)
    }
}
#endif
