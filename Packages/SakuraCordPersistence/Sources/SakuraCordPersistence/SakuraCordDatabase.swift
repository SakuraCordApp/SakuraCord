import Foundation
import GRDB
import SakuraCordModels

public struct PersistedConversationPage: Sendable {
    public let messages: [Message]
    /// Nil identifies message rows written before the boundary migration. The
    /// caller can present those rows immediately but must fetch once before
    /// claiming the beginning is authoritative.
    public let hasMoreBefore: Bool?

    public init(messages: [Message], hasMoreBefore: Bool?) {
        self.messages = messages
        self.hasMoreBefore = hasMoreBefore
    }
}

public enum ConversationPagePersistenceMode: Sendable {
    /// The server's newest page is authoritative for every cached row at or
    /// after its oldest message. Rows omitted from that covered range were
    /// deleted remotely and must not be resurrected on the next launch.
    case reconcileNewestPage
    /// An older page extends the cache without making any claim about rows
    /// outside that page.
    case appendOlderPage
}

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

    public func saveConversationPage(
        messages: [Message],
        protectedMessages: [Message] = [],
        deletedMessageIDs: Set<MessageID> = [],
        channelID: ChannelID,
        hasMoreBefore: Bool,
        mode: ConversationPagePersistenceMode
    ) throws {
        try queue.write { db in
            if mode == .reconcileNewestPage {
                let channelRows = MessageRecord
                    .filter(Column("channelID") == channelID.description)
                let authoritativeIDs = Set(messages.map { $0.id.description })
                let protectedIDs = Set(protectedMessages.map { $0.id.description })
                let deletedIDs = Set(deletedMessageIDs.map(\.description))
                let retainedIDs = authoritativeIDs
                    .union(protectedIDs)
                    .subtracting(deletedIDs)
                if hasMoreBefore, let oldestFreshID = messages.map(\.id).min() {
                    // The 8-byte big-endian key preserves unsigned snowflake
                    // order in SQLite and lets the indexed delete stay bounded
                    // to the authoritative newest-page range.
                    var coveredRows = channelRows.filter(
                        Column("snowflakeOrder")
                            >= MessageRecord.snowflakeOrderData(oldestFreshID.rawValue)
                    )
                    if !retainedIDs.isEmpty {
                        coveredRows = coveredRows.filter(
                            !Array(retainedIDs).contains(Column("id"))
                        )
                    }
                    _ = try coveredRows.deleteAll(db)
                } else if !hasMoreBefore {
                    if retainedIDs.isEmpty {
                        _ = try channelRows.deleteAll(db)
                    } else {
                        _ = try channelRows
                            .filter(!Array(retainedIDs).contains(Column("id")))
                            .deleteAll(db)
                    }
                }
            }
            for message in messages {
                try MessageRecord(message).save(db)
            }
            // Gateway mutations observed after the REST refresh boundary must
            // win over the potentially stale page in this same transaction.
            for message in protectedMessages {
                try MessageRecord(message).save(db)
            }
            for messageID in deletedMessageIDs {
                _ = try MessageRecord.deleteOne(db, key: messageID.description)
            }
            try ConversationPageRecord(
                channelID: channelID.description,
                hasMoreBefore: hasMoreBefore
            ).save(db)
        }
    }

    public func saveBootstrapSnapshot(_ snapshot: BootstrapSnapshot) throws {
        let payload = try JSONEncoder().encode(snapshot)
        try queue.write { db in
            try BootstrapSnapshotRecord(
                id: 1,
                payload: payload,
                updatedAt: .now
            ).save(db)
        }
    }

    public func bootstrapSnapshot() throws -> BootstrapSnapshot? {
        try queue.read { db in
            guard let record = try BootstrapSnapshotRecord.fetchOne(db, key: 1) else {
                return nil
            }
            // Model changes must never make the account database unusable.
            // Treat an obsolete cached presentation as a miss and let the
            // authenticated bootstrap replace it.
            return try? JSONDecoder().decode(
                BootstrapSnapshot.self,
                from: record.payload
            )
        }
    }

    public func saveSelectedChannelID(_ channelID: ChannelID) throws {
        try queue.write { db in
            try AccountPresentationRecord(
                id: 1,
                selectedChannelID: channelID.description
            ).save(db)
        }
    }

    public func selectedChannelID() throws -> ChannelID? {
        try queue.read { db in
            guard let rawValue = try AccountPresentationRecord
                .fetchOne(db, key: 1)?.selectedChannelID,
                let value = UInt64(rawValue)
            else { return nil }
            return ChannelID(rawValue: value)
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
                .order(
                    Column("timestamp").desc,
                    Column("snowflakeOrder").desc
                )
                .limit(limit)
                .fetchAll(db)
            // A cache entry written by an older model version must never prevent
            // the channel from falling through to a fresh Discord fetch.
            return records.reversed().compactMap { try? $0.message() }
        }
    }

    public func conversationPage(
        in channelID: ChannelID,
        limit: Int = 100
    ) throws -> PersistedConversationPage? {
        try queue.read { db in
            let page = try ConversationPageRecord.fetchOne(
                db,
                key: channelID.description
            )
            let records = try MessageRecord
                .filter(Column("channelID") == channelID.description)
                .order(
                    Column("timestamp").desc,
                    Column("snowflakeOrder").desc
                )
                .limit(limit + 1)
                .fetchAll(db)
            guard page != nil || !records.isEmpty else { return nil }
            let wasTruncated = records.count > limit
            let retainedRecords = records.prefix(limit)
            return PersistedConversationPage(
                messages: retainedRecords.reversed().compactMap {
                    try? $0.message()
                },
                hasMoreBefore: page.map {
                    $0.hasMoreBefore || wasTruncated
                }
            )
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
            try ConversationPageRecord.deleteAll(db)
            try BootstrapSnapshotRecord.deleteAll(db)
            try AccountPresentationRecord.deleteAll(db)
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
        migrator.registerMigration("v6-message-snowflake-order") { db in
            try db.alter(table: "messages") { table in
                table.add(
                    column: "snowflakeOrder",
                    .blob
                )
                .notNull()
                .defaults(to: Data(repeating: 0, count: 8))
            }
            var lastRowID: Int64 = 0
            while true {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT rowid, id
                    FROM messages
                    WHERE rowid > ?
                    ORDER BY rowid
                    LIMIT 500
                    """,
                    arguments: [lastRowID]
                )
                guard !rows.isEmpty else { break }
                for row in rows {
                    let rowID: Int64 = row["rowid"]
                    let id: String = row["id"]
                    lastRowID = rowID
                    guard let rawValue = UInt64(id) else {
                        try db.execute(
                            sql: "DELETE FROM messages WHERE rowid = ?",
                            arguments: [rowID]
                        )
                        continue
                    }
                    try db.execute(
                        sql: "UPDATE messages SET snowflakeOrder = ? WHERE rowid = ?",
                        arguments: [
                            MessageRecord.snowflakeOrderData(rawValue),
                            rowID,
                        ]
                    )
                }
            }
            try db.create(
                index: "messages_channel_snowflake",
                on: "messages",
                columns: ["channelID", "snowflakeOrder"]
            )
            try db.create(
                index: "messages_channel_timestamp_snowflake",
                on: "messages",
                columns: ["channelID", "timestamp", "snowflakeOrder"]
            )
            try db.drop(index: "messages_on_channelID")
            try db.drop(index: "messages_on_timestamp")
            try db.drop(index: "messages_channel_timestamp")
        }
        migrator.registerMigration("v7-refresh-bootstrap-unread-cache") { db in
            // Snapshots written before v7 omitted the account notification
            // mode and were not refreshed after read-state changes. Drop only
            // that derived first-paint cache; live Ready will repopulate it.
            try BootstrapSnapshotRecord.deleteAll(db)
        }
        return migrator
    }
}

private struct BootstrapSnapshotRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "bootstrapSnapshots"
    var id: Int
    var payload: Data
    var updatedAt: Date
}

private struct AccountPresentationRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "accountPresentation"
    var id: Int
    var selectedChannelID: String
}

private struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"
    var id: String
    var channelID: String
    var timestamp: Date
    var snowflakeOrder: Data
    var payload: Data

    init(_ message: Message) throws {
        id = message.id.description
        channelID = message.channelID.description
        timestamp = message.timestamp
        snowflakeOrder = Self.snowflakeOrderData(message.id.rawValue)
        payload = try JSONEncoder().encode(message)
    }

    static func snowflakeOrderData(_ rawValue: UInt64) -> Data {
        var ordered = rawValue.bigEndian
        return withUnsafeBytes(of: &ordered) { Data($0) }
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

private struct ConversationPageRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "conversationPages"
    var channelID: String
    var hasMoreBefore: Bool
}
