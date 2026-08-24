import Foundation
import GRDB
import SakuraCordModels
@testable import SakuraCordPersistence
import Testing

@Test func `drafts round trip and clear with scoped draft action`() async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let channelID = ChannelID(rawValue: 12)

    try await database.saveDraft("hello", channelID: channelID)
    #expect(try await database.draft(channelID: channelID) == "hello")

    try await database.clearDrafts()
    #expect(try await database.draft(channelID: channelID).isEmpty)
}

@Test func `legacy Discord caches are dropped while drafts survive migration`() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "sakuracord-session-cache-migration-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let accountID = AccountID(rawValue: 86)
    let channelID = ChannelID(rawValue: 87)
    let path = directory.appending(path: "account-\(accountID).sqlite").path
    try createVersionFiveDatabase(
        at: path,
        channelID: channelID,
        draft: "keep this draft"
    )

    let upgraded = try SakuraCordDatabase(
        accountID: accountID,
        directory: directory
    )
    #expect(try await upgraded.draft(channelID: channelID) == "keep this draft")

    let inspectionQueue = try DatabaseQueue(path: path)
    let tableNames = try await inspectionQueue.read { db in
        try String.fetchAll(
            db,
            sql: """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
    }
    #expect(tableNames == ["drafts", "grdb_migrations"])
}

private func createVersionFiveDatabase(
    at path: String,
    channelID: ChannelID,
    draft: String
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
        try db.execute(
            sql: """
            INSERT INTO drafts (channelID, content, updatedAt)
            VALUES (?, ?, ?)
            """,
            arguments: [channelID.description, draft, Date.now]
        )
        try db.execute(
            sql: """
            INSERT INTO messages (id, channelID, timestamp, payload)
            VALUES ('1', ?, ?, X'00')
            """,
            arguments: [channelID.description, Date.now]
        )
        try db.execute(
            sql: """
            INSERT INTO conversationPages (channelID, hasMoreBefore)
            VALUES (?, 0)
            """,
            arguments: [channelID.description]
        )
        try db.execute(
            sql: """
            INSERT INTO bootstrapSnapshots (id, payload, updatedAt)
            VALUES (1, X'00', ?)
            """,
            arguments: [Date.now]
        )
        try db.execute(
            sql: """
            INSERT INTO accountPresentation (id, selectedChannelID)
            VALUES (1, ?)
            """,
            arguments: [channelID.description]
        )
        try db.execute(
            sql: """
            INSERT INTO gatewaySession (accountID, sessionID, resumeURL, sequence)
            VALUES ('legacy', 'session', 'wss://gateway.example', 1)
            """
        )
    }
}
