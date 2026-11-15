import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    public func configureEmojiFrecencyPersistence(_ prepare: @escaping @Sendable () async -> EmojiFrecencySaveContribution?) async {
        prepareEmojiFrecencySave = prepare
    }

    public func saveEmojiFrecency(
        _ messages: DiscordFrecencyHistory,
        reactions: DiscordFrecencyHistory,
        favoriteKey: String?,
        isFavorite: Bool
    ) async throws -> EmojiUserSettings {
        let current = try await frecencySettingsProto()
        var patch = DiscordSettingsProto.frecencyPatch(messages, field: DiscordSettingsProto.emojiFrecencyField, limit: 100, preserving: current)
        patch.append(DiscordSettingsProto.frecencyPatch(reactions, field: DiscordSettingsProto.reactionFrecencyField, limit: 100, preserving: current))
        if let favoriteKey {
            patch.append(try emojiFavoritePatch(favoriteKey, isFavorite: isFavorite, current: current))
        }
        return try await persistEmojiSettingsPatch(patch, includesEmojiUsage: true)
    }

    func emojiFavoritePatch(_ key: String, isFavorite: Bool, current: Data) throws -> Data {
        let update = try DiscordSettingsProto.updatingEmojiFavorite(in: current, key: key, isFavorite: isFavorite)
        return frecencyField(5, in: update.data)
    }

    func frecencyField(_ number: Int, in data: Data) -> Data {
        var reader = ProtoReader(data: data)
        var patch = Data()
        while let field = reader.readRawField() {
            if field.field == number { patch.append(field.raw) }
        }
        return patch
    }

    func persistEmojiSettingsPatch(_ patch: Data, includesEmojiUsage: Bool = false) async throws -> EmojiUserSettings {
        let stored = try await persistFrecencySettingsPatch(patch, includesEmojiUsage: includesEmojiUsage)
        return DiscordSettingsProto.emojiSettings(from: stored)
    }

    /// Every type-2 save carries pending emoji usage, as Discord's before-send
    /// callback does. Keep one PATCH and acknowledge the exact contributed batch.
    func persistFrecencySettingsPatch(_ changedFields: Data, includesEmojiUsage: Bool = false) async throws -> Data {
        let contribution = includesEmojiUsage ? nil : await prepareEmojiFrecencySave?()
        var patch = changedFields
        if let contribution {
            let current = cachedFrecencySettingsProto ?? Data()
            patch.append(DiscordSettingsProto.frecencyPatch(contribution.messages, field: DiscordSettingsProto.emojiFrecencyField, limit: 100, preserving: current))
            patch.append(DiscordSettingsProto.frecencyPatch(contribution.reactions, field: DiscordSettingsProto.reactionFrecencyField, limit: 100, preserving: current))
        }
        do {
            let response: UserSettingsProtoDTO = try await request(
                "/users/@me/settings-proto/2", method: "PATCH",
                body: ["settings": .string(patch.base64EncodedString())]
            )
            guard let stored = Data(base64Encoded: response.settings) else {
                throw ChatProviderError.invalidRequest("Discord returned invalid frecency settings.")
            }
            let settings = DiscordSettingsProto.emojiSettings(from: stored)
            if (settings.dataVersion ?? 0) >= (cachedFrecencySettingsProto.flatMap { DiscordSettingsProto.dataVersion(in: $0) } ?? 0) {
                cachedFrecencySettingsProto = pendingStickerFrecencyPatch.map {
                    DiscordSettingsProto.mergingPartialFrecencySettings($0, into: stored)
                } ?? stored
                cachedEmojiUserSettings = settings
            }
            await contribution?.complete(settings)
            return stored
        } catch {
            await contribution?.complete(nil)
            throw error
        }
    }
}
