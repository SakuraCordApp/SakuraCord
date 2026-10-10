@testable import SakuraCord
import AppKit
import Foundation
import SakuraCordModels
import Testing

/// A short bubble must not narrow its reaction row. Wrapping against the
/// bubble's text width stacked each pill on its own line and clamped the pills
/// so their counts and reactor avatars overflowed.
@MainActor
@Test(arguments: [false, true])
func `bubble reactions flow in one line beyond a short bubble`(isOutgoing: Bool) throws {
    let you = User(id: UserID(rawValue: 99_501), username: "you", displayName: "You")
    let friend = User(id: UserID(rawValue: 99_502), username: "friend", displayName: "Friend")
    let channel = Channel(
        id: ChannelID(rawValue: 99_503), guildID: nil, name: "group", kind: .groupDirectMessage
    )
    let model = AppModel(launchMode: .offlineTesting)
    model.snapshot = BootstrapSnapshot(currentUser: you, guilds: [], channels: [channel], members: [])
    model.appearanceSettings.messageAppearance = .bubbles

    var message = Message(
        id: MessageID(rawValue: 99_504), channelID: channel.id,
        author: isOutgoing ? you : friend, content: "dsf"
    )
    message.reactions = ["👍", "😭", "💀"].map {
        Reaction(emoji: $0, count: 1, reactors: [ReactionReactor(user: friend)])
    }
    let item = NativeMessageTimelineItem.message(
        MessageRowPresentation(
            message: message, startsGroup: true, startsDay: false,
            replyPreview: nil, isReplyAvailable: false
        ),
        isUnreadBoundary: false, isHighlighted: false
    )
    let layout = NativeTimelineRowLayout.make(item: item, width: 900, model: model)

    let bubble = try #require(layout.bubbleRegion).frame
    let addFrame = try #require(layout.addReactionFrame)
    let regions = layout.reactionRegions
    #expect(regions.count == 3)
    for region in regions {
        #expect(region.frame.minY == addFrame.minY)
        #expect(region.frame.width == NativeTimelineRowLayout.reactionSize(region.reaction).width)
        let countFrame = try #require(region.countFrame)
        #expect(countFrame.maxX <= region.frame.maxX)
    }
    let first = try #require(regions.first).frame
    #expect(addFrame.maxX - first.minX > bubble.width)

    let padding = NativeTimelineBubbleLayout.horizontalPadding
    if isOutgoing {
        #expect(addFrame.maxX == bubble.maxX - padding)
    } else {
        #expect(first.minX == bubble.minX + padding)
    }
}
