import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func applyGuildSettingsProto(
        _ encoded: String?,
        replacesAllSettings: Bool = false
    ) {
        guard
            let encoded,
            let data = Data(base64Encoded: encoded)
        else { return }
        let decodedLayout = DiscordSettingsProto.guildLayout(from: data)
        guard decodedLayout != nil || replacesAllSettings else { return }
        let layout = decodedLayout ?? DiscordGuildLayout(folders: [], guildPositions: [])
        cachedGuildLayout = layout
        // A current desktop READY can provide every guild ID and its channels
        // while omitting the catalogue metadata required to construct Guilds.
        // Preserve the settings until bootstrap's bounded guild-list fallback
        // has installed that catalogue instead of replacing the cached rail
        // with an empty layout event here.
        guard !cachedGuilds.isEmpty else { return }
        let result = Self.applyingGuildLayout(layout, to: guildsInCurrentRailOrder())
        cachedGuilds = Dictionary(uniqueKeysWithValues: result.guilds.map { ($0.id, $0) })
        guard result.railItems != cachedGuildRailItems else { return }
        cachedGuildRailItems = result.railItems
        continuation?.yield(.guildLayoutChanged(guilds: result.guilds, railItems: result.railItems))
    }

    func guildsInCurrentRailOrder() -> [Guild] {
        let existingOrder = cachedGuildRailItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let id): [id]
            case .folder(let folder): folder.guildIDs
            }
        }
        let existingSet = Set(existingOrder)
        let orderedGuilds =
            existingOrder.compactMap { cachedGuilds[$0] }
                + cachedGuilds.values
                .filter { !existingSet.contains($0.id) }
                .sorted { $0.id.rawValue > $1.id.rawValue }
        return orderedGuilds
    }
}
