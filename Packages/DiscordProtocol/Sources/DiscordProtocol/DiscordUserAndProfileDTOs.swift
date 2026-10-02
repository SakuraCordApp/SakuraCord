import Foundation
import SakuraCordModels

struct ProfileCacheKey: Hashable {
    var userID: UserID
    var guildID: GuildID?
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
    var discriminator: String?
    var globalName: String?
    var avatar: String?
    var bot: Bool?
    var system: Bool?
    var banner: String?
    var accentColor: UInt32?
    var bio: String?
    var publicFlags: UInt64?
    var premiumType: Int?
    var nsfwAllowed: Bool?
    var avatarDecorationData: AvatarDecorationDTO?
    var collectibles: UserCollectiblesDTO?
    var primaryGuild: PrimaryGuildDTO?
    var displayNameStyles: DisplayNameStyleDTO?
    enum CodingKeys: String, CodingKey {
        case id, username, discriminator
        case globalName = "global_name"
        case avatar, bot, system, banner
        case accentColor = "accent_color"
        case bio
        case publicFlags = "public_flags"
        case premiumType = "premium_type"
        case nsfwAllowed = "nsfw_allowed"
        case avatarDecorationData = "avatar_decoration_data"
        case collectibles
        case primaryGuild = "primary_guild"
        case displayNameStyles = "display_name_styles"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Identity is the only required user-store field. Discord frequently
        // evolves optional profile cosmetics independently; a type change in
        // one of those fields must not make LossyList discard the entire user
        // from READY/READY_SUPPLEMENTAL and account-wide search.
        id = try container.decode(String.self, forKey: .id)
        username = try? container.decode(String.self, forKey: .username)
        discriminator = try? container.decode(String.self, forKey: .discriminator)
        globalName = try? container.decode(String.self, forKey: .globalName)
        avatar = try? container.decode(String.self, forKey: .avatar)
        bot = try? container.decode(Bool.self, forKey: .bot)
        system = try? container.decode(Bool.self, forKey: .system)
        banner = try? container.decode(String.self, forKey: .banner)
        accentColor = try? container.decode(UInt32.self, forKey: .accentColor)
        bio = try? container.decode(String.self, forKey: .bio)
        publicFlags = try? container.decode(UInt64.self, forKey: .publicFlags)
        premiumType = try? container.decode(Int.self, forKey: .premiumType)
        nsfwAllowed = try? container.decode(Bool.self, forKey: .nsfwAllowed)
        avatarDecorationData = try? container.decode(
            AvatarDecorationDTO.self,
            forKey: .avatarDecorationData
        )
        collectibles = try? container.decode(UserCollectiblesDTO.self, forKey: .collectibles)
        primaryGuild = try? container.decode(PrimaryGuildDTO.self, forKey: .primaryGuild)
        displayNameStyles = try? container.decode(
            DisplayNameStyleDTO.self,
            forKey: .displayNameStyles
        )
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
            discriminator: discriminator ?? "0",
            displayName: globalName ?? username ?? id.description,
            avatarURL: avatarURL,
            isBot: bot ?? false,
            isSystem: system ?? false,
            avatarDecorationURL: decorationURL,
            nameplate: nameplate,
            primaryGuild: guildIdentity,
            displayNameStyle: nameStyle,
            publicFlags: publicFlags ?? 0,
            premiumType: premiumType ?? 0,
            allowsAdultContent: nsfwAllowed
        )
    }
}

struct ProfileMetadataDTO: Decodable {
    struct CollectibleDTO: Decodable {
        var skuID: String
        var type: Int
        enum CodingKeys: String, CodingKey {
            case skuID = "sku_id"
            case type
        }
    }
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
    var themeColors: [UInt32?]?
    var renderedThemeColors: [UInt32]? {
        guard let themeColors else { return nil }
        guard themeColors.count == 2, themeColors.allSatisfy({ $0 != nil }) else { return [] }
        return themeColors.compactMap { $0 }
    }
    var profileEffect: EffectDTO?
    var collectibles: [CollectibleDTO]?
    enum CodingKeys: String, CodingKey {
        case bio, pronouns, banner, collectibles
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
    var avatarDecorationData: UserDTO.AvatarDecorationDTO?
    var collectibles: UserCollectiblesDTO?
    var displayNameStyles: UserDTO.DisplayNameStyleDTO?

