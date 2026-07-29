import Foundation
import OSLog
import SakuraCordModels

private let gatewayLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "Gateway")

nonisolated struct AttachmentUploadFile: Equatable, Sendable {
    let url: URL
    let name: String
    let description: String?

    init(url: URL, name: String, description: String? = nil) {
        self.url = url
        self.name = name
        self.description = description
    }
}

public actor DiscordRESTProvider: ChatProvider {
    private struct ForumReadState: Sendable {
        var lastReadMessageID: MessageID?
        var mentionCount: Int
    }
    private struct InitialGatewaySnapshot: Sendable {
        var readStates: [ChannelReadState]
        var notificationSettings: [GuildNotificationSettings]
        var usesNewNotifications: Bool
    }
    private struct ReactionReactorCacheKey: Hashable, Sendable {
        var channelID: ChannelID
        var messageID: MessageID
        var emojiIdentity: String
        var reactionCount: Int
    }

    private static let reactionReactorFetchLimit = 5
    private static let maximumReactionReactorCacheEntries = 256
    private static let maximumConcurrentReactionReactorReads = 4

    private let credentials: any CredentialStore
    private let handle: CredentialHandle
    private let session: URLSession
    private let gatewayTransport: any GatewayTransport
    private let clientMetadata: DiscordClientMetadata
    private var continuation: AsyncStream<ClientEvent>.Continuation?
    private var currentUser: User?
    private var authorizationValue: String?
    private var cachedMessages: [MessageID: Message] = [:]
    private var cachedChannels: [GuildID?: [Channel]] = [:]
    private var messageSendTasks: [String: Task<Message, Error>] = [:]
    private var cachedForumPosts: [ChannelID: [ChannelID: ForumPost]] = [:]
    private var forumCatalogueTasks: [ForumCatalogueLoadKey: Task<Void, Never>] = [:]
    private var forumCatalogueTaskIDs: [ForumCatalogueLoadKey: UUID] = [:]
    private var forumPreviewHydrationTasks: [ChannelID: Task<Void, Never>] = [:]
    private var forumPreviewHydrationTaskIDs: [ChannelID: UUID] = [:]
    private var forumPreviewHydrationQueues: [ChannelID: ForumPreviewHydrationQueue] = [:]
    private var forumReadStates: [ChannelID: ForumReadState] = [:]
    private var presenceStatus: PresenceStatus = .invisible
    private var globalRateLimitDate: Date = .distantPast
    private var routeRateLimitDates: [String: Date] = [:]
    private var nextRequestSlotDate: Date = .distantPast
    private var requestSafetyCircuitIsOpen = false
    private var unexpectedNotFoundCounts: [String: Int] = [:]
    private var gatewaySession: GatewaySession?
    private var gatewayEventTask: Task<Void, Never>?
    private var gatewayGuildIDs: [GuildID] = []
    private var gatewayReady = false
    private var initialGatewaySnapshot: InitialGatewaySnapshot?
    private var initialGatewaySnapshotContinuation:
        CheckedContinuation<InitialGatewaySnapshot, any Error>?
    private var pendingMemberGuildID: GuildID?
    private var cachedMembers: [GuildID: [Member]] = [:]
    private var cachedPrivateMembersByID: [UserID: Member] = [:]
    private var cachedMemberListItems: [GuildID: [GuildMemberListUpdateDTO.Item?]] = [:]
    private var cachedGatewayUsersByID: [String: UserDTO] = [:]
    private var cachedGuildRoles: [GuildID: [GuildRoleDTO]] = [:]
    private var pendingMemberSearchRequests: [String: PendingMemberSearchRequest] = [:]
    private var pendingMemberSearchRequestByGuild: [GuildID: String] = [:]
    private var pendingRoleMemberRequests: [String: PendingRoleMemberRequest] = [:]
    private var cachedGuilds: [GuildID: Guild] = [:]
    private var cachedGuildRailItems: [GuildRailItem] = []
    private var cachedProfiles: [ProfileCacheKey: UserProfile] = [:]
    private var cachedEmojis: [GuildID: EmojiCacheEntry] = [:]
    private var cachedEmojiUserSettings: EmojiUserSettings?
    private var cachedReactionReactors: [ReactionReactorCacheKey: [ReactionReactor]] = [:]
    private var reactionReactorCacheOrder: [ReactionReactorCacheKey] = []
    private var reactionReactorTasks: [ReactionReactorCacheKey: Task<[ReactionReactor], Error>] =
        [:]
    private var cachedApplicationCommandCatalogs:
        [ApplicationCommandIndexTarget: ApplicationCommandCatalog] = [:]
    private var applicationCommandCatalogTasks:
        [ApplicationCommandIndexTarget: Task<ApplicationCommandCatalog, Error>] = [:]
    private var pendingAutocompleteTypes: [String: ApplicationCommandOptionType] = [:]
    private var autocompleteTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var pendingModalContexts: [String: GatewayInteractionModalDTO] = [:]
    private var profileEffects: [String: ProfileEffectConfigDTO]?
    private var pendingVoiceNegotiation: PendingVoiceNegotiation?
    private var activeVoiceConnection: VoiceConnectionInfo?
    private var voiceNegotiationTimeoutTask: Task<Void, Never>?
    #if DEBUG
        private var suspendsForumCatalogueRefreshForTesting = false
    #endif

    private struct ForumCatalogueLoadKey: Hashable {
        let channelID: ChannelID
        let query: ForumPostQuery
    }

    private struct ForumPreviewHydrationQueue {
        private var ids: [ChannelID] = []
        private var nextIndex = 0
        private var pendingIDs: Set<ChannelID> = []

        var isEmpty: Bool {
            nextIndex >= ids.endIndex
        }

        mutating func enqueue(_ newIDs: some Sequence<ChannelID>) {
            for id in newIDs where pendingIDs.insert(id).inserted {
                ids.append(id)
            }
        }

        mutating func nextBatch(limit: Int) -> [ChannelID] {
            guard !isEmpty else { return [] }
            let upperBound = min(ids.endIndex, nextIndex + max(1, limit))
            let batch = Array(ids[nextIndex ..< upperBound])
            nextIndex = upperBound
            compactIfNeeded()
            return batch
        }

        mutating func complete(_ ids: [ChannelID]) {
            pendingIDs.subtract(ids)
        }

        private mutating func compactIfNeeded() {
            if isEmpty {
                ids.removeAll(keepingCapacity: true)
                nextIndex = 0
            } else if nextIndex >= 256, nextIndex * 2 >= ids.count {
                ids.removeFirst(nextIndex)
                nextIndex = 0
            }
        }
    }

    public init(
        credentials: any CredentialStore,
        handle: CredentialHandle,
        session: URLSession? = nil,
        fingerprint: String? = nil
    ) {
        let resolvedSession = session ?? URLSession(configuration: .default)
        self.credentials = credentials
        self.handle = handle
        self.session = resolvedSession
        gatewayTransport = URLSessionGatewayTransport(session: resolvedSession)
        clientMetadata = DiscordClientMetadata(fingerprint: fingerprint)
    }

    init(
        credentials: any CredentialStore,
        handle: CredentialHandle,
        session: URLSession,
        gatewayTransport: any GatewayTransport,
        fingerprint: String? = nil
    ) {
        self.credentials = credentials
        self.handle = handle
        self.session = session
        self.gatewayTransport = gatewayTransport
        clientMetadata = DiscordClientMetadata(fingerprint: fingerprint)
    }

    public func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.connecting))
        _ = try await authorizationToken()
        // Bootstrap deliberately stays sequential. A cold launch is not allowed to
        // fan out several authenticated user-account requests at once.
        let userDTO: UserDTO = try await request("/users/@me")
        let guildDTOs: [GuildDTO] = try await request("/users/@me/guilds")
        let user = try userDTO.domain()
        currentUser = user
        let guilds = try guildDTOs.map { try $0.domain() }
        cachedGuildRailItems = guilds.map { .guild($0.id) }
        cachedGuilds = Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) })
        cachedChannels[nil] = []
        presenceStatus =
            UserDefaults.standard.string(forKey: statusDefaultsKey).flatMap(
                PresenceStatus.init(rawValue:)
            ) ?? .invisible
        let members = [Member(user: user, roleName: "You", status: presenceStatus)]
        try await startGateway()
        let ready = try await waitForInitialGatewaySnapshot()
        let currentGuilds = guildsInCurrentRailOrder()
        var channelsByID = Dictionary(
            (cachedChannels[nil] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        for guild in currentGuilds {
            for channel in cachedChannels[guild.id] ?? [] {
                channelsByID[channel.id] = channel
            }
        }
        let startupChannels =
            (cachedChannels[nil] ?? []).compactMap { channelsByID.removeValue(forKey: $0.id) }
                + currentGuilds.flatMap { guild in
                    (cachedChannels[guild.id] ?? []).compactMap {
                        channelsByID.removeValue(forKey: $0.id)
                    }
                }
                + channelsByID.values.sorted { $0.id < $1.id }
        let startupThreads =
            cachedForumPosts.values
                .flatMap(\.values)
                .map(\.thread)
                .sorted { $0.id < $1.id }
        return BootstrapSnapshot(
            currentUser: user,
            guilds: currentGuilds,
            guildRailItems: cachedGuildRailItems,
            channels: startupChannels,
            threads: startupThreads,
            members: members,
            readStates: ready.readStates,
            notificationSettings: ready.notificationSettings,
            usesNewNotifications: ready.usesNewNotifications
        )
    }

    private func waitForInitialGatewaySnapshot() async throws -> InitialGatewaySnapshot {
        if let initialGatewaySnapshot {
            return initialGatewaySnapshot
        }
        return try await withCheckedThrowingContinuation { continuation in
            initialGatewaySnapshotContinuation = continuation
        }
    }

    private func finishInitialGatewaySnapshot(_ snapshot: InitialGatewaySnapshot) {
        initialGatewaySnapshot = snapshot
        initialGatewaySnapshotContinuation?.resume(returning: snapshot)
        initialGatewaySnapshotContinuation = nil
    }

    private func failInitialGatewaySnapshot(_ error: any Error) {
        initialGatewaySnapshotContinuation?.resume(throwing: error)
        initialGatewaySnapshotContinuation = nil
    }

    static func applyingGuildLayout(
        _ layout: DiscordGuildLayout,
        to guilds: [Guild]
    ) -> (guilds: [Guild], railItems: [GuildRailItem]) {
        let byID = Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) })
        let folderGuildIDs = layout.folders.flatMap(\.guildIDs)
        let orderedIDs = folderGuildIDs.isEmpty ? layout.guildPositions : folderGuildIDs
        guard !orderedIDs.isEmpty else {
            return (guilds, guilds.map { .guild($0.id) })
        }

        let referenced = Set(orderedIDs)
        let omitted =
            guilds
                .filter { !referenced.contains($0.id) }
                .sorted { $0.id.rawValue > $1.id.rawValue }
        var railItems = omitted.map { GuildRailItem.guild($0.id) }
        var emittedGuildIDs = Set(omitted.map(\.id))
        var emittedFolderIDs: Set<Int64> = []

        if layout.folders.isEmpty {
            for id in layout.guildPositions
                where byID[id] != nil && emittedGuildIDs.insert(id).inserted {
                railItems.append(.guild(id))
            }
        } else {
            for decodedFolder in layout.folders {
                let validIDs = decodedFolder.guildIDs.filter {
                    byID[$0] != nil && !emittedGuildIDs.contains($0)
                }
                emittedGuildIDs.formUnion(validIDs)
                guard !validIDs.isEmpty else { continue }
                if let id = decodedFolder.id, emittedFolderIDs.insert(id).inserted {
                    railItems.append(
                        .folder(
                            GuildFolder(
                                id: id,
                                name: decodedFolder.name,
                                colorHex: decodedFolder.colorHex,
                                guildIDs: validIDs
                            )))
                } else {
                    railItems.append(contentsOf: validIDs.map(GuildRailItem.guild))
                }
            }
        }

        let flattenedIDs = railItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let id): [id]
            case .folder(let folder): folder.guildIDs
            }
        }
        let orderedGuilds = flattenedIDs.compactMap { byID[$0] }
        gatewayLogger.info(
            "Applied guild folder settings; folders=\(emittedFolderIDs.count), guilds=\(orderedGuilds.count), omitted=\(omitted.count)"
        )
        return (orderedGuilds, railItems)
    }

    static func applyingGuildOrder(_ orderedIDs: [GuildID], to guilds: [Guild]) -> [Guild] {
        let byID = Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) })
        let ordered = orderedIDs.compactMap { byID[$0] }
        let orderedSet = Set(orderedIDs)
        let omitted =
            guilds
                .filter { !orderedSet.contains($0.id) }
                .sorted { $0.id.rawValue > $1.id.rawValue }
        gatewayLogger.info(
            "Applied guild settings order; ordered=\(ordered.count), omitted=\(omitted.count)"
        )
        // Match Discord/Paicord's unlisted-guild fallback: guilds absent from the
        // folder payload appear first, newest joined/created first. Guild IDs are
        // time-sortable snowflakes and are the bootstrap-safe proxy for join date.
        return omitted + ordered
    }

    public func channels(in guildID: GuildID?) async throws -> [Channel] {
        if let cached = cachedChannels[guildID] {
            return cached
        }
        guard let guildID else { return cachedChannels[nil] ?? [] }
        let values: [ChannelDTO] = try await request("/guilds/\(guildID)/channels")
        let channels = try Self.domainChannels(values, guildID: guildID)
        cachedChannels[guildID] = channels
        return channels
    }

    private func privateChannel(id: ChannelID) -> Channel? {
        cachedChannels[nil]?.first { $0.id == id }
    }

    private func upsertPrivateChannel(_ channel: Channel) {
        var channels = cachedChannels[nil] ?? []
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index] = channel
        } else {
            channels.append(channel)
        }
        cachedChannels[nil] = channels
        continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
        continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
    }

    private func promotePrivateChannel(
        channelID: ChannelID,
        lastMessageID: MessageID
    ) {
        var channels = cachedChannels[nil] ?? []
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else {
            return
        }
        var channel = channels.remove(at: index)
        channel.lastMessageID = lastMessageID
        channels.insert(channel, at: 0)
        cachedChannels[nil] = channels
        continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
    }

    private func privateMembersInChannelOrder() -> [Member] {
        var seen: Set<UserID> = []
        return (cachedChannels[nil] ?? []).flatMap(\.recipients).compactMap { user in
            guard seen.insert(user.id).inserted else { return nil }
            if var member = cachedPrivateMembersByID[user.id] {
                // READY presence records only contain a partial user. Keep DM
                // identity sourced from the hydrated private-channel recipient.
                member.user = user
                return member
            }
            return Member(user: user, roleName: "Direct Message", status: .offline)
        }
    }

    private func cachePrivatePresence(_ update: PresenceUpdateDTO) {
        guard update.guildID == nil,
              let userID = UserID(update.user.id),
              let status = PresenceStatus(rawValue: update.status)
        else { return }
        let user =
            cachedChannels[nil]?.lazy.flatMap(\.recipients)
                .first(where: { $0.id == userID })
                ?? cachedGatewayUsersByID[update.user.id].flatMap { try? $0.domain() }
        guard let user else { return }
        var member =
            cachedPrivateMembersByID[userID]
                ?? Member(user: user, roleName: "Direct Message", status: status)
        member.user = user
        member.status = status
        if let activities = update.activities {
            member.customStatus = activities.first(where: { $0.type == 4 })?.displayText
            member.activityText =
                activities.first(where: { $0.type != 4 })?.displayText
                    ?? member.customStatus
        }
        cachedPrivateMembersByID[userID] = member
    }

    private static func orderedPrivateChannels(_ channels: [Channel]) -> [Channel] {
        channels.sorted { lhs, rhs in
            let lhsActivity = lhs.lastMessageID?.rawValue ?? lhs.id.rawValue
            let rhsActivity = rhs.lastMessageID?.rawValue ?? rhs.id.rawValue
            return lhsActivity > rhsActivity
        }
    }

    private static func domainChannels(_ values: [ChannelDTO], guildID: GuildID) throws -> [Channel] {
        let categories = Dictionary(
            uniqueKeysWithValues: values.filter { $0.type == 4 }.map { ($0.id, $0) }
        )
        return try values.filter { $0.type != 4 }.map { dto in
            let category = dto.parentID.flatMap { categories[$0] }
            return try dto.domain(
                guildID: guildID,
                categoryName: category?.name,
                categoryPosition: category?.position ?? -1
            )
        }.sorted { lhs, rhs in
            if lhs.categoryPosition != rhs.categoryPosition {
                return lhs.categoryPosition < rhs.categoryPosition
            }
            return lhs.position < rhs.position
        }
    }

    public func members(in guildID: GuildID?) async throws -> [Member] {
        guard let guildID else {
            return privateMembersInChannelOrder()
        }
        if cachedGuildRoles[guildID] == nil {
            do {
                let roles: [GuildRoleDTO] = try await request("/guilds/\(guildID)/roles")
                cachedGuildRoles[guildID] = roles
            } catch {
                gatewayLogger.warning(
                    "Guild roles unavailable; member categories will use the default group: \(error.localizedDescription, privacy: .public)"
                )
                cachedGuildRoles[guildID] = []
            }
        }
        pendingMemberGuildID = guildID
        gatewayLogger.info("Member list requested; gatewayReady=\(self.gatewayReady)")
        if gatewayReady {
            await attemptMemberSubscription(guildID: guildID)
        }
        return cachedMembers[guildID] ?? []
    }

    public func roles(in guildID: GuildID) async throws -> [GuildRole] {
        if cachedGuildRoles[guildID] == nil {
            let roles: [GuildRoleDTO] = try await request("/guilds/\(guildID)/roles")
            cachedGuildRoles[guildID] = roles
        }
        return (cachedGuildRoles[guildID] ?? [])
            .compactMap(\.domain)
            .sorted { $0.position > $1.position }
    }

    public func searchMembers(
        in guildID: GuildID, query: String, limit: Int
    ) async throws -> [Member] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        _ = try await roles(in: guildID)
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to search guild members.")
        }
        let requestID = UUID().uuidString
        let maximumResults = min(max(1, limit), 20)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[Member], any Error>) in
                if let supersededRequestID = pendingMemberSearchRequestByGuild[guildID] {
                    failMemberSearchRequest(
                        requestID: supersededRequestID,
                        error: CancellationError()
                    )
                }
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    await self?.timeoutMemberSearchRequest(requestID: requestID)
                }
                pendingMemberSearchRequests[requestID] = PendingMemberSearchRequest(
                    guildID: guildID,
                    maximumResults: maximumResults,
                    members: [],
                    receivedChunks: [],
                    continuation: continuation,
                    timeoutTask: timeout
                )
                pendingMemberSearchRequestByGuild[guildID] = requestID
                Task { [weak self] in
                    do {
                        try await self?.sendGateway(
                            DiscordGatewayPayloadFactory.searchMembers(
                                guildID: guildID,
                                query: normalized,
                                limit: maximumResults
                            )
                        )
                        gatewayLogger.info(
                            "Sent member autocomplete Gateway request; limit=\(maximumResults)"
                        )
                    } catch {
                        await self?.failMemberSearchRequest(requestID: requestID, error: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.failMemberSearchRequest(
                    requestID: requestID,
                    error: CancellationError()
                )
            }
        }
    }

    public func members(withRole roleID: RoleID, in guildID: GuildID) async throws
        -> RoleMemberResult
    {
        let ids: [String] = try await request("/guilds/\(guildID)/roles/\(roleID)/member-ids")
        let validIDs = ids.compactMap(UserID.init)
        let maximumDisplayedMembers = 1_000
        let requestedIDs = Array(validIDs.prefix(maximumDisplayedMembers))
        let cachedByID = Dictionary(
            uniqueKeysWithValues: (cachedMembers[guildID] ?? []).map { ($0.id, $0) })
        let missing = requestedIDs.filter { cachedByID[$0] == nil }
        if !missing.isEmpty {
            try await requestMembersByID(missing, guildID: guildID)
        }
        let resolvedByID = Dictionary(
            uniqueKeysWithValues: (cachedMembers[guildID] ?? []).map { ($0.id, $0) })
        return RoleMemberResult(
            members: requestedIDs.compactMap { resolvedByID[$0] },
            totalCount: validIDs.count,
            isTruncated: validIDs.count > maximumDisplayedMembers
        )
    }

    public func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        let key = ProfileCacheKey(userID: userID, guildID: guildID)
        if let cached = cachedProfiles[key] {
            return cached
        }

        var query = [
            URLQueryItem(name: "with_mutual_guilds", value: "true"),
            URLQueryItem(name: "with_mutual_friends", value: "true"),
            URLQueryItem(name: "with_mutual_friends_count", value: "true"),
        ]
        if let guildID {
            query.append(URLQueryItem(name: "guild_id", value: guildID.description))
        }
        let dto: UserProfileDTO = try await request("/users/\(userID)/profile", query: query)

        let effectID =
            dto.guildMemberProfile?.profileEffect?.resolvedID
                ?? dto.userProfile?.profileEffect?.resolvedID
        if effectID != nil, profileEffects == nil {
            let locale = Locale.preferredLanguages.first ?? "en-US"
            let response: ProfileEffectsDTO? = try? await request(
                "/user-profile-effects",
                query: [URLQueryItem(name: "locale", value: locale)]
            )
            var effectsByID: [String: ProfileEffectConfigDTO] = [:]
            for effect in response?.profileEffectConfigs?.elements ?? [] {
                if let id = effect.id {
                    effectsByID[id] = effect
                }
                if let skuID = effect.skuID {
                    effectsByID[skuID] = effect
                }
            }
            profileEffects = effectsByID
        }
        if let effectID, profileEffects?[effectID] == nil {
            let product: CollectibleProductDTO? = try? await request(
                "/collectibles-products/\(effectID)")
            for effect in product?.items?.elements.filter({ $0.type == 1 }) ?? [] {
                if let id = effect.id {
                    profileEffects?[id] = effect
                }
                if let skuID = effect.skuID {
                    profileEffects?[skuID] = effect
                }
            }
        }

        let profile = try dto.domain(
            guildID: guildID,
            guilds: cachedGuilds,
            guildRoles: guildID.flatMap { cachedGuildRoles[$0] } ?? [],
            effectConfig: effectID.flatMap { profileEffects?[$0] }
        )
        gatewayLogger.debug(
            "Profile assets resolved; bio=\(profile.bio?.isEmpty == false), badges=\(profile.badges.count), effect=\(profile.effect != nil), animations=\(profile.effect?.animations.count ?? 0)"
        )
        cachedProfiles[key] = profile
        return profile
    }

    public func emojis(in guildID: GuildID) async throws -> [DiscordEmoji] {
        if let cached = cachedEmojis[guildID], cached.isFresh {
            return cached.emojis
        }
        if let disk = try? loadEmojiCache(for: guildID) {
            cachedEmojis[guildID] = disk
            if disk.isFresh {
                return disk.emojis
            }
        }

        do {
            let payload: [GuildEmojiDTO] = try await request("/guilds/\(guildID)/emojis")
            let emojis = payload.compactMap { $0.domain(guildID: guildID) }
            let entry = EmojiCacheEntry(fetchedAt: .now, emojis: emojis)
            cachedEmojis[guildID] = entry
            try? persistEmojiCache(entry, for: guildID)
            return emojis
        } catch {
            if let stale = cachedEmojis[guildID] {
                return stale.emojis
            }
            throw error
        }
    }

    public func emojiUserSettings() async throws -> EmojiUserSettings {
        if let cachedEmojiUserSettings {
            return cachedEmojiUserSettings
        }
        let response: UserSettingsProtoDTO = try await request("/users/@me/settings-proto/2")
        guard let data = Data(base64Encoded: response.settings) else { return EmojiUserSettings() }
        let settings = DiscordSettingsProto.emojiSettings(from: data)
        gatewayLogger.info(
            "Decoded emoji settings; favorites=\(settings.favoriteKeys.count), frequent=\(settings.frequentlyUsedKeys.count)"
        )
        cachedEmojiUserSettings = settings
        return settings
    }

    private func loadEmojiCache(for guildID: GuildID) throws -> EmojiCacheEntry {
        let data = try Data(contentsOf: emojiCacheURL(for: guildID))
        return try JSONDecoder().decode(EmojiCacheEntry.self, from: data)
    }

    private func persistEmojiCache(_ entry: EmojiCacheEntry, for guildID: GuildID) throws {
        let url = emojiCacheURL(for: guildID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    }

    private func emojiCacheURL(for guildID: GuildID) -> URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        return
            base
                .appending(
                    path: "dev.sakuracord.SakuraCord/EmojiCache/\(handle.accountID)",
                    directoryHint: .isDirectory
                )
                .appending(path: "\(guildID).json")
    }

    public func currentStatus() async -> PresenceStatus {
        presenceStatus
    }

    public func updateStatus(_ status: PresenceStatus) async throws {
        try await sendGateway([
            "op": 3,
            "d": ["since": 0, "activities": [], "status": status.rawValue, "afk": false]
                as [String: Any],
        ])
        presenceStatus = status
        UserDefaults.standard.set(status.rawValue, forKey: statusDefaultsKey)
    }

    private var statusDefaultsKey: String {
        "dev.sakuracord.presence.\(handle.accountID)"
    }

    public func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        var query: [URLQueryItem] = []
        if let before {
            query.append(URLQueryItem(name: "before", value: before.description))
        }
        query.append(
            URLQueryItem(
                name: "limit",
                value: String(min(max(limit, 1), 100))
            )
        )
        let payload: LossyList<MessageDTO> = try await request(
            "/channels/\(channelID)/messages", query: query
        )
        if payload.skippedCount > 0 {
            gatewayLogger.warning(
                "Skipped \(payload.skippedCount) unsupported message payloads in channel \(channelID)"
            )
        }
        let values = payload.elements.compactMap { try? $0.domain() }.sorted {
            $0.timestamp < $1.timestamp
        }
        for message in values {
            cachedMessages[message.id] = message
        }
        return MessagePage(messages: values, hasMoreBefore: values.count == min(max(limit, 1), 100))
    }

    public func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        guard
            let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                $0.id == channelID && $0.kind == .forum
            })
        else { throw ChatProviderError.channelNotFound }

        switch query.scope {
        case .active:
            let cachedPosts = Array(cachedForumPosts[channelID, default: [:]].values)
            if query.offset == 0, !cachedPosts.isEmpty {
                let immediatePosts = Self.filteredAndSortedForumPosts(
                    cachedPosts,
                    query: query
                )
                scheduleForumCatalogueRefresh(
                    channel: channel,
                    query: query
                )
                scheduleForumPostPreviewHydration(
                    parentID: channelID,
                    postIDs: immediatePosts.map(\.id)
                )
                return ForumPostPage(posts: immediatePosts, hasMore: false, nextOffset: nil)
            }
            do {
                let remotePage = try await olderForumPosts(channel: channel, query: query)
                let page = Self.mergedForumCataloguePage(
                    cachedPosts: cachedPosts,
                    olderPage: remotePage,
                    query: query
                )
                scheduleForumPostPreviewHydration(
                    parentID: channelID,
                    postIDs: page.posts.map(\.id)
                )
                return page
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard !cachedPosts.isEmpty else { throw error }
                gatewayLogger.warning(
                    "Older forum-post pagination failed; retaining cached posts for channel \(channelID)"
                )
                guard query.offset == 0 else { throw error }
                let posts = Self.filteredAndSortedForumPosts(cachedPosts, query: query)
                return ForumPostPage(posts: posts, hasMore: false, nextOffset: nil)
            }
        case .search(let text):
            return try await searchedForumPosts(
                channel: channel, query: query, searchText: text
            )
        }
    }

    private func scheduleForumCatalogueRefresh(
        channel: Channel,
        query: ForumPostQuery
    ) {
        let key = ForumCatalogueLoadKey(channelID: channel.id, query: query)
        guard forumCatalogueTasks[key] == nil else { return }

        let supersededKeys = forumCatalogueTasks.keys.filter { $0 != key }
        for supersededKey in supersededKeys {
            forumCatalogueTasks.removeValue(forKey: supersededKey)?.cancel()
            forumCatalogueTaskIDs[supersededKey] = nil
        }

        let taskID = UUID()
        forumCatalogueTaskIDs[key] = taskID
        forumCatalogueTasks[key] = Task { [weak self] in
            await self?.refreshForumCatalogue(
                channel: channel,
                query: query,
                key: key,
                taskID: taskID
            )
        }
    }

    private func refreshForumCatalogue(
        channel: Channel,
        query: ForumPostQuery,
        key: ForumCatalogueLoadKey,
        taskID: UUID
    ) async {
        let previouslyKnownPostIDs = Set(cachedForumPosts[channel.id, default: [:]].keys)
        defer {
            if forumCatalogueTaskIDs[key] == taskID {
                forumCatalogueTasks[key] = nil
                forumCatalogueTaskIDs[key] = nil
            }
        }
        #if DEBUG
            if suspendsForumCatalogueRefreshForTesting {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        #endif
        do {
            let remotePage = try await olderForumPosts(channel: channel, query: query)
            let page = Self.mergedForumCataloguePage(
                cachedPosts: Array(cachedForumPosts[channel.id, default: [:]].values),
                olderPage: remotePage,
                query: query
            )
            continuation?.yield(
                .forumPageLoaded(channelID: channel.id, query: query, page: page)
            )
            scheduleForumPostPreviewHydration(
                parentID: channel.id,
                postIDs: page.posts.lazy.map(\.id).filter {
                    !previouslyKnownPostIDs.contains($0)
                }
            )
        } catch {
            if !Task.isCancelled {
                gatewayLogger.warning(
                    "Background forum catalogue refresh failed for channel \(channel.id)"
                )
            }
        }
    }

    public func forumPost(threadID: ChannelID) async throws -> ForumPost {
        for posts in cachedForumPosts.values {
            if let post = posts[threadID] {
                return post
            }
        }
        let payload: ChannelDTO = try await request("/channels/\(threadID)")
        guard [10, 11, 12].contains(payload.type) else {
            throw ChatProviderError.invalidRequest("That link does not point to a thread.")
        }
        let post = try payload.forumPost(fallbackGuildID: nil)
        if let parentID = post.thread.parentID {
            cachedForumPosts[parentID, default: [:]][post.id] = post
        }
        cacheForumPreviewMessages(post)
        return post
    }

    public func createForumPost(
        _ draft: CreateForumPostDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> ForumPost {
        guard
            let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                $0.id == draft.channelID && $0.kind == .forum
            })
        else { throw ChatProviderError.channelNotFound }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 100).contains(title.count) else {
            throw ChatProviderError.invalidRequest(
                "Post titles must be between 1 and 100 characters.")
        }
        guard draft.content.count <= 2_000 else {
            throw ChatProviderError.invalidRequest("Post messages cannot exceed 2,000 characters.")
        }
        guard
            !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.attachments.isEmpty
        else {
            throw ChatProviderError.invalidRequest("Add a message or attachment before posting.")
        }
        guard draft.attachments.count <= 10 else {
            throw ChatProviderError.invalidRequest("A post can contain at most 10 attachments.")
        }
        guard draft.attachments.allSatisfy({
            !$0.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ChatProviderError.invalidRequest("Attachment filenames cannot be empty.")
        }
        guard draft.attachments.allSatisfy({ $0.description.count <= 1_024 }) else {
            throw ChatProviderError.invalidRequest(
                "Attachment descriptions cannot exceed 1,024 characters.")
        }
        guard Self.validForumAutoArchiveDurations.contains(draft.autoArchiveDuration) else {
            throw ChatProviderError.invalidRequest("The selected auto-archive duration is invalid.")
        }
        let selectedTags = Self.orderedUniqueForumTagIDs(
            draft.appliedTagIDs,
            availableTags: channel.availableTags
        )
        guard selectedTags.count <= 5 else {
            throw ChatProviderError.invalidRequest("A forum post can use at most 5 tags.")
        }
        guard Set(selectedTags) == Set(draft.appliedTagIDs) else {
            throw ChatProviderError.invalidRequest("One or more selected tags are unavailable.")
        }
        guard !channel.requiresForumTag || !selectedTags.isEmpty else {
            throw ChatProviderError.invalidRequest("Select at least one tag before posting.")
        }
        progress(.preparing)
        var message: [String: JSONValue] = ["content": .string(draft.content)]
        if !draft.attachments.isEmpty {
            message["attachments"] = try await .array(
                uploadForumAttachments(
                    draft.attachments, channelID: draft.channelID, progress: progress
                )
            )
        }
        let body: [String: JSONValue] = [
            "name": .string(title),
            "auto_archive_duration": .number(Double(draft.autoArchiveDuration)),
            "applied_tags": .array(selectedTags.map { .string($0.description) }),
            "message": .object(message),
        ]
        progress(.submitting)
        let dto: ChannelDTO = try await request(
            "/channels/\(draft.channelID)/threads",
            method: "POST",
            query: [URLQueryItem(name: "use_nested_fields", value: "true")],
            body: body
        )
        var post = try dto.forumPost(fallbackGuildID: channel.guildID)
        if post.owner == nil { post.owner = currentUser }
        cachedForumPosts[draft.channelID, default: [:]][post.id] = post
        cacheForumPreviewMessages(post)
        publishForumPosts(parentID: draft.channelID)
        progress(.completed(messageID: MessageID(rawValue: post.id.rawValue)))
        return post
    }

    public func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws
        -> ForumPost
    {
        guard let parentID = post.thread.parentID else {
            throw ChatProviderError.invalidRequest("The forum post has no parent channel.")
        }
        var working = post
        switch mutation {
        case .tags(let tags):
            guard
                let channel = cachedChannels.values.lazy.flatMap(\.self).first(where: {
                    $0.id == parentID && $0.kind == .forum
                })
            else { throw ChatProviderError.channelNotFound }
            let selectedTags = Self.orderedUniqueForumTagIDs(
                tags,
                availableTags: channel.availableTags
            )
            guard selectedTags.count <= 5 else {
                throw ChatProviderError.invalidRequest("A forum post can use at most 5 tags.")
            }
            guard Set(selectedTags) == Set(tags) else {
                throw ChatProviderError.invalidRequest("One or more selected tags are unavailable.")
            }
            guard !channel.requiresForumTag || !selectedTags.isEmpty else {
                throw ChatProviderError.invalidRequest(
                    "This forum requires every post to have at least one tag."
                )
            }
            if working.thread.isArchived {
                working = try await patchForumPost(working, body: ["archived": .bool(false)])
            }
            working = try await patchForumPost(
                working,
                body: ["applied_tags": .array(selectedTags.map { .string($0.description) })]
            )
        case .archived(let value):
            working = try await patchForumPost(working, body: ["archived": .bool(value)])
        case .locked(let value):
            let wasArchived = working.thread.isArchived
            if wasArchived {
                working = try await patchForumPost(working, body: ["archived": .bool(false)])
            }
            working = try await patchForumPost(
                working,
                body: ["locked": .bool(value), "archived": .bool(wasArchived)]
            )
        case .pinned(let value):
            var body: [String: JSONValue] = [
                "flags": .number(
                    Double(
                        value ? working.thread.flags | (1 << 1) : working.thread.flags & ~(1 << 1)))
            ]
            if value, working.thread.isArchived { body["archived"] = .bool(false) }
            working = try await patchForumPost(working, body: body)
        }
        cachedForumPosts[parentID, default: [:]][working.id] = working
        publishForumPosts(parentID: parentID)
        return working
    }

    nonisolated static func orderedUniqueForumTagIDs(
        _ selectedTagIDs: [ForumTagID],
        availableTags: [ForumTag]
    ) -> [ForumTagID] {
        let selected = Set(selectedTagIDs)
        return availableTags.lazy.map(\.id).filter(selected.contains)
    }

    nonisolated static let validForumAutoArchiveDurations: Set<Int> = [
        60, 1_440, 4_320, 10_080,
    ]

    public func deleteForumPost(_ post: ForumPost) async throws {
        guard let parentID = post.thread.parentID else {
            throw ChatProviderError.invalidRequest("The forum post has no parent channel.")
        }
        try await requestEmpty(Self.forumPostDeletionPath(postID: post.id), method: "DELETE")
        cachedForumPosts[parentID]?[post.id] = nil
        let messageIDs = cachedMessages.values
            .filter { $0.channelID == post.id }
            .map(\.id)
        for messageID in messageIDs {
            cachedMessages[messageID] = nil
        }
        publishForumPosts(parentID: parentID)
    }

    nonisolated static func forumPostDeletionPath(postID: ChannelID) -> String {
        "/channels/\(postID)"
    }

    private func olderForumPosts(channel: Channel, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        let items = Self.forumCatalogueQueryItems(query: query)
        let result: ForumThreadCatalogueResponseDTO = try await request(
            Self.forumThreadSearchPath(channelID: channel.id), query: items
        )
        let decodedPosts = result.posts(fallbackGuildID: channel.guildID)
        gatewayLogger.debug(
            "Forum catalogue decoded threads=\(result.threads.count) skipped=\(result.skippedThreadCount) posts=\(decodedPosts.count) archived=\(decodedPosts.count(where: { $0.thread.isArchived })) hasMore=\(result.hasMore) total=\(result.totalResults ?? -1)"
        )
        let posts = ingestForumPosts(decodedPosts, channel: channel)
        let nextOffset = result.hasMore && !result.threads.isEmpty
            ? query.offset + result.threads.count
            : nil
        return ForumPostPage(
            posts: posts,
            hasMore: result.hasMore && nextOffset != nil,
            nextOffset: nextOffset
        )
    }

    private func searchedForumPosts(
        channel: Channel,
        query: ForumPostQuery,
        searchText: String
    ) async throws -> ForumPostPage {
        let items = Self.forumNameSearchQueryItems(searchText: searchText, query: query)
        let result: ForumThreadSearchResponseDTO = try await request(
            "/channels/\(channel.id)/threads/search", query: items
        )
        var posts = ingestForumPosts(
            result.posts(fallbackGuildID: channel.guildID), channel: channel
        )
        posts = Self.filteredAndSortedForumPosts(posts, query: query)
        return ForumPostPage(posts: posts, hasMore: false, nextOffset: nil)
    }

    private func ingestForumPosts(
        _ incomingPosts: [ForumPost],
        channel: Channel
    ) -> [ForumPost] {
        var posts = incomingPosts
        for index in posts.indices {
            if let existing = cachedForumPosts[channel.id]?[posts[index].id] {
                posts[index] = Self.mergingForumPostCatalogueMetadata(
                    incoming: posts[index],
                    existing: existing
                )
            }
            if posts[index].owner == nil, let ownerID = posts[index].thread.ownerID,
               let ownerDTO = cachedGatewayUsersByID[ownerID.description]
            {
                posts[index].owner = try? ownerDTO.domain()
            }
            cachedForumPosts[channel.id, default: [:]][posts[index].id] = posts[index]
            cacheForumPreviewMessages(posts[index])
        }
        return posts
    }

    nonisolated static func mergingForumPostCatalogueMetadata(
        incoming: ForumPost,
        existing: ForumPost
    ) -> ForumPost {
        var merged = incoming
        if let firstMessage = incoming.firstMessage {
            merged.firstMessage = firstMessage.preservingReactionReactors(
                from: existing.firstMessage ?? firstMessage
            )
        } else {
            merged.firstMessage = existing.firstMessage
        }
        if let mostRecentMessage = incoming.mostRecentMessage {
            merged.mostRecentMessage = mostRecentMessage.preservingReactionReactors(
                from: existing.mostRecentMessage ?? mostRecentMessage
            )
        } else {
            merged.mostRecentMessage = existing.mostRecentMessage
        }
        merged.owner = incoming.owner ?? existing.owner
        merged.isUnread = existing.isUnread
        return merged
    }

    nonisolated static func forumCatalogueQueryItems(query: ForumPostQuery)
        -> [URLQueryItem]
    {
        var items = [
            URLQueryItem(name: "archived", value: "true"),
            URLQueryItem(
                name: "sort_by",
                value: query.sortOrder == .latestActivity ? "last_message_time" : "creation_time"
            ),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "limit", value: String(min(query.limit, 25))),
        ]
        appendForumTagQueryItems(to: &items, query: query)
        items.append(URLQueryItem(name: "offset", value: String(query.offset)))
        return items
    }

    nonisolated static func forumThreadSearchPath(channelID: ChannelID) -> String {
        "/channels/\(channelID)/threads/search"
    }

    nonisolated static func forumNameSearchQueryItems(
        searchText: String,
        query: ForumPostQuery
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(
                name: "name",
                value: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        ]
        appendForumTagQueryItems(to: &items, query: query)
        return items
    }

    nonisolated private static func appendForumTagQueryItems(
        to items: inout [URLQueryItem],
        query: ForumPostQuery
    ) {
        if !query.selectedTagIDs.isEmpty {
            let value = query.selectedTagIDs.map(\.description).sorted().joined(separator: ",")
            items.append(URLQueryItem(name: "tag", value: value))
        }
        items.append(URLQueryItem(name: "tag_setting", value: query.tagMatch.rawValue))
    }

    private func scheduleForumPostPreviewHydration(
        parentID: ChannelID,
        postIDs: [ChannelID]
    ) {
        let supersededParentIDs = forumPreviewHydrationTasks.keys.filter { $0 != parentID }
        for supersededParentID in supersededParentIDs {
            forumPreviewHydrationTasks.removeValue(forKey: supersededParentID)?.cancel()
            forumPreviewHydrationTaskIDs[supersededParentID] = nil
            forumPreviewHydrationQueues[supersededParentID] = nil
        }
        let missingIDs = postIDs.lazy.filter {
            self.cachedForumPosts[parentID]?[$0]?.firstMessage == nil
        }
        forumPreviewHydrationQueues[parentID, default: ForumPreviewHydrationQueue()]
            .enqueue(missingIDs)
        guard forumPreviewHydrationQueues[parentID]?.isEmpty == false else { return }
        guard forumPreviewHydrationTasks[parentID] == nil else { return }
        let taskID = UUID()
        forumPreviewHydrationTaskIDs[parentID] = taskID
        forumPreviewHydrationTasks[parentID] = Task { [weak self] in
            await self?.hydratePendingForumPostMessages(parentID: parentID, taskID: taskID)
        }
    }

    private func hydratePendingForumPostMessages(parentID: ChannelID, taskID: UUID) async {
        defer {
            if forumPreviewHydrationTaskIDs[parentID] == taskID {
                forumPreviewHydrationTasks[parentID] = nil
                forumPreviewHydrationTaskIDs[parentID] = nil
                forumPreviewHydrationQueues[parentID] = nil
            }
        }
        while !Task.isCancelled {
            guard forumPreviewHydrationQueues[parentID]?.isEmpty == false else {
                return
            }
            let batch = forumPreviewHydrationQueues[parentID]?.nextBatch(limit: 10) ?? []
            guard !batch.isEmpty else { return }
            let response: ForumPostDataResponseDTO
            do {
                response = try await request(
                    "/channels/\(parentID)/post-data",
                    method: "POST",
                    body: ["thread_ids": .array(batch.map { .string($0.description) })]
                )
            } catch {
                if Task.isCancelled { return }
                forumPreviewHydrationQueues[parentID]?.complete(batch)
                gatewayLogger.warning(
                    "Forum post preview hydration failed for channel \(parentID); retaining catalogue records"
                )
                continue
            }
            var changed: [ForumPost] = []
            changed.reserveCapacity(response.threads.count)
            for (id, data) in response.threads {
                guard let channelID = ChannelID(id),
                      var post = cachedForumPosts[parentID]?[channelID]
                else { continue }
                if let message = try? data.firstMessage?.domain() {
                    post.firstMessage = message.preservingReactionReactors(
                        from: post.firstMessage ?? message
                    )
                }
                if let message = try? data.mostRecentMessage?.domain() {
                    post.mostRecentMessage = message.preservingReactionReactors(
                        from: post.mostRecentMessage ?? message
                    )
                }
                cachedForumPosts[parentID, default: [:]][channelID] = post
                cacheForumPreviewMessages(post)
                changed.append(post)
            }
            forumPreviewHydrationQueues[parentID]?.complete(batch)
            if !changed.isEmpty {
                continuation?.yield(
                    .forumPostPreviewsChanged(channelID: parentID, posts: changed)
                )
            }
        }
    }

    private func patchForumPost(_ post: ForumPost, body: [String: JSONValue]) async throws
        -> ForumPost
    {
        let dto: ChannelDTO = try await request(
            "/channels/\(post.id)", method: "PATCH", body: body
        )
        var updated = try dto.forumPost(fallbackGuildID: post.thread.guildID)
        updated.firstMessage = post.firstMessage
        updated.mostRecentMessage = post.mostRecentMessage
        updated.owner = post.owner
        updated.isUnread = post.isUnread
        return updated
    }

    private func publishForumPosts(parentID: ChannelID) {
        let posts = Array(cachedForumPosts[parentID, default: [:]].values)
        continuation?.yield(.forumPostsChanged(channelID: parentID, posts: posts))
    }

    private func ingestForumThreads(
        _ threadDTOs: [ChannelDTO], fallbackGuildID: GuildID?,
        replacingParents: Set<ChannelID>? = nil,
        advancesParentLatestThreadID: Bool = false
    ) {
        if advancesParentLatestThreadID {
            advanceForumParentLatestThreadIDs(
                threadDTOs,
                fallbackGuildID: fallbackGuildID
            )
        }
        if let replacingParents {
            for parentID in replacingParents {
                cachedForumPosts[parentID] = cachedForumPosts[parentID, default: [:]].filter {
                    Self.shouldPreserveForumPostDuringThreadListReplacement($0.value)
                }
            }
        }
        var changed = Set<ChannelID>()
        for dto in threadDTOs {
            guard var post = try? dto.forumPost(fallbackGuildID: fallbackGuildID),
                  let parentID = post.thread.parentID
            else { continue }
            if post.owner == nil, let ownerID = post.thread.ownerID,
               let ownerDTO = cachedGatewayUsersByID[ownerID.description]
            {
                post.owner = try? ownerDTO.domain()
            }
            if let existing = cachedForumPosts[parentID]?[post.id] {
                post = Self.mergingForumPostCatalogueMetadata(
                    incoming: post,
                    existing: existing
                )
                post.isUnread = existing.isUnread
            } else if let state = forumReadStates[post.id] {
                post.isUnread =
                    state.mentionCount > 0
                        || post.thread.lastMessageID.map { lastMessageID in
                            state.lastReadMessageID.map { lastMessageID > $0 } ?? true
                        } ?? false
            }
            cachedForumPosts[parentID, default: [:]][post.id] = post
            cacheForumPreviewMessages(post)
            changed.insert(parentID)
        }
        for parentID in changed.union(replacingParents ?? []) {
            publishForumPosts(parentID: parentID)
        }
    }

    private func advanceForumParentLatestThreadIDs(
        _ threadDTOs: [ChannelDTO],
        fallbackGuildID: GuildID?
    ) {
        var changedGuildIDs = Set<GuildID>()
        for dto in threadDTOs {
            guard let parentID = dto.parentID.flatMap(ChannelID.init),
                  let threadID = MessageID(dto.id),
                  let guildID = dto.guildID.flatMap(GuildID.init) ?? fallbackGuildID,
                  var channels = cachedChannels[guildID],
                  let index = channels.firstIndex(where: { $0.id == parentID }),
                  channels[index].kind == .forum,
                  channels[index].lastMessageID.map({ $0 < threadID }) ?? true
            else { continue }
            channels[index].lastMessageID = threadID
            cachedChannels[guildID] = channels
            changedGuildIDs.insert(guildID)
        }
        for guildID in changedGuildIDs {
            continuation?.yield(
                .channelsChanged(
                    guildID: guildID,
                    channels: cachedChannels[guildID] ?? []
                )
            )
        }
    }

    nonisolated static func shouldPreserveForumPostDuringThreadListReplacement(
        _ post: ForumPost
    ) -> Bool {
        post.thread.isArchived || post.thread.isLocked
    }

    private func updateForumPostForMessage(
        _ message: Message,
        marksUnread: Bool = false,
        publishesChange: Bool = true
    ) {
        for (parentID, posts) in cachedForumPosts {
            guard var post = posts[message.channelID] else { continue }
            let isNewerReply =
                marksUnread
                && message.id.rawValue != post.id.rawValue
                && (post.thread.lastMessageID.map { message.id > $0 } ?? true)
            if message.id.rawValue == post.id.rawValue || post.firstMessage?.id == message.id {
                post.firstMessage = message
            }
            if post.mostRecentMessage == nil || message.timestamp >= post.lastActivityAt {
                post.mostRecentMessage = message
                post.thread.lastMessageID = message.id
            }
            if isNewerReply {
                post.thread.messageCount += 1
                post.thread.totalMessageSent += 1
            }
            if marksUnread,
               message.author.id != currentUser?.id,
               forumReadStates[post.id]?.lastReadMessageID.map({ message.id > $0 }) ?? true
            {
                post.isUnread = true
            }
            cachedForumPosts[parentID]?[post.id] = post
            if publishesChange {
                publishForumPosts(parentID: parentID)
            }
            return
        }
    }

    private func applyGatewayReactionUpdate(_ update: MessageReactionUpdate) {
        if var message = cachedMessages[update.messageID],
           message.applyReactionUpdate(update, currentUserID: currentUser?.id)
        {
            cachedMessages[message.id] = message
            updateForumPostForMessage(message, publishesChange: false)
        }
        continuation?.yield(.messageReactionUpdated(update))
    }

    private func cacheForumPreviewMessages(_ post: ForumPost) {
        if let firstMessage = post.firstMessage {
            cachedMessages[firstMessage.id] = firstMessage
        }
        if let mostRecentMessage = post.mostRecentMessage {
            cachedMessages[mostRecentMessage.id] = mostRecentMessage
        }
    }

    private static func filteredAndSortedForumPosts(
        _ posts: [ForumPost], query: ForumPostQuery
    ) -> [ForumPost] {
        ForumPostQueryPolicy.filteredAndSorted(
            posts,
            selectedTagIDs: query.selectedTagIDs,
            tagMatch: query.tagMatch,
            sortOrder: query.sortOrder
        )
    }

    nonisolated static func mergedForumCataloguePage(
        cachedPosts: [ForumPost],
        olderPage: ForumPostPage,
        query: ForumPostQuery
    ) -> ForumPostPage {
        var posts = olderPage.posts
        if query.offset == 0 {
            let activePosts = cachedPosts.filter { !$0.thread.isArchived }
            var byID = Dictionary(uniqueKeysWithValues: activePosts.map { ($0.id, $0) })
            for post in olderPage.posts {
                byID[post.id] = post
            }
            posts = Array(byID.values)
        }
        return ForumPostPage(
            posts: filteredAndSortedForumPosts(posts, query: query),
            hasMore: olderPage.hasMore,
            nextOffset: olderPage.nextOffset
        )
    }

    public func sendTyping(in channelID: ChannelID) async throws {
        let channel = cachedChannels.values.lazy.flatMap(\.self).first { $0.id == channelID }
        guard let channel else { throw ChatProviderError.channelNotFound }
        guard channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown else {
            throw ChatProviderError.invalidRequest("Typing is unavailable in this channel.")
        }
        // Discord documents this mutation as an empty POST returning 204. It goes
        // through the shared scheduler and, like every mutation, is attempted once.
        try await requestEmpty("/channels/\(channelID)/typing", method: "POST")
    }

    public func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?
    ) async throws -> ReadAcknowledgementResponse {
        try await acknowledge(
            channelID: channelID,
            messageID: messageID,
            token: token,
            manual: false,
            mentionCount: nil,
            flags: nil,
            lastViewed: nil
        )
    }

    public func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?,
        manual: Bool,
        mentionCount: Int?,
        flags: UInt64?,
        lastViewed: Int?
    ) async throws -> ReadAcknowledgementResponse {
        var body: [String: JSONValue] = [:]
        if let token {
            body["token"] = .string(token)
        }
        if manual {
            body["manual"] = .bool(true)
            body["mention_count"] = .number(Double(max(0, mentionCount ?? 0)))
        }
        if let flags {
            body["flags"] = .number(Double(flags))
        }
        if let lastViewed {
            body["last_viewed"] = .number(Double(lastViewed))
        }
        let (data, response) = try await perform(
            "/channels/\(channelID)/messages/\(messageID)/ack",
            method: "POST",
            query: [],
            body: body,
            maximumAttempts: 1
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                authorizationValue = nil
                throw ChatProviderError.unauthenticated
            }
            throw ChatProviderError.transport(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            )
        }
        guard !data.isEmpty else { return ReadAcknowledgementResponse(token: token) }
        return try JSONDecoder().decode(ReadAcknowledgementResponse.self, from: data)
    }

    public func supports(_ capability: ChatCapability) async -> Bool {
        capability == .slashCommands || capability == .forums
    }

    public func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    {
        if let cached = cachedApplicationCommandCatalogs[target] {
            return cached
        }
        if let task = applicationCommandCatalogTasks[target] {
            return try await task.value
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchApplicationCommandCatalog(for: target)
        }
        applicationCommandCatalogTasks[target] = task
        do {
            let catalog = try await task.value
            applicationCommandCatalogTasks[target] = nil
            cachedApplicationCommandCatalogs[target] = catalog
            return catalog
        } catch {
            applicationCommandCatalogTasks[target] = nil
            throw error
        }
    }

    public func requestApplicationCommandAutocomplete(
        _ request: ApplicationCommandAutocompleteRequest
    ) async throws {
        let payload = try ApplicationCommandPayloadBuilder.autocomplete(request)
        guard
            let focused = request.invocation.command.options.first(where: {
                $0.id == request.focusedOptionID
            })
        else {
            throw ChatProviderError.invalidRequest(
                "The focused autocomplete option is unavailable.")
        }
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for command autocomplete."
            )
        }
        var body: [String: JSONValue] = [
            "type": .number(4),
            "application_id": .string(request.invocation.command.applicationID),
            "channel_id": .string(request.invocation.channelID.description),
            "session_id": .string(sessionID),
            "data": .object(payload.data),
            "nonce": .string(request.nonce),
        ]
        if let guildID = request.invocation.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        pendingAutocompleteTypes[request.nonce] = focused.type
        autocompleteTimeoutTasks[request.nonce]?.cancel()
        do {
            let (_, response) = try await perform(
                "/interactions", method: "POST", query: [], body: body
            )
            guard response.statusCode == 204 else {
                pendingAutocompleteTypes[request.nonce] = nil
                throw interactionTransportError(response)
            }
        } catch {
            pendingAutocompleteTypes[request.nonce] = nil
            throw error
        }
        autocompleteTimeoutTasks[request.nonce] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.expireAutocomplete(nonce: request.nonce)
        }
    }

    public func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws {
        progress(.preparing)
        var payload = try ApplicationCommandPayloadBuilder.execution(invocation)
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for application commands.")
        }
        if !payload.attachmentURLs.isEmpty {
            let descriptors = try await uploadAttachments(
                payload.attachmentURLs,
                channelID: invocation.channelID
            ) { state in
                switch state {
                case .reserving(let files): progress(.reserving(files: files))
                case .uploading(let fileName, let completed, let total):
                    progress(.uploading(fileName: fileName, completed: completed, total: total))
                default: break
                }
            }
            payload.data["attachments"] = .array(descriptors)
        }
        var body: [String: JSONValue] = [
            "type": .number(2),
            "application_id": .string(invocation.command.applicationID),
            "channel_id": .string(invocation.channelID.description),
            "session_id": .string(sessionID),
            "data": .object(payload.data),
            "nonce": .string(invocation.nonce),
            "analytics_location": .string("slash_ui"),
        ]
        if let guildID = invocation.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        progress(.submitting(nonce: invocation.nonce))
        let (_, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        guard response.statusCode == 204 else {
            throw interactionTransportError(response)
        }
        progress(.awaitingResponse(nonce: invocation.nonce))
    }

    public func submitModal(_ submission: ModalSubmission, nonce: String) async throws {
        guard let context = pendingModalContexts[nonce] else {
            throw ChatProviderError.invalidRequest("The interaction form is no longer active.")
        }
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for interaction forms.")
        }
        let orderedFileKeys = submission.fileURLs.keys.sorted()
        var attachmentIDsByCustomID: [String: [String]] = [:]
        var allFiles: [URL] = []
        for key in orderedFileKeys {
            let urls = submission.fileURLs[key] ?? []
            attachmentIDsByCustomID[key] = (allFiles.count ..< allFiles.count + urls.count).map(
                String.init)
            allFiles.append(contentsOf: urls)
        }
        var descriptors: [JSONValue] = []
        if !allFiles.isEmpty {
            guard let channelID = ChannelID(context.channelID) else {
                throw ChatProviderError.invalidRequest("The interaction form has no valid channel.")
            }
            descriptors = try await uploadAttachments(
                allFiles, channelID: channelID, progress: { _ in }
            )
        }
        var data: [String: JSONValue] = [
            "custom_id": .string(submission.customID),
            "components": .array(
                context.modal.controls.map {
                    modalResponse(
                        $0, values: submission.values, attachmentIDs: attachmentIDsByCustomID)
                }),
        ]
        if !descriptors.isEmpty {
            data["resolved"] = .object([
                "attachments": .object(
                    Dictionary(
                        uniqueKeysWithValues: descriptors.enumerated().map {
                            (String($0.offset), $0.element)
                        })
                )
            ])
        }
        var body: [String: JSONValue] = [
            "type": .number(5),
            "application_id": .string(context.applicationID),
            "channel_id": .string(context.channelID),
            "session_id": .string(sessionID),
            "data": .object(data),
            "nonce": .string(nonce),
        ]
        if let guildID = context.guildID { body["guild_id"] = .string(guildID) }
        let (_, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        guard response.statusCode == 204 else { throw interactionTransportError(response) }
        pendingModalContexts[nonce] = nil
    }

    private func fetchApplicationCommandCatalog(for target: ApplicationCommandIndexTarget)
        async throws
        -> ApplicationCommandCatalog
    {
        let path: String =
            switch target {
            case .guild(let id): "/guilds/\(id)/application-command-index"
            case .channel(let id): "/channels/\(id)/application-command-index"
            case .user: "/users/@me/application-command-index"
            case .application(let id): "/applications/\(id)/application-command-index"
            }
        for attempt in 0 ..< 3 {
            let (data, response) = try await perform(
                path, method: "GET", query: [], body: nil, maximumAttempts: 1
            )
            if response.statusCode == 202 {
                guard attempt < 2 else {
                    throw ChatProviderError.transport(
                        status: 202,
                        requestID: response.value(forHTTPHeaderField: "x-request-id")
                    )
                }
                try await Task.sleep(for: .seconds(5))
                continue
            }
            if response.statusCode == 429 {
                guard attempt < 2 else { throw interactionTransportError(response) }
                let delay = Self.retryAfter(from: data, response: response)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                throw interactionTransportError(response)
            }
            return try ApplicationCommandIndexDecoder.decode(data, target: target)
        }
        throw ChatProviderError.invalidRequest(
            "Discord's application command index did not become ready.")
    }

    private func expireAutocomplete(nonce: String) {
        guard pendingAutocompleteTypes.removeValue(forKey: nonce) != nil else { return }
        autocompleteTimeoutTasks[nonce] = nil
        continuation?.yield(
            .interaction(.failed(nonce: nonce, message: "Command autocomplete timed out."))
        )
    }

    private func interactionTransportError(_ response: HTTPURLResponse) -> ChatProviderError {
        if response.statusCode == 401 {
            return .unauthenticated
        }
        return .transport(
            status: response.statusCode,
            requestID: response.value(forHTTPHeaderField: "x-request-id")
        )
    }

    private func modalResponse(
        _ control: ModalControl,
        values: [String: [String]],
        attachmentIDs: [String: [String]]
    ) -> JSONValue {
        switch control {
        case .label(_, _, _, let child):
            return .object([
                "type": .number(18),
                "component": modalResponse(
                    child, values: values, attachmentIDs: attachmentIDs
                ),
            ])
        case .textInput(_, let customID, _, _, _, _, _, _, _):
            return .object([
                "type": .number(4), "custom_id": .string(customID),
                "value": .string(values[customID]?.first ?? ""),
            ])
        case .select(_, let customID, let kind, _, _, _, _):
            return .object([
                "type": .number(Double(kind.rawValue)), "custom_id": .string(customID),
                "values": .array((values[customID] ?? []).map(JSONValue.string)),
            ])
        case .fileUpload(_, let customID, _, _, _):
            return .object([
                "type": .number(19), "custom_id": .string(customID),
                "values": .array((attachmentIDs[customID] ?? []).map(JSONValue.string)),
            ])
        case .radioGroup(_, let customID, _, _):
            return .object([
                "type": .number(21), "custom_id": .string(customID),
                "value": values[customID]?.first.map(JSONValue.string) ?? .null,
            ])
        case .checkboxGroup(_, let customID, _, _, _):
            return .object([
                "type": .number(22), "custom_id": .string(customID),
                "values": .array((values[customID] ?? []).map(JSONValue.string)),
            ])
        case .checkbox(_, let customID, _, _):
            return .object([
                "type": .number(23), "custom_id": .string(customID),
                "value": .bool(values[customID]?.first == "true"),
            ])
        case .unsupported(_, let type):
            return .object(["type": .number(Double(type))])
        }
    }

    public func send(_ draft: SendMessageDraft) async throws -> Message {
        try await send(draft, progress: { _ in })
    }

    public func send(
        _ draft: SendMessageDraft, progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
        guard draft.attachmentURLs.count <= SendMessageDraft.maximumAttachmentCount else {
            throw ChatProviderError.invalidRequest(
                "A message can include at most \(SendMessageDraft.maximumAttachmentCount) attachments."
            )
        }
        let key = "\(draft.channelID):\(draft.nonce)"
        if let task = messageSendTasks[key] {
            let message = try await task.value
            progress(.completed(messageID: message.id))
            return message
        }
        let task = Task { [self] in
            try await performSend(draft, progress: progress)
        }
        messageSendTasks[key] = task
        do {
            let message = try await task.value
            messageSendTasks[key] = nil
            return message
        } catch {
            messageSendTasks[key] = nil
            throw error
        }
    }

    private func performSend(
        _ draft: SendMessageDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
        progress(.preparing)
        var body: [String: JSONValue] = [
            "content": .string(draft.content),
            "nonce": .string(draft.nonce),
            "enforce_nonce": .bool(true),
            "attachments": .array([]),
        ]
        if let replyTo = draft.replyTo {
            body["message_reference"] = .object([
                "type": .number(0),
                "message_id": .string(replyTo.description),
                "channel_id": .string(draft.channelID.description),
            ])
        }
        if !draft.attachmentURLs.isEmpty {
            body["attachments"] = try await .array(
                uploadForumAttachments(
                    draft.attachments, channelID: draft.channelID, progress: progress)
            )
        }
        progress(.submitting)
        let dto: MessageDTO = try await request(
            "/channels/\(draft.channelID)/messages",
            method: "POST",
            body: body,
            headers: ["X-Context-Properties": DiscordClientMetadata.messageContextHeader]
        )
        var message = try dto.domain()
        message.nonce = draft.nonce
        cachedMessages[message.id] = message
        continuation?.yield(.messageCreated(message))
        progress(.completed(messageID: message.id))
        return message
    }

    private func uploadAttachments(
        _ urls: [URL], channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        try await uploadAttachmentFiles(
            urls.map { AttachmentUploadFile(url: $0, name: $0.lastPathComponent) },
            channelID: channelID,
            progress: progress
        )
    }

    private func uploadForumAttachments(
        _ attachments: [ForumPostAttachment],
        channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        try await uploadAttachmentFiles(
            attachments.map(Self.forumUploadFile),
            channelID: channelID,
            progress: progress
        )
    }

    nonisolated static func forumUploadFile(
        _ attachment: ForumPostAttachment
    ) -> AttachmentUploadFile {
        let chosenName = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = chosenName.isEmpty ? attachment.url.lastPathComponent : chosenName
        let name =
            attachment.isSpoiler && !original.hasPrefix("SPOILER_")
                ? "SPOILER_\(original)" : original
        let description = attachment.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachmentUploadFile(
            url: attachment.url,
            name: name,
            description: description.isEmpty ? nil : description
        )
    }

    nonisolated static func uploadedAttachmentPayload(
        id: Int,
        file: AttachmentUploadFile,
        uploadFilename: String
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string(String(id)),
            "filename": .string(file.name),
            "uploaded_filename": .string(uploadFilename),
        ]
        if let description = file.description {
            payload["description"] = .string(description)
        }
        return .object(payload)
    }

    private func uploadAttachmentFiles(
        _ files: [AttachmentUploadFile],
        channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        var descriptors: [JSONValue] = []
        for (index, file) in files.enumerated() {
            let url = file.url
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            descriptors.append(
                .object([
                    "filename": .string(file.name),
                    "file_size": .number(Double(size)),
                    "id": .string(String(index)),
                    "is_clip": .bool(false),
                ])
            )
        }

        progress(.reserving(files: files.count))
        let reservation: AttachmentReservationDTO = try await request(
            "/channels/\(channelID)/attachments",
            method: "POST",
            body: ["files": .array(descriptors)]
        )
        guard reservation.attachments.count == files.count else {
            throw ChatProviderError.invalidRequest(
                "Discord did not reserve every selected attachment.")
        }

        var uploaded: [JSONValue] = []
        for pair in zip(files, reservation.attachments) {
            let (file, slot) = pair
            let fileURL = file.url
            guard let uploadURL = URL(string: slot.uploadURL) else {
                throw ChatProviderError.invalidRequest(
                    "Discord returned an invalid attachment upload URL.")
            }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "PUT"
            uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let total =
                ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size])
                        as? NSNumber)?
                    .int64Value ?? 0
            progress(.uploading(fileName: file.name, completed: 0, total: total))
            let (_, rawResponse) = try await session.upload(for: uploadRequest, fromFile: fileURL)
            guard let response = rawResponse as? HTTPURLResponse,
                  (200 ..< 300).contains(response.statusCode)
            else {
                throw ChatProviderError.invalidRequest(
                    "Discord's attachment storage rejected \(file.name)."
                )
            }
            progress(.uploading(fileName: file.name, completed: total, total: total))
            uploaded.append(
                Self.uploadedAttachmentPayload(
                    id: slot.id,
                    file: file,
                    uploadFilename: slot.uploadFilename
                )
            )
        }
        return uploaded
    }

    public func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws
        -> Message
    {
        let dto: MessageDTO = try await request(
            "/channels/\(channelID)/messages/\(messageID)", method: "PATCH",
            body: ["content": .string(content)]
        )
        let message = try dto.domain()
        cachedMessages[message.id] = message
        continuation?.yield(.messageUpdated(message))
        return message
    }

    public func delete(messageID: MessageID, channelID: ChannelID) async throws {
        try await requestEmpty("/channels/\(channelID)/messages/\(messageID)", method: "DELETE")
        cachedMessages[messageID] = nil
        continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
    }

    public func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID)
        async throws
    {
        guard let message = cachedMessages[messageID] else {
            throw ChatProviderError.messageNotFound
        }
        let apiEmoji = Self.reactionAPIValue(emoji)
        let existing = message.reactions.firstIndex { Self.reactionAPIValue($0.emoji) == apiEmoji }
        let reacted = existing.map { message.reactions[$0].didCurrentUserReact } ?? false
        try await setReaction(
            emoji,
            reacted: !reacted,
            messageID: messageID,
            channelID: channelID
        )
    }

    public func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        guard let message = cachedMessages[messageID] else {
            throw ChatProviderError.messageNotFound
        }
        let apiEmoji = Self.reactionAPIValue(emoji)
        let currentReaction = message.reactions.first {
            Self.reactionAPIValue($0.emoji) == apiEmoji
        }
        guard currentReaction?.didCurrentUserReact != reacted else { return }
        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let method = reacted ? "PUT" : "DELETE"
        try await requestEmpty(
            "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)/@me", method: method
        )
        guard let currentUserID = currentUser?.id,
              var updated = cachedMessages[messageID]
        else { return }
        let reactionUpdate: MessageReactionUpdate =
            reacted
            ? .add(
                channelID: channelID,
                messageID: messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
            : .remove(
                channelID: channelID,
                messageID: messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
        guard updated.applyReactionUpdate(reactionUpdate, currentUserID: currentUserID) else {
            return
        }
        cachedMessages[messageID] = updated
        continuation?.yield(.messageUpdated(updated))
        updateForumPostForMessage(updated)
    }

    public func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        guard reactionCount > 0 else { return [] }
        let apiEmoji = Self.reactionAPIValue(emoji)
        let key = ReactionReactorCacheKey(
            channelID: channelID,
            messageID: messageID,
            emojiIdentity: Reaction(emoji: emoji, count: reactionCount).id,
            reactionCount: reactionCount
        )
        if let cached = cachedReactionReactors[key] {
            return cached
        }
        if let task = reactionReactorTasks[key] {
            return try await task.value
        }
        guard reactionReactorTasks.count < Self.maximumConcurrentReactionReactorReads else {
            throw ChatProviderError.invalidRequest(
                "Too many reaction details are already loading. Hover this reaction again shortly."
            )
        }

        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let task = Task { [self] in
            let users: [UserDTO] = try await request(
                "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)",
                query: [
                    URLQueryItem(name: "type", value: "0"),
                    URLQueryItem(
                        name: "limit",
                        value: String(Self.reactionReactorFetchLimit)
                    ),
                ]
            )
            return try users.map { ReactionReactor(user: try $0.domain()) }
        }
        reactionReactorTasks[key] = task
        do {
            let reactors = try await task.value
            reactionReactorTasks[key] = nil
            cacheReactionReactors(reactors, for: key)
            return reactors
        } catch {
            reactionReactorTasks[key] = nil
            throw error
        }
    }

    private func cacheReactionReactors(
        _ reactors: [ReactionReactor],
        for key: ReactionReactorCacheKey
    ) {
        cachedReactionReactors[key] = reactors
        reactionReactorCacheOrder.removeAll { $0 == key }
        reactionReactorCacheOrder.append(key)
        while reactionReactorCacheOrder.count > Self.maximumReactionReactorCacheEntries {
            let evicted = reactionReactorCacheOrder.removeFirst()
            cachedReactionReactors[evicted] = nil
        }
    }

    private static func reactionAPIValue(_ emoji: String) -> String {
        guard emoji.hasPrefix("<"), emoji.hasSuffix(">") else { return emoji }
        let value = emoji.dropFirst().dropLast()
        let withoutAnimationPrefix = value.hasPrefix("a:") ? value.dropFirst(2) : value.dropFirst(1)
        return String(withoutAnimationPrefix)
    }

    public func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        guard gatewayReady, let userID = currentUser?.id else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for a voice connection.")
        }
        let negotiationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let pendingVoiceNegotiation {
                    pendingVoiceNegotiation.continuation.resume(
                        throwing: ChatProviderError.invalidRequest(
                            "A newer voice connection replaced this request."
                        )
                    )
                }
                pendingVoiceNegotiation = PendingVoiceNegotiation(
                    id: negotiationID,
                    channelID: channelID,
                    guildID: guildID,
                    userID: userID,
                    selfMute: selfMute,
                    selfDeaf: selfDeaf,
                    continuation: continuation
                )
                voiceNegotiationTimeoutTask?.cancel()
                voiceNegotiationTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.failVoiceNegotiation(
                        id: negotiationID,
                        error: ChatProviderError.invalidRequest(
                            "Discord did not finish voice negotiation in time."
                        )
                    )
                }
                Task { [weak self] in
                    do {
                        try await self?.sendVoiceState(
                            channelID: channelID,
                            guildID: guildID,
                            selfMute: selfMute,
                            selfDeaf: selfDeaf,
                            selfVideo: false
                        )
                    } catch {
                        await self?.failVoiceNegotiation(id: negotiationID, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failVoiceNegotiation(id: negotiationID, error: CancellationError()) }
        }
    }

    public func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        try await sendVoiceState(
            channelID: channelID,
            guildID: guildID,
            selfMute: selfMute,
            selfDeaf: selfDeaf,
            selfVideo: selfVideo
        )
        if channelID == nil {
            activeVoiceConnection = nil
        }
    }

    private func sendVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        try await sendGateway(
            DiscordGatewayPayloadFactory.voiceStateUpdate(
                guildID: guildID,
                channelID: channelID,
                selfMute: selfMute,
                selfDeaf: selfDeaf,
                selfVideo: selfVideo
            )
        )
    }

    public func eventStream() async -> AsyncStream<ClientEvent> {
        let stream = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        continuation = stream.continuation
        return stream.stream
    }

    public func disconnect() async {
        requestSafetyCircuitIsOpen = true
        failInitialGatewaySnapshot(CancellationError())
        initialGatewaySnapshot = nil
        for task in forumCatalogueTasks.values {
            task.cancel()
        }
        forumCatalogueTasks = [:]
        forumCatalogueTaskIDs = [:]
        for task in messageSendTasks.values {
            task.cancel()
        }
        messageSendTasks = [:]
        for task in forumPreviewHydrationTasks.values {
            task.cancel()
        }
        forumPreviewHydrationTasks = [:]
        forumPreviewHydrationTaskIDs = [:]
        forumPreviewHydrationQueues = [:]
        for task in applicationCommandCatalogTasks.values {
            task.cancel()
        }
        applicationCommandCatalogTasks = [:]
        cachedApplicationCommandCatalogs = [:]
        for task in autocompleteTimeoutTasks.values {
            task.cancel()
        }
        autocompleteTimeoutTasks = [:]
        pendingAutocompleteTypes = [:]
        pendingModalContexts = [:]
        for request in pendingMemberSearchRequests.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CancellationError())
        }
        pendingMemberSearchRequests = [:]
        pendingMemberSearchRequestByGuild = [:]
        voiceNegotiationTimeoutTask?.cancel()
        if let pendingVoiceNegotiation {
            pendingVoiceNegotiation.continuation.resume(throwing: CancellationError())
            self.pendingVoiceNegotiation = nil
        }
        activeVoiceConnection = nil
        gatewayEventTask?.cancel()
        gatewayEventTask = nil
        await gatewaySession?.stop()
        gatewaySession = nil
        gatewayReady = false
        session.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
        continuation?.yield(.connectionChanged(.disconnected))
        continuation?.finish()
        continuation = nil
        authorizationValue = nil
    }

    #if DEBUG
        func seedForumChannelForTesting(
            _ channel: Channel,
            posts: [ForumPost] = [],
            currentUser: User? = nil
        ) {
            cachedChannels[channel.guildID, default: []].removeAll { $0.id == channel.id }
            cachedChannels[channel.guildID, default: []].append(channel)
            cachedForumPosts[channel.id] = Dictionary(
                uniqueKeysWithValues: posts.map { ($0.id, $0) }
            )
            for post in posts {
                cacheForumPreviewMessages(post)
            }
            if let currentUser {
                self.currentUser = currentUser
            }
        }

        func seedPrivateChannelsForTesting(
            _ channels: [Channel],
            currentUser: User? = nil
        ) {
            cachedChannels[nil] = channels
            if let currentUser {
                self.currentUser = currentUser
            }
        }

        func activeForumCatalogueQueriesForTesting(channelID: ChannelID) -> [ForumPostQuery] {
            forumCatalogueTasks.keys.compactMap {
                $0.channelID == channelID ? $0.query : nil
            }
        }

        func suspendForumCatalogueRefreshForTesting() {
            suspendsForumCatalogueRefreshForTesting = true
        }

        func receiveForumMessageForTesting(_ message: Message, marksUnread: Bool = true) {
            updateForumPostForMessage(message, marksUnread: marksUnread)
        }

        func receiveGatewayReactionForTesting(_ update: MessageReactionUpdate) {
            applyGatewayReactionUpdate(update)
        }

        func receiveGatewayDispatchForTesting(name: String, data: JSONValue) async {
            guard let encoded = try? JSONEncoder().encode(data),
                  let body = try? JSONSerialization.jsonObject(with: encoded)
            else { return }
            await handleGatewayDispatch(name: name, body: body)
        }

        func cachedChannelForTesting(channelID: ChannelID) -> Channel? {
            cachedChannels.values.lazy.flatMap { $0 }.first { $0.id == channelID }
        }

        func cachedPrivateChannelsForTesting() -> [Channel] {
            cachedChannels[nil] ?? []
        }

        func cachedForumPostForTesting(threadID: ChannelID) -> ForumPost? {
            cachedForumPosts.values.lazy.compactMap { $0[threadID] }.first
        }

        func cachedMessageForTesting(messageID: MessageID) -> Message? {
            cachedMessages[messageID]
        }
    #endif

    private func startGateway() async throws {
        guard gatewaySession == nil else { return }
        let token = try await authorizationToken()
        let identifyData = try JSONEncoder().encode(
            GatewayEnvelope(
                op: 2,
                data: .object([
                    "token": .string(token),
                    "capabilities": .number(
                        Double(DiscordProductionBaseline.july2026.defaultCapabilities)),
                    "properties": .object(clientMetadata.properties),
                    "presence": .object([
                        "status": .string(presenceStatus.rawValue),
                        "since": .number(0),
                        "activities": .array([]),
                        "afk": .bool(false),
                    ]),
                    "compress": .bool(false),
                    "client_state": .object(["guild_versions": .object([:])]),
                ])
            )
        )
        guard let gatewayURL = URL(string: "wss://gateway.discord.gg") else {
            throw ChatProviderError.invalidRequest("Discord's Gateway URL is invalid.")
        }
        let gateway = GatewaySession(
            configuration: GatewaySession.Configuration(
                gatewayURL: gatewayURL,
                identifyPayload: identifyData,
                token: token
            ),
            transport: gatewayTransport
        )
        gatewaySession = gateway
        gatewayEventTask = Task { [weak self, events = gateway.events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleGatewaySessionEvent(event)
            }
        }
        await gateway.connect()
    }

    private func handleGatewaySessionEvent(_ event: GatewaySessionEvent) async {
        switch event {
        case .stateChanged(let connectionState):
            gatewayReady = connectionState == .ready
            if connectionState == .authenticationFailed {
                failInitialGatewaySnapshot(ChatProviderError.unauthenticated)
                await openSafetyCircuit(
                    status: 401, discordCode: nil, route: "GATEWAY IDENTIFY/RESUME")
                return
            }
            continuation?.yield(.connectionChanged(connectionState))
            if connectionState == .ready {
                gatewayLogger.info("Gateway session ready")
                if let pendingMemberGuildID {
                    await attemptMemberSubscription(guildID: pendingMemberGuildID)
                }
            }
        case .dispatch(let name, let value):
            guard let data = try? JSONEncoder().encode(value),
                  let body = try? JSONSerialization.jsonObject(with: data)
            else { return }
            await handleGatewayDispatch(name: name, body: body)
        }
    }

    private func subscribeToMemberList(guildID: GuildID) async throws {
        let channel = cachedChannels[guildID]?.first(where: { $0.kind != .voice })
        try await sendGateway(
            DiscordGatewayPayloadFactory.guildSubscriptions(
                guildID: guildID,
                channelID: channel?.id
            )
        )
        gatewayLogger.info("Sent current bulk guild subscription with member-list range")
    }

    private func attemptMemberSubscription(guildID: GuildID) async {
        do { try await subscribeToMemberList(guildID: guildID) } catch {
            gatewayLogger.error(
                "Lazy member-list subscription failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendGateway(_ payload: [String: Any]) async throws {
        guard let gatewaySession else {
            throw ChatProviderError.invalidRequest("Discord Gateway is not connected yet.")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await gatewaySession.send(data)
    }

    private func requestMembersByID(_ userIDs: [UserID], guildID: GuildID) async throws {
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to resolve role members.")
        }
        for batch in userIDs.chunked(into: 100) {
            let nonce = UUID().uuidString.lowercased()
            let members = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[Member], any Error>) in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    await self?.timeoutRoleMemberRequest(nonce: nonce)
                }
                pendingRoleMemberRequests[nonce] = PendingRoleMemberRequest(
                    guildID: guildID,
                    members: [],
                    receivedChunks: [],
                    continuation: continuation,
                    timeoutTask: timeout
                )
                Task { [weak self] in
                    do {
                        try await self?.sendGateway(
                            DiscordGatewayPayloadFactory.requestMembers(
                                guildID: guildID,
                                userIDs: batch,
                                nonce: nonce
                            )
                        )
                    } catch {
                        await self?.failRoleMemberRequest(nonce: nonce, error: error)
                    }
                }
            }
            mergeResolvedMembers(members, guildID: guildID)
        }
    }

    private func mergeResolvedMembers(_ members: [Member], guildID: GuildID) {
        cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
            existing: cachedMembers[guildID] ?? [], updates: members
        )
    }

    private func timeoutRoleMemberRequest(nonce: String) {
        guard let request = pendingRoleMemberRequests.removeValue(forKey: nonce) else { return }
        request.continuation.resume(
            throwing: ChatProviderError.invalidRequest(
                "Discord did not finish resolving role members.")
        )
    }

    private func timeoutMemberSearchRequest(requestID: String) {
        guard let request = removeMemberSearchRequest(requestID: requestID) else { return }
        gatewayLogger.warning("Member autocomplete Gateway request timed out")
        request.continuation.resume(
            throwing: ChatProviderError.invalidRequest(
                "Discord did not finish searching guild members.")
        )
    }

    private func failMemberSearchRequest(requestID: String, error: any Error) {
        guard let request = removeMemberSearchRequest(requestID: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func removeMemberSearchRequest(requestID: String) -> PendingMemberSearchRequest? {
        guard let request = pendingMemberSearchRequests.removeValue(forKey: requestID) else {
            return nil
        }
        if pendingMemberSearchRequestByGuild[request.guildID] == requestID {
            pendingMemberSearchRequestByGuild[request.guildID] = nil
        }
        return request
    }

    private func failRoleMemberRequest(nonce: String, error: any Error) {
        guard let request = pendingRoleMemberRequests.removeValue(forKey: nonce) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func publishEmojiCollection(
        _ collection: GatewayGuildEmojiCollectionDTO,
        guildID: GuildID
    ) {
        switch collection.content {
        case .snapshot(let emojis):
            continuation?.yield(
                .emojisChanged(
                    guildID: guildID,
                    emojis: emojis.compactMap { $0.domain(guildID: guildID) }
                )
            )
        case .update(let writes, let deletes):
            continuation?.yield(
                .emojisUpdated(
                    guildID: guildID,
                    upserted: writes.compactMap { $0.domain(guildID: guildID) },
                    deletedIDs: deletes
                )
            )
        }
    }

    private func applyGuildRulesChannelID(_ rawRulesChannelID: String?, guildID: GuildID) {
        guard var guild = cachedGuilds[guildID] else { return }
        let rulesChannelID = rawRulesChannelID.flatMap(ChannelID.init)
        guard guild.rulesChannelID != rulesChannelID else { return }
        guild.rulesChannelID = rulesChannelID
        cachedGuilds[guildID] = guild
        continuation?.yield(.guildChanged(guild))
    }

    private func handleGatewayDispatch(name: String, body: Any) async {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return }
        switch name {
        case "READY", "RESUMED":
            if name == "READY",
               let ready = try? JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
            {
                cachedMembers = [:]
                cachedPrivateMembersByID = [:]
                cachedGatewayUsersByID = Dictionary(
                    ready.users.map { ($0.id, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                forumReadStates = ready.readState.channelEntriesByID.mapValues { entry in
                    ForumReadState(
                        lastReadMessageID: entry.lastMessageID.flatMap(MessageID.init),
                        mentionCount: entry.mentionCount ?? 0
                    )
                }
                let readyReadStates: [ChannelReadState] =
                    ready.readState.channelEntriesByID.map { channelID, entry in
                        ChannelReadState(
                            channelID: channelID,
                            lastAcknowledgedMessageID: entry.lastMessageID.flatMap(MessageID.init),
                            mentionCount: entry.mentionCount ?? 0,
                            flags: entry.flags,
                            lastViewed: entry.lastViewed
                        )
                    }
                    .sorted { $0.channelID.rawValue < $1.channelID.rawValue }
                let readyNotificationSettings = ready.userGuildSettings.map(\.domain)
                let guildAllUnreadSettingCount = readyNotificationSettings.count {
                    $0.flags & (1 << 11) != 0
                }
                let guildMentionOnlyUnreadSettingCount = readyNotificationSettings.count {
                    $0.flags & (1 << 12) != 0
                }
                let guildOptInCount = readyNotificationSettings.count {
                    $0.flags & (1 << 14) != 0
                }
                let channelOverrides = readyNotificationSettings.flatMap(\.channelOverrides)
                let channelAllUnreadSettingCount = channelOverrides.count {
                    $0.flags & (1 << 10) != 0
                }
                let channelMentionOnlyUnreadSettingCount = channelOverrides.count {
                    $0.flags & (1 << 9) != 0
                }
                let channelOptInCount = channelOverrides.count {
                    $0.flags & (1 << 12) != 0
                }
                gatewayLogger.info(
                    """
                    Ready unread metadata decoded; readStates=\(readyReadStates.count), \
                    guildSettings=\(readyNotificationSettings.count), \
                    guildSettingsPartial=\(ready.userGuildSettingsPartial), \
                    newNotifications=\(ready.usesNewNotifications), \
                    guildAll=\(guildAllUnreadSettingCount), \
                    guildMentions=\(guildMentionOnlyUnreadSettingCount), \
                    guildOptIn=\(guildOptInCount), \
                    channelOverrides=\(channelOverrides.count), \
                    channelAll=\(channelAllUnreadSettingCount), \
                    channelMentions=\(channelMentionOnlyUnreadSettingCount), \
                    channelOptIn=\(channelOptInCount)
                    """
                )
                continuation?.yield(
                    .notificationModeChanged(
                        usesNewNotifications: ready.usesNewNotifications
                    )
                )
                continuation?.yield(
                    .readStateSnapshot(readyReadStates)
                )
                for settings in readyNotificationSettings {
                    continuation?.yield(.notificationSettingsChanged(settings))
                }
                let privateChannels = Self.orderedPrivateChannels(
                    ready.privateChannels.compactMap {
                        try? $0.domain(
                            guildID: nil,
                            knownUsersByID: cachedGatewayUsersByID
                        )
                    }
                )
                cachedChannels[nil] = privateChannels
                for presence in ready.privatePresences {
                    cachePrivatePresence(presence)
                }
                continuation?.yield(
                    .channelsChanged(guildID: nil, channels: privateChannels)
                )
                continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
                let readyGuilds = ready.hydratedGuilds(using: cachedGatewayUsersByID)
                gatewayGuildIDs = readyGuilds.compactMap { GuildID($0.id) }
                var voiceStateCount = 0
                for guild in readyGuilds {
                    let guildID = GuildID(guild.id)
                    if let guildID {
                        applyGuildRulesChannelID(guild.rulesChannelID, guildID: guildID)
                    }
                    if let guildID, !guild.channels.isEmpty,
                       let channels = try? Self.domainChannels(guild.channels, guildID: guildID)
                    {
                        cachedChannels[guildID] = channels
                        continuation?.yield(.channelsChanged(guildID: guildID, channels: channels))
                    }
                    if let guildID, !guild.roles.isEmpty {
                        cachedGuildRoles[guildID] = guild.roles
                    }
                    if !guild.threads.isEmpty {
                        ingestForumThreads(
                            guild.threads,
                            fallbackGuildID: guildID,
                            advancesParentLatestThreadID: true
                        )
                    }
                    if let guildID, !guild.members.isEmpty {
                        let members = guild.members.compactMap {
                            try? $0.domain(
                                currentUserID: currentUser?.id,
                                currentStatus: presenceStatus,
                                guildRoles: cachedGuildRoles[guildID] ?? [],
                                guildID: guildID
                            )
                        }
                        cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                            existing: cachedMembers[guildID] ?? [], updates: members
                        )
                        if let currentUserID = currentUser?.id,
                           let currentMember = members.first(where: { $0.id == currentUserID })
                        {
                            continuation?.yield(
                                .currentUserRolesChanged(
                                    guildID: guildID,
                                    roleIDs: currentMember.roles.map(\.id)
                                )
                            )
                        }
                    }
                    if let guildID, let emojis = guild.emojis {
                        publishEmojiCollection(emojis, guildID: guildID)
                    }
                    for state in guild.voiceStates {
                        guard let participant = state.domain(defaultGuildID: guildID) else {
                            continue
                        }
                        voiceStateCount += 1
                        continuation?.yield(.voiceStateChanged(participant))
                    }
                }
                if voiceStateCount > 0 {
                    gatewayLogger.info(
                        "Ready voice-state snapshot received; count=\(voiceStateCount)")
                }
                applyGuildSettingsProto(ready.userSettingsProto)
                finishInitialGatewaySnapshot(
                    InitialGatewaySnapshot(
                        readStates: readyReadStates,
                        notificationSettings: readyNotificationSettings,
                        usesNewNotifications: ready.usesNewNotifications
                    )
                )
            } else if name == "READY" {
                failInitialGatewaySnapshot(
                    ChatProviderError.invalidRequest(
                        "Discord's initial Gateway state could not be decoded."
                    )
                )
            }
        case "USER_SETTINGS_PROTO_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayUserSettingsProtoUpdateDTO.self,
                    from: data
                ), update.settings.type == 1
            else { return }
            applyGuildSettingsProto(
                update.settings.proto,
                replacesAllSettings: update.partial != true
            )
        case "USER_GUILD_SETTINGS_UPDATE":
            guard let update = try? JSONDecoder().decode(
                GatewayUserGuildSettingsDTO.self, from: data
            ) else { return }
            continuation?.yield(.notificationSettingsChanged(update.domain))
        case "READY_SUPPLEMENTAL":
            if let supplemental = try? JSONDecoder().decode(
                GatewayReadyGuildsDTO.self, from: data
            ) {
                for user in supplemental.users {
                    cachedGatewayUsersByID[user.id] = user
                }
                for presence in supplemental.privatePresences {
                    cachePrivatePresence(presence)
                }
                if !supplemental.lazyPrivateChannels.isEmpty {
                    var channelsByID = Dictionary(
                        (cachedChannels[nil] ?? []).map { ($0.id, $0) },
                        uniquingKeysWith: { _, newer in newer }
                    )
                    for channel in supplemental.lazyPrivateChannels.compactMap({
                        try? $0.domain(
                            guildID: nil,
                            knownUsersByID: cachedGatewayUsersByID
                        )
                    }) {
                        channelsByID[channel.id] = channel
                    }
                    let channels = Self.orderedPrivateChannels(
                        Array(channelsByID.values)
                    )
                    cachedChannels[nil] = channels
                    continuation?.yield(
                        .channelsChanged(guildID: nil, channels: channels)
                    )
                }
                if !supplemental.lazyPrivateChannels.isEmpty
                    || !supplemental.privatePresences.isEmpty
                {
                    continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
                }
                for guild in supplemental.hydratedGuilds(using: cachedGatewayUsersByID) {
                    guard let guildID = GuildID(guild.id), !guild.members.isEmpty else { continue }
                    let members = guild.members.compactMap {
                        try? $0.domain(
                            currentUserID: currentUser?.id,
                            currentStatus: presenceStatus,
                            guildRoles: cachedGuildRoles[guildID] ?? [],
                            guildID: guildID
                        )
                    }
                    cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                        existing: cachedMembers[guildID] ?? [], updates: members
                    )
                }
            }
            let states = ReadySupplementalVoiceStateResolver.resolve(
                data: data,
                gatewayGuildIDs: gatewayGuildIDs
            )
            for state in states {
                continuation?.yield(.voiceStateChanged(state))
            }
            gatewayLogger.info("Supplemental voice-state snapshot received; count=\(states.count)")
        case "GUILD_CREATE":
            if let catalog = try? JSONDecoder().decode(GatewayGuildCatalogDTO.self, from: data),
               let guildID = GuildID(catalog.id)
            {
                applyGuildRulesChannelID(catalog.rulesChannelID, guildID: guildID)
                if !catalog.channels.isEmpty,
                   let channels = try? Self.domainChannels(catalog.channels, guildID: guildID)
                {
                    cachedChannels[guildID] = channels
                    continuation?.yield(.channelsChanged(guildID: guildID, channels: channels))
                }
                if !catalog.roles.isEmpty { cachedGuildRoles[guildID] = catalog.roles }
                if !catalog.threads.isEmpty {
                    ingestForumThreads(
                        catalog.threads,
                        fallbackGuildID: guildID,
                        advancesParentLatestThreadID: true
                    )
                }
                if !catalog.members.isEmpty {
                    let members = catalog.members.compactMap {
                        try? $0.domain(
                            currentUserID: currentUser?.id,
                            currentStatus: presenceStatus,
                            guildRoles: cachedGuildRoles[guildID] ?? [],
                            guildID: guildID
                        )
                    }
                    cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                        existing: cachedMembers[guildID] ?? [], updates: members
                    )
                }
            }
            if let emojiSnapshot = try? JSONDecoder().decode(
                GatewayGuildEmojiSnapshotDTO.self,
                from: data
            ),
                let guildID = GuildID(emojiSnapshot.id),
                let emojis = emojiSnapshot.emojis
            {
                publishEmojiCollection(emojis, guildID: guildID)
            }
            guard
                let snapshot = try? JSONDecoder().decode(
                    GuildVoiceStateSnapshotDTO.self, from: data)
            else { return }
            let states = snapshot.domainVoiceStates
            gatewayLogger.info(
                "Initial voice-state snapshot received; guild=\(snapshot.id, privacy: .public), count=\(states.count)"
            )
            for state in states {
                continuation?.yield(.voiceStateChanged(state))
            }
        case "GUILD_UPDATE":
            guard
                let metadata = try? JSONDecoder().decode(GatewayGuildMetadataDTO.self, from: data),
                let guildID = GuildID(metadata.id)
            else { return }
            applyGuildRulesChannelID(metadata.rulesChannelID, guildID: guildID)
        case "GUILD_EMOJIS_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayGuildEmojiSnapshotDTO.self,
                    from: data
                ),
                let guildID = GuildID(update.id),
                let emojis = update.emojis
            else { return }
            publishEmojiCollection(emojis, guildID: guildID)
        case "MESSAGE_CREATE":
            if let dto = try? JSONDecoder().decode(MessageDTO.self, from: data),
               let message = try? dto.domain()
            {
                cachedMessages[message.id] = message
                continuation?.yield(.messageCreated(message))
                promotePrivateChannel(
                    channelID: message.channelID,
                    lastMessageID: message.id
                )
                updateForumPostForMessage(message, marksUnread: true)
            }
        case "THREAD_CREATE":
            guard let dto = try? JSONDecoder().decode(ChannelDTO.self, from: data) else { return }
            ingestForumThreads(
                [dto],
                fallbackGuildID: dto.guildID.flatMap(GuildID.init),
                advancesParentLatestThreadID: true
            )
        case "THREAD_UPDATE":
            guard let dto = try? JSONDecoder().decode(ChannelDTO.self, from: data) else { return }
            ingestForumThreads([dto], fallbackGuildID: dto.guildID.flatMap(GuildID.init))
        case "THREAD_DELETE":
            guard let deleted = try? JSONDecoder().decode(GatewayThreadDeleteDTO.self, from: data),
                  let threadID = ChannelID(deleted.id),
                  let parentID = deleted.parentID.flatMap(ChannelID.init)
            else { return }
            cachedForumPosts[parentID]?[threadID] = nil
            publishForumPosts(parentID: parentID)
        case "THREAD_LIST_SYNC":
            guard let sync = try? JSONDecoder().decode(GatewayThreadListSyncDTO.self, from: data),
                  let guildID = GuildID(sync.guildID)
            else { return }
            let parents = Set(sync.channelIDs.compactMap(ChannelID.init))
            ingestForumThreads(
                sync.threads, fallbackGuildID: guildID,
                replacingParents: parents.isEmpty ? nil : parents,
                advancesParentLatestThreadID: true
            )
        case "MESSAGE_ACK":
            guard let ack = try? JSONDecoder().decode(GatewayMessageAckDTO.self, from: data),
                  let channelID = ChannelID(ack.channelID)
            else { return }
            forumReadStates[channelID] = ForumReadState(
                lastReadMessageID: ack.messageID.flatMap(MessageID.init),
                mentionCount: ack.mentionCount ?? 0
            )
            continuation?.yield(
                .readStateChanged(
                    ChannelReadState(
                        channelID: channelID,
                        lastAcknowledgedMessageID: ack.messageID.flatMap(MessageID.init),
                        mentionCount: ack.mentionCount ?? 0,
                        isManual: ack.manual ?? false,
                        flags: ack.flags,
                        lastViewed: ack.lastViewed
                    )
                )
            )
            for (parentID, posts) in cachedForumPosts where posts[channelID] != nil {
                if let lastMessageID = posts[channelID]?.thread.lastMessageID {
                    cachedForumPosts[parentID]?[channelID]?.isUnread =
                        (ack.mentionCount ?? 0) > 0
                        || (ack.messageID.flatMap(MessageID.init).map {
                            lastMessageID > $0
                        } ?? true)
                } else {
                    cachedForumPosts[parentID]?[channelID]?.isUnread =
                        (ack.mentionCount ?? 0) > 0
                }
                publishForumPosts(parentID: parentID)
                break
            }
        case "GUILD_APPLICATION_COMMAND_INDEX_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayApplicationCommandIndexUpdateDTO.self, from: data
                ), let guildID = GuildID(update.guildID)
            else { return }
            let target = ApplicationCommandIndexTarget.guild(guildID)
            if cachedApplicationCommandCatalogs[target]?.version != update.version?.value {
                invalidateApplicationCommandCatalog(target)
            }
        case "GUILD_DELETE":
            guard
                let deleted = try? JSONDecoder().decode(
                    GatewayDeletedEntityDTO.self, from: data
                ), let guildID = GuildID(deleted.id)
            else { return }
            invalidateApplicationCommandCatalog(.guild(guildID))
        case "CHANNEL_CREATE", "CHANNEL_UPDATE":
            guard let dto = try? JSONDecoder().decode(ChannelDTO.self, from: data),
                  dto.guildID == nil,
                  dto.type == 1 || dto.type == 3,
                  var channel = try? dto.domain(
                      guildID: nil,
                      knownUsersByID: cachedGatewayUsersByID
                  )
            else { return }
            if name == "CHANNEL_UPDATE", let existing = privateChannel(id: channel.id) {
                if dto.recipients == nil, dto.recipientIDs == nil {
                    channel.recipients = existing.recipients
                }
                if dto.name == nil, dto.recipients == nil, dto.recipientIDs == nil {
                    channel.name = existing.name
                }
                if dto.ownerID == nil {
                    channel.ownerID = existing.ownerID
                }
                if dto.icon == nil {
                    channel.iconURL = existing.iconURL
                }
                if dto.lastMessageID == nil {
                    channel.lastMessageID = existing.lastMessageID
                }
            }
            upsertPrivateChannel(channel)
        case "CHANNEL_RECIPIENT_ADD", "CHANNEL_RECIPIENT_REMOVE":
            guard let update = try? JSONDecoder().decode(
                GatewayChannelRecipientDTO.self,
                from: data
            ),
                let channelID = ChannelID(update.channelID),
                var channel = privateChannel(id: channelID),
                let user = try? update.user.domain()
            else { return }
            if name == "CHANNEL_RECIPIENT_ADD" {
                if !channel.recipients.contains(where: { $0.id == user.id }) {
                    channel.recipients.append(user)
                }
                channel.kind = .groupDirectMessage
            } else {
                channel.recipients.removeAll { $0.id == user.id }
            }
            upsertPrivateChannel(channel)
        case "CHANNEL_DELETE":
            guard
                let deleted = try? JSONDecoder().decode(
                    GatewayDeletedEntityDTO.self, from: data
                ), let channelID = ChannelID(deleted.id)
            else { return }
            invalidateApplicationCommandCatalog(.channel(channelID))
            if cachedChannels[nil]?.contains(where: { $0.id == channelID }) == true {
                cachedChannels[nil]?.removeAll { $0.id == channelID }
                continuation?.yield(
                    .channelsChanged(guildID: nil, channels: cachedChannels[nil] ?? [])
                )
                continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
            }
        case "USER_APPLICATION_UPDATE", "USER_APPLICATION_REMOVE":
            invalidateApplicationCommandCatalog(.user)
        case "APPLICATION_COMMAND_AUTOCOMPLETE_RESPONSE":
            guard
                let response = try? JSONDecoder().decode(
                    GatewayApplicationCommandAutocompleteDTO.self, from: data
                )
            else { return }
            let nonce = response.nonce.value
            guard let optionType = pendingAutocompleteTypes.removeValue(forKey: nonce) else {
                return
            }
            autocompleteTimeoutTasks.removeValue(forKey: nonce)?.cancel()
            let choices = response.choices.compactMap { $0.domain(optionType: optionType) }
            continuation?.yield(
                .applicationCommandAutocomplete(
                    ApplicationCommandAutocompleteResult(nonce: nonce, choices: choices)
                )
            )
        case "INTERACTION_CREATE":
            guard
                let event = try? JSONDecoder().decode(
                    GatewayInteractionLifecycleDTO.self, from: data),
                let nonce = event.nonce?.value, let interactionID = event.id
            else { return }
            continuation?.yield(
                .interaction(.created(nonce: nonce, interactionID: interactionID))
            )
        case "INTERACTION_SUCCESS":
            guard
                let event = try? JSONDecoder().decode(
                    GatewayInteractionLifecycleDTO.self, from: data),
                let nonce = event.nonce?.value
            else { return }
            if pendingAutocompleteTypes[nonce] == nil {
                continuation?.yield(.interaction(.succeeded(nonce: nonce)))
            }
        case "INTERACTION_FAILURE":
            guard
                let event = try? JSONDecoder().decode(
                    GatewayInteractionLifecycleDTO.self, from: data),
                let nonce = event.nonce?.value
            else { return }
            pendingAutocompleteTypes[nonce] = nil
            autocompleteTimeoutTasks.removeValue(forKey: nonce)?.cancel()
            continuation?.yield(
                .interaction(
                    .failed(
                        nonce: nonce,
                        message: event.errorMessage
                            ?? event.errorCode.map {
                                "Discord rejected the interaction (code \($0))."
                            }
                            ?? "Discord rejected the interaction."
                    )
                )
            )
        case "INTERACTION_MODAL_CREATE":
            guard
                let event = try? JSONDecoder().decode(
                    GatewayInteractionModalDTO.self, from: data
                )
            else { return }
            pendingModalContexts[event.nonce.value] = event
            continuation?.yield(
                .interaction(.presentModal(nonce: event.nonce.value, modal: event.modal))
            )
        case "TYPING_START":
            guard let typing = try? JSONDecoder().decode(TypingStartDTO.self, from: data),
                  let channelID = ChannelID(typing.channelID),
                  let userID = UserID(typing.userID),
                  let user = DiscordTypingEventResolver.resolve(
                      typing,
                      userID: userID,
                      currentUser: currentUser,
                      currentStatus: presenceStatus,
                      cachedMembers: cachedMembers,
                      cachedChannels: cachedChannels.values.flatMap(\.self),
                      cachedMessages: Array(cachedMessages.values),
                      cachedGuildRoles: cachedGuildRoles
                  )
            else {
                gatewayLogger.debug("Ignored an unresolved or malformed typing event")
                return
            }
            continuation?.yield(.typing(channelID: channelID, user: user))
        case "MESSAGE_REACTION_ADD":
            guard
                let value = try? JSONDecoder().decode(
                    GatewayMessageReactionUserDTO.self,
                    from: data
                ),
                let update = value.domainUpdate(isAddition: true)
            else { return }
            applyGatewayReactionUpdate(update)
        case "MESSAGE_REACTION_REMOVE":
            guard
                let value = try? JSONDecoder().decode(
                    GatewayMessageReactionUserDTO.self,
                    from: data
                ),
                let update = value.domainUpdate(isAddition: false)
            else { return }
            applyGatewayReactionUpdate(update)
        case "MESSAGE_REACTION_REMOVE_ALL":
            guard
                let value = try? JSONDecoder().decode(
                    GatewayMessageReactionRemoveAllDTO.self,
                    from: data
                ),
                let update = value.domainUpdate
            else { return }
            applyGatewayReactionUpdate(update)
        case "MESSAGE_REACTION_REMOVE_EMOJI":
            guard
                let value = try? JSONDecoder().decode(
                    GatewayMessageReactionRemoveEmojiDTO.self,
                    from: data
                ),
                let update = value.domainUpdate
            else { return }
            applyGatewayReactionUpdate(update)
        case "MESSAGE_UPDATE":
            if let update = try? JSONDecoder().decode(MessageUpdateDTO.self, from: data),
               let messageID = MessageID(update.id), ChannelID(update.channelID) != nil,
               var message = cachedMessages[messageID]
            {
                update.apply(to: &message)
                cachedMessages[messageID] = message
                continuation?.yield(.messageUpdated(message))
                updateForumPostForMessage(message)
            }
        case "MESSAGE_DELETE":
            if let value = try? JSONDecoder().decode(MessageDeleteDTO.self, from: data),
               let channelID = ChannelID(value.channelID), let messageID = MessageID(value.id)
            {
                continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
            }
        case "GUILD_MEMBER_LIST_UPDATE":
            guard let update = try? JSONDecoder().decode(GuildMemberListUpdateDTO.self, from: data),
                  let guildID = GuildID(update.guildID)
            else {
                gatewayLogger.error("Member-list update could not be decoded; bytes=\(data.count)")
                return
            }
            let syncItemCount = update.ops.reduce(0) { $0 + ($1.items?.count ?? 0) }
            if syncItemCount > 0 {
                gatewayLogger.info("Member-list range synchronized; items=\(syncItemCount)")
            }
            applyMemberListOperations(update.ops, guildID: guildID)
            var seen = Set<UserID>()
            let members = (cachedMemberListItems[guildID] ?? []).compactMap { item -> Member? in
                guard let memberDTO = item?.member,
                      let member = try? memberDTO.domain(
                          currentUserID: currentUser?.id,
                          currentStatus: presenceStatus,
                          presence: item?.presence,
                          guildRoles: cachedGuildRoles[guildID] ?? [],
                          guildID: guildID
                      ),
                      seen.insert(member.id).inserted
                else { return nil }
                return member
            }
            cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                existing: cachedMembers[guildID] ?? [], updates: members
            )
            if guildID == pendingMemberGuildID {
                continuation?.yield(
                    .membersChanged(guildID: guildID, members: cachedMembers[guildID] ?? [])
                )
            }
        case "GUILD_MEMBERS_CHUNK":
            guard
                let chunk = try? JSONDecoder().decode(GatewayGuildMembersChunkDTO.self, from: data),
                let guildID = GuildID(chunk.guildID)
            else { return }
            gatewayLogger.info(
                "Received member chunk; members=\(chunk.members.count), chunks=\(chunk.chunkCount), nonce=\(chunk.nonce != nil), pendingSearch=\(self.pendingMemberSearchRequestByGuild[guildID] != nil)"
            )
            if let nonce = chunk.nonce,
               var request = pendingRoleMemberRequests[nonce],
               request.guildID == guildID
            {
                request.members.append(
                    contentsOf: chunk.members.compactMap {
                        try? $0.domain(
                            currentUserID: currentUser?.id,
                            currentStatus: presenceStatus,
                            guildRoles: cachedGuildRoles[guildID] ?? [],
                            guildID: guildID
                        )
                    })
                request.receivedChunks.insert(chunk.chunkIndex)
                if request.receivedChunks.count >= max(1, chunk.chunkCount) {
                    pendingRoleMemberRequests[nonce] = nil
                    request.timeoutTask.cancel()
                    request.continuation.resume(returning: request.members)
                } else {
                    pendingRoleMemberRequests[nonce] = request
                }
                return
            }

            guard let requestID = pendingMemberSearchRequestByGuild[guildID],
                  var search = pendingMemberSearchRequests[requestID]
            else {
                return
            }
            search.members.append(
                contentsOf: chunk.members.compactMap {
                    try? $0.domain(
                        currentUserID: currentUser?.id,
                        currentStatus: presenceStatus,
                        guildRoles: cachedGuildRoles[guildID] ?? [],
                        guildID: guildID
                    )
                })
            search.receivedChunks.insert(chunk.chunkIndex)
            if search.receivedChunks.count >= max(1, chunk.chunkCount) {
                _ = removeMemberSearchRequest(requestID: requestID)
                search.timeoutTask.cancel()
                let responseMembers = Array(search.members.prefix(search.maximumResults))
                mergeResolvedMembers(responseMembers, guildID: guildID)
                let members = DiscordMemberStoreOrdering.searchResults(
                    in: cachedMembers[guildID] ?? [],
                    matching: responseMembers,
                    limit: search.maximumResults
                )
                search.continuation.resume(returning: members)
            } else {
                pendingMemberSearchRequests[requestID] = search
            }
        case "PRESENCE_UPDATE":
            guard let update = try? JSONDecoder().decode(PresenceUpdateDTO.self, from: data)
            else { return }
            if update.guildID == nil {
                cachePrivatePresence(update)
                continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
                return
            }
            guard let guildID = update.guildID.flatMap(GuildID.init),
                  let userID = UserID(update.user.id),
                  let status = PresenceStatus(rawValue: update.status),
                  var members = cachedMembers[guildID],
                  let index = members.firstIndex(where: { $0.id == userID })
            else { return }
            members[index].status = status
            if let activities = update.activities {
                members[index].customStatus = activities.first(where: { $0.type == 4 })?.displayText
                members[index].activityText =
                    activities.first(where: { $0.type != 4 })?.displayText
                        ?? members[index].customStatus
            }
            cachedMembers[guildID] = members
            if guildID == pendingMemberGuildID {
                continuation?.yield(.membersChanged(guildID: guildID, members: members))
            }
        case "VOICE_STATE_UPDATE":
            guard let state = try? JSONDecoder().decode(VoiceStateUpdateDTO.self, from: data),
                  let participant = state.domain()
            else { return }
            continuation?.yield(.voiceStateChanged(participant))
            if participant.userID == currentUser?.id {
                if participant.channelID == nil {
                    activeVoiceConnection = nil
                } else if participant.channelID == activeVoiceConnection?.channelID {
                    activeVoiceConnection?.sessionID = participant.sessionID
                }
            }
            if participant.userID == currentUser?.id,
               participant.channelID == pendingVoiceNegotiation?.channelID
            {
                pendingVoiceNegotiation?.sessionID = participant.sessionID
                finishVoiceNegotiationIfReady()
            }
        case "VOICE_SERVER_UPDATE":
            guard let update = try? JSONDecoder().decode(VoiceServerUpdateDTO.self, from: data)
            else {
                return
            }
            if let pending = pendingVoiceNegotiation, update.matches(guildID: pending.guildID) {
                pendingVoiceNegotiation?.token = update.token
                pendingVoiceNegotiation?.endpoint = update.resolvedEndpoint
                finishVoiceNegotiationIfReady()
                return
            }
            guard let activeVoiceConnection,
                  let resolution = VoiceServerMigrationResolver.resolve(
                      update: update,
                      activeConnection: activeVoiceConnection
                  )
            else { return }
            switch resolution {
            case .waitForAllocation:
                continuation?.yield(.voiceServerChanged(nil))
            case .reconnect(let info):
                self.activeVoiceConnection = info
                continuation?.yield(.voiceServerChanged(info))
            }
        default:
            break
        }
    }

    private func invalidateApplicationCommandCatalog(_ target: ApplicationCommandIndexTarget) {
        cachedApplicationCommandCatalogs[target] = nil
        applicationCommandCatalogTasks.removeValue(forKey: target)?.cancel()
        continuation?.yield(.applicationCommandIndexInvalidated(target))
    }

    private func applyGuildSettingsProto(
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
        let result = Self.applyingGuildLayout(layout, to: guildsInCurrentRailOrder())
        cachedGuilds = Dictionary(uniqueKeysWithValues: result.guilds.map { ($0.id, $0) })
        guard result.railItems != cachedGuildRailItems else { return }
        cachedGuildRailItems = result.railItems
        continuation?.yield(.guildLayoutChanged(guilds: result.guilds, railItems: result.railItems))
    }

    private func guildsInCurrentRailOrder() -> [Guild] {
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

enum DiscordTypingEventResolver {
    static func resolve(
        _ typing: TypingStartDTO,
        userID: UserID,
        currentUser: User?,
        currentStatus: PresenceStatus,
        cachedMembers: [GuildID: [Member]],
        cachedChannels: [Channel],
        cachedMessages: [Message],
        cachedGuildRoles: [GuildID: [GuildRoleDTO]]
    ) -> User? {
        let guildID = typing.guildID.flatMap(GuildID.init)
        if let member = typing.member,
           let resolved = try? member.domain(
               currentUserID: currentUser?.id,
               currentStatus: currentStatus,
               guildRoles: guildID.flatMap { cachedGuildRoles[$0] } ?? [],
               guildID: guildID
           ).user
        {
            return resolved
        }
        if let user = typing.user, let resolved = try? user.domain() {
            return resolved
        }
        if let guildID,
           let member = cachedMembers[guildID]?.first(where: { $0.id == userID })
        {
            return member.user
        }
        if let recipient = cachedChannels.lazy
            .flatMap(\.recipients)
            .first(where: { $0.id == userID })
        {
            return recipient
        }
        if let author = cachedMessages.first(where: { $0.author.id == userID })?.author {
            return author
        }
        return currentUser?.id == userID ? currentUser : nil
    }
}

extension DiscordRESTProvider {
    private func finishVoiceNegotiationIfReady() {
        guard let pending = pendingVoiceNegotiation,
              let sessionID = pending.sessionID,
              let token = pending.token,
              let endpoint = pending.endpoint
        else { return }
        voiceNegotiationTimeoutTask?.cancel()
        pendingVoiceNegotiation = nil
        let info = VoiceConnectionInfo(
            serverID: pending.guildID?.description ?? pending.channelID.description,
            channelID: pending.channelID,
            guildID: pending.guildID,
            userID: pending.userID,
            sessionID: sessionID,
            token: token,
            endpoint: endpoint
        )
        activeVoiceConnection = info
        pending.continuation.resume(returning: info)
    }

    private func failVoiceNegotiation(id: UUID, error: any Error) {
        guard let pending = pendingVoiceNegotiation, pending.id == id else { return }
        voiceNegotiationTimeoutTask?.cancel()
        pendingVoiceNegotiation = nil
        pending.continuation.resume(throwing: error)
    }

    private func applyMemberListOperations(
        _ operations: [GuildMemberListUpdateDTO.Operation], guildID: GuildID
    ) {
        var items = cachedMemberListItems[guildID] ?? []
        for operation in operations {
            switch operation.op {
            case "SYNC":
                guard let range = operation.range, range.count == 2, let values = operation.items
                else {
                    continue
                }
                let lower = max(0, range[0])
                let upper = max(lower, range[1])
                if items.count <= upper {
                    items.append(contentsOf: repeatElement(nil, count: upper + 1 - items.count))
                }
                for (offset, value) in values.enumerated() where lower + offset <= upper {
                    items[lower + offset] = value
                }
            case "INSERT":
                guard let index = operation.index, let item = operation.item else { continue }
                items.insert(item, at: min(max(0, index), items.count))
            case "UPDATE":
                guard let index = operation.index, index >= 0, let item = operation.item else {
                    continue
                }
                if items.count <= index {
                    items.append(contentsOf: repeatElement(nil, count: index + 1 - items.count))
                }
                items[index] = item
            case "DELETE":
                guard let index = operation.index, items.indices.contains(index) else { continue }
                items.remove(at: index)
            case "INVALIDATE":
                guard let range = operation.range, range.count == 2, !items.isEmpty else {
                    continue
                }
                let lower = max(0, range[0])
                let upper = min(items.count - 1, range[1])
                if lower <= upper {
                    for index in lower ... upper {
                        items[index] = nil
                    }
                }
            default:
                continue
            }
        }
        cachedMemberListItems[guildID] = items
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: [String: JSONValue]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let (data, response) = try await perform(
            path, method: method, query: query, body: body, headers: headers
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                authorizationValue = nil
                throw ChatProviderError.unauthenticated
            }
            throw ChatProviderError.transport(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let route = Self.routeTemplate(method: method, path: path)
            gatewayLogger.error(
                "Discord response decoding failed for \(route, privacy: .public): \(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
    }

    private func requestEmpty(_ path: String, method: String) async throws {
        let (_, response) = try await perform(
            path, method: method, query: [], body: nil, headers: [:])
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                authorizationValue = nil
                throw ChatProviderError.unauthenticated
            }
            throw ChatProviderError.transport(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            )
        }
    }

    private func perform(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: [String: JSONValue]?,
        headers: [String: String] = [:],
        maximumAttempts requestedMaximumAttempts: Int? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard !requestSafetyCircuitIsOpen else {
            throw ChatProviderError.invalidRequest(
                "Discord networking was stopped for this session after an authentication or permission response. Restart only after checking the account status."
            )
        }

        let routeKey = "\(method) \(path)"
        let maximumAttempts = requestedMaximumAttempts ?? (method == "GET" ? 2 : 1)
        for attempt in 0 ..< maximumAttempts {
            try await reserveConservativeRequestSlot(routeKey: routeKey)

            guard var components = URLComponents(
                string:
                "https://discord.com/api/v\(DiscordProductionBaseline.july2026.apiVersion)\(path)"
            ) else {
                throw ChatProviderError.invalidRequest("Could not construct the Discord API path.")
            }
            if !query.isEmpty {
                components.queryItems = query
            }
            guard let requestURL = components.url else {
                throw ChatProviderError.invalidRequest(
                    "Could not construct the Discord API query."
                )
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = method
            request.timeoutInterval = 30
            let token = try await authorizationToken()
            // Credential storage is an actor boundary. A different request may
            // have opened the safety circuit while this one was suspended.
            guard !requestSafetyCircuitIsOpen else {
                throw ChatProviderError.invalidRequest(
                    "Discord networking is stopped for this session.")
            }
            request.setValue(token, forHTTPHeaderField: "Authorization")
            try clientMetadata.apply(to: &request)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if let body {
                request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, rawResponse) = try await session.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else {
                throw ChatProviderError.invalidRequest("Discord returned an invalid HTTP response.")
            }

            if response.statusCode == 429 {
                let retryAfter = Self.retryAfter(from: data, response: response)
                let retryDate = Date.now.addingTimeInterval(retryAfter)
                if Self.isGlobalRateLimit(data: data, response: response) {
                    globalRateLimitDate = retryDate
                } else {
                    routeRateLimitDates[routeKey] = retryDate
                }
                // Pause every authenticated route as the conservative response to
                // any 429. Mutations never retry automatically; GETs retry once.
                globalRateLimitDate = max(globalRateLimitDate, retryDate)
                gatewayLogger.error(
                    "Discord returned 429; all REST traffic paused for \(retryAfter, privacy: .public) seconds"
                )
                if attempt + 1 >= maximumAttempts {
                    return (data, response)
                }
                continue
            }

            let discordCode = Self.discordErrorCode(from: data)
            let route = Self.routeTemplate(method: method, path: path)
            let bucket = response.value(forHTTPHeaderField: "X-RateLimit-Bucket") ?? "none"
            gatewayLogger.debug(
                "Discord REST \(route, privacy: .public) status=\(response.statusCode) bucket=\(bucket, privacy: .public)"
            )
            if Self.isSafetyStop(
                status: response.statusCode,
                discordCode: discordCode,
                method: method,
                data: data
            ) {
                await openSafetyCircuit(
                    status: response.statusCode,
                    discordCode: discordCode,
                    route: route
                )
                if Self.isAuthenticationFailure(
                    status: response.statusCode,
                    discordCode: discordCode
                ) {
                    throw ChatProviderError.unauthenticated
                }
                throw ChatProviderError.invalidRequest(
                    Self.safetyStopMessage(
                        status: response.statusCode,
                        discordCode: discordCode
                    )
                )
            }
            if response.statusCode == 404 {
                unexpectedNotFoundCounts[route, default: 0] += 1
                if unexpectedNotFoundCounts[route, default: 0] >= 2 {
                    await openSafetyCircuit(status: 404, discordCode: discordCode, route: route)
                    throw ChatProviderError.invalidRequest(
                        "Discord networking was stopped after this route repeatedly returned an unexpected not-found response."
                    )
                }
            } else if (200 ..< 300).contains(response.statusCode) {
                unexpectedNotFoundCounts[route] = nil
            }
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset-After").flatMap(
                   Double.init
               )
            {
                routeRateLimitDates[routeKey] = .now.addingTimeInterval(max(0, reset))
            } else {
                routeRateLimitDates[routeKey] = nil
            }
            return (data, response)
        }
        throw ChatProviderError.invalidRequest("Discord rate limiting did not recover.")
    }

    private func reserveConservativeRequestSlot(routeKey: String) async throws {
        guard !requestSafetyCircuitIsOpen else {
            throw ChatProviderError.invalidRequest(
                "Discord networking is stopped for this session.")
        }
        let now = Date.now
        let routeDate = routeRateLimitDates[routeKey] ?? .distantPast
        let scheduledDate = max(max(now, nextRequestSlotDate), max(globalRateLimitDate, routeDate))
        // Reserve before suspension so actor reentrancy cannot wake several calls
        // into the same instant. Two authenticated REST calls/second is the ceiling.
        nextRequestSlotDate = scheduledDate.addingTimeInterval(0.5)
        let delay = scheduledDate.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        guard !requestSafetyCircuitIsOpen else {
            throw ChatProviderError.invalidRequest(
                "Discord networking is stopped for this session.")
        }
    }

    private func openSafetyCircuit(status: Int, discordCode: Int?, route: String) async {
        guard !requestSafetyCircuitIsOpen else { return }
        requestSafetyCircuitIsOpen = true
        let authenticationFailure = Self.isAuthenticationFailure(
            status: status,
            discordCode: discordCode
        )
        if authenticationFailure {
            authorizationValue = nil
        }
        gatewayReady = false
        gatewayEventTask?.cancel()
        gatewayEventTask = nil
        await gatewaySession?.stop()
        gatewaySession = nil
        // The provider owns a dedicated URLSession in production. Cancel every
        // outstanding REST/upload/socket task so a request already suspended at
        // the actor boundary cannot continue after a stop signal.
        session.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
        continuation?.yield(
            .connectionChanged(
                authenticationFailure ? .authenticationFailed : .disconnected
            ))
        gatewayLogger.fault(
            "Discord network safety circuit opened route=\(route, privacy: .public) HTTP=\(status) code=\(discordCode ?? -1)"
        )
    }

    private static func discordErrorCode(from data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["code"] as? NSNumber)?.intValue
    }

    private static func isSafetyStop(status: Int, discordCode: Int?, method: String, data: Data)
        -> Bool
    {
        if isAuthenticationFailure(status: status, discordCode: discordCode) {
            return true
        }
        // A 403 can be scoped to one channel or lookup (for example 50001/50013).
        // Keep those failures local instead of invalidating a healthy Gateway
        // session; the account-wide codes below still fail closed.
        if let discordCode, [40001, 40002, 40003, 40004, 40012, 40333].contains(discordCode) {
            return true
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["captcha_key"] != nil || object["captcha_sitekey"] != nil
           || object["captcha_service"] != nil
        {
            return true
        }
        // A client-generated mutation reaching HTTP 400 means SakuraCord's
        // contract is malformed. Do not let another user action repeat it.
        return status == 400 && method != "GET"
    }

    private static func isAuthenticationFailure(status: Int, discordCode: Int?) -> Bool {
        status == 401 || discordCode == 40001 || discordCode == 50014
    }

    private static func safetyStopMessage(status: Int, discordCode: Int?) -> String {
        switch discordCode {
        case 10005:
            "Discord could not resolve the command's application integration. SakuraCord networking has been stopped without retrying."
        case 40002: "Discord requires account verification. SakuraCord networking has been stopped."
        case 40003:
            "Discord reported that direct messages are being opened too quickly. SakuraCord networking has been stopped."
        case 40004:
            "Discord temporarily disabled message sending. SakuraCord networking has been stopped without retrying."
        case 40012: "Discord revoked the connection. SakuraCord networking has been stopped."
        case 40333: "Discord rejected the request metadata. SakuraCord networking has been stopped."
        default:
            "Discord returned a safety-sensitive HTTP \(status) response. SakuraCord networking has been stopped."
        }
    }

    private static func routeTemplate(method: String, path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map {
            segment -> String in
            if segment.count >= 15, segment.allSatisfy(\.isNumber) {
                return "{id}"
            }
            return String(segment)
        }
        return "\(method) \(segments.joined(separator: "/"))"
    }

    private func authorizationToken() async throws -> String {
        if let authorizationValue {
            return authorizationValue
        }
        let credential = try await credentials.credential(for: handle)
        guard let value = String(data: credential, encoding: .utf8) else {
            throw ChatProviderError.unauthenticated
        }
        authorizationValue = value
        return value
    }

    static func retryAfter(from data: Data, response: HTTPURLResponse) -> TimeInterval {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["retry_after"] as? NSNumber
        {
            return max(value.doubleValue, 0.25) + 0.25
        }
        if let value = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
            return max(value, 0.25) + 0.25
        }
        return 2
    }

    private static func isGlobalRateLimit(data: Data, response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: "X-RateLimit-Global")?.lowercased() == "true" {
            return true
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (object["global"] as? Bool) == true
    }
}

