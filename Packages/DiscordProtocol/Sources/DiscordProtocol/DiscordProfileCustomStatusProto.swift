import Foundation
import SakuraCordModels

extension DiscordSettingsProto {
    static func statusSettings(in data: Data) -> Data? {
        var reader = ProtoReader(data: data)
        var result: Data?
        while let field = reader.readRawField() {
            if field.field == 11 { result = field.payload }
        }
        return result
    }

    /// PreloadedUserSettings `versions` (field 1) `data_version` (field 3).
    static func dataVersion(in root: Data) -> UInt32? {
        var reader = ProtoReader(data: root)
        var result: UInt32?
        while let field = reader.readRawField() {
            guard field.field == 1, let payload = field.payload else { continue }
            var versions = ProtoReader(data: payload)
            while let version = versions.readRawField() {
                if version.field == 3, let value = version.varint { result = UInt32(truncatingIfNeeded: value) }
            }
        }
        return result
    }

    /// StatusSettings.status (field 1) is a google.protobuf.StringValue whose
    /// field 1 carries the account-wide presence string.
    static func presenceStatus(in statusSettings: Data) -> PresenceStatus? {
        var statusReader = ProtoReader(data: statusSettings)
        var payload: Data?
        while let field = statusReader.readRawField() {
            if field.field == 1 { payload = field.payload }
        }
        guard let payload else { return nil }
        var reader = ProtoReader(data: payload)
        var value: String?
        while let field = reader.readRawField() {
            if field.field == 1 { value = field.payload.flatMap { String(data: $0, encoding: .utf8) } }
        }
        return value.flatMap(PresenceStatus.init(rawValue:))
    }

    static func customStatus(in statusSettings: Data) -> ProfileCustomStatus? {
        var statusReader = ProtoReader(data: statusSettings)
        var payload: Data?
        while let field = statusReader.readRawField() {
            if field.field == 2 { payload = field.payload }
        }
        guard let payload else { return nil }
        var reader = ProtoReader(data: payload)
        var status = ProfileCustomStatus(text: "")
        while let tag = reader.readTag() {
            switch (tag.field, tag.wireType) {
            case (1, 2): status.text = reader.readLengthDelimited().flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case (2, 1): status.emojiID = reader.readFixed64().flatMap { $0 == 0 ? nil : String($0) }
            case (3, 2): status.emojiName = reader.readLengthDelimited().flatMap { String(data: $0, encoding: .utf8) }
            case (4, 1): status.expiresAt = reader.readFixed64().flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: Double($0) / 1000) }
            case (5, 1): status.createdAt = reader.readFixed64().flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: Double($0) / 1000) }
            default: if !reader.skip(wireType: tag.wireType) { return nil }
            }
        }
        return status
    }

    /// settings-proto/1 replaces the complete StatusSettings message. Retain
    /// presence, its independent expiry/creation time, game visibility and unknown
    /// fields. Clearing omits custom_status rather than sending an empty message.
    static func updatingCustomStatus(_ status: ProfileCustomStatus?, in current: Data) -> Data {
        guard let status else { return updatingStatusSettings(in: current, replacing: [2: nil]) }
        var payload = Data()
        if !status.text.isEmpty { payload.append(protoLengthDelimitedField(1, Data(status.text.utf8))) }
        if let emojiID = status.emojiID.flatMap(UInt64.init), emojiID != 0 { payload.append(protoFixed64Field(2, emojiID)) }
        if let name = status.emojiName, !name.isEmpty { payload.append(protoLengthDelimitedField(3, Data(name.utf8))) }
        if let expiry = status.expiresAt { payload.append(protoFixed64Field(4, UInt64(expiry.timeIntervalSince1970 * 1000))) }
        if let createdAt = status.createdAt { payload.append(protoFixed64Field(5, UInt64(createdAt.timeIntervalSince1970 * 1000))) }
        return updatingStatusSettings(in: current, replacing: [2: protoLengthDelimitedField(2, payload)])
    }

    /// Official stable622805 module827827 picks a status without a duration by
    /// setting `status`, clearing `status_expires_at_ms` (0 is omitted), and
    /// keeping `status_created_at_ms` only when the status is unchanged.
    static func updatingPresenceStatus(_ status: PresenceStatus, in current: Data, now: Date) -> Data {
        var createdAt: Data?
        if presenceStatus(in: current) == status {
            var reader = ProtoReader(data: current)
            while let field = reader.readRawField() {
                if field.field == 5 { createdAt = field.raw }
            }
        }
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        return updatingStatusSettings(in: current, replacing: [
            1: protoLengthDelimitedField(1, protoLengthDelimitedField(1, Data(status.rawValue.utf8))),
            4: nil,
            5: createdAt ?? protoLengthDelimitedField(5, protoVarintField(1, milliseconds)),
        ])
    }

    /// Returns root field 11 with the named StatusSettings fields replaced or
    /// removed, preserving every other known and unknown sibling.
    private static func updatingStatusSettings(in current: Data, replacing replacements: [Int: Data?]) -> Data {
        var reader = ProtoReader(data: current)
        var fields: [(number: Int, bytes: Data)] = []
        while let field = reader.readRawField() {
            if !replacements.keys.contains(field.field) { fields.append((field.field, field.raw)) }
        }
        for case let (number, bytes?) in replacements { fields.append((number, bytes)) }
        return protoLengthDelimitedField(11, fields.sorted { $0.number < $1.number }.reduce(into: Data()) { $0.append($1.bytes) })
    }
}
