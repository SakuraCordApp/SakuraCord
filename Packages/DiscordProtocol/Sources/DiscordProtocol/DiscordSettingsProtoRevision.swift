import Foundation

extension DiscordSettingsProto {
    /// PreloadedUserSettings `versions` (field 1) `data_version` (field 3).
    static func dataVersion(in root: Data) -> UInt32? {
        ProtoReader.fields(root)
            .filter { $0.field == 1 }
            .compactMap(\.payload)
            .flatMap(ProtoReader.fields)
            .last { $0.field == 3 && $0.varint != nil }?.varint
            .map { UInt32(truncatingIfNeeded: $0) }
    }

    /// The field an encoded settings update carries, if the update applies:
    /// it must carry the field or replace all settings, where a missing
    /// field reads as empty, and must not be older than `dataVersion`, which
    /// it advances.
    static func acceptedField(
        in encoded: String?,
        replacesAllSettings: Bool,
        dataVersion: inout UInt32?,
        field: (Data) -> Data?
    ) -> Data? {
        guard let encoded, let data = Data(base64Encoded: encoded) else { return nil }
        let message = field(data)
        guard message != nil || replacesAllSettings else { return nil }
        let version = Self.dataVersion(in: data)
        if isStale(version, comparedWith: dataVersion) { return nil }
        if let version { dataVersion = version }
        return message ?? Data()
    }

    /// Whether an update at `incoming` is older than the `current` revision.
    static func isStale(_ incoming: UInt32?, comparedWith current: UInt32?) -> Bool {
        guard let incoming, let current else { return false }
        return incoming < current
    }

    static func advance(_ current: inout UInt32?, to version: UInt32) {
        current = max(current ?? version, version)
    }

    /// Each supplied top-level settings message replaces that field. A newer
    /// partial update must protect its fields without discarding older full
    /// snapshot fields that it never supplied.
    static func mergingRevisionedSettings(
        _ incoming: Data,
        into current: Data,
        isPartial: Bool,
        fieldVersions: inout [Int: UInt32]
    ) -> Data {
        let supplied = settingsFields(in: incoming)
        var result = settingsFields(in: current)
        let fields = isPartial ? Set(supplied.keys)
            : Set(supplied.keys).union(result.keys).union(fieldVersions.keys)
        let version = dataVersion(in: incoming)
        for field in fields {
            if isStale(version, comparedWith: fieldVersions[field]) { continue }
            result[field] = supplied[field]
            if let version { fieldVersions[field] = version }
        }
        return result.keys.sorted().reduce(into: Data()) { data, field in
            for raw in result[field] ?? [] { data.append(raw) }
        }
    }

    private static func settingsFields(in data: Data) -> [Int: [Data]] {
        var reader = ProtoReader(data: data)
        var result: [Int: [Data]] = [:]
        while let field = reader.readRawField() { result[field.field, default: []].append(field.raw) }
        return result
    }
}
