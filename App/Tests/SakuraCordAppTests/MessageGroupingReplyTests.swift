import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `ordinary same-author message continues beneath a reply`() {
    let fixture = replyGroupingFixture()

    let rows = MessageGrouping.rows(for: [fixture.target, fixture.reply, fixture.followUp])

    #expect(rows.map(\.startsGroup) == [true, true, false])
    #expect(rows.map(\.endsGroup) == [true, false, true])
}

@MainActor
@Test func `cooperative history grouping matches the synchronous result`() async {
    let fixture = replyGroupingFixture()
    let messages = [fixture.target, fixture.reply, fixture.followUp]

    let cooperative = await MessageGrouping.rowsCooperatively(
        for: messages,
        batchSize: 1
    )

    #expect(cooperative == MessageGrouping.rows(for: messages))
}

@MainActor
@Test(arguments: [false, true])
func `cancelled history preparation does not return a partial page`(throughModel: Bool) async {
    let fixture = replyGroupingFixture()
    let messages = [fixture.target, fixture.reply, fixture.followUp]
    let model = AppModel(launchMode: .offlineTesting)
    let work = Task { @MainActor in
        if throughModel {
            return await model.prepareTimelineRows(for: messages, priority: .userInitiated)
        }
        return await MessageGrouping.rowsCooperatively(for: messages, batchSize: 1)
    }
    // This actor has not suspended, so cancellation precedes any preparation.
    work.cancel()
    let rows = await work.value
    #expect(rows.isEmpty)
    #expect(model.messages.isEmpty)
    #expect(model.messageRows.isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func `running history preparation cancels its active detached worker`(grouping: Bool) async {
    let fixture = replyGroupingFixture()
    // Mentions keep every row on the resolved-text prewarming path, so the
    // worker still has real work remaining when the first item is gated.
    let messages = [fixture.target, fixture.reply, fixture.followUp].map { message in
        var value = message
        value.content += " <@\(fixture.target.author.id.rawValue)>"
        return value
    }
    let model = AppModel(launchMode: .offlineTesting)
    model.replaceSelectedMessages(with: [fixture.target])
    let originalRows = model.messageRows
    let probe = HistoryPreparationCancellationProbe()
    let checkpoint: @Sendable (Int) async -> Void = { await probe.checkpoint($0) }
    let work = Task { @MainActor in
        await model.prepareTimelineRows(
            for: messages, priority: .userInitiated,
            groupingCheckpoint: grouping ? checkpoint : nil,
            prewarmingCheckpoint: grouping ? nil : checkpoint
        )
    }

    // The checkpoint runs inside the real detached worker, after its first
    // processed item. Its continuation deliberately ignores cancellation.
    await probe.waitUntilStarted()
    work.cancel()
    await probe.release()
    let rows = await work.value
    let observation = await probe.observation
    #expect(observation.cancelled)
    #expect(observation.processed == 1)
    #expect(rows.isEmpty)
    #expect(model.messages == [fixture.target])
    #expect(model.messageRows == originalRows)
}

private actor HistoryPreparationCancellationProbe {
    private var processed = 0
    private var cancelled = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var workerWaiter: CheckedContinuation<Void, Never>?

    var observation: (processed: Int, cancelled: Bool) { (processed, cancelled) }

    func checkpoint(_ completed: Int) async {
        processed = completed
        guard completed == 1 else { return }
        await withCheckedContinuation { continuation in
            workerWaiter = continuation
            startedWaiter?.resume()
            startedWaiter = nil
        }
        cancelled = Task.isCancelled
    }

    func waitUntilStarted() async {
        guard workerWaiter == nil else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        workerWaiter?.resume()
        workerWaiter = nil
    }
}

@MainActor
@Test func `appending after a reply matches full message regrouping`() {
    let fixture = replyGroupingFixture()
    let oldMessages = [fixture.target, fixture.reply]
    let newMessages = oldMessages + [fixture.followUp]

    let updated = MessageGrouping.updating(
        existing: MessageGrouping.rows(for: oldMessages),
        oldMessages: oldMessages,
        newMessages: newMessages
    )

    #expect(updated == MessageGrouping.rows(for: newMessages))
    #expect(updated.map(\.startsGroup) == [true, true, false])
    #expect(updated.map(\.endsGroup) == [true, false, true])
}

@MainActor
@Test func `incremental append replaces the previous group boundary`() throws {
    let fixture = replyGroupingFixture()
    var rows = MessageGrouping.rows(for: [fixture.reply])
    let previousBoundary = try #require(rows.last)

    MessageGrouping.appendRows(
        for: [fixture.followUp],
        into: &rows,
        after: fixture.reply,
        existingMessage: { id in
            id == fixture.reply.id ? fixture.reply : nil
        }
    )

    #expect(rows.count == 2)
    #expect(rows[0] !== previousBoundary)
    #expect(rows.map(\.startsGroup) == [true, false])
    #expect(rows.map(\.endsGroup) == [false, true])
}

