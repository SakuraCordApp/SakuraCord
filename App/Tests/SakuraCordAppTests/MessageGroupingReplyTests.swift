import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `ordinary same-author message continues beneath a reply`() {
    let fixture = replyGroupingFixture()

    let rows = MessageGrouping.rows(for: [fixture.target, fixture.reply, fixture.followUp])

    #expect(rows.map(\.startsGroup) == [true, true, false])
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
