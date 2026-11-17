import Foundation

/// A reserved attachment-host slot and, once uploaded, its bytes.
public struct PendingUpload: Sendable {
    public var filename: String
    public var owner: Snowflake
    /// The channel the file will be posted in; nil for a profile widget image.
    public var channel: Snowflake?
    public var data: Data?
}

/// A Gateway dispatch the world produced, before any per-route shaping.
public struct WorldEvent: Sendable {
    public enum Audience: Sendable {
        /// Specific users (DMs, relationships, read states, own settings).
        case users(Set<Snowflake>)
        /// Members of a guild who can view `channel` (or the whole guild when nil).
        case guild(Snowflake, channel: Snowflake?)
    }

    public var name: String
    public var data: JSON
    public var audience: Audience
}

public protocol WorldEventSink: AnyObject, Sendable {
    func deliver(_ events: [WorldEvent]) async
}

public struct WorldError: Error, Sendable {
    /// Discord's JSON error codes, e.g. 10003 Unknown Channel, 50013 Missing Permissions.
    public var status: Int
    public var code: Int
    public var message: String

    public static func unknown(_ what: String, code: Int) -> WorldError {
        WorldError(status: 404, code: code, message: "Unknown \(what)")
    }
    public static let missingPermissions = WorldError(status: 403, code: 50013, message: "Missing Permissions")
    public static let missingAccess = WorldError(status: 403, code: 50001, message: "Missing Access")
    public static let unauthorized = WorldError(status: 401, code: 0, message: "401: Unauthorized")
    /// Discord's bare 404 for a resource it does not name.
    static let notFound = WorldError(status: 404, code: 0, message: "404: Not Found")
    static let wrongChannelType = WorldError(status: 400, code: 50024, message: "Cannot execute action on this channel type")
    public static func invalidBody(_ reason: String) -> WorldError {
        WorldError(status: 400, code: 50035, message: "Invalid Form Body: \(reason)")
    }
}

/// A real Discord request whose behavior was never captured: the router answers
/// 500 and logs an ERROR, so the gap is loud rather than a quiet stub.
public struct NotSimulated: Error, CustomStringConvertible {
    public var description: String
}

