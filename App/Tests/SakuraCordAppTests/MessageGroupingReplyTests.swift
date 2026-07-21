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
