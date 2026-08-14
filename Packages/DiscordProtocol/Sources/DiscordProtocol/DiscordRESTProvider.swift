import Foundation
import OSLog
import SakuraCordModels

let gatewayLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "Gateway")

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

public actor DiscordRESTProvider: PendingCredentialChatProvider {
    struct ForumReadState: Sendable {
        var lastReadMessageID: MessageID?
        var mentionCount: Int
    }
    struct InitialGatewaySnapshot: Sendable {
        var readStates: [ChannelReadState]
        var notificationSettings: [GuildNotificationSettings]
        var usesNewNotifications: Bool
    }
    struct ReactionReactorCacheKey: Hashable, Sendable {
        var channelID: ChannelID
        var messageID: MessageID
        var emojiIdentity: String
        var reactionCount: Int
    }

    static let reactionReactorFetchLimit = 5
    static let maximumReactionReactorCacheEntries = 256
    static let maximumConcurrentReactionReactorReads = 4

    var credentialSource: DiscordCredentialSource
    var accountID: String?
    let session: URLSession
    let gatewayTransport: any GatewayTransport
    let gatewayCodec: any GatewayCodec
    let gatewayEncoding: String
    let gatewayCompression: GatewayCompression
    let usesDesktopHeartbeat: Bool
    let clientMetadata: DiscordClientMetadata
    let apiDiagnostics: DiscordAPIDiagnosticStore
    let usesEmojiDiskCache: Bool
    let usesForwardSearchPeopleDiskCache: Bool
    let persistsResolvedInstallationID: Bool
    var clientAppState = "focused"
    var continuation: AsyncStream<ClientEvent>.Continuation?
    var currentUser: User?
    var authorizationValue: String?
    var installationResolutionAttempted = false
    var cachedMessages: [MessageID: Message] = [:]
    var cachedChannels: [GuildID?: [Channel]] = [:]
    // Discord's global channel search iterates ChannelStore insertion order,
    // which is independent of the category/position order used by the sidebar.
    // Preserve the raw Connection Open channel sequence for Forward search.
    var cachedForwardChannelStoreOrder: [ChannelID] = []
    var cachedPrivateRecipientIDsByChannelID: [ChannelID: [String]] = [:]
    var cachedGuildChannelDTOs: [GuildID: [String: ChannelDTO]] = [:]
    var guildChannelTasks: [GuildID: Task<[Channel], Error>] = [:]
    var privateChannelTasks: [UserID: Task<Channel, Error>] = [:]
    var messageSendTasks: [String: Task<Message, Error>] = [:]
    var cachedForumPosts: [ChannelID: [ChannelID: ForumPost]] = [:]
    var cachedJoinedThreads: [ChannelID: MessageThreadSummary] = [:]
    var cachedJoinedThreadOrder: [ChannelID] = []
    var forumCatalogueTasks: [ForumCatalogueLoadKey: Task<Void, Never>] = [:]
    var forumCatalogueTaskIDs: [ForumCatalogueLoadKey: UUID] = [:]
    var forumPreviewHydrationTasks: [ChannelID: Task<Void, Never>] = [:]
    var forumPreviewHydrationTaskIDs: [ChannelID: UUID] = [:]
    var forumPreviewHydrationQueues: [ChannelID: ForumPreviewHydrationQueue] = [:]
    var forumReadStates: [ChannelID: ForumReadState] = [:]
    var presenceStatus: PresenceStatus = .invisible
    var globalRateLimitDate: Date = .distantPast
    var routeRateLimitDates: [String: Date] = [:]
    var nextRequestSlotDate: Date = .distantPast
    var requestSafetyCircuitIsOpen = false
    var unexpectedNotFoundCounts: [String: Int] = [:]
    var gatewaySession: GatewaySession?
    var gatewayEventTask: Task<Void, Never>?
    var gatewayGuildIDs: [GuildID] = []
    // Preserve READY's raw guild membership projection independently of user
    // hydration. A merged member can precede its UserStore row in
    // READY_SUPPLEMENTAL, but Discord still makes it eligible immediately in
    // the quick switcher for the selected guild.
    var quickSwitcherGuildMemberUserIDsByGuildID: [GuildID: Set<UserID>] = [:]
    // Bare @ uses GuildMemberStore rather than the search worker's broader
    // message-derived membership markers.
    var quickSwitcherJoinedMemberIDsByGuildID: [GuildID: Set<UserID>] = [:]
    var gatewayReady = false
    var initialGatewaySnapshotResult: Result<InitialGatewaySnapshot, any Error>?
    var initialGatewaySnapshotContinuation:
        CheckedContinuation<InitialGatewaySnapshot, any Error>?
    var pendingMemberGuildID: GuildID?
    var cachedMembers: [GuildID: [Member]] = [:]
    var cachedPrivateMembersByID: [UserID: Member] = [:]
    var cachedMemberListItems:
        [GuildID: [String: [GuildMemberListUpdateDTO.Item?]]] = [:]
    var cachedMemberListGroups:
        [GuildID: [String: [GuildMemberListGroup]]] = [:]
    var selectedMemberListID: [GuildID: String] = [:]
    var memberListSubscriptions:
        [GuildID: [String: DiscordMemberListSubscription]] = [:]
    var memberListSubscriptionOrder: [GuildID: [String]] = [:]
    var cachedGatewayUsersByID: [String: UserDTO] = [:]
    var cachedGatewayUserOrder: [String] = []
    var forwardSearchEligibleUserIDs: Set<UserID> = []
    var forwardSearchEligibleUserOrder: [UserID] = []
    var cachedForwardSearchUsersByID: [UserID: User] = [:]
    var cachedForwardSearchUserOrder: [UserID] = []
    var cachedForwardSearchAliasesByGuildID: [GuildID: [UserID: String]] = [:]
    var cachedForwardSearchAliasGuildOrder: [GuildID] = []
    var loadedForwardSearchAliasGuildOrder: [GuildID] = []
    var forwardPeopleCacheDirectoryOverride: URL?
    var cachedFriendUserIDs: Set<UserID> = []
    var cachedBlockedOrIgnoredUserIDs: Set<UserID> = []
    var cachedRelationshipNicknamesByUserID: [UserID: String] = [:]
    var cachedGuildRoles: [GuildID: [GuildRoleDTO]] = [:]
    var guildRoleTasks: [GuildID: Task<[GuildRoleDTO], Error>] = [:]
    var pendingMemberSearchRequests: [String: PendingMemberSearchRequest] = [:]
    var pendingMemberSearchRequestByGuild: [GuildID: String] = [:]
    var pendingRoleMemberRequests: [String: PendingRoleMemberRequest] = [:]
    var requestedHistoryMemberIDs: [GuildID: Set<UserID>] = [:]
    var cachedGuilds: [GuildID: Guild] = [:]
    var cachedGuildRailItems: [GuildRailItem] = []
    var cachedGuildLayout: DiscordGuildLayout?
    var cachedProfiles: [ProfileCacheKey: UserProfile] = [:]
    var profileTasks: [ProfileCacheKey: Task<UserProfile, Error>] = [:]
    var collectibleProductTasks: [String: Task<CollectibleProductDTO?, Never>] = [:]
    var cachedEmojis: [GuildID: EmojiCacheEntry] = [:]
    var emojiTasks: [GuildID: Task<[DiscordEmoji], Error>] = [:]
    var cachedEmojiUserSettings: EmojiUserSettings?
    var emojiUserSettingsTask: Task<EmojiUserSettings, Error>?
    var cachedFrecencySettingsProto: Data?
    var frecencySettingsTask: Task<Data, Error>?
    var cachedGIFPickerLanding: GIFPickerLanding?
    var cachedGIFFavorites: [GIFSearchResult]?
    var isMutatingGIFFavorite = false
    var cachedReactionReactors: [ReactionReactorCacheKey: [ReactionReactor]] = [:]
    var gatewayOpcodeRateLimitDates: [Int: Date] = [:]
    var reactionReactorCacheOrder: [ReactionReactorCacheKey] = []
    var reactionReactorTasks: [ReactionReactorCacheKey: Task<[ReactionReactor], Error>] =
        [:]
    var cachedApplicationCommandCatalogs:
        [ApplicationCommandIndexTarget: ApplicationCommandCatalog] = [:]
    var applicationCommandCatalogTasks:
        [ApplicationCommandIndexTarget: Task<ApplicationCommandCatalog, Error>] = [:]
    var pendingAutocompleteTypes: [String: ApplicationCommandOptionType] = [:]
    var autocompleteTimeoutTasks: [String: Task<Void, Never>] = [:]
    var pendingModalContexts: [String: GatewayInteractionModalDTO] = [:]
    var profileEffects: [String: ProfileEffectConfigDTO]?
    var pendingVoiceNegotiation: PendingVoiceNegotiation?
    var activeVoiceConnection: VoiceConnectionInfo?
    var voiceNegotiationTimeoutTask: Task<Void, Never>?
    var privateCallsByChannel: [ChannelID: PrivateCall] = [:]
    var subscribedPrivateCallChannelIDs: Set<ChannelID> = []
    #if DEBUG
        var suspendsForumCatalogueRefreshForTesting = false
    #endif

    struct ForumCatalogueLoadKey: Hashable {
        let channelID: ChannelID
        let query: ForumPostQuery
    }

    struct ForumPreviewHydrationQueue {
        var ids: [ChannelID] = []
        var nextIndex = 0
        var pendingIDs: Set<ChannelID> = []

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

        mutating func compactIfNeeded() {
            if isEmpty {
                ids.removeAll(keepingCapacity: true)
                nextIndex = 0
            } else if nextIndex >= 256, nextIndex * 2 >= ids.count {
                ids.removeFirst(nextIndex)
                nextIndex = 0
            }
        }
    }

    public func updateClientAppState(isFocused: Bool) async {
        clientAppState = isFocused ? "focused" : "unfocused"
        let heartbeat = clientMetadata.updateHeartbeatActivity(isActive: isFocused)
        await gatewaySession?.updateQOS(
            active: isFocused,
            heartbeatSession: heartbeat.session
        )
    }

    #if DEBUG
        func clientAppStateForTesting() -> String {
            clientAppState
        }
    #endif

    public init(
        credentials: any CredentialStore,
        handle: CredentialHandle,
        session: URLSession? = nil,
        installationID: String? = nil,
        apiDiagnostics: DiscordAPIDiagnosticStore = .shared,
        usesEmojiDiskCache: Bool = true,
        usesForwardSearchPeopleDiskCache: Bool? = nil
    ) {
        let resolvedSession = session ?? URLSession(configuration: .default)
        credentialSource = .stored(credentials, handle)
        accountID = handle.accountID
        self.session = resolvedSession
        gatewayTransport = URLSessionGatewayTransport(session: resolvedSession)
        gatewayCodec = ETFGatewayCodec()
        gatewayEncoding = DiscordProductionBaseline.august2026.desktopGatewayEncoding
        gatewayCompression = .zstdStream
        usesDesktopHeartbeat = true
        clientMetadata = DiscordClientMetadata(
            installationID: installationID ?? DiscordClientMetadata.persistedInstallationID()
        )
        self.apiDiagnostics = apiDiagnostics
        self.usesEmojiDiskCache = usesEmojiDiskCache
        self.usesForwardSearchPeopleDiskCache =
            usesForwardSearchPeopleDiskCache ?? (session == nil)
        persistsResolvedInstallationID = true
    }

    public init(
        pendingCredential: PendingDiscordCredential,
        session: URLSession? = nil,
        installationID: String? = nil,
        apiDiagnostics: DiscordAPIDiagnosticStore = .shared,
        usesEmojiDiskCache: Bool = true,
        usesForwardSearchPeopleDiskCache: Bool? = nil
    ) {
        let resolvedSession = session ?? URLSession(configuration: .default)
        credentialSource = .pending(pendingCredential)
        accountID = nil
        self.session = resolvedSession
        gatewayTransport = URLSessionGatewayTransport(session: resolvedSession)
        gatewayCodec = ETFGatewayCodec()
        gatewayEncoding = DiscordProductionBaseline.august2026.desktopGatewayEncoding
        gatewayCompression = .zstdStream
        usesDesktopHeartbeat = true
        clientMetadata = DiscordClientMetadata(
            installationID: installationID ?? DiscordClientMetadata.persistedInstallationID()
        )
        self.apiDiagnostics = apiDiagnostics
        self.usesEmojiDiskCache = usesEmojiDiskCache
        self.usesForwardSearchPeopleDiskCache =
            usesForwardSearchPeopleDiskCache ?? (session == nil)
        persistsResolvedInstallationID = true
    }

    init(
        credentials: any CredentialStore,
        handle: CredentialHandle,
        session: URLSession,
        gatewayTransport: any GatewayTransport,
        gatewayCodec: any GatewayCodec = JSONGatewayCodec(),
        gatewayEncoding: String = "json",
        gatewayCompression: GatewayCompression = .zlibStream,
        usesDesktopHeartbeat: Bool = false,
        installationID: String? = nil,
        apiDiagnostics: DiscordAPIDiagnosticStore = .shared,
        usesEmojiDiskCache: Bool = true
    ) {
        credentialSource = .stored(credentials, handle)
        accountID = handle.accountID
        self.session = session
        self.gatewayTransport = gatewayTransport
        self.gatewayCodec = gatewayCodec
        self.gatewayEncoding = gatewayEncoding
        self.gatewayCompression = gatewayCompression
        self.usesDesktopHeartbeat = usesDesktopHeartbeat
        clientMetadata = DiscordClientMetadata(installationID: installationID)
        self.apiDiagnostics = apiDiagnostics
        self.usesEmojiDiskCache = usesEmojiDiskCache
        usesForwardSearchPeopleDiskCache = false
        persistsResolvedInstallationID = false
    }

    init(
        pendingCredential: PendingDiscordCredential,
        session: URLSession,
        gatewayTransport: any GatewayTransport,
        gatewayCodec: any GatewayCodec = JSONGatewayCodec(),
        gatewayEncoding: String = "json",
        gatewayCompression: GatewayCompression = .zlibStream,
        usesDesktopHeartbeat: Bool = false,
        installationID: String? = nil,
        apiDiagnostics: DiscordAPIDiagnosticStore = .shared,
        usesEmojiDiskCache: Bool = true
    ) {
        credentialSource = .pending(pendingCredential)
        accountID = nil
        self.session = session
        self.gatewayTransport = gatewayTransport
        self.gatewayCodec = gatewayCodec
        self.gatewayEncoding = gatewayEncoding
        self.gatewayCompression = gatewayCompression
        self.usesDesktopHeartbeat = usesDesktopHeartbeat
        clientMetadata = DiscordClientMetadata(installationID: installationID)
        self.apiDiagnostics = apiDiagnostics
        self.usesEmojiDiskCache = usesEmojiDiskCache
        usesForwardSearchPeopleDiskCache = false
        persistsResolvedInstallationID = false
    }
}