/// All simulated Discord state. Every mutation goes through this actor and
/// reports the Gateway events Discord would dispatch for it.
public actor World {
    public let seed: UInt64
    public nonisolated let clock: SimulatorClock
    var random: SeededRandom
    /// Next increment per millisecond, so IDs stay unique when scenarios
    /// create records out of time order.
    private var idIncrements: [UInt64: UInt64] = [:]

    public var users: [Snowflake: User] = [:]
    public var guilds: [Snowflake: Guild] = [:]
    /// Guild order per user, as in their server rail.
    public var guildOrder: [Snowflake] = []
    public var channels: [Snowflake: Channel] = [:]
    public var presences: [Snowflake: Presence] = [:]
    public var relationships: [Snowflake: [Snowflake: Relationship]] = [:]
    public var readStates: [Snowflake: [Snowflake: ReadState]] = [:]
    public var settingsProto: [Snowflake: [Int: Data]] = [:]
    /// Private channels each user has open in their DM list.
    public var openPrivateChannels: [Snowflake: [Snowflake]] = [:]
    public var tokens: [String: Snowflake] = [:]
    /// Discord's own sticker packs, outside any guild.
    public var standardStickers: [Sticker] = []
    /// Simulated bots' slash command replies and button behavior, set by scenarios.
    var commandReplies: [String: CommandReply] = [:]
    var componentResponders: [String: ComponentResponder] = [:]
    /// Invites, applications to join, server guides and onboarding.
    public var servers = ServerState()
    /// Two-factor sign-in codes and pending login tickets.
    public var signIn = SignInState()
    /// Installed bots, open modals, and bots that ignore interactions.
    public var bots = BotState()
    /// The account the app signs in as.
    public private(set) var primaryUserID: Snowflake?
    /// Messages users scheduled, keyed by scheduled message ID.
    public var scheduledMessages: [Snowflake: ScheduledMessage] = [:]
    /// Notification settings per user and guild (nil for direct messages), wire-shaped.
    public var guildSettings: [Snowflake: [Snowflake?: JSONObject]] = [:]
    /// Each user's past avatars (`id`, `storage_hash`, `description`), newest first.
    public var avatarHistory: [Snowflake: [JSONObject]] = [:]
    /// Each user's profile widgets, wire-shaped, in display order.
    public var profileWidgets: [Snowflake: [JSON]] = [:]
    /// Messages each user cleared from their inbox's Mentions tab.
    public var dismissedMentions: [Snowflake: Set<Snowflake>] = [:]
    /// Group DMs where each user dismissed the warning about a blocked or ignored member.
    public var dismissedBlockedUserWarnings: [Snowflake: Set<Snowflake>] = [:]
    /// Discord's game catalogue, in the order games were added.
    public var games: [Game] = []
    /// The collectibles shop and what each user bought there.
    public var collectibles = CollectiblesShop()
    /// Voice states, private calls and voice server grants.
    var voice = VoiceRegistry()
    /// Files the client uploaded to the attachment host, keyed by `upload_filename`.
    public var pendingUploads: [String: PendingUpload] = [:]
    /// Generator palette per asset hash, so a person's avatar keeps their colours.
    public var palettes: [String: Int] = [:]
    /// The picture an avatar or icon hash shows, when one was picked rather than left to the seed.
    public var arts: [String: MediaGenerator.Art] = [:]
    /// Media generated on first request (large worlds would take too long to render up front).
    public var lazyMedia: [String: @Sendable () -> (data: Data, contentType: String)] = [:]
    /// Bytes served by the CDN and media hosts, keyed by path.
    public var media: [String: (data: Data, contentType: String)] = [:]
    /// Older history generated the first time a channel is looked up.
    var pendingHistory: [Snowflake: HistoryPlan] = [:]
    /// Generated servers' traffic for the `live-activity` script.
    var liveActivity: [LiveActivityPlan] = []
    /// Huge servers' members not yet made, made when the client looks.
    var memberDirectories: [Snowflake: MemberDirectory] = [:]

    private weak var sink: (any WorldEventSink)?
    /// Embeds for links in new messages, as the scenario's pages would unfurl.
    public var unfurler: (@Sendable (String) -> [JSON])?

    /// The scenario's "now" when the world was built.
    public nonisolated let epoch: Date

    public init(seed: UInt64, epoch: Date, freezeClock: Bool = false) {
        self.seed = seed
        self.epoch = epoch
        clock = SimulatorClock(epoch: epoch, frozen: freezeClock)
        random = SeededRandom(seed: seed).fork("world")
    }

    public func attach(_ sink: any WorldEventSink) { self.sink = sink }
    public func setUnfurler(_ unfurler: (@Sendable (String) -> [JSON])?) { self.unfurler = unfurler }

    func emit(_ events: [WorldEvent]) async {
        guard !events.isEmpty, let sink else { return }
        await sink.deliver(events)
    }

    func emit(_ name: String, _ data: JSON, to audience: WorldEvent.Audience) async {
        await emit([WorldEvent(name: name, data: data, audience: audience)])
    }

    // MARK: IDs

    /// A snowflake for `date` (default: now). Increments keep IDs unique and ordered.
    public func nextID(at date: Date? = nil) -> Snowflake {
        let when = date ?? clock.now
        let milliseconds = UInt64(max(0, Int64(when.timeIntervalSince1970 * 1000) - Snowflake.discordEpochMilliseconds))
        let increment = idIncrements[milliseconds, default: 0]
        idIncrements[milliseconds] = increment + 1
        // Past 4,096 IDs in one millisecond, borrow the next millisecond like a busy worker would.
        guard increment < 4_096 else { return nextID(at: Date(timeIntervalSince1970: when.timeIntervalSince1970 + 0.001)) }
        return Snowflake(date: when, increment: increment)
    }

    /// A 32-hex-digit asset hash, deterministic for the seed.
    public func nextHash(animated: Bool = false) -> String {
        let value = String(format: "%016llx%016llx", random.next(), random.next())
        return animated ? "a_" + value : value
    }

    // MARK: Lookups

    public func user(_ id: Snowflake) throws -> User {
        guard let user = users[id] else { throw WorldError.unknown("User", code: 10013) }
        return user
    }

    public func channel(_ id: Snowflake) throws -> Channel {
        materializeHistory(id)
        guard let channel = channels[id] else { throw WorldError.unknown("Channel", code: 10003) }
        return channel
    }

    public func guild(_ id: Snowflake) throws -> Guild {
        guard let guild = guilds[id] else { throw WorldError.unknown("Guild", code: 10004) }
        return guild
    }

    public func userID(forToken token: String) -> Snowflake? { tokens[token] }

    /// The channel permissions are computed from: a thread uses its parent.
    func permissionChannel(_ channel: Channel) -> Channel {
        if channel.type.isThread, let parent = channel.parentID, let parentChannel = channels[parent] { return parentChannel }
        return channel
    }

    public func permissions(of userID: Snowflake, in channel: Channel) -> Permissions {
        if channel.type.isPrivate { return channel.recipients.contains(userID) || channel.ownerID == userID ? .all : [] }
        guard let guildID = channel.guildID, let guild = guilds[guildID] else { return [] }
        return guild.permissions(of: userID, in: permissionChannel(channel), at: clock.now)
    }

    public func canView(_ userID: Snowflake, _ channel: Channel) -> Bool {
        if channel.type.isPrivate { return channel.recipients.contains(userID) }
        let permissions = permissions(of: userID, in: channel)
        // Private threads are visible to their members and to thread managers.
        if channel.type == .privateThread, !channel.threadMembers.contains(userID), !permissions.contains(.manageThreads) {
            return false
        }
        return permissions.contains(.viewChannel)
    }

    func require(_ permission: Permissions, _ userID: Snowflake, _ channel: Channel) throws {
        guard canView(userID, channel) else { throw WorldError.missingAccess }
        guard permissions(of: userID, in: channel).contains(permission) else { throw WorldError.missingPermissions }
    }

    public func guilds(of userID: Snowflake) -> [Guild] {
        guildOrder.compactMap { guilds[$0] }.filter { $0.members[userID] != nil }
    }

    public func visibleChannels(in guild: Guild, for userID: Snowflake) -> [Channel] {
        guild.channelIDs.compactMap { channels[$0] }.filter { !$0.type.isThread && canView(userID, $0) }
    }

    /// Active threads the user has joined, which is what READY carries for them.
    public func activeThreads(in guild: Guild, for userID: Snowflake) -> [Channel] {
        guild.channelIDs.compactMap { channels[$0] }
            .filter { $0.type.isThread && $0.thread?.archived == false && $0.threadMembers.contains(userID) && canView(userID, $0) }
    }

    func audience(for channel: Channel) -> WorldEvent.Audience {
        if let guildID = channel.guildID { return .guild(guildID, channel: channel.id) }
        return .users(Set(channel.recipients))
    }

    /// Who receives `audience` (used by the Gateway hub).
    public func recipients(of audience: WorldEvent.Audience) -> Set<Snowflake> {
        switch audience {
        case let .users(ids): return ids
        case let .guild(guildID, channelID):
            guard let guild = guilds[guildID] else { return [] }
            let members = Set(guild.members.keys)
            guard let channelID, let channel = channels[channelID] else { return members }
            return members.filter { canView($0, channel) }
        }
    }

    // MARK: Building (scenarios)

    @discardableResult
    public func addUser(_ user: User, token: String? = nil, presence: Presence? = nil) -> User {
        users[user.id] = user
        if let token { tokens[token] = user.id }
        if let presence { presences[user.id] = presence }
        return user
    }

    public func addGuild(_ guild: Guild) {
        guilds[guild.id] = guild
        if !guildOrder.contains(guild.id) { guildOrder.append(guild.id) }
    }

    public func addChannel(_ channel: Channel) {
        channels[channel.id] = channel
        if let guildID = channel.guildID, guilds[guildID]?.channelIDs.contains(channel.id) == false {
            guilds[guildID]?.channelIDs.append(channel.id)
        }
        if channel.type.isPrivate {
            for recipient in channel.recipients where openPrivateChannels[recipient]?.contains(channel.id) != true {
                openPrivateChannels[recipient, default: []].append(channel.id)
            }
        }
    }

    /// Appends a historical message without dispatching anything.
    public func seedMessage(_ message: Message) {
        channels[message.channelID]?.messages.append(message)
        channels[message.channelID]?.totalMessageSent += 1
    }

    public func setRelationship(_ owner: Snowflake, _ relationship: Relationship) {
        relationships[owner, default: [:]][relationship.userID] = relationship
    }

    public func setReadState(_ userID: Snowflake, channel: Snowflake, _ state: ReadState) {
        readStates[userID, default: [:]][channel] = state
    }

    public func storeMedia(_ path: String, _ data: Data, contentType: String) {
        media[path] = (data, contentType)
    }

    public func storeLazyMedia(_ path: String, _ generate: @escaping @Sendable () -> (data: Data, contentType: String)) {
        lazyMedia[path] = generate
    }

    /// Stored bytes for a CDN path, rendering lazily registered media once.
    public func mediaData(_ path: String) -> (data: Data, contentType: String)? {
        if let stored = media[path] { return stored }
        guard let generate = lazyMedia[path] else { return nil }
        let generated = generate()
        media[path] = generated
        lazyMedia[path] = nil
        return generated
    }

    public func setPrimaryUser(_ id: Snowflake) { primaryUserID = id }

    public func setPalette(_ palette: Int, forHash hash: String) { palettes[hash] = palette }

    public func setArt(_ art: MediaGenerator.Art, forHash hash: String) { arts[hash] = art }

    /// Makes an asset hash (or SKU ID) known to the CDN, which 404s anything else.
    public func registerAsset(_ key: String, palette: Int? = nil) {
        palettes[key] = palette ?? Int(key.hashValueStable % 12)
    }

    public func isKnownAsset(_ key: String) -> Bool { palettes[key] != nil || arts[key] != nil || key == Self.premiumBadgeIcon }

    /// The profile badge icon for Nitro subscribers.
    public nonisolated static let premiumBadgeIcon = "2ba85e8026a8614b640c2837bcdfe21b"

    public func setPresence(_ userID: Snowflake, _ presence: Presence) {
        presences[userID] = presence
    }
}