private struct ProfileCacheKey: Hashable {
    var userID: UserID
    var guildID: GuildID?
}

private struct UserSettingsProtoDTO: Decodable {
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
        var frequentEntries: [(key: String, frecency: Int, order: Int)] = []
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
                    frequentEntries.append((entry.key, entry.frecency, frequentEntries.count))
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

    private static func computedGuildAndChannelFrecency(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> Int? {
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

    private static func computedFrecency(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> (score: Int, frecency: Int)? {
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

private struct ProtoReader {
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

struct LossyValue<Element: Decodable>: Decodable {
    var value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

struct UserDTO: Decodable {
    struct AvatarDecorationDTO: Decodable { var asset: String? }
    struct CollectiblesDTO: Decodable {
        struct NameplateDTO: Decodable {
            struct AssetsDTO: Decodable {
                var staticImageURL: String?
                var animatedImageURL: String?
                var videoURL: String?
                enum CodingKeys: String, CodingKey {
                    case staticImageURL = "static_image_url"
                    case animatedImageURL = "animated_image_url"
                    case videoURL = "video_url"
                }
            }

            var asset: String?
            var label: String?
            var palette: String?
            var assets: AssetsDTO?
        }

        var nameplate: NameplateDTO?
    }

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
    var collectibles: CollectiblesDTO?
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
            guard let asset = value.asset else { return nil }
            let path = asset.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return Nameplate(
                staticURL: value.assets?.staticImageURL.flatMap(URL.init)
                    ?? URL(
                        string: "https://cdn.discordapp.com/assets/collectibles/\(path)/static.png"),
                // Discord supplies WebM alongside the animated image for current
                // nameplates. Prefer the streaming video representation so the UI
                // can use WebKit's hardware-backed decoder instead of eagerly
                // expanding every APNG frame in memory.
                animatedURL: value.assets?.videoURL.flatMap(URL.init)
                    ?? value.assets?.animatedImageURL.flatMap(URL.init)
                    ?? URL(
                        string: "https://cdn.discordapp.com/assets/collectibles/\(path)/asset.webm"),
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

private struct ProfileMetadataDTO: Decodable {
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

private struct ProfileBadgeDTO: Decodable {
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

private struct MutualGuildDTO: Decodable {
    var id: String
    var nick: String?
}

private struct ConnectedAccountDTO: Decodable {
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

    private static func profileURL(type: String, accountID: String, name: String) -> URL? {
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

private struct ProfileGuildMemberDTO: Decodable {
    var nick: String?
    var roles: [String]?
    var avatar: String?
    var banner: String?
    var bio: String?
}

private struct ProfileEffectConfigDTO: Decodable {
    struct AnimationDTO: Decodable {
        struct PositionDTO: Decodable {
            var x: Int?
            var y: Int?
        }

        struct SourceDTO: Decodable { var src: String? }

        var src: String?
        var loop: Bool?
        var height: Int?
        var width: Int?
        var duration: Int?
        var start: Int?
        var loopDelay: Int?
        var position: PositionDTO?
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
                positionX: position?.x ?? 0,
                positionY: position?.y ?? 0,
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

private struct ProfileEffectsDTO: Decodable {
    var profileEffectConfigs: LossyList<ProfileEffectConfigDTO>?
    enum CodingKeys: String, CodingKey { case profileEffectConfigs = "profile_effect_configs" }
}

private struct CollectibleProductDTO: Decodable {
    var items: LossyList<ProfileEffectConfigDTO>?
}

private struct UserProfileDTO: Decodable {
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

private struct GuildDTO: Decodable {
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
    var availableTags: [ForumTagDTO]?
    var defaultReactionEmoji: DefaultReactionDTO?
    var defaultSortOrder: Int?
    var defaultForumLayout: Int?
    var defaultTagSetting: String?
    var defaultAutoArchiveDuration: Int?
    var defaultThreadRateLimitPerUser: Int?
    var rateLimitPerUser: Int?
    fileprivate var message: MessageDTO?
    enum CodingKeys: String, CodingKey {
        case id
        case guildID = "guild_id"
        case name, icon, topic, type
        case parentID = "parent_id"
        case position, recipients
        case recipientIDs = "recipient_ids"
        case permissionOverwrites = "permission_overwrites"
        case lastMessageID = "last_message_id"
        case lastPinTimestamp = "last_pin_timestamp"
        case ownerID = "owner_id"
        case owner, flags, message
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
            rateLimitPerUser: rateLimitPerUser ?? 0
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
                totalMessageSent: totalMessageSent ?? messageCount ?? 0
            ),
            owner: ownerUser ?? firstMessage?.author,
            firstMessage: firstMessage,
            mostRecentMessage: nil,
            isUnread: false
        )
    }
}

struct GuildMemberDTO: Decodable {
    struct PresenceDTO: Decodable {
        struct ActivityDTO: Decodable {
            struct EmojiDTO: Decodable {
                var name: String?
                var id: String?
                var animated: Bool?
            }

            var name: String?
            var type: Int?
            var state: String?
            var emoji: EmojiDTO?

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

        var status: String?
        var activities: [ActivityDTO]?
    }

    var user: UserDTO
    var nick: String?
    var roles: [String]?
    var presence: PresenceDTO?
    var avatar: String?
    var banner: String?
    var bio: String?

    func domain(
        currentUserID: UserID?,
        currentStatus: PresenceStatus,
        presence overridePresence: PresenceDTO? = nil,
        guildRoles: [GuildRoleDTO] = [],
        guildID: GuildID? = nil
    ) throws -> Member {
        var domainUser = try user.domain()
        let globalDisplayName = domainUser.displayName
        if let nick, !nick.isEmpty {
            domainUser.displayName = nick
        }
        let guildAvatarURL: URL? = avatar.flatMap { avatarHash in
            guard let guildID else { return nil }
            return URL(
                string:
                "https://cdn.discordapp.com/guilds/\(guildID)/users/\(domainUser.id)/avatars/\(avatarHash).webp?size=128&animated=\(avatarHash.hasPrefix("a_") ? "true" : "false")"
            )
        }
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
            rolePosition: categoryRole?.position,
            isRoleCategory: categoryRole != nil,
            roles: domainRoles,
            guildAvatarURL: guildAvatarURL,
            globalDisplayName: globalDisplayName,
            activityText: activities.first(where: { $0.type != 4 })?.displayText ?? customStatus,
            customStatus: customStatus
        )
    }
}

struct GuildRoleDTO: Decodable {
    var id: String
    var name: String
    var position: Int
    var hoist: Bool
    var color: UInt32?
    var icon: String?
    var unicodeEmoji: String?
    var mentionable: Bool?
    var permissions: String?
    enum CodingKeys: String, CodingKey {
        case id, name, position, hoist, color, icon
        case unicodeEmoji = "unicode_emoji"
        case mentionable, permissions
    }

    var domain: GuildRole? {
        guard let id = RoleID(id) else { return nil }
        let iconURL = icon.flatMap {
            URL(string: "https://cdn.discordapp.com/role-icons/\(id)/\($0).png?size=32")
        }
        return GuildRole(
            id: id,
            name: name,
            position: position,
            colorHex: color.flatMap { $0 == 0 ? nil : $0 },
            iconURL: iconURL,
            unicodeEmoji: unicodeEmoji,
            isMentionable: mentionable ?? false,
            permissions: permissions.flatMap(UInt64.init)
        )
    }
}

private struct GatewayGuildMembersChunkDTO: Decodable {
    var guildID: String
    var members: [GuildMemberDTO]
    var chunkIndex: Int
    var chunkCount: Int
    var nonce: String?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case members
        case chunkIndex = "chunk_index"
        case chunkCount = "chunk_count"
        case nonce
    }
}

private struct MessageMentionDTO: Decodable {
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

private struct MessageDeleteDTO: Decodable {
    var id: String
    var channelID: String
    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
    }
}

private struct GatewayMessageReactionUserDTO: Decodable {
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

private struct GatewayMessageReactionRemoveAllDTO: Decodable {
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

private struct GatewayMessageReactionRemoveEmojiDTO: Decodable {
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

private struct MessageUpdateDTO: Decodable {
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

private struct GuildMemberListUpdateDTO: Decodable {
    struct Operation: Decodable {
        var op: String
        var range: [Int]?
        var index: Int?
        var items: [Item]?
        var item: Item?
    }

    struct Item: Decodable {
        var member: GuildMemberDTO?
        var presence: GuildMemberDTO.PresenceDTO?
    }

    var guildID: String
    var ops: [Operation]
    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case ops
    }
}

enum DiscordGatewayPayloadFactory {
    static func guildSubscriptions(guildID: GuildID, channelID: ChannelID?) -> [String: Any] {
        let channels: [String: Any] = channelID.map { [$0.description: [[0, 99]]] } ?? [:]
        return [
            "op": 37,
            "d": [
                "subscriptions": [
                    guildID.description: [
                        "typing": true,
                        "activities": true,
                        "threads": true,
                        "channels": channels,
                    ] as [String: Any]
                ]
            ] as [String: Any],
        ]
    }

    static func requestMembers(guildID: GuildID, userIDs: [UserID], nonce: String) -> [String: Any] {
        [
            "op": 8,
            "d": [
                "guild_id": guildID.description,
                "user_ids": userIDs.map(\.description),
                "presences": false,
                "nonce": nonce,
            ] as [String: Any],
        ]
    }

    static func searchMembers(guildID: GuildID, query: String, limit: Int) -> [String: Any] {
        [
            "op": 8,
            "d": [
                "guild_id": guildID.description,
                "query": query,
                "limit": limit,
                "presences": true,
            ] as [String: Any],
        ]
    }

    static func voiceStateUpdate(
        guildID: GuildID?,
        channelID: ChannelID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool = false
    ) -> [String: Any] {
        [
            "op": 4,
            "d": [
                "guild_id": guildID?.description ?? NSNull(),
                "channel_id": channelID?.description ?? NSNull(),
                "self_mute": selfMute,
                "self_deaf": selfDeaf,
                "self_video": selfVideo,
                "self_stream": false,
            ] as [String: Any],
        ]
    }
}

private struct PendingRoleMemberRequest {
    var guildID: GuildID
    var members: [Member]
    var receivedChunks: Set<Int>
    var continuation: CheckedContinuation<[Member], any Error>
    var timeoutTask: Task<Void, Never>
}

private struct PendingMemberSearchRequest {
    var guildID: GuildID
    var maximumResults: Int
    var members: [Member]
    var receivedChunks: Set<Int>
    var continuation: CheckedContinuation<[Member], any Error>
    var timeoutTask: Task<Void, Never>
}

enum DiscordMemberStoreOrdering {
    static func merging(existing: [Member], updates: [Member]) -> [Member] {
        var result = existing
        var indexByID = Dictionary(uniqueKeysWithValues: result.indices.map { (result[$0].id, $0) })
        for member in updates {
            if let index = indexByID[member.id] {
                result[index] = member
            } else {
                indexByID[member.id] = result.endIndex
                result.append(member)
            }
        }
        return result
    }

    static func searchResults(
        in store: [Member], matching response: [Member], limit: Int
    ) -> [Member] {
        let matchingIDs = Set(response.map(\.id))
        return Array(store.lazy.filter { matchingIDs.contains($0.id) }.prefix(max(0, limit)))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

private struct PendingVoiceNegotiation {
    var id: UUID
    var channelID: ChannelID
    var guildID: GuildID?
    var userID: UserID
    var selfMute: Bool
    var selfDeaf: Bool
    var sessionID: String?
    var token: String?
    var endpoint: String?
    var continuation: CheckedContinuation<VoiceConnectionInfo, any Error>
}

struct VoiceStateUpdateDTO: Decodable {
    var userID: String
    var channelID: String?
    var guildID: String?
    var sessionID: String
    var mute: Bool?
    var deaf: Bool?
    var selfMute: Bool?
    var selfDeaf: Bool?
    var suppress: Bool?
    var selfStream: Bool?
    var selfVideo: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case channelID = "channel_id"
        case guildID = "guild_id"
        case sessionID = "session_id"
        case mute, deaf, suppress
        case selfMute = "self_mute"
        case selfDeaf = "self_deaf"
        case selfStream = "self_stream"
        case selfVideo = "self_video"
    }

    func domain(defaultGuildID: GuildID? = nil) -> VoiceParticipantState? {
        guard let userID = UserID(userID) else { return nil }
        return VoiceParticipantState(
            userID: userID,
            channelID: channelID.flatMap(ChannelID.init),
            guildID: guildID.flatMap(GuildID.init) ?? defaultGuildID,
            sessionID: sessionID,
            isMuted: mute ?? false,
            isDeafened: deaf ?? false,
            isSelfMuted: selfMute ?? false,
            isSelfDeafened: selfDeaf ?? false,
            isSuppressed: suppress ?? false,
            isStreaming: selfStream ?? false,
            isVideoEnabled: selfVideo ?? false
        )
    }
}

struct GuildVoiceStateSnapshotDTO: Decodable {
    var id: String
    var voiceStates: LossyList<VoiceStateUpdateDTO>

    enum CodingKeys: String, CodingKey {
        case id
        case voiceStates = "voice_states"
    }

    var domainVoiceStates: [VoiceParticipantState] {
        let guildID = GuildID(id)
        return voiceStates.elements.compactMap { $0.domain(defaultGuildID: guildID) }
    }
}

struct GatewayReadyGuildsDTO: Decodable {
    struct GuildReference: Decodable {
        var id: String
        var rulesChannelID: String?
        var voiceStates: [VoiceStateUpdateDTO]
        var emojis: GatewayGuildEmojiCollectionDTO?
        var channels: [ChannelDTO]
        var threads: [ChannelDTO]
        var roles: [GuildRoleDTO]
        var members: [GuildMemberDTO]

        enum CodingKeys: String, CodingKey {
            case id
            case rulesChannelID = "rules_channel_id"
            case voiceStates = "voice_states"
            case emojis
            case channels, threads, roles, members
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            rulesChannelID = try? container.decode(String.self, forKey: .rulesChannelID)
            voiceStates =
                (try? container.decode(
                    LossyList<VoiceStateUpdateDTO>.self,
                    forKey: .voiceStates
                ))?.elements ?? []
            emojis = try? container.decode(
                GatewayGuildEmojiCollectionDTO.self,
                forKey: .emojis
            )
            channels =
                (try? container.decode(
                    LossyList<ChannelDTO>.self, forKey: .channels
                ))?.elements ?? []
            threads =
                (try? container.decode(
                    LossyList<ChannelDTO>.self, forKey: .threads
                ))?.elements ?? []
            roles =
                (try? container.decode(
                    LossyList<GuildRoleDTO>.self, forKey: .roles
                ))?.elements ?? []
            members =
                (try? container.decode(
                    LossyList<GuildMemberDTO>.self, forKey: .members
                ))?.elements ?? []
        }
    }

    var guilds: [GuildReference]
    var privateChannels: [ChannelDTO]
    var lazyPrivateChannels: [ChannelDTO]
    var currentUser: UserDTO?
    var users: [UserDTO]
    var presences: [PresenceUpdateDTO]
    var mergedPresences: GatewayMergedPresencesDTO
    var mergedMembers: [[ReadyMergedMemberDTO]]
    var userSettingsProto: String?
    var readState: GatewayReadStateDTO
    fileprivate var userGuildSettings: [GatewayUserGuildSettingsDTO]
    var userGuildSettingsPartial: Bool
    var usesNewNotifications: Bool

    enum CodingKeys: String, CodingKey {
        case guilds
        case privateChannels = "private_channels"
        case lazyPrivateChannels = "lazy_private_channels"
        case currentUser = "user"
        case users
        case presences
        case mergedPresences = "merged_presences"
        case mergedMembers = "merged_members"
        case userSettingsProto = "user_settings_proto"
        case readState = "read_state"
        case userGuildSettings = "user_guild_settings"
        case notificationSettings = "notification_settings"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guilds =
            (try? container.decode(
                LossyList<GuildReference>.self, forKey: .guilds
            ))?.elements ?? []
        privateChannels =
            (try? container.decode(
                LossyList<ChannelDTO>.self, forKey: .privateChannels
            ))?.elements ?? []
        lazyPrivateChannels =
            (try? container.decode(
                LossyList<ChannelDTO>.self, forKey: .lazyPrivateChannels
            ))?.elements ?? []
        currentUser = try? container.decode(UserDTO.self, forKey: .currentUser)
        users =
            (try? container.decode(
                LossyList<UserDTO>.self, forKey: .users
            ))?.elements ?? []
        presences =
            (try? container.decode(
                LossyList<PresenceUpdateDTO>.self, forKey: .presences
            ))?.elements ?? []
        mergedPresences =
            (try? container.decode(
                GatewayMergedPresencesDTO.self,
                forKey: .mergedPresences
            )) ?? GatewayMergedPresencesDTO()
        if let currentUser, !users.contains(where: { $0.id == currentUser.id }) {
            users.append(currentUser)
        }
        mergedMembers =
            (try? container.decode(
                LossyList<LossyList<ReadyMergedMemberDTO>>.self,
                forKey: .mergedMembers
            ))?.elements.map(\.elements) ?? []
        userSettingsProto = try? container.decode(String.self, forKey: .userSettingsProto)
        readState =
            (try? container.decode(GatewayReadStateDTO.self, forKey: .readState))
                ?? GatewayReadStateDTO(entries: [])
        let userGuildSettingsCollection = try? container.decode(
            GatewayUserGuildSettingsCollectionDTO.self,
            forKey: .userGuildSettings
        )
        userGuildSettings = userGuildSettingsCollection?.entries ?? []
        userGuildSettingsPartial = userGuildSettingsCollection?.partial ?? false
        let accountNotificationSettings = try? container.decode(
            GatewayAccountNotificationSettingsDTO.self,
            forKey: .notificationSettings
        )
        usesNewNotifications =
            accountNotificationSettings.map { $0.flags & (1 << 4) != 0 } ?? true
    }

    var privatePresences: [PresenceUpdateDTO] {
        presences.filter { $0.guildID == nil } + mergedPresences.friends
    }

    func hydratedGuilds(using knownUsersByID: [String: UserDTO]) -> [GuildReference] {
        var usersByID = knownUsersByID
        for user in users { usersByID[user.id] = user }
        return guilds.enumerated().map { index, value in
            guard mergedMembers.indices.contains(index) else { return value }
            var guild = value
            // The official client expands READY's parallel merged_members
            // array into each guild before dispatching CONNECTION_OPEN. The
            // array order is therefore GuildMemberStore insertion order.
            guild.members = mergedMembers[index].compactMap {
                $0.hydrated(using: usersByID)
            }
            return guild
        }
    }
}

private struct GatewayAccountNotificationSettingsDTO: Decodable {
    var flags: UInt64
}

private struct GatewayUserGuildSettingsCollectionDTO: Decodable {
    var entries: [GatewayUserGuildSettingsDTO]
    var partial: Bool

    private enum CodingKeys: String, CodingKey {
        case entries
        case partial
    }

    init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(
            LossyList<GatewayUserGuildSettingsDTO>.self
        ) {
            entries = legacy.elements
            partial = false
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries =
            (try? container.decode(
                LossyList<GatewayUserGuildSettingsDTO>.self,
                forKey: .entries
            ))?.elements ?? []
        partial = (try? container.decode(Bool.self, forKey: .partial)) ?? false
    }
}

private struct GatewayUserGuildSettingsDTO: Decodable {
    struct MuteConfigDTO: Decodable {
        var endTime: String?
        enum CodingKeys: String, CodingKey { case endTime = "end_time" }

        var domain: DiscordMuteConfiguration {
            DiscordMuteConfiguration(endTime: endTime.flatMap(DiscordDate.parse))
        }
    }

    struct OverrideDTO: Decodable {
        var channelID: String
        var messageNotifications: Int?
        var muted: Bool?
        var muteConfig: MuteConfigDTO?
        var flags: UInt64?

        enum CodingKeys: String, CodingKey {
            case channelID = "channel_id"
            case messageNotifications = "message_notifications"
            case muted
            case muteConfig = "mute_config"
            case flags
        }

        var domain: ChannelNotificationOverride? {
            guard let channelID = ChannelID(channelID) else { return nil }
            return ChannelNotificationOverride(
                channelID: channelID,
                messageNotifications:
                    messageNotifications.flatMap(MessageNotificationLevel.init(rawValue:))
                    ?? .inherit,
                isMuted: muted ?? false,
                muteConfiguration: muteConfig?.domain,
                flags: flags ?? 0
            )
        }
    }

    var guildID: String?
    var messageNotifications: Int?
    var muted: Bool?
    var muteConfig: MuteConfigDTO?
    var suppressEveryone: Bool?
    var suppressRoles: Bool?
    var flags: UInt64?
    var channelOverrides: [OverrideDTO]

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case messageNotifications = "message_notifications"
        case muted
        case muteConfig = "mute_config"
        case suppressEveryone = "suppress_everyone"
        case suppressRoles = "suppress_roles"
        case flags
        case channelOverrides = "channel_overrides"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try? values.decode(String.self, forKey: .guildID)
        messageNotifications = try? values.decode(Int.self, forKey: .messageNotifications)
        muted = try? values.decode(Bool.self, forKey: .muted)
        muteConfig = try? values.decode(MuteConfigDTO.self, forKey: .muteConfig)
        suppressEveryone = try? values.decode(Bool.self, forKey: .suppressEveryone)
        suppressRoles = try? values.decode(Bool.self, forKey: .suppressRoles)
        flags = try? values.decode(UInt64.self, forKey: .flags)
        channelOverrides =
            (try? values.decode(
                LossyList<OverrideDTO>.self, forKey: .channelOverrides
            ))?.elements ?? []
    }

    var domain: GuildNotificationSettings {
        GuildNotificationSettings(
            guildID: guildID.flatMap(GuildID.init),
            messageNotifications:
                messageNotifications.flatMap(MessageNotificationLevel.init(rawValue:))
                ?? .inherit,
            isMuted: muted ?? false,
            muteConfiguration: muteConfig?.domain,
            suppressEveryone: suppressEveryone ?? false,
            suppressRoles: suppressRoles ?? false,
            flags: flags ?? 0,
            channelOverrides: channelOverrides.compactMap(\.domain)
        )
    }
}

struct GatewayReadStateDTO: Decodable {
    struct Entry: Decodable {
        var id: String
        var readStateType: Int
        var lastMessageID: String?
        var mentionCount: Int?
        var flags: UInt64?
        var lastViewed: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case readStateType = "read_state_type"
            case lastMessageID = "last_message_id"
            case mentionCount = "mention_count"
            case flags
            case lastViewed = "last_viewed"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            readStateType = (try? container.decode(Int.self, forKey: .readStateType)) ?? 0
            lastMessageID = try? container.decode(String.self, forKey: .lastMessageID)
            mentionCount = try? container.decode(Int.self, forKey: .mentionCount)
            flags = try? container.decode(UInt64.self, forKey: .flags)
            lastViewed = try? container.decode(Int.self, forKey: .lastViewed)
        }
    }

    var entries: [Entry]
    var channelEntriesByID: [ChannelID: Entry] {
        Dictionary(
            entries.compactMap { entry in
                guard entry.readStateType == 0, let id = ChannelID(entry.id) else { return nil }
                return (id, entry)
            },
            uniquingKeysWith: { _, newer in newer }
        )
    }

    init(entries: [Entry]) { self.entries = entries }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries =
            (try? values.decode(LossyList<Entry>.self, forKey: .entries))?.elements ?? []
    }

    private enum CodingKeys: String, CodingKey { case entries }
}

struct ReadyMergedMemberDTO: Decodable {
    var userID: String
    var nick: String?
    var roles: [String]?
    var presence: GuildMemberDTO.PresenceDTO?
    var avatar: String?
    var banner: String?
    var bio: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case nick, roles, presence, avatar, banner, bio
    }

    func hydrated(using usersByID: [String: UserDTO]) -> GuildMemberDTO? {
        guard let user = usersByID[userID] else { return nil }
        return GuildMemberDTO(
            user: user,
            nick: nick,
            roles: roles,
            presence: presence,
            avatar: avatar,
            banner: banner,
            bio: bio
        )
    }
}

private struct GatewayGuildCatalogDTO: Decodable {
    var id: String
    var rulesChannelID: String?
    var channels: [ChannelDTO]
    var threads: [ChannelDTO]
    var roles: [GuildRoleDTO]
    var members: [GuildMemberDTO]

    enum CodingKeys: String, CodingKey {
        case id, channels, threads, roles, members
        case rulesChannelID = "rules_channel_id"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        rulesChannelID = try values.decodeIfPresent(String.self, forKey: .rulesChannelID)
        channels =
            try values.decodeIfPresent(
                LossyList<ChannelDTO>.self, forKey: .channels
            )?.elements ?? []
        threads =
            try values.decodeIfPresent(
                LossyList<ChannelDTO>.self, forKey: .threads
            )?.elements ?? []
        roles =
            try values.decodeIfPresent(
                LossyList<GuildRoleDTO>.self, forKey: .roles
            )?.elements ?? []
        members =
            try values.decodeIfPresent(
                LossyList<GuildMemberDTO>.self, forKey: .members
            )?.elements ?? []
    }
}

private struct GatewayGuildMetadataDTO: Decodable {
    var id: String
    var rulesChannelID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case rulesChannelID = "rules_channel_id"
    }
}

private struct GatewayThreadDeleteDTO: Decodable {
    var id: String
    var parentID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
    }
}

private struct GatewayMessageAckDTO: Decodable {
    var channelID: String
    var messageID: String?
    var mentionCount: Int?
    var manual: Bool?
    var flags: UInt64?
    var lastViewed: Int?

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case messageID = "message_id"
        case mentionCount = "mention_count"
        case manual
        case flags
        case lastViewed = "last_viewed"
    }
}

private struct GatewayThreadListSyncDTO: Decodable {
    var guildID: String
    var channelIDs: [String]
    var threads: [ChannelDTO]

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case channelIDs = "channel_ids"
        case threads
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try values.decode(String.self, forKey: .guildID)
        channelIDs = try values.decodeIfPresent([String].self, forKey: .channelIDs) ?? []
        threads =
            try values.decodeIfPresent(
                LossyList<ChannelDTO>.self, forKey: .threads
            )?.elements ?? []
    }
}

struct GatewayGuildEmojiSnapshotDTO: Decodable {
    var id: String
    var emojis: GatewayGuildEmojiCollectionDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case guildID = "guild_id"
        case emojis
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id =
            try container.decodeIfPresent(String.self, forKey: .guildID)
                ?? container.decode(String.self, forKey: .id)
        emojis = try container.decodeIfPresent(
            GatewayGuildEmojiCollectionDTO.self,
            forKey: .emojis
        )
    }
}

struct GatewayGuildEmojiCollectionDTO: Decodable {
    enum Content {
        case snapshot([GuildEmojiDTO])
        case update(writes: [GuildEmojiDTO], deletes: [String])
    }

    var content: Content

    private enum CodingKeys: String, CodingKey {
        case op
        case items
        case writes
        case deletes
    }

    init(from decoder: any Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode(
            LossyList<GuildEmojiDTO>.self
        ) {
            content = .snapshot(list.elements)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .op) {
        case "full_sync":
            content = .snapshot(
                try container.decodeIfPresent(
                    LossyList<GuildEmojiDTO>.self,
                    forKey: .items
                )?.elements ?? []
            )
        case "update":
            content = .update(
                writes: try container.decodeIfPresent(
                    LossyList<GuildEmojiDTO>.self,
                    forKey: .writes
                )?.elements ?? [],
                deletes: try container.decodeIfPresent([String].self, forKey: .deletes) ?? []
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op,
                in: container,
                debugDescription: "Unknown Discord emoji synchronization operation"
            )
        }
    }
}

struct GatewayUserSettingsProtoUpdateDTO: Decodable {
    struct Settings: Decodable {
        var type: Int
        var proto: String
    }

    var settings: Settings
    var partial: Bool?
}

enum ReadySupplementalVoiceStateResolver {
    static func resolve(data: Data, gatewayGuildIDs: [GuildID]) -> [VoiceParticipantState] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var resolved: [VoiceParticipantState] = []

        func append(rawStates: Any, fallbackGuildID: GuildID?) {
            guard let values = rawStates as? [Any] else { return }
            for value in values where JSONSerialization.isValidJSONObject(value) {
                guard let data = try? JSONSerialization.data(withJSONObject: value),
                      let dto = try? JSONDecoder().decode(VoiceStateUpdateDTO.self, from: data),
                      let state = dto.domain(defaultGuildID: fallbackGuildID)
                else { continue }
                resolved.append(state)
            }
        }

        let merged = root["merged_voice_states"]
        if let object = merged as? [String: Any] {
            if let batches = object["guilds"] as? [Any] {
                for (index, batch) in batches.enumerated() {
                    append(
                        rawStates: batch,
                        fallbackGuildID: gatewayGuildIDs.indices.contains(index)
                            ? gatewayGuildIDs[index] : nil
                    )
                }
            } else if let keyed = object["guilds"] as? [String: Any] {
                for (guildID, batch) in keyed {
                    append(rawStates: batch, fallbackGuildID: GuildID(guildID))
                }
            } else {
                for (guildID, batch) in object {
                    append(rawStates: batch, fallbackGuildID: GuildID(guildID))
                }
            }
        } else if let batches = merged as? [Any] {
            for (index, batch) in batches.enumerated() {
                append(
                    rawStates: batch,
                    fallbackGuildID: gatewayGuildIDs.indices.contains(index)
                        ? gatewayGuildIDs[index] : nil
                )
            }
        }

        if let guilds = root["guilds"] as? [[String: Any]] {
            for guild in guilds {
                append(
                    rawStates: guild["voice_states"] as Any,
                    fallbackGuildID: (guild["id"] as? String).flatMap(GuildID.init)
                )
            }
        }

        var byUserID: [UserID: VoiceParticipantState] = [:]
        for state in resolved {
            byUserID[state.userID] = state
        }
        return Array(byUserID.values)
    }
}

struct VoiceServerUpdateDTO: Decodable {
    var token: String
    var guildID: String?
    var endpoint: String?

    enum CodingKeys: String, CodingKey {
        case token, endpoint
        case guildID = "guild_id"
    }

    func matches(guildID: GuildID?) -> Bool {
        switch (self.guildID, guildID) {
        case (nil, nil): true
        case (let value?, let guildID?): value == guildID.description
        default: false
        }
    }

    var resolvedEndpoint: String? {
        guard let endpoint, !endpoint.isEmpty else { return nil }
        return endpoint
    }
}

enum VoiceServerMigrationResolution: Equatable {
    case waitForAllocation
    case reconnect(VoiceConnectionInfo)
}

enum VoiceServerMigrationResolver {
    static func resolve(
        update: VoiceServerUpdateDTO,
        activeConnection: VoiceConnectionInfo
    ) -> VoiceServerMigrationResolution? {
        guard update.matches(guildID: activeConnection.guildID) else { return nil }
        guard let endpoint = update.resolvedEndpoint else { return .waitForAllocation }

        var replacement = activeConnection
        replacement.token = update.token
        replacement.endpoint = endpoint
        guard replacement != activeConnection else { return nil }
        return .reconnect(replacement)
    }
}

struct GatewayMergedPresencesDTO: Decodable {
    var friends: [PresenceUpdateDTO]

    enum CodingKeys: String, CodingKey {
        case friends
    }

    init(friends: [PresenceUpdateDTO] = []) {
        self.friends = friends
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        friends =
            (try? container.decode(
                LossyList<PresenceUpdateDTO>.self,
                forKey: .friends
            ))?.elements ?? []
    }
}

struct PresenceUpdateDTO: Decodable {
    struct PartialUser: Decodable { var id: String }
    var guildID: String?
    var user: PartialUser
    var status: String
    var activities: [GuildMemberDTO.PresenceDTO.ActivityDTO]?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case user
        case userID = "user_id"
        case status
        case activities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try container.decodeIfPresent(String.self, forKey: .guildID)
        if let embeddedUser = try container.decodeIfPresent(
            PartialUser.self,
            forKey: .user
        ) {
            user = embeddedUser
        } else {
            user = PartialUser(
                id: try container.decode(String.self, forKey: .userID)
            )
        }
        status = try container.decode(String.self, forKey: .status)
        activities = try container.decodeIfPresent(
            [GuildMemberDTO.PresenceDTO.ActivityDTO].self,
            forKey: .activities
        )
    }
}

private struct AttachmentReservationDTO: Decodable {
    var attachments: [AttachmentSlotDTO]
}

private struct GatewayApplicationCommandIndexUpdateDTO: Decodable {
    var guildID: String
    var version: StringOrIntegerDTO?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case version
    }
}

private struct GatewayDeletedEntityDTO: Decodable {
    var id: String
}

private struct GatewayChannelRecipientDTO: Decodable {
    var channelID: String
    var user: UserDTO

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case user
    }
}

private struct GatewayApplicationCommandAutocompleteDTO: Decodable {
    struct Choice: Decodable {
        var name: String
        var localizedName: String?
        var value: JSONValue

        enum CodingKeys: String, CodingKey {
            case name, value
            case localizedName = "name_localized"
        }

        func domain(optionType: ApplicationCommandOptionType) -> ApplicationCommandChoice? {
            let parsed: ApplicationCommandChoiceValue
            switch (optionType, value) {
            case (.integer, let .number(value))
                where value.isFinite && value.rounded(.towardZero) == value:
                parsed = .integer(Int64(value))
            case (.number, let .number(value)) where value.isFinite:
                parsed = .number(value)
            case (.string, let .string(value)):
                parsed = .string(value)
            default:
                return nil
            }
            return ApplicationCommandChoice(
                name: name, localizedName: localizedName, value: parsed
            )
        }
    }

    var nonce: StringOrIntegerDTO
    var choices: [Choice]
}

private struct GatewayInteractionLifecycleDTO: Decodable {
    var id: String?
    var nonce: StringOrIntegerDTO?
    var errorCode: Int?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, nonce
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

private struct GatewayInteractionModalDTO: Decodable {
    var nonce: StringOrIntegerDTO
    var applicationID: String
    var channelID: String
    var guildID: String?
    var customID: String
    var title: String
    var components: LossyList<MessageComponentDTO>

    enum CodingKeys: String, CodingKey {
        case nonce, title, components
        case applicationID = "application_id"
        case channelID = "channel_id"
        case guildID = "guild_id"
        case customID = "custom_id"
    }

    var modal: InteractionModal {
        InteractionModal(
            customID: customID,
            title: title,
            controls: components.elements.enumerated().map {
                $0.element.modalControl(path: "modal.\($0.offset)")
            }
        )
    }
}

private struct AttachmentSlotDTO: Decodable {
    var id: Int
    var uploadURL: String
    var uploadFilename: String
    enum CodingKeys: String, CodingKey {
        case id
        case uploadURL = "upload_url"
        case uploadFilename = "upload_filename"
    }
}

private struct MessageDTO: Decodable {
    struct MemberDTO: Decodable {
        var nick: String?
        var roles: [String]?
        var avatar: String?

        func domain(guildID: GuildID?, userID: UserID) -> MessageGuildMember {
            let nickname = nick?.trimmingCharacters(in: .whitespacesAndNewlines)
            let avatarURL = avatar.flatMap { hash in
                guildID.flatMap {
                    URL(
                        string:
                        "https://cdn.discordapp.com/guilds/\($0)/users/\(userID)/avatars/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                    )
                }
            }
            return MessageGuildMember(
                nickname: nickname?.isEmpty == false ? nickname : nil,
                roleIDs: (roles ?? []).compactMap(RoleID.init),
                avatarURL: avatarURL
            )
        }
    }

    struct ApplicationDTO: Decodable {
        var id: String
        var name: String
        var description: String?
        var icon: String?
        var bot: UserDTO?

        var domain: ApplicationCommandApplication {
            ApplicationCommandApplication(
                id: id,
                name: name,
                description: description ?? "",
                iconURL: icon.flatMap {
                    URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\($0).webp?size=64")
                },
                bot: bot.flatMap { try? $0.domain() }
            )
        }
    }

    struct InteractionDTO: Decodable {
        var id: String?
        var type: Int?
        var name: String?
        var localizedName: String?
        var user: UserDTO?

        enum CodingKeys: String, CodingKey {
            case id, type, name, user
            case localizedName = "name_localized"
        }
    }

    struct InteractionMetadataDTO: Decodable {
        var id: String?
        var type: Int?
        var name: String?
        var localizedName: String?
        var user: UserDTO?
        var applicationID: String?
        var originalResponseMessageID: String?

        enum CodingKeys: String, CodingKey {
            case id, type, name, user
            case localizedName = "name_localized"
            case applicationID = "application_id"
            case originalResponseMessageID = "original_response_message_id"
        }
    }

    struct ReferenceDTO: Decodable {
        var messageID: String?
        enum CodingKeys: String, CodingKey { case messageID = "message_id" }
    }

    struct ReferencedMessageDTO: Decodable {
        var id: String
        var author: UserDTO?
        var member: MemberDTO?
        var content: String?

        func domain(guildID: GuildID?) -> MessageReplyPreview? {
            guard let messageID = MessageID(id), let author, var user = try? author.domain() else {
                return nil
            }
            if let member = member?.domain(guildID: guildID, userID: user.id) {
                user.displayName = member.nickname ?? user.displayName
                user.avatarURL = member.avatarURL ?? user.avatarURL
            }
            return MessageReplyPreview(messageID: messageID, author: user, content: content ?? "")
        }
    }

    var id: String
    var channelID: String
    var author: UserDTO?
    var member: MemberDTO?
    var content: String?
    var timestamp: String?
    var editedTimestamp: String?
    var attachments: LossyList<AttachmentDTO>?
    var reactions: LossyList<ReactionDTO>?
    var nonce: StringOrIntegerDTO?
    var messageReference: ReferenceDTO?
    var referencedMessage: ReferencedMessageDTO?
    var type: Int?
    var flags: UInt64?
    var applicationID: String?
    var application: ApplicationDTO?
    var interaction: InteractionDTO?
    var interactionMetadata: InteractionMetadataDTO?
    var guildID: String?
    var embeds: LossyList<MessageEmbedDTO>?
    var components: LossyList<MessageComponentDTO>?
    var stickerItems: LossyList<MessageStickerDTO>?
    var stickers: LossyList<MessageStickerDTO>?
    var thread: MessageThreadDTO?
    var mentions: LossyList<MessageMentionDTO>?
    var mentionRoles: [String]?
    var mentionEveryone: Bool?
    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case author, member, content, timestamp
        case editedTimestamp = "edited_timestamp"
        case attachments, reactions, nonce
        case messageReference = "message_reference"
        case referencedMessage = "referenced_message"
        case type, flags, application, interaction, embeds, components, stickers, thread, mentions
        case mentionRoles = "mention_roles"
        case mentionEveryone = "mention_everyone"
        case applicationID = "application_id"
        case interactionMetadata = "interaction_metadata"
        case guildID = "guild_id"
        case stickerItems = "sticker_items"
    }

    func domain() throws -> Message {
        guard let id = MessageID(id), let channelID = ChannelID(channelID) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid message identifier.")
        }
        guard let author else {
            throw ChatProviderError.invalidRequest("Discord returned a message without an author.")
        }
        let metadata: MessageInteractionMetadata? = {
            guard interaction != nil || interactionMetadata != nil else { return nil }
            let source = interactionMetadata
            return MessageInteractionMetadata(
                id: source?.id ?? interaction?.id,
                type: source?.type ?? interaction?.type ?? 2,
                name: source?.name ?? interaction?.name,
                localizedName: source?.localizedName ?? interaction?.localizedName,
                user: (source?.user ?? interaction?.user).flatMap { try? $0.domain() },
                applicationID: source?.applicationID ?? applicationID ?? application?.id,
                originalResponseMessageID: source?.originalResponseMessageID.flatMap(MessageID.init)
            )
        }()
        let resolvedGuildID = guildID.flatMap(GuildID.init)
        var resolvedAuthor = try author.domain()
        let resolvedMember = member?.domain(guildID: resolvedGuildID, userID: resolvedAuthor.id)
        resolvedAuthor.displayName = resolvedMember?.nickname ?? resolvedAuthor.displayName
        resolvedAuthor.avatarURL = resolvedMember?.avatarURL ?? resolvedAuthor.avatarURL
        return Message(
            id: id, channelID: channelID, author: resolvedAuthor, guildMember: resolvedMember,
            content: content ?? "",
            timestamp: timestamp.flatMap(DiscordDate.parse) ?? .now,
            editedTimestamp: editedTimestamp.flatMap(DiscordDate.parse),
            replyTo: messageReference?.messageID.flatMap(MessageID.init)
                ?? referencedMessage.flatMap { MessageID($0.id) },
            replyPreview: referencedMessage?.domain(guildID: resolvedGuildID),
            attachments: attachments?.elements.compactMap { try? $0.domain() } ?? [],
            reactions: reactions?.elements.map(\.domain) ?? [],
            nonce: nonce?.value,
            type: DiscordMessageType(rawValue: type ?? 0),
            flags: MessageFlags(rawValue: flags ?? 0),
            applicationID: (applicationID ?? application?.id).flatMap(ApplicationID.init),
            application: application?.domain,
            interactionMetadata: metadata,
            guildID: resolvedGuildID,
            embeds: (embeds?.elements ?? []).enumerated().map {
                $0.element.domain(index: $0.offset)
            },
            components: (components?.elements ?? []).enumerated().map {
                $0.element.domain(path: "\($0.offset)")
            },
            stickers: (stickerItems ?? stickers)?.elements.map(\.domain) ?? [],
            thread: thread?.domain,
            mentionedUsers: mentions?.elements.compactMap {
                try? $0.domain(guildID: resolvedGuildID)
            } ?? [],
            mentionedRoleIDs: (mentionRoles ?? []).compactMap(RoleID.init),
            mentionsEveryone: mentionEveryone ?? false
        )
    }
}

private struct ForumPostDataResponseDTO: Decodable {
    struct ThreadData: Decodable {
        var firstMessage: MessageDTO?
        var mostRecentMessage: MessageDTO?

        enum CodingKeys: String, CodingKey {
            case firstMessage = "first_message"
            case mostRecentMessage = "most_recent_message"
        }
    }

    var threads: [String: ThreadData]
}

struct ForumThreadCatalogueResponseDTO: Decodable {
    var threads: [ChannelDTO]
    var skippedThreadCount: Int
    var hasMore: Bool
    var totalResults: Int?

    enum CodingKeys: String, CodingKey {
        case threads
        case hasMore = "has_more"
        case totalResults = "total_results"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedThreads = try values.decodeIfPresent(
            LossyList<ChannelDTO>.self,
            forKey: .threads
        )
        threads = decodedThreads?.elements ?? []
        skippedThreadCount = decodedThreads?.skippedCount ?? 0
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        totalResults = try values.decodeIfPresent(Int.self, forKey: .totalResults)
    }

    func posts(fallbackGuildID: GuildID?) -> [ForumPost] {
        threads.compactMap { try? $0.forumPost(fallbackGuildID: fallbackGuildID) }
    }
}

struct ForumThreadSearchResponseDTO: Decodable {
    var threads: [ChannelDTO]
    fileprivate var firstMessages: [MessageDTO]
    fileprivate var mostRecentMessages: [MessageDTO]
    var hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case threads
        case firstMessages = "first_messages"
        case mostRecentMessages = "most_recent_messages"
        case hasMore = "has_more"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threads =
            try values.decodeIfPresent(LossyList<ChannelDTO>.self, forKey: .threads)?.elements ?? []
        firstMessages =
            try values.decodeIfPresent(
                LossyList<MessageDTO>.self, forKey: .firstMessages
            )?.elements ?? []
        mostRecentMessages =
            try values.decodeIfPresent(
                LossyList<MessageDTO>.self, forKey: .mostRecentMessages
            )?.elements ?? []
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore)
    }

    func posts(fallbackGuildID: GuildID?) -> [ForumPost] {
        let firstByChannel = Dictionary(
            firstMessages.compactMap { dto -> (ChannelID, Message)? in
                guard let message = try? dto.domain() else { return nil }
                return (message.channelID, message)
            },
            uniquingKeysWith: { _, newer in newer }
        )
        let recentByChannel = Dictionary(
            mostRecentMessages.compactMap { dto -> (ChannelID, Message)? in
                guard let message = try? dto.domain() else { return nil }
                return (message.channelID, message)
            },
            uniquingKeysWith: { _, newer in newer }
        )
        return threads.compactMap { dto in
            guard var post = try? dto.forumPost(fallbackGuildID: fallbackGuildID) else {
                return nil
            }
            post.firstMessage = post.firstMessage ?? firstByChannel[post.id]
            post.mostRecentMessage = recentByChannel[post.id]
            post.owner = post.owner ?? post.firstMessage?.author
            return post
        }
    }
}

enum RichMessageFixtureDecoder {
    static func decodeMessage(from data: Data) throws -> Message {
        try JSONDecoder().decode(MessageDTO.self, from: data).domain()
    }

    static func mergeUpdate(from data: Data, into message: Message) throws -> Message {
        var result = message
        try JSONDecoder().decode(MessageUpdateDTO.self, from: data).apply(to: &result)
        return result
    }
}

private struct StringOrIntegerDTO: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = try String(container.decode(UInt64.self))
        }
    }
}

