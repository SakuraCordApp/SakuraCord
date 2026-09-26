import Foundation
import OSLog
import SakuraCordModels

let gatewayLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "Gateway")
let discordPerformanceSignposter = OSSignposter(
    subsystem: "dev.sakuracord.SakuraCord",
    category: "PointsOfInterest"
)

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
    let prepareUploadFile: @Sendable (URL) async throws -> PreparedUploadFile
    let anonymisesUploadFilenames: @Sendable () async -> Bool
    struct RESTRateLimitBucketKey: Hashable, Sendable {
        let identifier: String
        let majorParameter: String
    }

    struct RESTRateLimitBucketState: Sendable {
        var limit: Int?
        var remaining: Int?
        var resetDate: Date
        var resetInterval: TimeInterval?
    }

    struct RESTRateLimitReservation: Sendable {
        let routeKey: String
        let discoveryToken: UUID?
    }

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
    var restSession: URLSession
    let restSessionConfiguration: URLSessionConfiguration?
    var restSessionGeneration = 0
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
    var continuation: SessionEventBuffer<ClientEvent>?
    var currentUser: User?
    var currentAccountDetails: AccountDetails?
    var currentAuthSessionIDHash: String?
    var accountInformationRevision = UUID()
    var profileApexAssignments: ProfileApexAssignmentsDTO?
    var profileEditingResponses: [ProfileEditingScope: ProfileEditingResponseDTO] = [:]
    var profileWidgetCatalogues: [Bool: [ProfileApplicationWidget]] = [:]
    var profileWidgetConfigurations: [String: [ProfileApplicationWidget]] = [:]
    var profileWidgetIdentities: [UserID: [ProfileWidgetApplicationIdentity]] = [:]
    var profileWidgetConnectionStates: [String: ProfileWidgetConnection] = [:]
    var profileWidgetAuthorizationTokenIDs: [String: String] = [:]
    var profileWidgetConnectionRevision = UUID()
    var profileWidgetConnectionTasks: [String: Task<[String: ProfileWidgetConnection], Error>] = [:]
    var profileWidgetGameDetails: [String: ProfileGame] = [:]
    var profileSimilarGameIDs: [String: [String]] = [:]
    var profileGameAnnouncementCache: [String: ProfileGameAnnouncements] = [:]
    var profileWidgetGameSearches: [String: ProfileGameAutocompleteCacheEntry] = [:]
    var profileWidgetGameSearchFailures: [String: ProfileGameAutocompleteFailure] = [:]
    var profileWidgetGameSearchTasks: [String: Task<[ProfileGame], Error>] = [:]
    var profileDeveloperMode = false
    var authorizationValue: String?
    var installationResolutionAttempted = false
    var isClearingDerivedCaches = false
    var derivedCacheGeneration: UInt64 = 0
    var cachedMessages = DiscordMessageCache()
    var cachedChannels: [GuildID?: [Channel]] = [:]
    // Discord's global channel search iterates ChannelStore insertion order,
    // which is independent of the category/position order used by the sidebar.
    // Preserve the raw Connection Open channel sequence for Forward search.
    var cachedForwardChannelStoreOrder: [ChannelID] = []
    var cachedPrivateRecipientIDsByChannelID: [ChannelID: [String]] = [:]
    var cachedGuildChannelDTOs: [GuildID: ChannelDTOStore] = [:]
    var guildChannelTasks: [GuildID: Task<[Channel], Error>] = [:]
    var privateChannelTasks: [UserID: Task<Channel, Error>] = [:]
    var messageSendTasks: [String: Task<Message, Error>] = [:]
    var cachedForumPosts: [ChannelID: [ChannelID: ForumPost]] = [:]
    var cachedForumThreadOrder: [ChannelID] = []
    var cachedJoinedThreads: [ChannelID: MessageThreadSummary] = [:]
    var cachedJoinedThreadOrder: [ChannelID] = []
    var cachedGuildNotificationSettings: [GuildID?: GuildNotificationSettings] = [:]
    var forumCatalogueTasks: [ForumCatalogueLoadKey: Task<Void, Never>] = [:]
    var forumCatalogueTaskIDs: [ForumCatalogueLoadKey: UUID] = [:]
    var forumPreviewHydrationTasks: [ChannelID: Task<Void, Never>] = [:]
    var forumPreviewHydrationTaskIDs: [ChannelID: UUID] = [:]
    var forumPreviewHydrationQueues: [ChannelID: ForumPreviewHydrationQueue] = [:]
    var forumReadStates: [ChannelID: ForumReadState] = [:]
    var presenceStatus: PresenceStatus = .invisible
    var globalRateLimitDate: Date = .distantPast
    var routeRateLimitDates: [String: Date] = [:]
    var rateLimitBucketKeyByRoute:
        [String: RESTRateLimitBucketKey] = [:]
    var rateLimitBuckets:
        [RESTRateLimitBucketKey: RESTRateLimitBucketState] = [:]
    var rateLimitRoutesWithoutBuckets: Set<String> = []
    var rateLimitDiscoveryTokenByRoute: [String: UUID] = [:]
    var rateLimitDiscoveryWaitersByRoute:
        [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
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
    var cachedMembers: [GuildID: [Member]] = [:] {
        didSet {
            // Member arrays preserve Discord's store order. Keep a separate
            // process-only lookup projection for bounded history/profile reads;
            // any ordered-store mutation invalidates it atomically.
            cachedMembersByID.removeAll(keepingCapacity: true)
        }
    }
    var cachedMembersByID: [GuildID: [UserID: Member]] = [:]
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
    var cachedGatewayUserIDs: Set<String> = []
    var messageSearchUserIDs: Set<UserID> = []
    var messageSearchUserOrder: [UserID] = []
    var lazyPrivateChannelIDs: Set<ChannelID> = []
    var forwardSearchEligibleUserIDs: Set<UserID> = []
    var forwardSearchEligibleUserOrder: [UserID] = []
    var cachedForwardSearchUsersByID: [UserID: User] = [:]
    var cachedForwardSearchUserOrder: [UserID] = []
    var cachedForwardSearchAliasesByGuildID: [GuildID: [UserID: String]] = [:]
    var cachedForwardSearchAliasGuildOrder: [GuildID] = []
    var loadedForwardSearchAliasGuildOrder: [GuildID] = []
    var forwardPeopleCacheDirectoryOverride: URL?
    var forwardPeopleCachePersistenceTask: Task<Void, Never>?
    var forwardPeopleCachePersistenceGeneration: UInt64 = 0
    var forwardPeopleCacheWriteTask: Task<Void, Never>?
    var forwardPeopleCacheWriteGeneration: UInt64 = 0
    var startupSearchCacheLoadTask:
        Task<DiscordStartupSearchCacheSnapshot, Never>?
    var startupSearchCacheLoadGeneration: UInt64 = 0
    var cachedFriendUserIDs: Set<UserID> = []
    var cachedBlockedOrIgnoredUserIDs: Set<UserID> = []
    var cachedRelationshipNicknamesByUserID: [UserID: String] = [:]
    var cachedGuildRoles: [GuildID: [GuildRoleDTO]] = [:]
    var guildRoleTasks: [GuildID: Task<[GuildRoleDTO], Error>] = [:]
    var pendingMemberSearchRequests: [String: PendingMemberSearchRequest] = [:]
    var pendingMemberSearchRequestByGuild: [GuildID: String] = [:]
    var pendingRoleMemberRequests: [String: PendingRoleMemberRequest] = [:]
    var requestedHistoryMemberIDs: [GuildID: Set<UserID>] = [:]
    var resolvingHistoryMemberIDs: [GuildID: Set<UserID>] = [:]
    var cachedGuildOnboarding: [GuildID: GuildOnboarding] = [:]
    var cachedGuilds: [GuildID: Guild] = [:]
    var cachedGuildRailItems: [GuildRailItem] = []
    var cachedGuildLayout: DiscordGuildLayout?
    var cachedProfiles: [ProfileCacheKey: UserProfile] = [:]
    var profileTasks: [ProfileCacheKey: Task<UserProfile, Error>] = [:]
    var collectibleProductTasks: [String: Task<ProfileCollectibleProductDTO, Error>] = [:]
    var profileCollectibleProducts: [String: ProfileCollectibleProductDTO] = [:]
    var profileDetailedProductIDs: Set<String> = []
    var profileInventory: ProfileCollectibleInventory?
    var profileInventoryTask: Task<ProfileCollectibleInventory, Error>?
    var profileEditingGeneration: UInt64 = 0
    var profilePresentationGeneration: UInt64 = 0
    var profilePresentationRevisions: [UserID: UInt64] = [:]
    var profileResponses: [ProfileCacheKey: UserProfileDTO] = [:]
    var profileSaveID: UUID?
    var cachedEmojis: [GuildID: EmojiCacheEntry] = [:]
    var emojiTasks: [GuildID: Task<[DiscordEmoji], Error>] = [:]
    var cachedEmojiUserSettings: EmojiUserSettings?
    var emojiUserSettingsTask: Task<EmojiUserSettings, Error>?
    var cachedFrecencySettingsProto: Data?
    var profileStatusSettings: Data?
    var inboxScheduledEvents = InboxScheduledEvents()
    var inboxSettingsProto: Data?
    var inboxSettingsSaveID: UUID?
    var profileStatusSaveID: UUID?
    var profileCustomStatusExpiryTask: Task<Void, Never>?
    var frecencySettingsTask: Task<Data, Error>?
    var cachedStickersByGuild: [GuildID: [MessageSticker]] = [:]
    var cachedStandardStickerPacks: [StickerPack]?
    var standardStickerPacksTask: Task<[StickerPack], Error>?
    var cachedStickerUserSettings: StickerUserSettings?
    var pendingStickerFrecencyPatch: Data?
    var stickerFrecencyFlushTask: Task<Void, Never>?
    var stickerFrecencyRevision: UInt64 = 0
    var stickerFrecencyFlushGeneration: UInt64 = 0
    var cachedDefaultSoundboardSounds: [SoundboardSound]?
    var cachedSoundboardSounds: [GuildID: [SoundboardSound]] = [:]
    var cachedSoundboardUserSettings: SoundboardUserSettings?
    var pendingSoundboardRequests: [UUID: PendingSoundboardRequest] = [:]
    var soundboardRequestTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    var cachedGIFPickerLanding: GIFPickerLanding?
    var cachedGIFFavorites: [GIFSearchResult]?
    var isMutatingFrecencyFavorite = false
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
    var applicationStreams: [ApplicationStreamKey: ApplicationStream] = [:]
    var applicationStreamConnections:
        [ApplicationStreamKey: ApplicationStreamConnectionInfo] = [:]
    var pendingApplicationStreamNegotiations:
        [ApplicationStreamKey: PendingApplicationStreamNegotiation] = [:]
    var applicationStreamNegotiationTimeoutTasks:
        [ApplicationStreamKey: Task<Void, Never>] = [:]
    var privateCallsByChannel: [ChannelID: PrivateCall] = [:]
    var subscribedPrivateCallChannelIDs: Set<ChannelID> = []
    #if DEBUG
        var suspendsForumCatalogueRefreshForTesting = false
        var eventOverflowDidStopRequestsForTesting: (@Sendable () -> Void)?
        var derivedCacheClearDidBeginForTesting: (@Sendable () -> Void)?
        var emojiResponseReceivedForTesting: (@Sendable () async -> Void)?
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
        usesForwardSearchPeopleDiskCache: Bool? = nil,
        anonymisesUploadFilenames: @escaping @Sendable () async -> Bool = { false },
        prepareUploadFile: @escaping @Sendable (URL) async throws -> PreparedUploadFile = { PreparedUploadFile(url: $0) }
    ) {
        let defaultRESTConfiguration = URLSessionConfiguration.default
        let resolvedSession = session ?? URLSession(
            configuration: defaultRESTConfiguration
        )
        let gatewaySession = session ?? URLSession(configuration: .default)
        credentialSource = .stored(credentials, handle)
        accountID = handle.accountID
        restSession = resolvedSession
        restSessionConfiguration = session == nil ? defaultRESTConfiguration : nil
        gatewayTransport = URLSessionGatewayTransport(session: gatewaySession)
        gatewayCodec = ETFGatewayCodec()
        gatewayEncoding = DiscordProductionBaseline.current.desktopGatewayEncoding
        gatewayCompression = .zstdStream
        usesDesktopHeartbeat = true
        clientMetadata = DiscordClientMetadata(
            installationID: installationID ?? DiscordClientMetadata.persistedInstallationID()
        )
        self.apiDiagnostics = apiDiagnostics
        self.anonymisesUploadFilenames = anonymisesUploadFilenames
        self.prepareUploadFile = prepareUploadFile
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
        usesForwardSearchPeopleDiskCache: Bool? = nil,
        anonymisesUploadFilenames: @escaping @Sendable () async -> Bool = { false },
        prepareUploadFile: @escaping @Sendable (URL) async throws -> PreparedUploadFile = { PreparedUploadFile(url: $0) }
    ) {
        let defaultRESTConfiguration = URLSessionConfiguration.default
        let resolvedSession = session ?? URLSession(
            configuration: defaultRESTConfiguration
        )
        let gatewaySession = session ?? URLSession(configuration: .default)
        credentialSource = .pending(pendingCredential)
        accountID = nil
        restSession = resolvedSession
        restSessionConfiguration = session == nil ? defaultRESTConfiguration : nil
        gatewayTransport = URLSessionGatewayTransport(session: gatewaySession)
        gatewayCodec = ETFGatewayCodec()
        gatewayEncoding = DiscordProductionBaseline.current.desktopGatewayEncoding
        gatewayCompression = .zstdStream
        usesDesktopHeartbeat = true
        clientMetadata = DiscordClientMetadata(
            installationID: installationID ?? DiscordClientMetadata.persistedInstallationID()
        )
        self.apiDiagnostics = apiDiagnostics
        self.anonymisesUploadFilenames = anonymisesUploadFilenames
        self.prepareUploadFile = prepareUploadFile
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
        usesEmojiDiskCache: Bool = true,
        ownsRESTSession: Bool = false,
        anonymisesUploadFilenames: @escaping @Sendable () async -> Bool = { false },
        prepareUploadFile: @escaping @Sendable (URL) async throws -> PreparedUploadFile = { PreparedUploadFile(url: $0) }
    ) {
        credentialSource = .stored(credentials, handle)
        accountID = handle.accountID
        restSession = session
        restSessionConfiguration = ownsRESTSession ? session.configuration : nil
        self.gatewayTransport = gatewayTransport
        self.gatewayCodec = gatewayCodec
        self.gatewayEncoding = gatewayEncoding
        self.gatewayCompression = gatewayCompression
        self.usesDesktopHeartbeat = usesDesktopHeartbeat
        clientMetadata = DiscordClientMetadata(installationID: installationID)
        self.apiDiagnostics = apiDiagnostics
        self.anonymisesUploadFilenames = anonymisesUploadFilenames
        self.prepareUploadFile = prepareUploadFile
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
        usesEmojiDiskCache: Bool = true,
        ownsRESTSession: Bool = false,
        anonymisesUploadFilenames: @escaping @Sendable () async -> Bool = { false },
        prepareUploadFile: @escaping @Sendable (URL) async throws -> PreparedUploadFile = { PreparedUploadFile(url: $0) }
    ) {
        credentialSource = .pending(pendingCredential)
        accountID = nil
        restSession = session
        restSessionConfiguration = ownsRESTSession ? session.configuration : nil
        self.gatewayTransport = gatewayTransport
        self.gatewayCodec = gatewayCodec
        self.gatewayEncoding = gatewayEncoding
        self.gatewayCompression = gatewayCompression
        self.usesDesktopHeartbeat = usesDesktopHeartbeat
        clientMetadata = DiscordClientMetadata(installationID: installationID)
        self.apiDiagnostics = apiDiagnostics
        self.anonymisesUploadFilenames = anonymisesUploadFilenames
        self.prepareUploadFile = prepareUploadFile
        self.usesEmojiDiskCache = usesEmojiDiskCache
        usesForwardSearchPeopleDiskCache = false
        persistsResolvedInstallationID = false
    }
}

