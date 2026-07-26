@testable import SakuraCordModels
import Foundation
import Testing

@Test func `current user reaction updates are idempotent with optimistic state`() {
    let currentUserID = UserID(rawValue: 1)
    let channelID = ChannelID(rawValue: 2)
    let messageID = MessageID(rawValue: 3)
    var message = reactionTestMessage(
        channelID: channelID,
        messageID: messageID,
        reactions: [Reaction(emoji: "✅", count: 2)]
    )
    let add = MessageReactionUpdate.add(
        channelID: channelID,
        messageID: messageID,
        userID: currentUserID,
        emoji: "✅",
        kind: .normal
    )

    let appliedAdd = message.applyReactionUpdate(add, currentUserID: currentUserID)
    #expect(appliedAdd)
    #expect(message.reactions == [Reaction(emoji: "✅", count: 3, didCurrentUserReact: true)])
    let replayedAdd = message.applyReactionUpdate(add, currentUserID: currentUserID)
    #expect(!replayedAdd)
    #expect(message.reactions.first?.count == 3)

    let remove = MessageReactionUpdate.remove(
        channelID: channelID,
        messageID: messageID,
        userID: currentUserID,
        emoji: "✅",
        kind: .normal
    )
    let appliedRemove = message.applyReactionUpdate(remove, currentUserID: currentUserID)
    #expect(appliedRemove)
    #expect(message.reactions == [Reaction(emoji: "✅", count: 2)])
    let replayedRemove = message.applyReactionUpdate(remove, currentUserID: currentUserID)
    #expect(!replayedRemove)
    #expect(message.reactions.first?.count == 2)
}

@Test func `burst and normal current user reaction state reconcile independently`() {
    let currentUserID = UserID(rawValue: 10)
    let channelID = ChannelID(rawValue: 20)
    let messageID = MessageID(rawValue: 30)
    var message = reactionTestMessage(channelID: channelID, messageID: messageID)

    let burstAdd = MessageReactionUpdate.add(
        channelID: channelID,
        messageID: messageID,
        userID: currentUserID,
        emoji: "<a:party_blob:123>",
        kind: .burst
    )
    let normalAdd = MessageReactionUpdate.add(
        channelID: channelID,
        messageID: messageID,
        userID: currentUserID,
        emoji: "<:renamed_blob:123>",
        kind: .normal
    )

    let appliedBurstAdd = message.applyReactionUpdate(burstAdd, currentUserID: currentUserID)
    let appliedNormalAdd = message.applyReactionUpdate(normalAdd, currentUserID: currentUserID)
    #expect(appliedBurstAdd)
    #expect(appliedNormalAdd)
    let reaction = message.reactions[0]
    #expect(reaction.id == "custom:123")
    #expect(reaction.count == 2)
    #expect(reaction.didCurrentUserReact)
    #expect(reaction.didCurrentUserBurstReact)

    let burstRemove = MessageReactionUpdate.remove(
        channelID: channelID,
        messageID: messageID,
        userID: currentUserID,
        emoji: "<:party_blob:123>",
        kind: .burst
    )
    let appliedBurstRemove = message.applyReactionUpdate(
        burstRemove,
        currentUserID: currentUserID
    )
    #expect(appliedBurstRemove)
    #expect(message.reactions[0].count == 1)
    #expect(message.reactions[0].didCurrentUserReact)
    #expect(!message.reactions[0].didCurrentUserBurstReact)
}