private struct AttachmentDTO: Decodable {
    var id: String
    var filename: String
    var url: String
    var proxyURL: String?
    var contentType: String?
    var width: Int?
    var height: Int?
    var size: Int
    var description: String?
    var title: String?
    var placeholder: String?
    var placeholderVersion: Int?
    var durationSeconds: Double?
    var waveform: String?
    var flags: UInt64?
    enum CodingKeys: String, CodingKey {
        case id, filename, url, width, height, size, description, title, placeholder, waveform,
             flags
        case proxyURL = "proxy_url"
        case contentType = "content_type"
        case placeholderVersion = "placeholder_version"
        case durationSeconds = "duration_secs"
    }

    func domain() throws -> Attachment {
        guard let url = URL(string: url) else {
            throw ChatProviderError.invalidRequest("Discord returned an invalid attachment URL.")
        }
        return Attachment(
            id: id, filename: filename, url: url, proxyURL: proxyURL.flatMap(URL.init),
            mediaType: contentType, width: width, height: height, size: size,
            description: description,
            title: title, placeholder: placeholder, placeholderVersion: placeholderVersion,
            durationSeconds: durationSeconds, waveform: waveform,
            flags: AttachmentFlags(rawValue: flags ?? 0)
        )
    }
}

private struct ReactionDTO: Decodable {
    struct EmojiDTO: Decodable {
        var id: String?
        var name: String?
        var animated: Bool?

