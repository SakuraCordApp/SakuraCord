import Foundation
import GRDB
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

@Test func `bootstrap snapshot round trips and clears with account data`() async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let snapshot = BootstrapSnapshot(
        currentUser: User(
            id: UserID(rawValue: 91),
            username: "cached-user",
            displayName: "Cached User"
        ),
        guilds: [],
        channels: [],
        members: []
    )

    #expect(try await database.bootstrapSnapshot() == nil)
    try await database.saveBootstrapSnapshot(snapshot)
    #expect(try await database.bootstrapSnapshot() == snapshot)
    let channelID = ChannelID(rawValue: 92)
    try await database.saveSelectedChannelID(channelID)
    #expect(try await database.selectedChannelID() == channelID)

    try await database.clearAccountData()
    #expect(try await database.bootstrapSnapshot() == nil)
    #expect(try await database.selectedChannelID() == nil)
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

@Test func `conversation page persists an empty or complete history boundary`() async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let channelID = ChannelID(rawValue: 77)
    let user = User(
        id: UserID(rawValue: 1),
        username: "user",
        displayName: "User"
    )
    let message = Message(
        id: MessageID(rawValue: 78),
        channelID: channelID,
        author: user,
        content: "cached"
    )

    #expect(try await database.conversationPage(in: channelID) == nil)
    try await database.saveConversationPage(
        messages: [message],
        channelID: channelID,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )
    let complete = try #require(
        try await database.conversationPage(in: channelID)
    )
    #expect(complete.messages == [message])
    #expect(complete.hasMoreBefore == false)

    let emptyChannel = ChannelID(rawValue: 79)
    try await database.saveConversationPage(
        messages: [],
        channelID: emptyChannel,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )
    let empty = try #require(
        try await database.conversationPage(in: emptyChannel)
    )
    #expect(empty.messages.isEmpty)
    #expect(empty.hasMoreBefore == false)

    let pagedChannel = ChannelID(rawValue: 80)
    let pagedMessages = (1 ... 3).map { value in
        Message(
            id: MessageID(rawValue: UInt64(80 + value)),
            channelID: pagedChannel,
            author: user,
            content: "cached \(value)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(value))
        )
    }
    try await database.saveConversationPage(
        messages: pagedMessages,
        channelID: pagedChannel,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )
    let truncated = try #require(
        try await database.conversationPage(in: pagedChannel, limit: 2)
    )
    #expect(truncated.messages == Array(pagedMessages.suffix(2)))
    #expect(truncated.hasMoreBefore == true)
}

@Test func `authoritative newest page prunes deleted rows but older pages append`() async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let channelID = ChannelID(rawValue: 81)
    let user = User(
        id: UserID(rawValue: 1),
        username: "user",
        displayName: "User"
    )
    func message(_ value: UInt64) -> Message {
        Message(
            id: MessageID(rawValue: value),
            channelID: channelID,
            author: user,
            content: "cached \(value)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(value))
        )
    }

    try await database.saveConversationPage(
        messages: [message(1), message(2), message(3), message(4)],
        channelID: channelID,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )
    try await database.saveConversationPage(
        messages: [message(3), message(4)],
        channelID: channelID,
        hasMoreBefore: true,
        mode: .reconcileNewestPage
    )
    var page = try #require(
        try await database.conversationPage(in: channelID)
    )
    #expect(page.messages == [message(1), message(2), message(3), message(4)])

    try await database.saveConversationPage(
        messages: [message(2), message(4)],
        channelID: channelID,
        hasMoreBefore: true,
        mode: .reconcileNewestPage
    )
    page = try #require(try await database.conversationPage(in: channelID))
    #expect(page.messages == [message(1), message(2), message(4)])

    try await database.saveConversationPage(
        messages: [message(0)],
        channelID: channelID,
        hasMoreBefore: false,
        mode: .appendOlderPage
    )
    page = try #require(try await database.conversationPage(in: channelID))
    #expect(page.messages == [message(0), message(1), message(2), message(4)])

    try await database.saveConversationPage(
        messages: [message(4)],
        channelID: channelID,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )
    page = try #require(try await database.conversationPage(in: channelID))
    #expect(page.messages == [message(4)])
    #expect(page.hasMoreBefore == false)
}

@Test func `authoritative page keeps an older snowflake sharing its boundary timestamp`() async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let channelID = ChannelID(rawValue: 82)
    let user = User(
        id: UserID(rawValue: 2),
        username: "boundary-user",
        displayName: "Boundary User"
    )
    let sharedTimestamp = Date(timeIntervalSince1970: 1_000)
    func message(_ value: UInt64) -> Message {
        Message(
            id: MessageID(rawValue: value),
            channelID: channelID,
            author: user,
            content: "boundary \(value)",
            timestamp: sharedTimestamp
        )
    }

    try await database.saveConversationPage(
        messages: [message(99), message(100), message(101)],
        channelID: channelID,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )
    try await database.saveConversationPage(
        messages: [message(100), message(101)],
        channelID: channelID,
        hasMoreBefore: true,
        mode: .reconcileNewestPage
    )

    let page = try #require(try await database.conversationPage(in: channelID))
    #expect(page.messages == [message(99), message(100), message(101)])
}

