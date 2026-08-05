import Foundation
import SakuraCordModels

struct ProfileCacheKey: Hashable {
    var userID: UserID
    var guildID: GuildID?
}

struct UserSettingsProtoDTO: Decodable {
    var settings: String
}

struct DiscordGuildLayout: Equatable {
    struct Folder: Equatable {
        var guildIDs: [GuildID]
        var id: Int64?
        var name: String?
        var colorHex: UInt32?
    }

    var folders: [Folder]
    var guildPositions: [GuildID]
}

enum DiscordSettingsProto {
    private struct FrequentEmojiEntry {
        let key: String
        let frecency: Int
        let order: Int
    }

    static func guildOrder(from data: Data) -> [GuildID]? {
        guard let layout = guildLayout(from: data) else { return nil }
        let folderOrder = layout.folders.flatMap(\.guildIDs)
        return folderOrder.isEmpty ? layout.guildPositions : folderOrder
    }

    static func guildLayout(from data: Data) -> DiscordGuildLayout? {
        var topLevel = ProtoReader(data: data)
        while let tag = topLevel.readTag() {
            if tag.field == 14, tag.wireType == 2, let guildFolders = topLevel.readLengthDelimited() {
                return layout(fromGuildFolders: guildFolders)
            }
            guard topLevel.skip(wireType: tag.wireType) else { return nil }
        }
        return nil
    }

    static func emojiSettings(
        from data: Data,
        nowMilliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) -> EmojiUserSettings {
        var reader = ProtoReader(data: data)
        var favorites: [String] = []
        var favoriteSet: Set<String> = []
        var frequentEntries: [FrequentEmojiEntry] = []
        var scores: [String: Int] = [:]
        var guildAndChannelScores: [String: Int] = [:]
        while let tag = reader.readTag() {
            guard tag.wireType == 2, let payload = reader.readLengthDelimited() else {
                if !reader.skip(wireType: tag.wireType) {
                    break
                }
                continue
            }
            if tag.field == 5 {
                for key in strings(fromRepeatedStringField: 1, data: payload)
                    where favoriteSet.insert(key).inserted {
                    favorites.append(key)
                }
            } else if tag.field == 6 {
                for entry in stringFrecencyEntries(
                    from: payload,
                    nowMilliseconds: nowMilliseconds
                ) {
                    scores[entry.key] = max(scores[entry.key, default: 0], entry.score)
                    frequentEntries.append(FrequentEmojiEntry(
                        key: entry.key,
                        frecency: entry.frecency,
                        order: frequentEntries.count
                    ))
                }
            } else if tag.field == 12 {
                for (key, score) in guildAndChannelFrecencyScores(
                    from: payload,
                    nowMilliseconds: nowMilliseconds
                ) {
                    guildAndChannelScores[key] = max(guildAndChannelScores[key, default: 0], score)
                }
            }
        }
        var seenFrequent: Set<String> = []
        let frequentlyUsed =
            frequentEntries
                .sorted { left, right in
                    left.frecency == right.frecency
                        ? left.order < right.order
                        : left.frecency > right.frecency
                }
                .compactMap { entry in
                    seenFrequent.insert(entry.key).inserted ? entry.key : nil
                }
                .prefix(18)
        return EmojiUserSettings(
            favoriteKeys: favorites,
            frequentlyUsedKeys: Array(frequentlyUsed),
            usageScores: scores,
            guildAndChannelUsageScores: guildAndChannelScores
        )
    }