        var domainToken: String {
            id.map {
                "<\(animated == true ? "a" : ""):\(name ?? "emoji"):\($0)>"
            } ?? (name ?? "?")
        }
    }

    var count: Int?
    var me: Bool?
    var meBurst: Bool?
    var emoji: EmojiDTO?

    enum CodingKeys: String, CodingKey {
        case count, me, emoji
        case meBurst = "me_burst"
    }

    var domain: Reaction {
        Reaction(
            emoji: emoji?.domainToken ?? "?",
            count: count ?? 0,
            didCurrentUserReact: me ?? false,
            didCurrentUserBurstReact: meBurst ?? false
        )
    }
}

struct GuildEmojiDTO: Decodable {
    var id: String?
    var name: String?
    var animated: Bool?
    var available: Bool?

    func domain(guildID: GuildID) -> DiscordEmoji? {
        guard let id, let name, !name.isEmpty else { return nil }
        return DiscordEmoji(
            id: id,
            name: name,
            isAnimated: animated ?? false,
            guildID: guildID,
            isAvailable: available ?? true
        )
    }
}

private struct EmojiCacheEntry: Codable {
    var fetchedAt: Date
    var emojis: [DiscordEmoji]

    var isFresh: Bool {
        Date.now.timeIntervalSince(fetchedAt) < 7 * 24 * 60 * 60
    }
}

private enum DiscordDate {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
