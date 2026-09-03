import Foundation
import SakuraCordModels

private struct DiscordStickerPackCollectionDTO: Decodable {
    var stickerPacks: [DiscordStickerPackDTO]

    enum CodingKeys: String, CodingKey {
        case stickerPacks = "sticker_packs"
    }
}

private struct DiscordStickerPackDTO: Decodable {
    var id: String
    var name: String
    var description: String?
    var coverStickerID: String?
    var stickers: [MessageStickerDTO]

    enum CodingKeys: String, CodingKey {
        case id, name, description, stickers
        case coverStickerID = "cover_sticker_id"
    }

    var domain: StickerPack {
        StickerPack(
            id: id,
            name: name,
            description: description,
            coverStickerID: coverStickerID,
            stickers: stickers
                .filter { $0.available ?? true }
                .sorted {
                    ($0.sortValue ?? .max, $0.id) < ($1.sortValue ?? .max, $1.id)
                }
                .map(\.domain)
        )
    }
}

struct GatewayGuildStickersUpdateDTO: Decodable {
    var guildID: String
    var stickers: [MessageStickerDTO]

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case stickers
    }
}

public extension DiscordRESTProvider {
    func stickers(in guildID: GuildID) async throws -> [MessageSticker] {
        cachedStickersByGuild[guildID] ?? []
    }

    func standardStickerPacks() async throws -> [StickerPack] {
        if let cachedStandardStickerPacks { return cachedStandardStickerPacks }
        if let standardStickerPacksTask { return try await standardStickerPacksTask.value }
        let task = Task { [self] in
            let response: DiscordStickerPackCollectionDTO = try await request(
                "/sticker-packs",
                query: [URLQueryItem(name: "locale", value: Self.stickerLocale)]
            )
            return response.stickerPacks.map(\.domain)
        }
        standardStickerPacksTask = task
        do {
            let packs = try await task.value
            standardStickerPacksTask = nil
            cachedStandardStickerPacks = packs
            return packs
        } catch {
            standardStickerPacksTask = nil
            throw error
        }
    }

    func stickerUserSettings() async throws -> StickerUserSettings {
        if let cachedStickerUserSettings { return cachedStickerUserSettings }
        let data = try await frecencySettingsProto()
        let settings = DiscordSettingsProto.stickerSettings(from: data)
        cachedStickerUserSettings = settings
        return settings
    }

    func setStickerFavorite(_ stickerID: String, isFavorite: Bool) async throws
        -> StickerUserSettings
    {
        guard !isMutatingFrecencyFavorite else {
            throw ChatProviderError.invalidRequest("A favorite update is already in progress.")
        }
        isMutatingFrecencyFavorite = true
        defer { isMutatingFrecencyFavorite = false }

        let current = try await frecencySettingsProto()
        let update = try DiscordSettingsProto.updatingStickerFavorite(
            in: current,
            stickerID: stickerID,
            isFavorite: isFavorite
        )
        let includedFrecencyRevision = stickerFrecencyRevision
        var patch = update.patch
        if let pendingStickerFrecencyPatch {
            patch.append(pendingStickerFrecencyPatch)
        }
        let response: UserSettingsProtoDTO = try await request(
            "/users/@me/settings-proto/2",
            method: "PATCH",
            body: ["settings": .string(patch.base64EncodedString())]
        )
        let responseData = Data(base64Encoded: response.settings) ?? update.data
        let merged: Data
        if stickerFrecencyRevision == includedFrecencyRevision {
            merged = responseData
            stickerFrecencyFlushGeneration &+= 1
            stickerFrecencyFlushTask?.cancel()
            stickerFrecencyFlushTask = nil
            pendingStickerFrecencyPatch = nil
        } else {
            // A send recorded another use while the favorite request was in
            // flight. Keep that newer field 4 and apply only this field-3
            // favorite result locally; its scheduled flush remains authoritative.
            merged = DiscordSettingsProto.mergingPartialFrecencySettings(
                update.patch,
                into: cachedFrecencySettingsProto ?? responseData
            )
        }
        cachedFrecencySettingsProto = merged
        let settings = DiscordSettingsProto.stickerSettings(from: merged)
        cachedStickerUserSettings = settings
        continuation?.yield(.stickerUserSettingsChanged(settings))
        return settings
    }

    func recordStickerUse(_ stickerID: String) async throws -> StickerUserSettings {
        let current = try await frecencySettingsProto()
        let update = try DiscordSettingsProto.recordingStickerUse(
            in: current,
            stickerID: stickerID
        )
        cachedFrecencySettingsProto = update.data
        cachedStickerUserSettings = update.settings
        pendingStickerFrecencyPatch = update.patch
        stickerFrecencyRevision &+= 1
        scheduleStickerFrecencyFlush()
        continuation?.yield(.stickerUserSettingsChanged(update.settings))
        return update.settings
    }

    internal func flushStickerFrecencyIfNeeded(expectedGeneration: UInt64? = nil) async {
        if let expectedGeneration,
           expectedGeneration != stickerFrecencyFlushGeneration
        {
            return
        }
        guard let patch = pendingStickerFrecencyPatch else { return }
        let revision = stickerFrecencyRevision
        defer {
            if expectedGeneration == nil
                || expectedGeneration == stickerFrecencyFlushGeneration
            {
                stickerFrecencyFlushTask = nil
            }
        }
        do {
            let response: UserSettingsProtoDTO = try await request(
                "/users/@me/settings-proto/2",
                method: "PATCH",
                body: ["settings": .string(patch.base64EncodedString())]
            )
            if stickerFrecencyRevision == revision,
               let data = Data(base64Encoded: response.settings)
            {
                cachedFrecencySettingsProto = data
                let settings = DiscordSettingsProto.stickerSettings(from: data)
                cachedStickerUserSettings = settings
                continuation?.yield(.stickerUserSettingsChanged(settings))
            }
            if stickerFrecencyRevision == revision,
               pendingStickerFrecencyPatch == patch
            {
                pendingStickerFrecencyPatch = nil
            }
        } catch {
            gatewayLogger.error(
                "Could not persist sticker frecency: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func scheduleStickerFrecencyFlush() {
        stickerFrecencyFlushTask?.cancel()
        stickerFrecencyFlushGeneration &+= 1
        let generation = stickerFrecencyFlushGeneration
        stickerFrecencyFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.flushStickerFrecencyIfNeeded(expectedGeneration: generation)
        }
    }

    private static var stickerLocale: String {
        Locale.preferredLanguages.first ?? "en-US"
    }
}