    private static func guildAndChannelFrecencyScores(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> [String: Int] {
        var reader = ProtoReader(data: data)
        var result: [String: Int] = [:]
        while let tag = reader.readTag() {
            guard tag.field == 1, tag.wireType == 2,
                  let mapEntry = reader.readLengthDelimited()
            else {
                if !reader.skip(wireType: tag.wireType) { break }
                continue
            }
            var entryReader = ProtoReader(data: mapEntry)
            var key: UInt64?
            var item: Data?
            while let entryTag = entryReader.readTag() {
                if entryTag.field == 1, entryTag.wireType == 1 {
                    key = entryReader.readFixed64()
                } else if entryTag.field == 2, entryTag.wireType == 2 {
                    item = entryReader.readLengthDelimited()
                } else if !entryReader.skip(wireType: entryTag.wireType) {
                    break
                }
            }
            if let key, let item,
               let score = computedGuildAndChannelFrecency(
                   from: item,
                   nowMilliseconds: nowMilliseconds
               )
            {
                result[String(key)] = score
            }
        }
        return result
    }

    private static var guildAndChannelFrecencyComputation:
        (Data, UInt64) -> Int?
    {
        { data, nowMilliseconds in
        var reader = ProtoReader(data: data)
        var totalUses = 0
        var recentUses: [UInt64] = []
        var storedFrecency = 0
        var storedScore = 0
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 0, let value = reader.readVarint() {
                totalUses = Int(clamping: value)
            } else if tag.field == 2, tag.wireType == 0, let value = reader.readVarint() {
                if value > 0 { recentUses.append(value) }
            } else if tag.field == 2, tag.wireType == 2,
                      let packedUses = reader.readLengthDelimited()
            {
                var packedReader = ProtoReader(data: packedUses)
                while let value = packedReader.readVarint() {
                    if value > 0 { recentUses.append(value) }
                }
            } else if tag.field == 3, tag.wireType == 0, let value = reader.readVarint() {
                storedFrecency = Int(clamping: value)
            } else if tag.field == 4, tag.wireType == 0, let value = reader.readVarint() {
                storedScore = Int(clamping: value)
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        let sampledUses = recentUses.prefix(10)
        guard !sampledUses.isEmpty else {
            // Discord persists the computed fields as well as recent samples.
            // Older positive entries can legitimately have no retained sample,
            // but the current autocomplete still treats their stored frecency
            // as positive. The channel scorer only needs that same sign.
            let stored = max(totalUses, max(storedFrecency, storedScore))
            return stored > 0 ? stored : nil
        }
        let millisecondsPerDay: UInt64 = 86_400_000
        let recencyScore = sampledUses.reduce(into: 0) { result, timestamp in
            let ageDays =
                timestamp >= nowMilliseconds
                    ? 0
                    : Int((nowMilliseconds - timestamp) / millisecondsPerDay)
            let weight =
                switch ageDays {
                case 0: 100
                case 1: 70
                case 2 ... 3: 50
                case 4 ... 6: 30
                default: 10
                }
            result += weight
        }
        guard recencyScore > 0 else { return nil }
        let computed = ceil(
            Double(totalUses) * Double(recencyScore) / Double(sampledUses.count)
        )
        let recomputed = computed >= Double(Int.max) ? Int.max : Int(computed)
        return max(recomputed, max(storedFrecency, storedScore))
        }
    }

    private static func computedGuildAndChannelFrecency(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> Int? {
        guildAndChannelFrecencyComputation(data, nowMilliseconds)
    }

    private static func strings(fromRepeatedStringField field: Int, data: Data) -> [String] {
        var reader = ProtoReader(data: data)
        var values: [String] = []
        while let tag = reader.readTag() {
            if tag.field == field, tag.wireType == 2,
               let value = reader.readLengthDelimited().flatMap({
                   String(data: $0, encoding: .utf8)
               })
            {
                values.append(value)
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        return values
    }

    private struct FrecencyEntry {
        var key: String
        var score: Int
        var frecency: Int
    }

    private static func stringFrecencyEntries(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> [FrecencyEntry] {
        var reader = ProtoReader(data: data)
        var result: [FrecencyEntry] = []
        while let tag = reader.readTag() {
            guard tag.field == 1, tag.wireType == 2, let entry = reader.readLengthDelimited() else {
                if !reader.skip(wireType: tag.wireType) {
                    break
                }
                continue
            }
            var entryReader = ProtoReader(data: entry)
            var key: String?
            var frecency: (score: Int, frecency: Int)?
            while let entryTag = entryReader.readTag() {
                if entryTag.field == 1, entryTag.wireType == 2 {
                    key = entryReader.readLengthDelimited().flatMap {
                        String(data: $0, encoding: .utf8)
                    }
                } else if entryTag.field == 2, entryTag.wireType == 2,
                          let item = entryReader.readLengthDelimited()
                {
                    frecency = computedFrecency(
                        from: item,
                        nowMilliseconds: nowMilliseconds
                    )
                } else if !entryReader.skip(wireType: entryTag.wireType) {
                    break
                }
            }
            if let key, let frecency {
                result.append(
                    FrecencyEntry(
                        key: key,
                        score: frecency.score,
                        frecency: frecency.frecency
                    ))
            }
        }
        return result
    }

    private static var frecencyComputation:
        (Data, UInt64) -> (score: Int, frecency: Int)?
    {
        { data, nowMilliseconds in
        var reader = ProtoReader(data: data)
        var totalUses = 0
        var recentUses: [UInt64] = []
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 0, let value = reader.readVarint() {
                totalUses = Int(clamping: value)
            } else if tag.field == 2, tag.wireType == 0, let value = reader.readVarint() {
                if value > 0 { recentUses.append(value) }
            } else if tag.field == 2, tag.wireType == 2,
                      let packedUses = reader.readLengthDelimited()
            {
                var packedReader = ProtoReader(data: packedUses)
                while let value = packedReader.readVarint() {
                    if value > 0 { recentUses.append(value) }
                }
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        let sampledUses = recentUses.prefix(10)
        guard !sampledUses.isEmpty else { return nil }
        let millisecondsPerDay: UInt64 = 86_400_000
        let score = sampledUses.reduce(into: 0) { result, timestamp in
            let ageDays =
                timestamp >= nowMilliseconds
                    ? 0
                    : Int((nowMilliseconds - timestamp) / millisecondsPerDay)
            let weight =
                switch ageDays {
                case ...3: 100
                case ...15: 70
                case ...30: 50
                case ...45: 30
                case ...80: 10
                default: 1
                }
            result += weight
        }
        guard score > 0 else { return nil }
        let computedFrecency = ceil(
            Double(totalUses) * Double(score) / Double(sampledUses.count)
        )
        let frecency =
            computedFrecency >= Double(Int.max)
                ? Int.max
                : Int(computedFrecency)
        return (score, frecency)
        }
    }

    private static func computedFrecency(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> (score: Int, frecency: Int)? {
        frecencyComputation(data, nowMilliseconds)
    }

    private static func layout(fromGuildFolders data: Data) -> DiscordGuildLayout {
        var reader = ProtoReader(data: data)
        var folders: [DiscordGuildLayout.Folder] = []
        var legacyOrder: [GuildID] = []
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 2, let folderData = reader.readLengthDelimited() {
                folders.append(folder(from: folderData))
            } else if tag.field == 2 {
                legacyOrder.append(
                    contentsOf: readFixed64Values(wireType: tag.wireType, reader: &reader))
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        return DiscordGuildLayout(folders: folders, guildPositions: legacyOrder)
    }

    private static func folder(from data: Data) -> DiscordGuildLayout.Folder {
        var reader = ProtoReader(data: data)
        var guildIDs: [GuildID] = []
        var id: Int64?
        var name: String?
        var colorHex: UInt32?
        while let tag = reader.readTag() {
            if tag.field == 1 {
                guildIDs.append(
                    contentsOf: readFixed64Values(wireType: tag.wireType, reader: &reader))
            } else if tag.wireType == 2, let wrapper = reader.readLengthDelimited() {
                switch tag.field {
                case 2:
                    id = wrappedVarint(from: wrapper).map { Int64(bitPattern: $0) }
                case 3:
                    name = wrappedString(from: wrapper)?.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if name?.isEmpty == true { name = nil }
                case 4:
                    colorHex = wrappedVarint(from: wrapper).flatMap { UInt32(exactly: $0) }
                default:
                    break
                }
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        return DiscordGuildLayout.Folder(
            guildIDs: guildIDs,
            id: id,
            name: name,
            colorHex: colorHex
        )
    }

    private static func wrappedVarint(from data: Data) -> UInt64? {
        var reader = ProtoReader(data: data)
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 0 {
                return reader.readVarint()
            }
            guard reader.skip(wireType: tag.wireType) else { return nil }
        }
        return nil
    }

    private static func wrappedString(from data: Data) -> String? {
        var reader = ProtoReader(data: data)
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 2 {
                return reader.readLengthDelimited().flatMap { String(data: $0, encoding: .utf8) }
            }
            guard reader.skip(wireType: tag.wireType) else { return nil }
        }
        return nil
    }

    private static func readFixed64Values(wireType: Int, reader: inout ProtoReader) -> [GuildID] {
        if wireType == 1, let value = reader.readFixed64() {
            return [GuildID(rawValue: value)]
        }
        if wireType == 2, let packed = reader.readLengthDelimited() {
            var packedReader = ProtoReader(data: packed)
            var values: [GuildID] = []
            while let value = packedReader.readFixed64() {
                values.append(GuildID(rawValue: value))
            }
            return values
        }
        _ = reader.skip(wireType: wireType)
        return []
    }
}

struct ProtoReader {
    var data: Data
    var index = 0

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard let value = readVarint() else { return nil }
        return (Int(value >> 3), Int(value & 0x07))
    }

    mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count, shift < 64 {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }
        return nil
    }

    mutating func readFixed64() -> UInt64? {
        guard index + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for offset in 0 ..< 8 {
            value |= UInt64(data[index + offset]) << UInt64(offset * 8)
        }
        index += 8
        return value
    }

    mutating func readLengthDelimited() -> Data? {
        guard let rawLength = readVarint(), rawLength <= UInt64(Int.max) else { return nil }
        let length = Int(rawLength)
        guard index + length <= data.count else { return nil }
        defer { index += length }
        return Data(data[index ..< (index + length)])
    }

    mutating func skip(wireType: Int) -> Bool {
        switch wireType {
        case 0: return readVarint() != nil
        case 1:
            guard index + 8 <= data.count else { return false }
            index += 8
            return true
        case 2: return readLengthDelimited() != nil
        case 5:
            guard index + 4 <= data.count else { return false }
            index += 4
            return true
        default: return false
        }
    }
}

struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skippedCount = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                try elements.append(container.decode(Element.self))
            } catch {
                skippedCount += 1
                _ = try? container.decode(JSONValue.self)
            }
        }
    }
}

extension LossyList: Sendable where Element: Sendable {}

struct LossyValue<Element: Decodable>: Decodable {
    var value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

struct UserNameplateAssetsDTO: Decodable {
    var staticImageURL: String?
    var animatedImageURL: String?
    var videoURL: String?

    enum CodingKeys: String, CodingKey {
        case staticImageURL = "static_image_url"
        case animatedImageURL = "animated_image_url"
        case videoURL = "video_url"
    }
}

struct UserNameplateDTO: Decodable {
    var skuID: String?
    var asset: String?
    var label: String?
    var palette: String?
    var assets: UserNameplateAssetsDTO?

    enum CodingKeys: String, CodingKey {
        case skuID = "sku_id"
        case asset, label, palette, assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skuID = try? container.decode(String.self, forKey: .skuID)
        if skuID == nil, let numericSKU = try? container.decode(UInt64.self, forKey: .skuID) {
            skuID = numericSKU.description
        }
        asset = try container.decodeIfPresent(String.self, forKey: .asset)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        palette = try container.decodeIfPresent(String.self, forKey: .palette)
        assets = try container.decodeIfPresent(UserNameplateAssetsDTO.self, forKey: .assets)
    }
}

struct UserCollectiblesDTO: Decodable {
    var nameplate: UserNameplateDTO?
}

struct UserDTO: Decodable {
    struct AvatarDecorationDTO: Decodable { var asset: String? }

    struct PrimaryGuildDTO: Decodable {
        var identityGuildID: String?
        var identityEnabled: Bool?
        var tag: String?
        var badge: String?
        enum CodingKeys: String, CodingKey {
            case identityGuildID = "identity_guild_id"
            case identityEnabled = "identity_enabled"
            case tag, badge
        }
    }

    struct DisplayNameStyleDTO: Decodable {
        var fontID: Int?
        var effectID: Int?
        var colors: [UInt32]?
        enum CodingKeys: String, CodingKey {
            case fontID = "font_id"
            case effectID = "effect_id"
            case colors
        }
    }

    var id: String
    var username: String?
    var globalName: String?
    var avatar: String?
    var bot: Bool?
    var system: Bool?
    var banner: String?
    var accentColor: UInt32?
    var bio: String?
    var publicFlags: UInt64?
    var premiumType: Int?
    var avatarDecorationData: AvatarDecorationDTO?
    var collectibles: UserCollectiblesDTO?
    var primaryGuild: PrimaryGuildDTO?
    var displayNameStyles: DisplayNameStyleDTO?
    enum CodingKeys: String, CodingKey {
        case id, username
        case globalName = "global_name"
        case avatar, bot, system, banner
        case accentColor = "accent_color"
        case bio
        case publicFlags = "public_flags"
        case premiumType = "premium_type"
        case avatarDecorationData = "avatar_decoration_data"
        case collectibles
        case primaryGuild = "primary_guild"
        case displayNameStyles = "display_name_styles"
    }

    func domain() throws -> User {
        guard let id = UserID(id) else {
            throw ChatProviderError.invalidRequest("Discord returned an invalid user identifier.")
        }
        let avatarURL = avatar.flatMap { hash in
            URL(
                string:
                "https://cdn.discordapp.com/avatars/\(id)/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
            )
        }
        let decorationURL = avatarDecorationData?.asset.flatMap {
            URL(string: "https://cdn.discordapp.com/avatar-decoration-presets/\($0).png?size=160")
        }
        let nameplate = collectibles?.nameplate.flatMap { value -> Nameplate? in
            let legacyPath = value.asset?.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            let officialBase = value.skuID.map {
                "https://cdn.discordapp.com/media/v1/collectibles-shop/\($0)"
            }
            let staticURL = officialBase.flatMap { URL(string: "\($0)/static") }
                ?? value.assets?.staticImageURL.flatMap(URL.init)
                ?? legacyPath.flatMap {
                    URL(string: "https://cdn.discordapp.com/assets/collectibles/\($0)/static.png")
                }
            let animatedURL = officialBase.flatMap { URL(string: "\($0)/animated") }
                ?? value.assets?.animatedImageURL.flatMap(URL.init)
                ?? legacyPath.flatMap {
                    URL(string: "https://cdn.discordapp.com/assets/collectibles/\($0)/img.png")
                }
            guard staticURL != nil || animatedURL != nil else { return nil }
            return Nameplate(
                staticURL: staticURL,
                animatedURL: animatedURL,
                label: value.label ?? "",
                palette: value.palette ?? "none"
            )
        }
        let guildIdentity: PrimaryGuildIdentity? = primaryGuild.flatMap { value in
            guard value.identityEnabled != false else { return nil }
            let guildID = value.identityGuildID.flatMap(GuildID.init)
            let badgeURL = guildID.flatMap { guildID in
                value.badge.flatMap {
                    URL(
                        string:
                        "https://cdn.discordapp.com/guild-tag-badges/\(guildID)/\($0).png?size=32"
                    )
                }
            }
            return PrimaryGuildIdentity(guildID: guildID, tag: value.tag, badgeURL: badgeURL)
        }
        let nameStyle = displayNameStyles.map {
            DisplayNameStyle(
                fontID: $0.fontID ?? 11, effectID: $0.effectID ?? 1, colors: $0.colors ?? [])
        }
        return User(
            id: id,
            username: username ?? id.description,
            displayName: globalName ?? username ?? id.description,
            avatarURL: avatarURL,
            isBot: bot ?? false,
            isSystem: system ?? false,
            avatarDecorationURL: decorationURL,
            nameplate: nameplate,
            primaryGuild: guildIdentity,
            displayNameStyle: nameStyle,
            publicFlags: publicFlags ?? 0,
            premiumType: premiumType ?? 0
        )
    }
}

struct ProfileMetadataDTO: Decodable {
    struct EffectDTO: Decodable {
        var id: String?
        var skuID: String?
        var resolvedID: String? {
            id ?? skuID
        }

        enum CodingKeys: String, CodingKey {
            case id
            case skuID = "sku_id"
        }
    }

    var bio: String?
    var pronouns: String?
    var banner: String?
    var accentColor: UInt32?
    var themeColors: [UInt32]?
    var profileEffect: EffectDTO?
    enum CodingKeys: String, CodingKey {
        case bio, pronouns, banner
        case accentColor = "accent_color"
        case themeColors = "theme_colors"
        case profileEffect = "profile_effect"
    }
}

struct ProfileBadgeDTO: Decodable {
    var id: String
    var description: String?
    var icon: String?
    var link: String?

    var domain: ProfileBadge {
        ProfileBadge(
            id: id,
            description: description ?? id,
            iconURL: icon.flatMap {
                URL(string: "https://cdn.discordapp.com/badge-icons/\($0).png")
            },
            linkURL: link.flatMap(URL.init)
        )
    }
}

struct MutualGuildDTO: Decodable {
    var id: String
    var nick: String?
}

struct ConnectedAccountDTO: Decodable {
    var id: String?
    var type: String
    var name: String?
    var verified: Bool?

    var domain: ConnectedAccount {
        let accountID = id ?? name ?? type
        let displayName = name ?? type.localizedCapitalized
        return ConnectedAccount(
            accountID: accountID,
            type: type,
            name: displayName,
            isVerified: verified ?? false,
            profileURL: Self.profileURL(type: type, accountID: accountID, name: displayName)
        )
    }

    private static var profileURLResolution: (String, String, String) -> URL? {
        { type, accountID, name in
        let encodedID =
            accountID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? accountID
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let value: String? =
            switch type.lowercased() {
            case "domain": name.contains("://") ? name : "https://\(name)"
            case "github": "https://github.com/\(encodedName)"
            case "instagram": "https://www.instagram.com/\(encodedName)"
            case "reddit": "https://www.reddit.com/user/\(encodedName)"
            case "roblox": "https://www.roblox.com/users/\(encodedID)/profile"
            case "spotify": "https://open.spotify.com/user/\(encodedID)"
            case "steam": "https://steamcommunity.com/profiles/\(encodedID)"
            case "tiktok": "https://www.tiktok.com/@\(encodedName)"
            case "twitch": "https://www.twitch.tv/\(encodedName)"
            case "twitter", "x": "https://x.com/\(encodedName)"
            case "youtube": "https://www.youtube.com/channel/\(encodedID)"
            case "facebook": "https://www.facebook.com/\(encodedID)"
            case "bluesky": "https://bsky.app/profile/\(encodedName)"
            case "mastodon": name.hasPrefix("@") ? nil : "https://mastodon.social/@\(encodedName)"
            case "soundcloud": "https://soundcloud.com/\(encodedName)"
            default: serviceHomeURL(type: type)
            }
        return value.flatMap(URL.init)
        }
    }

    private static func profileURL(type: String, accountID: String, name: String) -> URL? {
        profileURLResolution(type, accountID, name)
    }

    private static func serviceHomeURL(type: String) -> String? {
        switch type.lowercased() {
        case "amazon-music": "https://music.amazon.com"
        case "battlenet": "https://battle.net"
        case "bungie": "https://www.bungie.net"
        case "crunchyroll": "https://www.crunchyroll.com"
        case "ebay": "https://www.ebay.com"
        case "epicgames": "https://www.epicgames.com"
        case "leagueoflegends": "https://www.leagueoflegends.com"
        case "paypal": "https://www.paypal.com"
        case "playstation", "playstation-stg": "https://www.playstation.com"
        case "riotgames": "https://www.riotgames.com"
        case "xbox": "https://www.xbox.com"
        default: nil
        }
    }
}

struct ProfileGuildMemberDTO: Decodable {
    var nick: String?
    var roles: [String]?
    var avatar: String?
    var banner: String?
    var bio: String?
}

struct ProfileEffectConfigDTO: Decodable, Sendable {
    struct AnimationDTO: Decodable, Sendable {
        struct SourceDTO: Decodable, Sendable { var src: String? }

        var src: String?
        var loop: Bool?
        var height: Int?
        var width: Int?
        var duration: Int?
        var start: Int?
        var loopDelay: Int?
        var position: ProfileEffectPositionDTO?
        var zIndex: Int?
        var randomizedSources: LossyList<SourceDTO>?

        var domain: ProfileEffectAnimation? {
            let source = randomizedSources?.elements.compactMap(\.src).first ?? src
            guard let source, let sourceURL = URL(string: source) else { return nil }
            return ProfileEffectAnimation(
                sourceURL: sourceURL,
                isLooping: loop ?? true,
                width: width,
                height: height,
                durationMilliseconds: duration ?? 0,
                startMilliseconds: start ?? 0,
                loopDelayMilliseconds: loopDelay ?? 0,
                positionX: position?.horizontal ?? 0,
                positionY: position?.vertical ?? 0,
                zIndex: zIndex ?? 0
            )
        }
    }

    var type: Int?
    var id: String?
    var skuID: String?
    var title: String?
    var accessibilityLabel: String?
    var reducedMotionSrc: String?
    var staticFrameSrc: String?
    var effects: LossyList<AnimationDTO>?
    enum CodingKeys: String, CodingKey {
        case type, id
        case skuID = "sku_id"
        case title, accessibilityLabel, reducedMotionSrc, staticFrameSrc, effects
    }

    var domain: ProfileEffect {
        ProfileEffect(
            id: id ?? skuID ?? "unknown-effect",
            title: title,
            accessibilityLabel: accessibilityLabel,
            staticURL: staticFrameSrc.flatMap(URL.init),
            reducedMotionURL: reducedMotionSrc.flatMap(URL.init),
            animations: (effects?.elements ?? []).compactMap(\.domain).sorted {
                $0.zIndex < $1.zIndex
            }
        )
    }
}

struct ProfileEffectPositionDTO: Decodable, Sendable {
    var horizontal: Int?
    var vertical: Int?

    private enum CodingKeys: String, CodingKey {
        case horizontal = "x"
        case vertical = "y"
    }
}

struct CollectibleProductDTO: Decodable, Sendable {
    var items: LossyList<ProfileEffectConfigDTO>?
}

struct UserProfileDTO: Decodable {
    var user: UserDTO
    var userProfile: ProfileMetadataDTO?
    var guildMember: ProfileGuildMemberDTO?
    var guildMemberProfile: ProfileMetadataDTO?
    var badges: LossyList<ProfileBadgeDTO>?
    var guildBadges: LossyList<ProfileBadgeDTO>?
    var mutualGuilds: LossyList<MutualGuildDTO>?
    var mutualFriends: LossyList<UserDTO>?
    var mutualFriendsCount: Int?
    var connectedAccounts: LossyList<ConnectedAccountDTO>?
    var premiumSince: String?
    var premiumGuildSince: String?
    var legacyUsername: String?
    enum CodingKeys: String, CodingKey {
        case user
        case userProfile = "user_profile"
        case guildMember = "guild_member"
        case guildMemberProfile = "guild_member_profile"
        case badges
        case guildBadges = "guild_badges"
        case mutualGuilds = "mutual_guilds"
        case mutualFriends = "mutual_friends"
        case mutualFriendsCount = "mutual_friends_count"
        case connectedAccounts = "connected_accounts"
        case premiumSince = "premium_since"
        case premiumGuildSince = "premium_guild_since"
        case legacyUsername = "legacy_username"
    }

    func domain(
        guildID: GuildID?,
        guilds: [GuildID: Guild],
        guildRoles: [GuildRoleDTO],
        effectConfig: ProfileEffectConfigDTO?
    ) throws -> UserProfile {
        var domainUser = try user.domain()
        let displayName =
            guildMember?.nick.flatMap { $0.isEmpty ? nil : $0 } ?? domainUser.displayName
        let guildAvatarURL = guildID.flatMap { guildID in
            guildMember?.avatar.flatMap { hash in
                URL(
                    string:
                    "https://cdn.discordapp.com/guilds/\(guildID)/users/\(domainUser.id)/avatars/\(hash).webp?size=256&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                )
            }
        }
        let avatarURL = guildAvatarURL ?? domainUser.avatarURL
        domainUser.displayName = displayName
        domainUser.avatarURL = avatarURL

        let globalMetadata = userProfile
        let guildMetadata = guildMemberProfile
        let bannerHash =
            guildMetadata?.banner ?? guildMember?.banner ?? globalMetadata?.banner ?? user.banner
        let usesGuildBanner =
            guildID != nil && (guildMetadata?.banner != nil || guildMember?.banner != nil)
        let bannerURL: URL? = bannerHash.flatMap { hash in
            if usesGuildBanner, let guildID {
                return URL(
                    string:
                    "https://cdn.discordapp.com/guilds/\(guildID)/users/\(domainUser.id)/banners/\(hash).webp?size=600&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                )
            }
            return URL(
                string:
                "https://cdn.discordapp.com/banners/\(domainUser.id)/\(hash).webp?size=600&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
            )
        }

        let roleIDs = Set(guildMember?.roles ?? [])
        let roles =
            guildRoles
                .filter { roleIDs.contains($0.id) }
                .sorted { $0.position > $1.position }
                .compactMap(\.domain)
        let mutualServers = (mutualGuilds?.elements ?? []).compactMap { value -> MutualGuild? in
            guard let id = GuildID(value.id), let guild = guilds[id] else { return nil }
            return MutualGuild(
                id: id, name: guild.name, iconURL: guild.iconURL, nickname: value.nick)
        }
        let friends = (mutualFriends?.elements ?? []).compactMap { try? $0.domain() }
        let allBadges = (badges?.elements ?? []) + (guildBadges?.elements ?? [])
        var seenBadgeIDs = Set<String>()
        let uniqueBadges = allBadges.map(\.domain).filter { seenBadgeIDs.insert($0.id).inserted }
        let effectID =
            guildMetadata?.profileEffect?.resolvedID ?? globalMetadata?.profileEffect?.resolvedID
        let effect = effectConfig?.domain ?? effectID.map { ProfileEffect(id: $0) }

        return UserProfile(
            user: domainUser,
            displayName: displayName,
            avatarURL: avatarURL,
            bannerURL: bannerURL,
            accentHex: guildMetadata?.accentColor ?? globalMetadata?.accentColor
                ?? user.accentColor,
            themeHexes: guildMetadata?.themeColors ?? globalMetadata?.themeColors ?? [],
            bio: Self.firstNonEmpty(
                guildMetadata?.bio, guildMember?.bio, globalMetadata?.bio, user.bio),
            pronouns: Self.firstNonEmpty(guildMetadata?.pronouns, globalMetadata?.pronouns),
            effect: effect,
            badges: uniqueBadges,
            mutualGuilds: mutualServers,
            mutualFriends: friends,
            mutualFriendsCount: mutualFriendsCount ?? friends.count,
            roles: roles,
            connectedAccounts: (connectedAccounts?.elements ?? []).map(\.domain),
            premiumSince: premiumSince.flatMap(DiscordDate.parse),
            premiumGuildSince: premiumGuildSince.flatMap(DiscordDate.parse),
            legacyUsername: legacyUsername
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }.first
    }
}

struct ThreadMemberDTO: Decodable {
    struct MuteConfigDTO: Decodable {
        var endTime: String?

        enum CodingKeys: String, CodingKey {
            case endTime = "end_time"
        }
    }

    var id: String
    var userID: String?
    var flags: UInt64?
    var muted: Bool?
    var muteConfig: MuteConfigDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case flags, muted
        case muteConfig = "mute_config"
    }

    var domain: ThreadNotificationSettings {
        ThreadNotificationSettings(
            flags: flags ?? 0,
            isMuted: muted ?? false,
            muteConfiguration: muteConfig.map {
                DiscordMuteConfiguration(
                    endTime: $0.endTime.flatMap(DiscordDate.parse)
                )
            }
        )
    }
}

struct GuildDTO: Decodable {
    var id: String
    var name: String
    var icon: String?
    var owner: Bool?
    var permissions: String?
    var rulesChannelID: String?
    var defaultMessageNotifications: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, owner, permissions
        case rulesChannelID = "rules_channel_id"
        case defaultMessageNotifications = "default_message_notifications"
    }

    func domain() throws -> Guild {
        guard let id = GuildID(id) else {
            throw ChatProviderError.invalidRequest("Discord returned an invalid guild identifier.")
        }
        let iconURL = icon.flatMap { hash in
            URL(
                string:
                "https://cdn.discordapp.com/icons/\(id)/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
            )
        }
        return Guild(
            id: id,
            name: name,
            iconURL: iconURL,
            isOwnedByCurrentUser: owner,
            currentUserPermissions: permissions.flatMap(UInt64.init),
            rulesChannelID: rulesChannelID.flatMap(ChannelID.init),
            defaultMessageNotifications:
                defaultMessageNotifications.flatMap(MessageNotificationLevel.init(rawValue:))
                ?? .onlyMentions
        )
    }
}

struct ChannelDTO: Decodable {
    struct PermissionOverwriteDTO: Decodable {
        var id: String
        var type: Int
        var allow: String
        var deny: String

        var domain: ChannelPermissionOverwrite {
            ChannelPermissionOverwrite(
                id: id,
                type: type,
                allow: UInt64(allow) ?? 0,
                deny: UInt64(deny) ?? 0
            )
        }
    }

    struct ForumTagDTO: Decodable {
        var id: String
        var name: String
        var moderated: Bool?
        var emojiID: String?
        var emojiName: String?

        enum CodingKeys: String, CodingKey {
            case id, name, moderated
            case emojiID = "emoji_id"
            case emojiName = "emoji_name"
        }

        var domain: ForumTag? {
            guard let id = ForumTagID(id) else { return nil }
            return ForumTag(
                id: id, name: name, isModerated: moderated ?? false,
                emojiID: emojiID, emojiName: emojiName
            )
        }
    }

    struct DefaultReactionDTO: Decodable {
        var emojiID: String?
        var emojiName: String?

        enum CodingKeys: String, CodingKey {
            case emojiID = "emoji_id"
            case emojiName = "emoji_name"
        }
    }

    struct ThreadMetadataDTO: Decodable {
        var archived: Bool?
        var locked: Bool?
        var archiveTimestamp: String?
        var createTimestamp: String?
        var autoArchiveDuration: Int?

        enum CodingKeys: String, CodingKey {
            case archived, locked
            case archiveTimestamp = "archive_timestamp"
            case createTimestamp = "create_timestamp"
            case autoArchiveDuration = "auto_archive_duration"
        }
    }

    var id: String
    var guildID: String?
    var name: String?
    var icon: String?
    var topic: String?
    var type: Int
    var parentID: String?
    var position: Int?
    var recipients: [UserDTO]?
    var recipientIDs: [String]?
    var permissionOverwrites: [PermissionOverwriteDTO]?
    var memberListID: String?
    var lastMessageID: String?
    var lastPinTimestamp: String?
    var ownerID: String?
    var owner: LossyValue<UserDTO>?
    var messageCount: Int?
    var memberCount: Int?
    var totalMessageSent: Int?
    var threadMetadata: ThreadMetadataDTO?
    var appliedTags: [String]?
    var flags: UInt64?
    var member: ThreadMemberDTO?
    var availableTags: [ForumTagDTO]?
    var defaultReactionEmoji: DefaultReactionDTO?
    var defaultSortOrder: Int?
    var defaultForumLayout: Int?
    var defaultTagSetting: String?
    var defaultAutoArchiveDuration: Int?
    var defaultThreadRateLimitPerUser: Int?
    var rateLimitPerUser: Int?
    var status: String?
    var voiceStartTime: DiscordTimestampDTO?
    var message: MessageDTO?
    enum CodingKeys: String, CodingKey {
        case id
        case guildID = "guild_id"
        case name, icon, topic, type
        case parentID = "parent_id"
        case position, recipients
        case recipientIDs = "recipient_ids"
        case permissionOverwrites = "permission_overwrites"
        case memberListID = "member_list_id"
        case lastMessageID = "last_message_id"
        case lastPinTimestamp = "last_pin_timestamp"
        case ownerID = "owner_id"
        case owner, flags, member, message
        case messageCount = "message_count"
        case memberCount = "member_count"
        case totalMessageSent = "total_message_sent"
        case threadMetadata = "thread_metadata"
        case appliedTags = "applied_tags"
        case availableTags = "available_tags"
        case defaultReactionEmoji = "default_reaction_emoji"
        case defaultSortOrder = "default_sort_order"
        case defaultForumLayout = "default_forum_layout"
        case defaultTagSetting = "default_tag_setting"
        case defaultAutoArchiveDuration = "default_auto_archive_duration"
        case defaultThreadRateLimitPerUser = "default_thread_rate_limit_per_user"
        case rateLimitPerUser = "rate_limit_per_user"
        case status
        case voiceStartTime = "voice_start_time"
    }

    func domain(
        guildID fallbackGuildID: GuildID?,
        categoryName: String? = nil,
        categoryPosition: Int = 0,
        knownUsersByID: [String: UserDTO] = [:]
    ) throws -> Channel {
        guard let id = ChannelID(id) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid channel identifier.")
        }
        let guild = guildID.flatMap(GuildID.init) ?? fallbackGuildID
        let recipientDTOs =
            recipients
            ?? recipientIDs?.compactMap { knownUsersByID[$0] }
            ?? []
        let users = try recipientDTOs.map { try $0.domain() }
        let kind: ChannelKindValue =
            switch type {
            case 1: .directMessage
            case 3: .groupDirectMessage
            case 2, 13: .voice
            case 5: .announcement
            case 15: .forum
            default: .text
            }
        let resolvedName = name ?? users.map(\.displayName).joined(separator: ", ")
        let iconURL = icon.flatMap { hash in
            URL(
                string:
                    "https://cdn.discordapp.com/channel-icons/\(id)/\(hash).webp?size=128"
            )
        }
        return Channel(
            id: id,
            guildID: guild,
            name: resolvedName.isEmpty ? "Direct Message" : resolvedName,
            iconURL: iconURL,
            ownerID: ownerID.flatMap(UserID.init),
            topic: topic,
            kind: kind,
            category: categoryName,
            categoryID: parentID.flatMap(ChannelID.init),
            position: position ?? 0,
            categoryPosition: categoryPosition,
            recipients: users,
            permissionOverwrites: permissionOverwrites?.map(\.domain),
            memberListID: memberListID,
            lastMessageID: lastMessageID.flatMap(MessageID.init),
            lastPinTimestamp: lastPinTimestamp.flatMap(DiscordDate.parse),
            flags: flags ?? 0,
            availableTags: availableTags?.compactMap(\.domain) ?? [],
            defaultReaction: defaultReactionEmoji.map {
                ForumDefaultReaction(emojiID: $0.emojiID, emojiName: $0.emojiName)
            },
            defaultSortOrder: defaultSortOrder.flatMap(ForumSortOrder.init(rawValue:)),
            defaultForumLayout: defaultForumLayout.flatMap(ForumLayout.init(rawValue:))
                ?? .defaultLayout,
            defaultTagMatch: defaultTagSetting.flatMap(ForumTagMatch.init(rawValue:)) ?? .matchSome,
            defaultAutoArchiveDuration: defaultAutoArchiveDuration,
            defaultThreadRateLimitPerUser: defaultThreadRateLimitPerUser,
            rateLimitPerUser: rateLimitPerUser ?? 0,
            voiceStatus: status,
            voiceStartTime: voiceStartTime?.date
        )
    }

    func forumPost(fallbackGuildID: GuildID?) throws -> ForumPost {
        guard let id = ChannelID(id) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid forum post identifier.")
        }
        let guild = guildID.flatMap(GuildID.init) ?? fallbackGuildID
        // Forum search records can contain a deliberately partial embedded owner
        // or starter message. The thread itself is still a valid search result;
        // the parallel first_messages payload and Gateway user cache hydrate what
        // Discord omitted without dropping the post.
        let ownerUser = owner?.value.flatMap { try? $0.domain() }
        let firstMessage = message.flatMap { try? $0.domain() }
        return ForumPost(
            thread: MessageThreadSummary(
                id: id,
                guildID: guild,
                parentID: parentID.flatMap(ChannelID.init),
                name: name ?? "Untitled post",
                messageCount: messageCount ?? totalMessageSent ?? (firstMessage == nil ? 0 : 1),
                memberCount: memberCount ?? 0,
                lastMessageID: lastMessageID.flatMap(MessageID.init),
                isArchived: threadMetadata?.archived ?? false,
                isLocked: threadMetadata?.locked ?? false,
                ownerID: ownerID.flatMap(UserID.init) ?? ownerUser?.id,
                appliedTagIDs: appliedTags?.compactMap(ForumTagID.init) ?? [],
                flags: flags ?? 0,
                archiveTimestamp: threadMetadata?.archiveTimestamp.flatMap(DiscordDate.parse),
                createdAt: threadMetadata?.createTimestamp.flatMap(DiscordDate.parse),
                autoArchiveDuration: threadMetadata?.autoArchiveDuration,
                totalMessageSent: totalMessageSent ?? messageCount ?? 0,
                notificationSettings: member?.domain
            ),
            owner: ownerUser ?? firstMessage?.author,
            firstMessage: firstMessage,
            mostRecentMessage: nil,
            isUnread: false
        )
    }
}

struct GuildActivityEmojiDTO: Decodable {
    var name: String?
    var id: String?
    var animated: Bool?
}

struct GuildActivityDTO: Decodable {
    var name: String?
    var type: Int?
    var state: String?
    var emoji: GuildActivityEmojiDTO?

    var displayText: String? {
        let emojiPrefix =
            emoji.flatMap { emoji -> String? in
                guard let name = emoji.name else { return nil }
                if let id = emoji.id {
                    return "<\(emoji.animated == true ? "a" : ""):\(name):\(id)> "
                }
                return "\(name) "
            } ?? ""
        if type == 4, let state, !state.isEmpty {
            return emojiPrefix + state
        }
        return state.flatMap { $0.isEmpty ? nil : $0 } ?? name
    }
}

struct GuildPresenceDTO: Decodable {
    var status: String?
    var activities: [GuildActivityDTO]?
}

struct GuildMemberDTO: Decodable {
    var user: UserDTO
    var nick: String?
    var roles: [String]?
    var presence: GuildPresenceDTO?
    var avatar: String?
    var banner: String?
    var bio: String?

    func domain(
        currentUserID: UserID?,
        currentStatus: PresenceStatus,
        presence overridePresence: GuildPresenceDTO? = nil,
        guildRoles: [GuildRoleDTO] = [],
        guildID: GuildID? = nil
    ) throws -> Member {
        var domainUser = try user.domain()
        let globalDisplayName = domainUser.displayName
        if let nick, !nick.isEmpty {
            domainUser.displayName = nick
        }
        let guildAvatarURL = guildAvatarURL(guildID: guildID, userID: domainUser.id)
        if let guildAvatarURL {
            domainUser.avatarURL = guildAvatarURL
        }
        let status =
            domainUser.id == currentUserID
                ? currentStatus
                : (overridePresence ?? presence)?.status.flatMap(PresenceStatus.init(rawValue:))
                ?? .offline
        let memberRoleIDs = Set(roles ?? [])
        let categoryRole =
            guildRoles
                .filter { $0.hoist && memberRoleIDs.contains($0.id) }
                .max { lhs, rhs in
                    if lhs.position != rhs.position {
                        return lhs.position < rhs.position
                    }
                    return lhs.id < rhs.id
                }
        let domainRoles =
            guildRoles
                .filter { memberRoleIDs.contains($0.id) }
                .sorted { $0.position > $1.position }
                .compactMap(\.domain)
        let activities = (overridePresence ?? presence)?.activities ?? []
        let customStatus = activities.first(where: { $0.type == 4 })?.displayText
        return Member(
            user: domainUser,
            roleName: categoryRole?.name ?? "Member",
            status: status,
            roleID: categoryRole.flatMap { RoleID($0.id) },
            rolePosition: categoryRole?.position,
            isRoleCategory: categoryRole != nil,
            roleIDs: (roles ?? []).compactMap(RoleID.init),
            roles: domainRoles,
            guildAvatarURL: guildAvatarURL,
            globalDisplayName: globalDisplayName,
            activityText: activities.first(where: { $0.type != 4 })?.displayText ?? customStatus,
            customStatus: customStatus
        )
    }

    private func guildAvatarURL(guildID: GuildID?, userID: UserID) -> URL? {
        guard let avatar, let guildID else { return nil }
        return URL(
            string:
            "https://cdn.discordapp.com/guilds/\(guildID)/users/\(userID)/avatars/\(avatar).webp?size=128&animated=\(avatar.hasPrefix("a_") ? "true" : "false")"
        )
    }
}

struct GuildRoleColorsDTO: Decodable {
    var primaryColor: UInt32?

    enum CodingKeys: String, CodingKey {
        case primaryColor = "primary_color"
    }
}

struct GuildRoleDTO: Decodable {
    var id: String
    var name: String
    var position: Int
    var hoist: Bool
    var color: UInt32?
    private var colors: GuildRoleColorsDTO?
    var icon: String?
    var unicodeEmoji: String?
    var mentionable: Bool?
    var permissions: String?
    enum CodingKeys: String, CodingKey {
        case id, name, position, hoist, color, colors, icon
        case unicodeEmoji = "unicode_emoji"
        case mentionable, permissions
    }

    var domain: GuildRole? {
        guard let id = RoleID(id) else { return nil }
        let colorHex = colors?.primaryColor.flatMap { $0 == 0 ? nil : $0 }
            ?? color.flatMap { $0 == 0 ? nil : $0 }
        let iconURL = icon.flatMap {
            URL(string: "https://cdn.discordapp.com/role-icons/\(id)/\($0).png?size=32")
        }
        return GuildRole(
            id: id,
            name: name,
            position: position,
            colorHex: colorHex,
            iconURL: iconURL,
            unicodeEmoji: unicodeEmoji,
            isMentionable: mentionable ?? false,
            permissions: permissions.flatMap(UInt64.init)
        )
    }
}

struct GatewayGuildMembersChunkDTO: Decodable {
    var guildID: String
    var members: [GuildMemberDTO]
    var chunkIndex: Int
    var chunkCount: Int
    var notFound: [String]?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case members
        case chunkIndex = "chunk_index"
        case chunkCount = "chunk_count"
        case notFound = "not_found"
    }
}

struct MessageMentionDTO: Decodable {
    private struct PartialMemberDTO: Decodable {
        var nick: String?
        var avatar: String?
    }