    enum CodingKeys: String, CodingKey {
        case nick, roles, avatar, banner, bio, collectibles
        case avatarDecorationData = "avatar_decoration_data"
        case displayNameStyles = "display_name_styles"
    }
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
    var thumbnailPreviewSrc: String?
    var effects: LossyList<AnimationDTO>?
    enum CodingKeys: String, CodingKey {
        case type, id
        case skuID = "sku_id"
        case title, accessibilityLabel, reducedMotionSrc, staticFrameSrc, thumbnailPreviewSrc, effects
    }

    var domain: ProfileEffect {
        ProfileEffect(
            id: id ?? skuID ?? "unknown-effect",
            title: title,
            accessibilityLabel: accessibilityLabel,
            staticURL: staticFrameSrc.flatMap(URL.init),
            thumbnailURL: thumbnailPreviewSrc.flatMap(URL.init),
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

struct UserProfileDTO: Decodable {
    var user: UserDTO
    var isPrivate: Bool?
    var widgets: [ProfileWidgetDTO]?
    var premiumType: Int?
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
    var frameSKUID: String? {
        guildMemberProfile?.collectibles?.first(where: { $0.type == 3 })?.skuID
            ?? userProfile?.collectibles?.first(where: { $0.type == 3 })?.skuID
    }
    enum CodingKeys: String, CodingKey {
        case user, widgets
        case isPrivate = "private"
        case premiumType = "premium_type"
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
        effectConfig: ProfileEffectConfigDTO?,
        frame: ProfileFrame? = nil
    ) throws -> UserProfile {
        var domainUser = try user.domain()
        if let premiumType { domainUser.premiumType = premiumType }
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
        let defaultAvatarURL = DiscordProfileImageAssets.defaultAvatarURL(userID: user.id, discriminator: user.discriminator)
        let avatarURL = guildAvatarURL ?? domainUser.avatarURL ?? defaultAvatarURL
        domainUser.displayName = displayName
        domainUser.avatarURL = avatarURL
        if let guildMember {
            var scopedUser = user
            scopedUser.avatarDecorationData = guildMember.avatarDecorationData ?? user.avatarDecorationData
            scopedUser.collectibles = guildMember.collectibles?.nameplate != nil ? guildMember.collectibles : user.collectibles
            scopedUser.displayNameStyles = guildMember.displayNameStyles ?? user.displayNameStyles
            let cosmetics = try scopedUser.domain()
            domainUser.avatarDecorationURL = cosmetics.avatarDecorationURL
            domainUser.nameplate = cosmetics.nameplate
            domainUser.displayNameStyle = cosmetics.displayNameStyle
        }

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
            isPrivate: isPrivate,
            displayName: displayName,
            avatarURL: avatarURL,
            defaultAvatarURL: defaultAvatarURL,
            bannerURL: bannerURL,
            accentHex: guildMetadata?.accentColor ?? globalMetadata?.accentColor
                ?? user.accentColor,
            themeHexes: guildMetadata?.renderedThemeColors ?? globalMetadata?.renderedThemeColors ?? [],
            bio: Self.firstNonEmpty(
                guildMetadata?.bio, guildMember?.bio, globalMetadata?.bio, user.bio),
            pronouns: Self.firstNonEmpty(guildMetadata?.pronouns, globalMetadata?.pronouns),
            effect: effect,
            frame: frame,
            widgets: try widgets?.map { try $0.domain(userID: domainUser.id) },
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