extension DiscordRESTProvider {
    public func prepareAuthentication() async throws {
        _ = try await authorizationToken()
        if usesDesktopHeartbeat {
            try await ensureInstallationID()
        }
    }

    public func persistPendingCredential(
        to store: any CredentialStore,
        accountID: String
    ) async throws -> CredentialHandle {
        guard case let .pending(pendingCredential) = credentialSource else {
            throw PendingDiscordCredentialError.unavailable
        }
        let handle = try await pendingCredential.persist(
            to: store,
            accountID: accountID
        )
        credentialSource = .stored(store, handle)
        self.accountID = handle.accountID
        return handle
    }

    public func discardPendingCredential() async {
        guard case let .pending(pendingCredential) = credentialSource else { return }
        await pendingCredential.discard()
    }

    private func ensureInstallationID() async throws {
        guard clientMetadata.installationID == nil, !installationResolutionAttempted else { return }
        installationResolutionAttempted = true
        let baseline = DiscordProductionBaseline.august2026
        var installationID: String?
        do {
            installationID = try await fetchInstallationID(
                baseline: baseline,
                path: "/apex/experiments",
                queryItems: [URLQueryItem(
                    name: "surface",
                    value: String(baseline.apexAppSurface)
                )],
                referer: "https://discordapp.com/app"
            )
        } catch {
            try Task.checkCancellation()
        }
        if installationID == nil {
            do {
                installationID = try await fetchInstallationID(
                baseline: baseline,
                path: "/experiments",
                queryItems: [URLQueryItem(
                    name: "with_guild_experiments",
                    value: "true"
                )],
                referer: "https://discordapp.com/login",
                contextProperties: Data(#"{"location":"Login"}"#.utf8)
                    .base64EncodedString()
                )
            } catch {
                try Task.checkCancellation()
            }
        }
        guard let installationID, !installationID.isEmpty else { return }
        clientMetadata.setInstallationID(installationID)
        if persistsResolvedInstallationID {
            DiscordClientMetadata.persistInstallationID(installationID)
        }
    }

    private func fetchInstallationID(
        baseline: DiscordProductionBaseline,
        path: String,
        queryItems: [URLQueryItem],
        referer: String,
        contextProperties: String? = nil
    ) async throws -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "discordapp.com"
        components.path = "/api/v\(baseline.apiVersion)\(path)"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ChatProviderError.invalidRequest(
                "Discord's installation identity endpoint was invalid."
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        try clientMetadata.apply(to: &request, includesHeartbeatSession: false)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(contextProperties, forHTTPHeaderField: "X-Context-Properties")
        request.setValue(nil, forHTTPHeaderField: "Origin")
        apiDiagnostics.recordHTTPRequest(
            transport: "authentication",
            method: "GET",
            path: path,
            body: nil,
            attempt: 1
        )
        let requestStarted = ContinuousClock.now
        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await session.data(for: request)
        } catch {
            apiDiagnostics.recordHTTPFailure(
                transport: "authentication",
                method: "GET",
                path: path,
                attempt: 1,
                duration: requestStarted.duration(to: .now),
                error: error
            )
            throw error
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid installation identity response."
            )
        }
        apiDiagnostics.recordHTTPResponse(
            transport: "authentication",
            method: "GET",
            path: path,
            attempt: 1,
            response: response,
            body: data,
            duration: requestStarted.duration(to: .now)
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ChatProviderError.transport(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            )
        }
        return try? JSONDecoder().decode(
            DiscordInstallationExperimentsDTO.self,
            from: data
        ).installation.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.connecting))
        _ = try await authorizationToken()
        if usesDesktopHeartbeat {
            try await ensureInstallationID()
        }
        presenceStatus = statusDefaultsKey.flatMap {
            UserDefaults.standard.string(forKey: $0)
        }.flatMap(PresenceStatus.init(rawValue:)) ?? .invisible
        try await startGateway()
        let ready = try await waitForInitialGatewaySnapshot()

        // Current Discord and Swiftcord v1 source a newly authenticated account
        // from Gateway READY. Paicord performs an additional /users/@me read,
        // but a pending SakuraCord login must fail closed instead of introducing
        // that observable difference before its credential has been persisted.
        // Previously stored sessions retain the bounded compatibility fallback.
        if currentUser == nil {
            guard !credentialSource.isPending else {
                throw ChatProviderError.invalidRequest(
                    "Discord's initial Gateway state omitted the current user."
                )
            }
            let userDTO: UserDTO = try await request("/users/@me")
            currentUser = try userDTO.domain()
        }
        let cachedGuildIDs = Set(cachedGuilds.keys)
        let readyGuildIDs = Set(gatewayGuildIDs)
        if !readyGuildIDs.isSubset(of: cachedGuildIDs) {
            let guildDTOs: [GuildDTO] = try await request("/users/@me/guilds")
            let guilds = try guildDTOs.map { try $0.domain() }
            cachedGuildRailItems = guilds.map { .guild($0.id) }
            cachedGuilds = Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) })
            if let cachedGuildLayout {
                let result = Self.applyingGuildLayout(cachedGuildLayout, to: guilds)
                cachedGuilds = Dictionary(
                    uniqueKeysWithValues: result.guilds.map { ($0.id, $0) }
                )
                cachedGuildRailItems = result.railItems
            }
        }
        guard let user = currentUser else {
            throw ChatProviderError.invalidRequest(
                "Discord's initial Gateway state omitted the current user."
            )
        }
        let currentGuilds = guildsInCurrentRailOrder()
        let currentGuildsByID = Dictionary(
            uniqueKeysWithValues: currentGuilds.map { ($0.id, $0) }
        )
        var channelGuildIDs = Set<GuildID>()
        let channelGuilds = gatewayGuildIDs.compactMap { guildID -> Guild? in
            guard channelGuildIDs.insert(guildID).inserted else { return nil }
            return cachedGuilds[guildID] ?? currentGuildsByID[guildID]
        } + currentGuilds.filter { channelGuildIDs.insert($0.id).inserted }
        let members = [Member(user: user, roleName: "You", status: presenceStatus)]
        var channelsByID = Dictionary(
            (cachedChannels[nil] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        for guild in channelGuilds {
            for channel in cachedChannels[guild.id] ?? [] {
                channelsByID[channel.id] = channel
            }
        }
        let startupChannels =
            (cachedChannels[nil] ?? []).compactMap { channelsByID.removeValue(forKey: $0.id) }
                + channelGuilds.flatMap { guild in
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
        let startupActiveJoinedThreads = currentActiveJoinedThreads()
        let userSearchAliasesByUserID = currentUserSearchAliasesByUserID()
        return BootstrapSnapshot(
            currentUser: user,
            knownUsers: currentKnownUsers(),
            quickSwitcherUserIDs: currentQuickSwitcherUsers().map(\.id),
            friendUserIDs: cachedFriendUserIDs,
            relationshipNicknamesByUserID: cachedRelationshipNicknamesByUserID,
            userSearchAliasesByUserID: userSearchAliasesByUserID,
            quickSwitcherGuildMemberUserIDs: currentQuickSwitcherGuildMemberUserIDs(),
            quickSwitcherJoinedGuildMemberUserIDs:
                currentQuickSwitcherJoinedGuildMemberUserIDs(),
            quickSwitcherGuildMemberAliases: currentQuickSwitcherGuildMemberAliases(),
            guilds: currentGuilds,
            guildRailItems: cachedGuildRailItems,
            forwardGuildStoreOrder: gatewayGuildIDs,
            channels: startupChannels,
            forwardChannelStoreOrder: cachedForwardChannelStoreOrder,
            threads: startupThreads,
            activeJoinedThreads: startupActiveJoinedThreads,
            members: members,
            readStates: ready.readStates,
            notificationSettings: ready.notificationSettings,
            usesNewNotifications: ready.usesNewNotifications
        )
    }

    func currentUserSearchAliasesByUserID() -> [UserID: [String]] {
        var result: [UserID: [String]] = [:]
        var seenGuildIDs = Set<GuildID>()
        // CONNECTION_OPEN establishes GuildMemberStore's key insertion order.
        // Cached aliases only fill gaps after that live authoritative order;
        // putting the disk cache first changed equal-score nickname ties.
        let orderedGuildIDs = gatewayGuildIDs.filter {
            seenGuildIDs.insert($0).inserted
        } + loadedForwardSearchAliasGuildOrder.filter { seenGuildIDs.insert($0).inserted }
            + cachedMembers.keys.sorted().filter { seenGuildIDs.insert($0).inserted }
            + cachedForwardSearchAliasGuildOrder.filter { seenGuildIDs.insert($0).inserted }
        for guildID in orderedGuildIDs {
            var aliases = cachedForwardSearchAliasesByGuildID[guildID] ?? [:]
            for member in cachedMembers[guildID] ?? [] {
                aliases[member.id] = forwardSearchNickname(from: member)
            }
            for userID in aliases.keys.sorted() {
                guard let alias = aliases[userID],
                      result[userID, default: []].contains(where: {
                          $0.localizedCaseInsensitiveCompare(alias) == .orderedSame
                      }) == false
                else { continue }
                result[userID, default: []].append(alias)
            }
        }
        return result
    }

    func currentQuickSwitcherGuildMemberUserIDs() -> [GuildID: [UserID]] {
        var guildIDs = Set(gatewayGuildIDs)
        guildIDs.formUnion(quickSwitcherGuildMemberUserIDsByGuildID.keys)
        guildIDs.formUnion(cachedMembers.keys)
        return Dictionary(uniqueKeysWithValues: guildIDs.map { guildID in
            var userIDs = quickSwitcherGuildMemberUserIDsByGuildID[guildID] ?? []
            userIDs.formUnion((cachedMembers[guildID] ?? []).map(\.id))
            return (guildID, userIDs.sorted())
        })
    }

    func currentQuickSwitcherGuildMemberAliases() -> [GuildID: [UserID: String]] {
        var guildIDs = Set(gatewayGuildIDs)
        guildIDs.formUnion(cachedMembers.keys)
        return Dictionary(uniqueKeysWithValues: guildIDs.map { guildID in
            var aliases: [UserID: String] = [:]
            for member in cachedMembers[guildID] ?? [] {
                aliases[member.id] = forwardSearchNickname(from: member)
            }
            return (guildID, aliases.filter { !$0.value.isEmpty })
        })
    }

    func currentQuickSwitcherJoinedGuildMemberUserIDs() -> [GuildID: [UserID]] {
        Dictionary(uniqueKeysWithValues: quickSwitcherJoinedMemberIDsByGuildID.map { entry in
            (entry.key, entry.value.sorted())
        })
    }

    func publishUserSearchAliases() {
        continuation?.yield(.userSearchAliasesChanged(currentUserSearchAliasesByUserID()))
        continuation?.yield(.quickSwitcherGuildMemberUserIDsChanged(
            currentQuickSwitcherGuildMemberUserIDs()
        ))
        continuation?.yield(.quickSwitcherJoinedMemberIDsChanged(
            currentQuickSwitcherJoinedGuildMemberUserIDs()
        ))
        continuation?.yield(.quickSwitcherGuildMemberAliasesChanged(
            currentQuickSwitcherGuildMemberAliases()
        ))
    }

    func currentKnownUsers() -> [User] {
        cachedGatewayUserOrder.compactMap { rawUserID -> User? in
            let userID = UserID(rawUserID)
            guard let user = cachedGatewayUsersByID[rawUserID]
                .flatMap({ try? $0.domain() }) ?? userID.flatMap({
                    cachedForwardSearchUsersByID[$0]
                }),
                  !cachedBlockedOrIgnoredUserIDs.contains(user.id)
            else { return nil }
            return user
        }
    }

    func currentQuickSwitcherUsers() -> [User] {
        var seen = Set<UserID>()
        let orderedUserIDs = forwardSearchEligibleUserOrder.filter {
            seen.insert($0).inserted
        }
        // Discord's quick-switcher worker mirrors the live UserStore. It does
        // not index every user record carried by READY_SUPPLEMENTAL, nor does
        // it restore message authors from an app-specific disk cache. READY
        // users and members hydrated into UserStore are marked eligible at
        // their ingestion sites and retain the same insertion order here.
        // UserStore retains blocked/ignored relationships as searchable
        // identities; forwarding continues to exclude them separately.
        // Keeping this distinct from currentKnownUsers() prevents a relaunch
        // with ForwardSearchPeople data from changing quick-switcher results.
        return orderedUserIDs.compactMap { userID in
            cachedGatewayUsersByID[userID.description]
                .flatMap { try? $0.domain() } ?? cachedForwardSearchUsersByID[userID]
        }
    }

    @discardableResult
    func cacheGatewayUser(
        _ user: UserDTO,
        forwardSearchEligible: Bool = true
    ) -> Bool {
        let userID = UserID(user.id)
        let previous = cachedGatewayUsersByID[user.id].flatMap { try? $0.domain() }
            ?? userID.flatMap { cachedForwardSearchUsersByID[$0] }
        let inserted = previous == nil
        if inserted {
            cachedGatewayUserOrder.append(user.id)
        }
        cachedGatewayUsersByID[user.id] = user
        let becameForwardSearchEligible = userID.map {
            forwardSearchEligible && forwardSearchEligibleUserIDs.insert($0).inserted
        } ?? false
        if let userID, becameForwardSearchEligible {
            forwardSearchEligibleUserOrder.append(userID)
        }
        return becameForwardSearchEligible || inserted || previous != (try? user.domain())
    }

    func cacheLiveSearchUsers(_ users: [UserDTO]) {
        cacheSearchUsers(users, persistToMessageCache: false)
    }

    func cacheMessageSearchUsers(_ users: [UserDTO]) {
        cacheSearchUsers(users, persistToMessageCache: true)
    }

    private func cacheSearchUsers(
        _ users: [UserDTO],
        persistToMessageCache: Bool
    ) {
        var changed = false
        for user in users {
            changed = cacheGatewayUser(user) || changed
        }
        let persistentChanged = persistToMessageCache
            ? cacheForwardSearchMessageUsers(users) : false
        if persistentChanged {
            persistForwardSearchPeopleCache()
        }
        if changed || persistentChanged {
            continuation?.yield(.knownUsersChanged(currentKnownUsers()))
            continuation?.yield(
                .quickSwitcherUserIDsChanged(currentQuickSwitcherUsers().map(\.id))
            )
        }
    }

    func currentActiveJoinedThreads() -> [MessageThreadSummary] {
        var seen = Set<ChannelID>()
        return cachedJoinedThreadOrder.compactMap { threadID in
            guard seen.insert(threadID).inserted,
                  let thread = cachedJoinedThreads[threadID], !thread.isArchived
            else { return nil }
            return thread
        } + cachedJoinedThreads.values
            .filter { !seen.contains($0.id) && !$0.isArchived }
            .sorted { $0.id < $1.id }
    }

    func waitForInitialGatewaySnapshot() async throws -> InitialGatewaySnapshot {
        if let initialGatewaySnapshotResult {
            return try initialGatewaySnapshotResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            initialGatewaySnapshotContinuation = continuation
        }
    }

    func finishInitialGatewaySnapshot(_ snapshot: InitialGatewaySnapshot) {
        guard initialGatewaySnapshotResult == nil else { return }
        // GatewaySession emits READY dispatch before its `.ready` state event.
        // Bootstrap resumes here, so immediate channel loads must already be
        // allowed to resolve missing message authors through the Gateway.
        gatewayReady = true
        initialGatewaySnapshotResult = .success(snapshot)
        initialGatewaySnapshotContinuation?.resume(returning: snapshot)
        initialGatewaySnapshotContinuation = nil
    }

    func failInitialGatewaySnapshot(_ error: any Error) {
        guard initialGatewaySnapshotResult == nil else { return }
        initialGatewaySnapshotResult = .failure(error)
        initialGatewaySnapshotContinuation?.resume(throwing: error)
        initialGatewaySnapshotContinuation = nil
    }

    func failInitialGatewaySnapshotOnTerminalDisconnect(_ state: ConnectionState) {
        guard state == .disconnected else { return }
        failInitialGatewaySnapshot(
            ChatProviderError.invalidRequest(
                "Discord's Gateway disconnected before initial state was ready."
            )
        )
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
        if let task = guildChannelTasks[guildID] {
            return try await task.value
        }
        let task = Task { [self] in
            let values: [ChannelDTO] = try await request("/guilds/\(guildID)/channels")
            cachedGuildChannelDTOs[guildID] = Dictionary(
                values.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            return try Self.domainChannels(values, guildID: guildID)
        }
        guildChannelTasks[guildID] = task
        do {
            let channels = try await task.value
            guildChannelTasks[guildID] = nil
            cachedChannels[guildID] = channels
            return channels
        } catch {
            guildChannelTasks[guildID] = nil
            throw error
        }
    }

    func privateChannel(id: ChannelID) -> Channel? {
        cachedChannels[nil]?.first { $0.id == id }
    }

    func upsertPrivateChannel(_ channel: Channel) {
        var channels = cachedChannels[nil] ?? []
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            var channel = channel
            // `cachedChannels[nil]` is reordered by last activity for the DM
            // sidebar. Preserve the independent READY/store insertion rank used
            // by Discord's equal-score forwarding search.
            channel.position = channels[index].position
            channels[index] = channel
        } else {
            var channel = channel
            channel.position = (channels.lazy.map(\.position).max() ?? -1) + 1
            channels.append(channel)
        }
        cachedChannels[nil] = channels
        continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
        continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
    }

    func cachePrivateRecipientReferences(_ values: [ChannelDTO]) {
        for value in values {
            guard let channelID = ChannelID(value.id), value.type == 1 || value.type == 3,
                  let recipientIDs = value.recipientIDs ?? value.recipients?.map(\.id)
            else { continue }
            cachedPrivateRecipientIDsByChannelID[channelID] =
                DiscordPrivateRecipientOrdering.sortedIDs(
                    recipientIDs,
                    channelID: value.id,
                    channelType: value.type
                )
        }
    }

    /// READY can describe private channels with only `recipient_ids`, while
    /// the corresponding UserStore records arrive in READY_SUPPLEMENTAL. The
    /// official client retains those references and resolves the recipients
    /// once its UserStore advances; do the same without issuing a REST read.
    func rehydratePrivateChannelRecipients() {
        guard var channels = cachedChannels[nil] else { return }
        var changed = false
        for index in channels.indices {
            let channel = channels[index]
            guard let recipientIDs = cachedPrivateRecipientIDsByChannelID[channel.id]
            else { continue }
            let recipients = recipientIDs.compactMap {
                cachedGatewayUsersByID[$0].flatMap { try? $0.domain() }
            }
            guard recipients != channel.recipients else { continue }
            channels[index].recipients = recipients
            if !channel.hasExplicitName {
                let recipientName = recipients.map(\.displayName).joined(separator: ", ")
                if !recipientName.isEmpty {
                    channels[index].name = recipientName
                } else if channel.kind == .groupDirectMessage,
                          let ownerID = channel.ownerID,
                          let owner = cachedGatewayUsersByID[ownerID.description]
                            .flatMap({ try? $0.domain() })
                {
                    channels[index].name = "\(owner.displayName)'s Group"
                } else {
                    channels[index].name = channel.kind == .groupDirectMessage
                        ? "Group Direct Message" : "Direct Message"
                }
            }
            changed = true
        }
        guard changed else { return }
        cachedChannels[nil] = channels
        continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
        continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
    }

    func promotePrivateChannel(
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

    func privateMembersInChannelOrder() -> [Member] {
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

    func cachePrivatePresence(_ update: PresenceUpdateDTO) {
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

    static func orderedPrivateChannels(_ channels: [Channel]) -> [Channel] {
        channels.sorted { lhs, rhs in
            let lhsActivity = lhs.lastMessageID?.rawValue ?? lhs.id.rawValue
            let rhsActivity = rhs.lastMessageID?.rawValue ?? rhs.id.rawValue
            return lhsActivity > rhsActivity
        }
    }

    static func domainChannels(_ values: [ChannelDTO], guildID: GuildID) throws -> [Channel] {
        let categories = Dictionary(
            uniqueKeysWithValues: values.filter { $0.type == 4 }.map { ($0.id, $0) }
        )
        return try values.filter { $0.type != 4 && !$0.isThread }.map { dto in
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
                _ = try await guildRoleDTOs(in: guildID)
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
        return orderedMemberListMembers(guildID: guildID) ?? cachedMembers[guildID] ?? []
    }

    public func roles(in guildID: GuildID) async throws -> [GuildRole] {
        try await guildRoleDTOs(in: guildID)
            .compactMap(\.domain)
            .sorted { $0.position > $1.position }
    }

    func guildRoleDTOs(in guildID: GuildID) async throws -> [GuildRoleDTO] {
        if let cached = cachedGuildRoles[guildID] {
            return cached
        }
        if let task = guildRoleTasks[guildID] {
            return try await task.value
        }
        let task = Task { [self] in
            let roles: [GuildRoleDTO] = try await request("/guilds/\(guildID)/roles")
            return roles
        }
        guildRoleTasks[guildID] = task
        do {
            let roles = try await task.value
            guildRoleTasks[guildID] = nil
            cachedGuildRoles[guildID] = roles
            return roles
        } catch {
            guildRoleTasks[guildID] = nil
            throw error
        }
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
        let maximumResults = min(max(1, limit), 100)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Member], any Error>) in
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

    public func requestQuickSwitcherMembers(
        in guildID: GuildID, query: String, limit: Int
    ) async throws {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to search guild members.")
        }
        let maximumResults = min(max(1, limit), 100)
        try await sendGateway(
            DiscordGatewayPayloadFactory.searchMembers(
                guildIDs: [guildID],
                query: normalized.lowercased(),
                limit: maximumResults
            )
        )
        gatewayLogger.info(
            "Sent quick-switcher member Gateway request; limit=\(maximumResults)"
        )
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

    public func resolveMembers(in guildID: GuildID, userIDs: [UserID]) async throws -> [Member] {
        var seen: Set<UserID> = []
        let requested = Array(userIDs.filter { seen.insert($0).inserted }.prefix(100))
        guard !requested.isEmpty else { return [] }

        let cachedByID = Dictionary(
            uniqueKeysWithValues: (cachedMembers[guildID] ?? []).map { ($0.id, $0) }
        )
        let missing = requested.filter { cachedByID[$0] == nil }
        if !missing.isEmpty {
            try await requestMembersByID(missing, guildID: guildID)
        }
        let resolvedByID = Dictionary(
            uniqueKeysWithValues: (cachedMembers[guildID] ?? []).map { ($0.id, $0) }
        )
        return requested.compactMap { resolvedByID[$0] }
    }

    public func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        let key = ProfileCacheKey(userID: userID, guildID: guildID)
        if let cached = cachedProfiles[key] {
            return cached
        }
        if let task = profileTasks[key] {
            return try await task.value
        }
        let task = Task { [self] in
            try await loadProfile(for: userID, in: guildID)
        }
        profileTasks[key] = task
        do {
            let profile = try await task.value
            profileTasks[key] = nil
            cachedProfiles[key] = profile
            return profile
        } catch {
            profileTasks[key] = nil
            throw error
        }
    }

    func loadProfile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        var query = [
            URLQueryItem(name: "with_mutual_guilds", value: "true"),
            URLQueryItem(name: "with_mutual_friends", value: "true"),
            URLQueryItem(name: "with_mutual_friends_count", value: "true"),
        ]
        if let guildID {
            query.append(URLQueryItem(name: "guild_id", value: guildID.description))
        }
        let dto: UserProfileDTO
        do {
            dto = try await request("/users/\(userID)/profile", query: query)
        } catch ChatProviderError.transport(status: 404, requestID: _) {
            throw ChatProviderError.invalidRequest(
                "This profile is unavailable. You may no longer share a server or friendship with this user."
            )
        }

        let effectID =
            dto.guildMemberProfile?.profileEffect?.resolvedID
                ?? dto.userProfile?.profileEffect?.resolvedID
        if effectID != nil, profileEffects == nil { profileEffects = [:] }
        if let effectID, profileEffects?[effectID] == nil {
            let product = await collectibleProduct(for: effectID)
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
        return profile
    }

    func collectibleProduct(for effectID: String) async -> CollectibleProductDTO? {
        if let task = collectibleProductTasks[effectID] {
            return await task.value
        }
        let task = Task<CollectibleProductDTO?, Never> { [self] in
            try? await request(
                "/collectibles-products/\(effectID)",
                query: [URLQueryItem(name: "locale", value: clientMetadata.locale)]
            )
        }
        collectibleProductTasks[effectID] = task
        let product = await task.value
        collectibleProductTasks[effectID] = nil
        return product
    }

    public func emojis(in guildID: GuildID) async throws -> [DiscordEmoji] {
        if let cached = cachedEmojis[guildID], cached.isFresh {
            return cached.emojis
        }
        if usesEmojiDiskCache, let disk = try? loadEmojiCache(for: guildID) {
            cachedEmojis[guildID] = disk
            if disk.isFresh {
                return disk.emojis
            }
        }
        if let task = emojiTasks[guildID] {
            do {
                return try await task.value
            } catch {
                if let stale = cachedEmojis[guildID] {
                    return stale.emojis
                }
                throw error
            }
        }
        let task = Task { [self] in
            let payload: [GuildEmojiDTO] = try await request("/guilds/\(guildID)/emojis")
            return payload.compactMap { $0.domain(guildID: guildID) }
        }
        emojiTasks[guildID] = task

        do {
            let emojis = try await task.value
            emojiTasks[guildID] = nil
            let entry = EmojiCacheEntry(fetchedAt: .now, emojis: emojis)
            cachedEmojis[guildID] = entry
            if usesEmojiDiskCache {
                try? persistEmojiCache(entry, for: guildID)
            }
            return emojis
        } catch {
            emojiTasks[guildID] = nil
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
        if let task = emojiUserSettingsTask {
            return try await task.value
        }
        let task = Task { [self] in
            let data = try await frecencySettingsProto()
            return DiscordSettingsProto.emojiSettings(from: data)
        }
        emojiUserSettingsTask = task
        do {
            let settings = try await task.value
            emojiUserSettingsTask = nil
            gatewayLogger.info(
                "Decoded emoji settings; favorites=\(settings.favoriteKeys.count), frequent=\(settings.frequentlyUsedKeys.count)"
            )
            cachedEmojiUserSettings = settings
            return settings
        } catch {
            emojiUserSettingsTask = nil
            throw error
        }
    }

    func loadEmojiCache(for guildID: GuildID) throws -> EmojiCacheEntry {
        let data = try Data(contentsOf: try emojiCacheURL(for: guildID))
        return try JSONDecoder().decode(EmojiCacheEntry.self, from: data)
    }

    func persistEmojiCache(_ entry: EmojiCacheEntry, for guildID: GuildID) throws {
        let url = try emojiCacheURL(for: guildID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    }

    func emojiCacheURL(for guildID: GuildID) throws -> URL {
        guard let accountID else { throw ChatProviderError.unauthenticated }
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        return
            base
                .appending(
                    path: "dev.sakuracord.SakuraCord/EmojiCache/\(accountID)",
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
        if let statusDefaultsKey {
            UserDefaults.standard.set(status.rawValue, forKey: statusDefaultsKey)
        }
    }

    var statusDefaultsKey: String? {
        accountID.map { "dev.sakuracord.presence.\($0)" }
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
        cacheMessageSearchUsers(payload.elements.flatMap(\.searchIndexUsers))
        if payload.skippedCount > 0 {
            gatewayLogger.warning(
                "Skipped \(payload.skippedCount) unsupported message payloads in channel \(channelID)"
            )
        }
        var values = payload.elements.compactMap { try? $0.domain() }.sorted {
            $0.timestamp < $1.timestamp
        }
        await hydrateHistoryMembers(&values, channelID: channelID)
        cacheForwardSearchMessageAliases(values)
        for index in values.indices {
            if let existing = cachedMessages[values[index].id] {
                values[index].guildMember = MessageGuildMember.merging(
                    incoming: values[index].guildMember,
                    existing: existing.guildMember
                )
            }
            cachedMessages[values[index].id] = values[index]
        }
        return MessagePage(messages: values, hasMoreBefore: values.count == min(max(limit, 1), 100))
    }

    func hydrateHistoryMembers(_ values: inout [Message], channelID: ChannelID) async {
        if let guildID = cachedChannels.values.lazy.flatMap(\.self).first(where: {
            $0.id == channelID
        })?.guildID {
            for index in values.indices where values[index].guildID == nil {
                values[index].guildID = guildID
            }

            let requested = requestedHistoryMemberIDs[guildID] ?? []
            let cached = Set((cachedMembers[guildID] ?? []).map(\.id))
            let missing = DiscordMessageMemberHydration.missingUserIDs(
                in: values,
                cached: cached,
                requested: requested
            )
            if !missing.isEmpty {
                requestedHistoryMemberIDs[guildID, default: []].formUnion(missing)
                do {
                    try await requestMembersByID(missing, guildID: guildID)
                } catch {
                    requestedHistoryMemberIDs[guildID]?.subtract(missing)
                    if requestedHistoryMemberIDs[guildID]?.isEmpty == true {
                        requestedHistoryMemberIDs[guildID] = nil
                    }
                    gatewayLogger.warning(
                        "History member lookup failed; count=\(missing.count), error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            let membersByID = Dictionary(
                uniqueKeysWithValues: (cachedMembers[guildID] ?? []).map { ($0.id, $0) }
            )
            for index in values.indices {
                DiscordMessageMemberHydration.hydrate(
                    message: &values[index],
                    membersByID: membersByID
                )
            }
        }
    }

}

private nonisolated struct DiscordInstallationExperimentsDTO: Decodable {
    let installation: String?
}