public extension DiscordRESTProvider {
    func prepareAuthentication() async throws {
        _ = try await authorizationToken()
        if usesDesktopHeartbeat {
            try await ensureInstallationID()
        }
    }

    func persistPendingCredential(
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

    func discardPendingCredential() async {
        guard case let .pending(pendingCredential) = credentialSource else { return }
        await pendingCredential.discard()
    }

    private func ensureInstallationID() async throws {
        guard clientMetadata.installationID == nil, !installationResolutionAttempted else { return }
        installationResolutionAttempted = true
        let baseline = DiscordProductionBaseline.current
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
        let requestSession = restSession
        let requestSessionGeneration = restSessionGeneration
        do {
            (data, rawResponse) = try await requestSession.data(for: request)
        } catch {
            apiDiagnostics.recordHTTPFailure(
                transport: "authentication",
                method: "GET",
                path: path,
                attempt: 1,
                duration: requestStarted.duration(to: .now),
                error: error
            )
            _ = recoverRESTSessionIfNeeded(
                after: error,
                requestGeneration: requestSessionGeneration
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
            throw apiDiagnostics.coalescing(ChatProviderError.transport(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            ), with: response)
        }
        return try? JSONDecoder().decode(
            DiscordInstallationExperimentsDTO.self,
            from: data
        ).installation.flatMap { $0.isEmpty ? nil : $0 }
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.connecting))
        let ready = try await prepareInitialGatewaySnapshot()
        let assembly = discordPerformanceSignposter.beginInterval(
            "ProviderBootstrapSnapshotAssembly",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        defer {
            discordPerformanceSignposter.endInterval(
                "ProviderBootstrapSnapshotAssembly", assembly
            )
        }
        let user = try await bootstrapCurrentUser()
        try await refreshBootstrapGuildCacheIfNeeded()
        return makeBootstrapSnapshot(user: user, ready: ready)
    }

    private func prepareInitialGatewaySnapshot() async throws -> InitialGatewaySnapshot {
        let authentication = discordPerformanceSignposter.beginInterval(
            "ProviderBootstrapAuthentication",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        _ = try await authorizationToken()
        if usesDesktopHeartbeat {
            try await ensureInstallationID()
        }
        discordPerformanceSignposter.endInterval(
            "ProviderBootstrapAuthentication", authentication
        )
        presenceStatus = statusDefaultsKey.flatMap {
            UserDefaults.standard.string(forKey: $0)
        }.flatMap(PresenceStatus.init(rawValue:)) ?? .invisible
        beginStartupSearchCacheLoad()
        let gatewayStartup = discordPerformanceSignposter.beginInterval(
            "ProviderGatewayStartup",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        try await startGateway()
        discordPerformanceSignposter.endInterval(
            "ProviderGatewayStartup", gatewayStartup
        )
        let initialSnapshotWait = discordPerformanceSignposter.beginInterval(
            "ProviderGatewayInitialSnapshotWait",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        let ready = try await waitForInitialGatewaySnapshot()
        discordPerformanceSignposter.endInterval(
            "ProviderGatewayInitialSnapshotWait", initialSnapshotWait
        )
        return ready
    }

    private func bootstrapCurrentUser() async throws -> User {
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
        guard let user = currentUser else {
            throw ChatProviderError.invalidRequest(
                "Discord's initial Gateway state omitted the current user."
            )
        }
        return user
    }

    private func refreshBootstrapGuildCacheIfNeeded() async throws {
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
    }

}
