import Foundation
import SakuraCordModels

nonisolated struct DiscordForwardSearchPeopleCache: Codable, Sendable {
    struct Alias: Codable, Hashable, Sendable {
        let guildID: GuildID
        let userID: UserID
        let nickname: String
    }

    static let currentVersion = 5
    static let oldestSupportedVersion = 3
    static let maximumUsers = 10_000
    static let maximumAliases = 20_000

    var version = currentVersion
    var users: [User]
    var aliases: [Alias]

    private enum CodingKeys: String, CodingKey {
        case version, users, aliases
    }

    init(
        version: Int = currentVersion,
        users: [User],
        aliases: [Alias]
    ) {
        self.version = version
        self.users = users
        self.aliases = aliases
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        users = try container.decode([User].self, forKey: .users)
        aliases = try container.decode([Alias].self, forKey: .aliases)
    }

    static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              (oldestSupportedVersion ... currentVersion).contains(value.version)
        else { return nil }
        return value
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension DiscordRESTProvider {
    func loadForwardSearchPeopleCache() {
        cachedForwardSearchUsersByID = [:]
        cachedForwardSearchUserOrder = []
        cachedForwardSearchAliasesByGuildID = [:]
        cachedForwardSearchAliasGuildOrder = []
        loadedForwardSearchAliasGuildOrder = []
        guard let url = forwardSearchPeopleCacheURL(),
              let cache = DiscordForwardSearchPeopleCache.load(from: url)
        else { return }

        for user in cache.users.suffix(DiscordForwardSearchPeopleCache.maximumUsers) {
            guard cachedForwardSearchUsersByID[user.id] == nil else { continue }
            cachedForwardSearchUserOrder.append(user.id)
            cachedGatewayUserOrder.append(user.id.description)
            cachedForwardSearchUsersByID[user.id] = user
        }
        for alias in cache.aliases.suffix(DiscordForwardSearchPeopleCache.maximumAliases) {
            if cachedForwardSearchAliasesByGuildID[alias.guildID] == nil {
                cachedForwardSearchAliasGuildOrder.append(alias.guildID)
                loadedForwardSearchAliasGuildOrder.append(alias.guildID)
            }
            cachedForwardSearchAliasesByGuildID[alias.guildID, default: [:]][alias.userID] =
                alias.nickname
        }
    }

    @discardableResult
    func cacheForwardSearchMessageUsers(_ users: [UserDTO]) -> Bool {
        var changed = false
        for dto in users {
            guard let user = try? dto.domain() else { continue }
            if cachedForwardSearchUsersByID[user.id] == nil {
                cachedForwardSearchUserOrder.append(user.id)
                changed = true
            } else if cachedForwardSearchUsersByID[user.id] != user {
                changed = true
            }
            cachedForwardSearchUsersByID[user.id] = user
        }
        compactForwardSearchPeopleCacheIfNeeded()
        return changed
    }

    func cacheForwardSearchMessageAliases(_ messages: [Message]) {
        var changed = false
        var quickSwitcherMembershipChanged = false
        for message in messages {
            guard let guildID = message.guildID else { continue }
            if cachedForwardSearchAliasesByGuildID[guildID] == nil {
                cachedForwardSearchAliasGuildOrder.append(guildID)
            }
            let relevantUserIDs = Set(
                CollectionOfOne(message.author.id) + message.mentionedUsers.map(\.id)
            )
            for userID in relevantUserIDs {
                quickSwitcherMembershipChanged = quickSwitcherGuildMemberUserIDsByGuildID[
                    guildID,
                    default: []
                ].insert(userID).inserted || quickSwitcherMembershipChanged
            }
            let membersByID = Dictionary(
                uniqueKeysWithValues: (cachedMembers[guildID] ?? []).map { ($0.id, $0) }
            )
            for userID in relevantUserIDs {
                // Discord's GuildMemberStore indexes the current member
                // resolved for a history author/mention. It deliberately does
                // not index the historical `message.member` snapshot.
                let nickname = forwardSearchNickname(from: membersByID[userID])
                let normalized = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let normalized, !normalized.isEmpty {
                    if cachedForwardSearchAliasesByGuildID[guildID]?[userID] != normalized {
                        cachedForwardSearchAliasesByGuildID[guildID, default: [:]][userID] = normalized
                        changed = true
                    }
                }
            }
        }
        if changed {
            compactForwardSearchPeopleCacheIfNeeded()
        }
        if changed || quickSwitcherMembershipChanged {
            publishUserSearchAliases()
        }
        if changed {
            persistForwardSearchPeopleCache()
        }
    }

    func persistForwardSearchPeopleCache() {
        guard let url = forwardSearchPeopleCacheURL() else { return }
        var seenUserIDs = Set<UserID>()
        let orderedUserIDs = cachedGatewayUserOrder.compactMap(UserID.init).filter {
            seenUserIDs.insert($0).inserted
        } + cachedForwardSearchUserOrder.filter { seenUserIDs.insert($0).inserted }
        let users = orderedUserIDs.suffix(
            DiscordForwardSearchPeopleCache.maximumUsers
        ).compactMap { userID in
            cachedGatewayUsersByID[userID.description].flatMap { try? $0.domain() }
                ?? cachedForwardSearchUsersByID[userID]
        }
        let aliases = cachedForwardSearchAliasGuildOrder.flatMap { guildID in
            (cachedForwardSearchAliasesByGuildID[guildID] ?? [:]).map {
                DiscordForwardSearchPeopleCache.Alias(
                    guildID: guildID,
                    userID: $0.key,
                    nickname: $0.value
                )
            }
            .sorted { $0.userID.rawValue < $1.userID.rawValue }
        }
        try? DiscordForwardSearchPeopleCache(
            users: users,
            aliases: aliases
        ).save(to: url)
    }

    func forwardSearchNickname(from member: Member?) -> String? {
        guard let member else { return nil }
        let nickname = member.user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let globalName = (member.globalDisplayName ?? member.user.username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return nickname.localizedCaseInsensitiveCompare(globalName) == .orderedSame
            ? nil : nickname
    }

    func compactForwardSearchPeopleCacheIfNeeded() {
        let maximumUsers = DiscordForwardSearchPeopleCache.maximumUsers
        if cachedForwardSearchUserOrder.count > maximumUsers {
            let removed = cachedForwardSearchUserOrder.dropLast(maximumUsers)
            for userID in removed { cachedForwardSearchUsersByID[userID] = nil }
            cachedForwardSearchUserOrder = Array(cachedForwardSearchUserOrder.suffix(maximumUsers))
        }
        let maximumAliases = DiscordForwardSearchPeopleCache.maximumAliases
        var aliasCount = cachedForwardSearchAliasesByGuildID.values.reduce(0) {
            $0 + $1.count
        }
        guard aliasCount > maximumAliases else { return }
        for guildID in cachedForwardSearchAliasGuildOrder {
            for userID in (cachedForwardSearchAliasesByGuildID[guildID] ?? [:]).keys.sorted() {
                guard aliasCount > maximumAliases else { return }
                cachedForwardSearchAliasesByGuildID[guildID]?[userID] = nil
                aliasCount -= 1
            }
        }
    }

    func forwardSearchPeopleCacheURL() -> URL? {
        guard usesForwardSearchPeopleDiskCache, let accountID else { return nil }
        let safeAccountID = accountID.replacingOccurrences(
            of: #"[^A-Za-z0-9_.-]"#,
            with: "-",
            options: .regularExpression
        )
        let base = forwardPeopleCacheDirectoryOverride
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(
                    path: "dev.sakuracord.SakuraCord/ForwardSearchPeople",
                    directoryHint: .isDirectory
                )
        return base?.appending(path: "\(safeAccountID).json")
    }

    #if DEBUG
        func setForwardSearchPeopleCacheDirectoryForTesting(_ url: URL) {
            forwardPeopleCacheDirectoryOverride = url
        }
    #endif
}