    private var user: UserDTO
    private var member: PartialMemberDTO?

    private enum CodingKeys: String, CodingKey { case member }

    init(from decoder: Decoder) throws {
        user = try UserDTO(from: decoder)
        member = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(PartialMemberDTO.self, forKey: .member)
    }

    func domain(guildID: GuildID?) throws -> User {
        var value = try user.domain()
        if let nickname = member?.nick?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nickname.isEmpty
        {
            value.displayName = nickname
        }
        if let guildID, let avatarHash = member?.avatar {
            value.avatarURL = URL(
                string:
                "https://cdn.discordapp.com/guilds/\(guildID)/users/\(value.id)/avatars/\(avatarHash).webp?size=128&animated=\(avatarHash.hasPrefix("a_") ? "true" : "false")"
            )
        }
        return value
    }
}

struct MessageDeleteDTO: Decodable {
    var id: String
    var channelID: String
    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
    }
}

struct GatewayMessageReactionUserDTO: Decodable {
    var userID: String
    var channelID: String
    var messageID: String
    var emoji: ReactionDTO.EmojiDTO
    var type: Int?
    var burst: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case channelID = "channel_id"
        case messageID = "message_id"
        case emoji, type, burst
    }

    func domainUpdate(isAddition: Bool) -> MessageReactionUpdate? {
        guard
            let channelID = ChannelID(channelID),
            let messageID = MessageID(messageID),
            let userID = UserID(userID),
            let kind = MessageReactionKind(rawValue: type ?? (burst == true ? 1 : 0))
        else { return nil }
        if isAddition {
            return .add(
                channelID: channelID,
                messageID: messageID,
                userID: userID,
                emoji: emoji.domainToken,
                kind: kind
            )
        }
        return .remove(
            channelID: channelID,
            messageID: messageID,
            userID: userID,
            emoji: emoji.domainToken,
            kind: kind
        )
    }
}