@Test func `authoritative refresh preserves a flushed Gateway arrival across reopen`() async throws {
    let directory = try temporaryDatabaseDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let accountID = AccountID(rawValue: 83)
    let channelID = ChannelID(rawValue: 83)
    let user = User(id: UserID(rawValue: 3), username: "gateway", displayName: "Gateway")
    let timestamp = Date(timeIntervalSince1970: 2_000)
    func message(_ value: UInt64) -> Message {
        Message(
            id: MessageID(rawValue: value),
            channelID: channelID,
            author: user,
            content: "gateway \(value)",
            timestamp: timestamp
        )
    }

    let database = try SakuraCordDatabase(accountID: accountID, directory: directory)
    try await database.saveConversationPage(
        messages: [message(100), message(101)],
        channelID: channelID,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )
    // Model the 100 ms Gateway sink winning the race with the REST refresh.
    try await database.save(messages: [message(103)])
    try await database.saveConversationPage(
        messages: [message(100), message(102)],
        protectedMessages: [message(103)],
        channelID: channelID,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )

    let reopened = try SakuraCordDatabase(accountID: accountID, directory: directory)
    let page = try #require(try await reopened.conversationPage(in: channelID))
    #expect(page.messages.map(\.id.rawValue) == [100, 102, 103])
}

@Test func `same millisecond limits use deterministic snowflake order after update and reopen`()
    async throws
{
    let directory = try temporaryDatabaseDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let accountID = AccountID(rawValue: 84)
    let channelID = ChannelID(rawValue: 84)
    let user = User(id: UserID(rawValue: 4), username: "tie", displayName: "Tie")
    let timestamp = Date(timeIntervalSince1970: 3_000)
    func message(_ value: UInt64, content: String? = nil) -> Message {
        Message(
            id: MessageID(rawValue: value),
            channelID: channelID,
            author: user,
            content: content ?? "tie \(value)",
            timestamp: timestamp
        )
    }

    let database = try SakuraCordDatabase(accountID: accountID, directory: directory)
    try await database.saveConversationPage(
        messages: (100 ... 105).reversed().map { message(UInt64($0)) },
        channelID: channelID,
        hasMoreBefore: false,
        mode: .reconcileNewestPage
    )
    try await database.save(messages: [message(104, content: "updated")])

    let reopened = try SakuraCordDatabase(accountID: accountID, directory: directory)
    let page = try #require(try await reopened.conversationPage(in: channelID, limit: 3))
    #expect(page.messages.map(\.id.rawValue) == [103, 104, 105])
    #expect(page.messages[1].content == "updated")
    #expect(page.hasMoreBefore == true)
    #expect(
        try await reopened.messages(in: channelID, limit: 3).map(\.id.rawValue)
            == [103, 104, 105]
    )
}

@Test func `partial reconciliation uses the bounded snowflake index`() async throws {
    let directory = try temporaryDatabaseDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let accountID = AccountID(rawValue: 85)
    let channelID = ChannelID(rawValue: 85)
    let user = User(id: UserID(rawValue: 5), username: "index", displayName: "Index")
    func message(_ value: UInt64) -> Message {
        Message(
            id: MessageID(rawValue: value),
            channelID: channelID,
            author: user,
            content: "index \(value)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(value))
        )
    }

    let database = try SakuraCordDatabase(accountID: accountID, directory: directory)
    try await database.save(messages: (1 ... 10_000).map { message(UInt64($0)) })
    let path = directory.appending(path: "account-\(accountID).sqlite").path
    let inspectionQueue = try DatabaseQueue(path: path)
    let indexNames = try await inspectionQueue.read { db in
        try Row.fetchAll(db, sql: "PRAGMA index_list(messages)")
            .map { (row: Row) -> String in row["name"] }
    }
    #expect(indexNames.contains("messages_channel_snowflake"))
    #expect(indexNames.contains("messages_channel_timestamp_snowflake"))
    #expect(!indexNames.contains("messages_on_channelID"))
    #expect(!indexNames.contains("messages_on_timestamp"))
    #expect(!indexNames.contains("messages_channel_timestamp"))
    let plan = try await inspectionQueue.read { db in
        try Row.fetchAll(
            db,
            sql: """
            EXPLAIN QUERY PLAN
            DELETE FROM messages
            WHERE channelID = ? AND snowflakeOrder >= ? AND id NOT IN (?, ?)
            """,
            arguments: [
                channelID.description,
                snowflakeOrderData(9_998),
                "9998",
                "10000"
            ]
        ).map { (row: Row) -> String in row["detail"] }
    }
    #expect(plan.contains { $0.contains("messages_channel_snowflake") })
    #expect(!plan.contains { $0.contains("SCAN messages") })

    try await database.saveConversationPage(
        messages: [message(9_998), message(10_000)],
        channelID: channelID,
        hasMoreBefore: true,
        mode: .reconcileNewestPage
    )
    let retained = try await database.messages(in: channelID, limit: 10_000)
    #expect(retained.count == 9_999)
    #expect(!retained.contains { $0.id.rawValue == 9_999 })
    #expect(retained.first?.id.rawValue == 1)
}

