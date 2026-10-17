import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test(arguments: [false, true], [false, true])
func `history insertion reconciles an overlapping timeline before publishing rows`(
    loadsEarlier: Bool,
    includesExistingID: Bool
) async throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 900)
    let author = User(id: UserID(rawValue: 901), username: "history", displayName: "History")
    let page = (1 ... 3).map { index in
        Message(
            id: MessageID(rawValue: UInt64(index)),
            channelID: channelID,
            author: author,
            content: "History \(index)",
            timestamp: Date(timeIntervalSince1970: Double(index))
        )
    }
    var current = page[1]
    current.content = "Newer live edit"
    current.replyTo = page[0].id
    current.reactions = [Reaction(emoji: "👍", count: 1)]
    model.selectedChannelID = channelID
    // Pagination filtered this page against the old timeline. A concurrent
    // history refresh/Gateway event has now published an overlapping message.
    model.replaceSelectedMessages(with: [current])
    // Without the shared ID, only the ordering guard prevents the page from
    // being inserted wholly before or after the message already in its middle.
    let incoming = includesExistingID ? page : page.filter { $0.id != current.id }

    let committed = if loadsEarlier {
        await model.prependSelectedMessages(incoming, channelID: channelID, anchorID: current.id)
    } else {
        await model.appendSelectedHistoryMessages(incoming, channelID: channelID)
    }
    #expect(committed)
    try #require(model.messages.map(\.id) == page.map(\.id))
    try #require(Set(model.messages.map(\.id)).count == model.messages.count)
    #expect(model.messages[1] == current)
    #expect(model.messageRows == MessageGrouping.rows(for: model.messages))
    for (index, message) in model.messages.enumerated() {
        #expect(model.selectedMessageIndex(for: message.id) == index)
    }

    // This is the update that trapped in Dictionary(uniqueKeysWithValues:)
    // in the reported crashes, after the duplicate row had already appeared.
    let reactor = ReactionReactor(user: author)
    model.applyReactionReactors([reactor], for: AppModel.ReactionReactorLoadKey(
        channelID: channelID,
        messageID: current.id,
        reactionID: current.reactions[0].id
    ))
    #expect(model.messages[1].reactions[0].reactors == [reactor])
    #expect(model.messageRows == MessageGrouping.rows(for: model.messages))
}
