import Foundation
import SakuraCordModels

extension DiscordSettingsProto {
    private struct FrequentSoundEntry {
        let key: String
        let frecency: Int
        let order: Int
    }

    static func soundboardSettings(
        from data: Data,
        nowMilliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) -> SoundboardUserSettings {
        var reader = ProtoReader(data: data)
        var favorites: [String] = []
        var favoriteSet: Set<String> = []
        var frequentEntries: [FrequentSoundEntry] = []
        var scores: [String: Int] = [:]
        while let tag = reader.readTag() {
            guard tag.wireType == 2, let payload = reader.readLengthDelimited() else {
                if !reader.skip(wireType: tag.wireType) { break }
                continue
            }
            if tag.field == 8 {
                var favoriteReader = ProtoReader(data: payload)
                while let favoriteTag = favoriteReader.readTag() {
                    guard favoriteTag.field == 1 else {
                        if !favoriteReader.skip(wireType: favoriteTag.wireType) { break }
                        continue
                    }
                    for soundID in readFixed64Values(
                        wireType: favoriteTag.wireType,
                        reader: &favoriteReader
                    ).map(\.description)
                    where favoriteSet.insert(soundID).inserted {
                        favorites.append(soundID)
                    }
                }
            } else if tag.field == 11 {
                for entry in stringFrecencyEntries(
                    from: payload,
                    nowMilliseconds: nowMilliseconds
                ) {
                    scores[entry.key] = max(scores[entry.key, default: 0], entry.score)
                    frequentEntries.append(FrequentSoundEntry(
                        key: entry.key,
                        frecency: entry.frecency,
                        order: frequentEntries.count
                    ))
                }
            }
        }
        var seen: Set<String> = []
        let frequent = frequentEntries
            .sorted { left, right in
                left.frecency == right.frecency
                    ? left.order < right.order
                    : left.frecency > right.frecency
            }
            .compactMap { seen.insert($0.key).inserted ? $0.key : nil }
            .prefix(32)
        return SoundboardUserSettings(
            favoriteSoundIDs: favorites,
            frequentlyUsedSoundIDs: Array(frequent),
            usageScores: scores
        )
    }

    static func updatingSoundboardFavorite(
        in data: Data,
        soundID: String,
        isFavorite: Bool
    ) throws -> (data: Data, settings: SoundboardUserSettings) {
        guard UInt64(soundID) != nil else {
            throw ChatProviderError.invalidRequest("The sound has an invalid Discord ID.")
        }
        var favorites = soundboardSettings(from: data).favoriteSoundIDs
        favorites.removeAll { $0 == soundID }
        if isFavorite {
            guard favorites.count < 250 else {
                throw ChatProviderError.invalidRequest(
                    "Discord's soundboard favorites limit has been reached."
                )
            }
            favorites.append(soundID)
        }

        var packed = Data()
        for favorite in favorites.compactMap(UInt64.init) {
            var littleEndian = favorite.littleEndian
            withUnsafeBytes(of: &littleEndian) { packed.append(contentsOf: $0) }
        }
        var payload = Data()
        payload.append(protoLengthDelimitedField(1, packed))
        let updated = replacingLengthDelimitedField(8, in: data, with: payload)
        return (updated, soundboardSettings(from: updated))
    }
}