@MainActor
@Test func `prepending a reply target matches full message regrouping`() {
    let fixture = replyGroupingFixture()
    let oldMessages = [fixture.reply, fixture.followUp]
    let newMessages = [fixture.target] + oldMessages

    let updated = MessageGrouping.updating(
        existing: MessageGrouping.rows(for: oldMessages),
        oldMessages: oldMessages,
        newMessages: newMessages
    )

    #expect(updated == MessageGrouping.rows(for: newMessages))
    #expect(updated.map(\.startsGroup) == [true, true, false])
    #expect(updated.map(\.endsGroup) == [true, false, true])
    #expect(updated[1].replyPreview?.messageID == fixture.target.id)
    #expect(updated[1].replyMessageID == fixture.target.id)
}

@MainActor
@Test func `unresolved reply retains a visible navigable reference`() throws {
    let fixture = replyGroupingFixture()
    let row = try #require(MessageGrouping.rows(for: [fixture.reply]).first)

    #expect(row.replyPreview == nil)
    #expect(row.replyMessageID == fixture.target.id)

    let item = NativeMessageTimelineItem.message(
        row,
        isUnreadBoundary: false,
        isHighlighted: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: item,
        width: 600
    )
    let replyFrame = try #require(layout.replyFrame)
    let replyContentFrame = try #require(layout.replyContentFrame)
    let authorFrame = try #require(layout.authorFrame)

    #expect(replyContentFrame.minX == authorFrame.minX)

    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 600, height: layout.height)
    )
    canvas.storage.items = [item]
    canvas.storage.layouts = [layout]
    canvas.storage.rowOrigins = [0]
    canvas.storage.contentHeight = layout.height

    #expect(
        canvas.pointerActivationTarget(
            at: CGPoint(x: replyFrame.midX, y: replyFrame.midY)
        ) == .reply(fixture.reply.id, fixture.target.id)
    )
}

@MainActor
@Test func `changing an ordinary message into a reply matches full message regrouping`() {
    let fixture = replyGroupingFixture()
    var ordinary = fixture.reply
    ordinary.replyTo = nil
    let oldMessages = [fixture.target, ordinary, fixture.followUp]
    let newMessages = [fixture.target, fixture.reply, fixture.followUp]

    let updated = MessageGrouping.updating(
        existing: MessageGrouping.rows(for: oldMessages),
        oldMessages: oldMessages,
        newMessages: newMessages
    )

    #expect(updated == MessageGrouping.rows(for: newMessages))
    #expect(updated.map(\.startsGroup) == [true, true, false])
}

private func replyGroupingFixture() -> (target: Message, reply: Message, followUp: Message) {
    let channelID = ChannelID(rawValue: 10)
    let replyingAuthor = User(
        id: UserID(rawValue: 1), username: "replying", displayName: "Replying"
    )
    let targetAuthor = User(
        id: UserID(rawValue: 2), username: "target", displayName: "Target"
    )
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let target = Message(
        id: MessageID(rawValue: 1), channelID: channelID, author: targetAuthor,
        content: "target", timestamp: base
    )
    let reply = Message(
        id: MessageID(rawValue: 2), channelID: channelID, author: replyingAuthor,
        content: "reply", timestamp: base.addingTimeInterval(1), replyTo: target.id
    )
    let followUp = Message(
        id: MessageID(rawValue: 3), channelID: channelID, author: replyingAuthor,
        content: "follow-up", timestamp: base.addingTimeInterval(2)
    )
    return (target, reply, followUp)
}

@MainActor
@Test func `one webhook starts a new group when its presented identity changes`() {
    func webhookMessage(_ id: UInt64, name: String, seconds: TimeInterval) -> Message {
        Message(
            id: MessageID(rawValue: id), channelID: ChannelID(rawValue: 1),
            author: User(id: UserID(rawValue: 900), username: name, discriminator: "0000", displayName: name, isBot: true),
            webhookID: "900", content: name, timestamp: Date(timeIntervalSince1970: 1_000 + seconds)
        )
    }
    let messages = [
        webhookMessage(1, name: "The Impersonator", seconds: 0),
        webhookMessage(2, name: "SakuraCord Testing", seconds: 5),
        webhookMessage(3, name: "SakuraCord Testing", seconds: 10),
    ]

    #expect(MessageGrouping.rows(for: messages).map(\.startsGroup) == [true, true, false])
}
