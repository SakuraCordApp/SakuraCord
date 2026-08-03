import Foundation
import GRDB
import SakuraCordModels

/// Per-account storage is intentionally limited to user-authored state.
/// Discord workspace, message, read, and Gateway state belongs to the running
/// session and is never written here.
public actor SakuraCordDatabase {
    private let queue: DatabaseQueue

    public init(accountID: AccountID, directory: URL? = nil) throws {
        let root = try directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: root.appending(path: "account-\(accountID).sqlite").path)
        try Self.migrator.migrate(queue)
    }

    public init(inMemory: Bool) throws {
        queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
    }

    public func saveDraft(_ content: String, channelID: ChannelID) throws {
        try queue.write { db in
            if content.isEmpty {
                _ = try DraftRecord.deleteOne(db, key: channelID.description)
            } else {
                try DraftRecord(
                    channelID: channelID.description,
                    content: content,
                    updatedAt: .now
                ).save(db)
            }
        }
    }

    public func draft(channelID: ChannelID) throws -> String {
        try queue.read { db in
            try DraftRecord.fetchOne(db, key: channelID.description)?.content ?? ""
        }
    }

    public func clearAccountData() throws {
        _ = try queue.write { db in
            try DraftRecord.deleteAll(db)
        }
    }

    private static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "SakuraCord/Accounts", directoryHint: .isDirectory)
    }

    private static var migrator: DatabaseMigrator {
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
        // These names are retained so databases created by older builds keep a
        // monotonic migration history. Their derived-cache work is obsolete.
        migrator.registerMigration("v6-message-snowflake-order") { _ in }
        migrator.registerMigration("v7-refresh-bootstrap-unread-cache") { _ in }
        migrator.registerMigration("v8-session-only-cache") { db in
            try db.execute(sql: "DELETE FROM accountPresentation")
            try db.execute(sql: "DELETE FROM bootstrapSnapshots")
            try db.execute(sql: "DELETE FROM conversationPages")
            try db.execute(sql: "DELETE FROM gatewaySession")
            try db.execute(sql: "DELETE FROM messages")
        }
        migrator.registerMigration("v9-drop-persistent-discord-cache") { db in
            try db.drop(table: "accountPresentation")
            try db.drop(table: "bootstrapSnapshots")
            try db.drop(table: "conversationPages")
            try db.drop(table: "gatewaySession")
            try db.drop(table: "messages")
        }
        return migrator
    }
}

private struct DraftRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "drafts"
    var channelID: String
    var content: String
    var updatedAt: Date
}
