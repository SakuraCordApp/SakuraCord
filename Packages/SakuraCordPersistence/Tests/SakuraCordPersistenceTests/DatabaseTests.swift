import Foundation
import SakuraCordModels
@testable import SakuraCordPersistence
import Testing

@Test func `drafts and messages round trip`() async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let channelID = ChannelID(rawValue: 12)
    try await database.saveDraft("hello", channelID: channelID)
    #expect(try await database.draft(channelID: channelID) == "hello")

    let user = User(id: UserID(rawValue: 1), username: "user", displayName: "User")
    let message = Message(id: MessageID(rawValue: 2), channelID: channelID, author: user, content: "cached")
    try await database.save(messages: [message])
    #expect(try await database.messages(in: channelID) == [message])
}

@Test func `message history returns the newest page in chronological order`() async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let channelID = ChannelID(rawValue: 42)
    let user = User(id: UserID(rawValue: 1), username: "user", displayName: "User")
    let messages = (1 ... 150).map { value in
        Message(
            id: MessageID(rawValue: UInt64(value)),
            channelID: channelID,
            author: user,
            content: "message \(value)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(value))
        )
    }

    try await database.save(messages: messages)
    let page = try await database.messages(in: channelID, limit: 100)

    #expect(page.count == 100)
    #expect(page.first?.id == MessageID(rawValue: 51))
    #expect(page.last?.id == MessageID(rawValue: 150))
}