struct GatewayMessageReactionRemoveAllDTO: Decodable {
    var channelID: String
    var messageID: String

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case messageID = "message_id"
    }

    var domainUpdate: MessageReactionUpdate? {
        guard let channelID = ChannelID(channelID), let messageID = MessageID(messageID) else {
            return nil
        }
        return .removeAll(channelID: channelID, messageID: messageID)
    }
}

struct GatewayMessageReactionRemoveEmojiDTO: Decodable {
    var channelID: String
    var messageID: String
    var emoji: ReactionDTO.EmojiDTO

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case messageID = "message_id"
        case emoji
    }

    var domainUpdate: MessageReactionUpdate? {
        guard let channelID = ChannelID(channelID), let messageID = MessageID(messageID) else {
            return nil
        }
        return .removeEmoji(
            channelID: channelID,
            messageID: messageID,
            emoji: emoji.domainToken
        )
    }
}

struct TypingStartDTO: Decodable {
    var channelID: String
    var guildID: String?
    var userID: String
    var member: GuildMemberDTO?
    var user: UserDTO?

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case guildID = "guild_id"
        case userID = "user_id"
        case member, user
    }
}

struct MessageUpdateDTO: Decodable {
    var id: String
    var channelID: String
    var content: String?
    var editedTimestamp: String?
    var attachments: LossyList<AttachmentDTO>?
    var embeds: LossyList<MessageEmbedDTO>?
    var components: LossyList<MessageComponentDTO>?
    var stickerItems: LossyList<MessageStickerDTO>?
    var stickers: LossyList<MessageStickerDTO>?
    var thread: MessageThreadDTO?
    var mentions: LossyList<MessageMentionDTO>?
    var mentionRoles: [String]?
    var mentionEveryone: Bool?
    var flags: UInt64?
    var type: Int?
    var application: MessageDTO.ApplicationDTO?
    var interaction: MessageDTO.InteractionDTO?
    var interactionMetadata: MessageDTO.InteractionMetadataDTO?
    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case content
        case editedTimestamp = "edited_timestamp"
        case attachments
        case embeds, components, stickers, thread, flags, type, mentions, application, interaction
        case mentionRoles = "mention_roles"
        case mentionEveryone = "mention_everyone"
        case interactionMetadata = "interaction_metadata"
        case stickerItems = "sticker_items"
    }

    func apply(to message: inout Message) {
        if let content {
            message.content = content
        }
        if let editedTimestamp {
            message.editedTimestamp = DiscordDate.parse(editedTimestamp)
        }
        if let attachments {
            message.attachments = attachments.elements.compactMap { try? $0.domain() }
        }
        if let embeds {
            message.embeds = embeds.elements.enumerated().map {
                $0.element.domain(index: $0.offset)
            }
        }
        if let components {
            message.components = components.elements.enumerated().map {
                $0.element.domain(path: "\($0.offset)")
            }
        }
        if let stickers = stickerItems ?? stickers {
            message.stickers = stickers.elements.map(\.domain)
        }
        if let thread {
            message.thread = thread.domain
        }
        if let flags {
            message.flags = MessageFlags(rawValue: flags)
        }
        if let type {
            message.type = DiscordMessageType(rawValue: type)
        }
        if let application {
            message.application = application.domain
            message.applicationID = ApplicationID(application.id)
        }
        if interaction != nil || interactionMetadata != nil {
            message.interactionMetadata = MessageInteractionMetadata(
                id: interactionMetadata?.id ?? interaction?.id,
                type: interactionMetadata?.type ?? interaction?.type ?? 2,
                name: interactionMetadata?.name ?? interaction?.name,
                localizedName: interactionMetadata?.localizedName ?? interaction?.localizedName,
                user: (interactionMetadata?.user ?? interaction?.user).flatMap { try? $0.domain() },
                applicationID: interactionMetadata?.applicationID
                    ?? message.applicationID?.description,
                originalResponseMessageID: interactionMetadata?.originalResponseMessageID.flatMap(
                    MessageID.init
                )
            )
        }
        if let mentions {
            message.mentionedUsers = mentions.elements.compactMap {
                try? $0.domain(guildID: message.guildID)
            }
        }
        if let mentionRoles {
            message.mentionedRoleIDs = mentionRoles.compactMap(RoleID.init)
        }
        if let mentionEveryone {
            message.mentionsEveryone = mentionEveryone
        }
    }
}

struct GuildMemberListUpdateDTO: Decodable {
    struct Group: Decodable {
        var id: String
        var count: Int
    }

    struct Operation: Decodable {
        var op: String
        var range: [Int]?
        var index: Int?
        var items: [Item]?
        var item: Item?
    }

    struct Item: Decodable {
        var member: GuildMemberDTO?
        var presence: GuildPresenceDTO?
    }

    var guildID: String
    var id: String
    var memberCount: Int?
    var onlineCount: Int?
    var ops: [Operation]
    var groups: [Group]?
    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case id
        case memberCount = "member_count"
        case onlineCount = "online_count"
        case ops
        case groups
    }
}