@Test func `external remove emoji and remove all updates clear matching aggregates`() {
    let channelID = ChannelID(rawValue: 200)
    let messageID = MessageID(rawValue: 300)
    var message = reactionTestMessage(
        channelID: channelID,
        messageID: messageID,
        reactions: [
            Reaction(emoji: "<:old_name:999>", count: 3),
            Reaction(emoji: "🔥", count: 1),
        ]
    )

    let appliedRemoveEmoji = message.applyReactionUpdate(
        .removeEmoji(
            channelID: channelID,
            messageID: messageID,
            emoji: "<a:new_name:999>"
        ),
        currentUserID: UserID(rawValue: 1)
    )
    #expect(appliedRemoveEmoji)
    #expect(message.reactions.map(\.emoji) == ["🔥"])
    let appliedRemoveAll = message.applyReactionUpdate(
        .removeAll(channelID: channelID, messageID: messageID),
        currentUserID: UserID(rawValue: 1)
    )
    #expect(appliedRemoveAll)
    #expect(message.reactions.isEmpty)
}

@Test func `reaction deltas preserve known reactor avatars and update the affected user only`() {
    let channelID = ChannelID(rawValue: 400)
    let messageID = MessageID(rawValue: 500)
    let first = ReactionReactor(
        id: UserID(rawValue: 1),
        displayName: "One",
        avatarURL: URL(string: "https://cdn.example/one.png")
    )
    let second = ReactionReactor(
        id: UserID(rawValue: 2),
        displayName: "Two",
        avatarURL: URL(string: "https://cdn.example/two.png")
    )
    let third = ReactionReactor(
        id: UserID(rawValue: 3),
        displayName: "Three",
        avatarURL: URL(string: "https://cdn.example/three.png")
    )
    var message = reactionTestMessage(
        channelID: channelID,
        messageID: messageID,
        reactions: [Reaction(emoji: "✅", count: 2, reactors: [first, second])]
    )

    let appliedAdd = message.applyReactionUpdate(
        .add(
            channelID: channelID,
            messageID: messageID,
            userID: third.id,
            emoji: "✅",
            kind: .normal
        ),
        currentUserID: UserID(rawValue: 99),
        reactor: third
    )
    #expect(appliedAdd)
    #expect(message.reactions[0].count == 3)
    #expect(message.reactions[0].reactors == [first, second, third])

    let appliedRemove = message.applyReactionUpdate(
        .remove(
            channelID: channelID,
            messageID: messageID,
            userID: second.id,
            emoji: "✅",
            kind: .normal
        ),
        currentUserID: UserID(rawValue: 99)
    )
    #expect(appliedRemove)
    #expect(message.reactions[0].count == 2)
    #expect(message.reactions[0].reactors == [first, third])
}

@Test func `replacement messages preserve only matching reaction avatars`() {
    let channelID = ChannelID(rawValue: 600)
    let messageID = MessageID(rawValue: 700)
    let first = ReactionReactor(id: UserID(rawValue: 1), displayName: "One")
    let second = ReactionReactor(id: UserID(rawValue: 2), displayName: "Two")
    let third = ReactionReactor(id: UserID(rawValue: 3), displayName: "Three")
    let previous = reactionTestMessage(
        channelID: channelID,
        messageID: messageID,
        reactions: [
            Reaction(emoji: "❤️", count: 2, reactors: [first, second]),
            Reaction(emoji: "🐛", count: 1, reactors: [third]),
        ]
    )
    let incoming = reactionTestMessage(
        channelID: channelID,
        messageID: messageID,
        reactions: [
            Reaction(emoji: "❤️", count: 3, reactors: [third]),
            Reaction(emoji: "🎉", count: 1),
        ]
    )

    let merged = incoming.preservingReactionReactors(from: previous)

    #expect(merged.reactions[0].count == 3)
    #expect(merged.reactions[0].reactors == [third, first, second])
    #expect(merged.reactions[1].reactors.isEmpty)
}

private func reactionTestMessage(
    channelID: ChannelID,
    messageID: MessageID,
    reactions: [Reaction] = []
) -> Message {
    Message(
        id: messageID,
        channelID: channelID,
        author: User(
            id: UserID(rawValue: 99),
            username: "author",
            displayName: "Author"
        ),
        content: "Reaction test",
        reactions: reactions
    )
}
