import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor @Test
func `ten thousand message timeline keeps stable identities across incremental update`() {
    let author = User(id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture")
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    var messages = (0 ..< 10000).map { index in
        Message(
            id: MessageID(rawValue: UInt64(index + 1)), channelID: ChannelID(rawValue: 1), author: author,
            content: "Message \(index)", timestamp: base.addingTimeInterval(Double(index))
        )
    }
    let original = MessageGrouping.rows(for: messages)
    messages[5000].content = "Changed"
    let updated = MessageGrouping.updating(
        existing: original, oldMessages: original.map(\.message), newMessages: messages
    )

    #expect(updated.count == 10000)
    #expect(updated.map(\.id) == original.map(\.id))
    #expect(updated[4999] == original[4999])
    #expect(updated[5000].message.content == "Changed")
    #expect(updated[5002] == original[5002])
}

@MainActor @Test func `timeline prepend preserves prior rows beyond boundary`() {
    let author = User(id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture")
    let channel = ChannelID(rawValue: 1)
    let old = (10 ..< 20).map {
        Message(
            id: MessageID(rawValue: UInt64($0)), channelID: channel, author: author, content: "\($0)",
            timestamp: Date(timeIntervalSince1970: Double($0 * 600))
        )
    }
    let earlier = (0 ..< 10).map {
        Message(
            id: MessageID(rawValue: UInt64($0 + 100)), channelID: channel, author: author,
            content: "earlier \($0)", timestamp: Date(timeIntervalSince1970: Double($0 * 600))
        )
    }
    let original = MessageGrouping.rows(for: old)
    let updated = MessageGrouping.updating(
        existing: original, oldMessages: old, newMessages: earlier + old
    )
    #expect(updated.count == 20)
    #expect(updated[11] == original[1])
}