@Test func `version five cache upgrades in bounded batches with final indexes`() async throws {
    let directory = try temporaryDatabaseDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let accountID = AccountID(rawValue: 86)
    let channelID = ChannelID(rawValue: 86)
    let path = directory.appending(path: "account-\(accountID).sqlite").path
    let user = User(
        id: UserID(rawValue: 6),
        username: "upgrade",
        displayName: "Upgrade"
    )
    let timestamp = Date(timeIntervalSince1970: 4_000)
    var legacyMessages = (1 ... 1_200).map { value in
        Message(
            id: MessageID(rawValue: UInt64(value)),
            channelID: channelID,
            author: user,
            content: "legacy \(value)",
            timestamp: timestamp
        )
    }
    let unsignedHighID = UInt64.max - 1
    legacyMessages.append(Message(
        id: MessageID(rawValue: unsignedHighID),
        channelID: channelID,
        author: user,
        content: "unsigned high",
        timestamp: timestamp
    ))
    try createVersionFiveDatabase(
        at: path,
        messages: legacyMessages
    )

    let upgraded = try SakuraCordDatabase(
        accountID: accountID,
        directory: directory
    )
    let newest = try await upgraded.messages(in: channelID, limit: 2)
    #expect(newest.map(\.id.rawValue) == [1_200, unsignedHighID])

    let inspectionQueue = try DatabaseQueue(path: path)
    let indexNames = try await inspectionQueue.read { db in
        try Row.fetchAll(db, sql: "PRAGMA index_list(messages)")
            .map { (row: Row) -> String in row["name"] }
    }
    #expect(indexNames.contains("messages_channel_snowflake"))
    #expect(indexNames.contains("messages_channel_timestamp_snowflake"))
    #expect(!indexNames.contains("messages_on_channelID"))
    #expect(!indexNames.contains("messages_on_timestamp"))
    #expect(!indexNames.contains("messages_channel_timestamp"))
}

private func temporaryDatabaseDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sakuracord-persistence-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func snowflakeOrderData(_ rawValue: UInt64) -> Data {
    var ordered = rawValue.bigEndian
    return withUnsafeBytes(of: &ordered) { Data($0) }
}

private func createVersionFiveDatabase(
    at path: String,
    messages: [Message]
) throws {
    let queue = try DatabaseQueue(path: path)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-core") { db in
        try db.create(table: "messages") { table in
            table.primaryKey("id", .text)
            table.column("channelID", .text).notNull().indexed()
            table.column("timestamp", .datetime).notNull().indexed()
            table.column("payload", .blob).notNull()
        }
        try db.create(table: "drafts") { table in
            table.primaryKey("channelID", .text)
            table.column("content", .text).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
        try db.create(table: "gatewaySession") { table in
            table.primaryKey("accountID", .text)
            table.column("sessionID", .text)
            table.column("resumeURL", .text)
            table.column("sequence", .integer)
        }
    }
    migrator.registerMigration("v2-message-timeline-index") { db in
        try db.create(
            index: "messages_channel_timestamp",
            on: "messages",
            columns: ["channelID", "timestamp"]
        )
    }
    migrator.registerMigration("v3-conversation-page-boundary") { db in
        try db.create(table: "conversationPages") { table in
            table.primaryKey("channelID", .text)
            table.column("hasMoreBefore", .boolean).notNull()
        }
    }
    migrator.registerMigration("v4-bootstrap-snapshot") { db in
        try db.create(table: "bootstrapSnapshots") { table in
            table.primaryKey("id", .integer)
            table.column("payload", .blob).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
    }
    migrator.registerMigration("v5-account-presentation") { db in
        try db.create(table: "accountPresentation") { table in
            table.primaryKey("id", .integer)
            table.column("selectedChannelID", .text).notNull()
        }
    }
    try migrator.migrate(queue)
    try queue.write { db in
        let encoder = JSONEncoder()
        for message in messages {
            try db.execute(
                sql: """
                INSERT INTO messages (id, channelID, timestamp, payload)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    message.id.description,
                    message.channelID.description,
                    message.timestamp,
                    try encoder.encode(message),
                ]
            )
        }
    }
}
