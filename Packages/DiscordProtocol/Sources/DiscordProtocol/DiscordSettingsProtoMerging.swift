import Foundation

extension DiscordSettingsProto {
    static func mergingPartialFrecencySettings(
        _ patch: Data,
        into current: Data
    ) -> Data {
        var patchReader = ProtoReader(data: patch)
        var patchFields: [RawProtoField] = []
        var replacedFieldNumbers: Set<Int> = []
        while let field = patchReader.readRawField() {
            patchFields.append(field)
            replacedFieldNumbers.insert(field.field)
        }
        guard !patchFields.isEmpty else { return current }

        var currentReader = ProtoReader(data: current)
        var merged = Data()
        while let field = currentReader.readRawField() {
            if !replacedFieldNumbers.contains(field.field) {
                merged.append(field.raw)
            }
        }
        for field in patchFields {
            merged.append(field.raw)
        }
        return merged
    }
}
