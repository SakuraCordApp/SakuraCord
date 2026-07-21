import Foundation
import GRDB
import SakuraCordModels

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

    public func save(messages: [Message]) throws {
        try queue.write { db in
            for message in messages {
                try MessageRecord(message).save(db)
            }
        }
    }

    public func deleteMessage(_ messageID: MessageID) throws {
        try queue.write { db in
            _ = try MessageRecord.deleteOne(db, key: messageID.description)
        }
    }

    public func messages(in channelID: ChannelID, limit: Int = 100) throws -> [Message] {
        try queue.read { db in
            let records = try MessageRecord
                .filter(Column("channelID") == channelID.description)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
            // A cache entry written by an older model version must never prevent
            // the channel from falling through to a fresh Discord fetch.
            return records.reversed().compactMap { try? $0.message() }
        }
    }

    public func saveDraft(_ content: String, channelID: ChannelID) throws {
        try queue.write { db in
            if content.isEmpty {
                _ = try DraftRecord.deleteOne(db, key: channelID.description)
            } else {
                try DraftRecord(channelID: channelID.description, content: content, updatedAt: .now).save(db)
            }
        }
    }

    public func draft(channelID: ChannelID) throws -> String {
        try queue.read { db in try DraftRecord.fetchOne(db, key: channelID.description)?.content ?? "" }
    }

    public func clearAccountData() throws {
        try queue.write { db in
            try MessageRecord.deleteAll(db)
            try DraftRecord.deleteAll(db)
        }
    }

    private static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
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
        return migrator
    }
}

private struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"
    var id: String
    var channelID: String
    var timestamp: Date
    var payload: Data

    init(_ message: Message) throws {
        id = message.id.description
        channelID = message.channelID.description
        timestamp = message.timestamp
        payload = try JSONEncoder().encode(message)
    }

    func message() throws -> Message {
        try JSONDecoder().decode(Message.self, from: payload)
    }
}

private struct DraftRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "drafts"
    var channelID: String
    var content: String
    var updatedAt: Date
}
