import Foundation
import SakuraCordModels

enum DiscordGatewayPayloadFactory {
    static func guildSubscriptions(
        guildID: GuildID,
        channelID: ChannelID?,
        ranges: [ClosedRange<Int>] = [0 ... 99]
    ) -> [String: Any] {
        guildSubscriptions(
            guildID: guildID,
            channelRanges: channelID.map { [$0: ranges] } ?? [:]
        )
    }

    static func guildSubscriptions(
        guildID: GuildID,
        channelRanges: [ChannelID: [ClosedRange<Int>]]
    ) -> [String: Any] {
        let channels = Dictionary(
            uniqueKeysWithValues: channelRanges.map { channelID, ranges in
                (
                    channelID.description,
                    ranges.map { [$0.lowerBound, $0.upperBound] }
                )
            }
        )
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

    static func requestMembers(guildID: GuildID, userIDs: [UserID]) -> [String: Any] {
        [
            "op": 8,
            "d": [
                "guild_id": guildID.description,
                "user_ids": userIDs.map(\.description),
                "presences": false
            ] as [String: Any]
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

    static func searchMembers(
        guildIDs: [GuildID], query: String, limit: Int
    ) -> [String: Any] {
        [
            "op": 8,
            "d": [
                "guild_id": guildIDs.map(\.description),
                "query": query,
                "limit": limit,
                "presences": true,
                "user_ids": NSNull(),
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

    static func privateCallConnect(channelID: ChannelID) -> [String: Any] {
        [
            "op": 13,
            "d": [
                "channel_id": channelID.description
            ] as [String: Any],
        ]
    }
}

enum DiscordMemberListRangePolicy {
    struct SubscriptionState: Equatable {
        let memberListOrder: [String]
        let subscriptionsByMemberListID: [String: DiscordMemberListSubscription]

        var rangesByChannel: [ChannelID: [ClosedRange<Int>]] {
            Dictionary(
                subscriptionsByMemberListID.values.map { ($0.channelID, $0.ranges) },
                uniquingKeysWith: { _, newer in newer }
            )
        }
    }

    static let blockSize = 100
    static let maximumRangePairs = 5
    static let maximumSubscribedMemberLists = 5
    static let initialRange = 0 ... 99

    static func ranges(around visibleRange: ClosedRange<Int>) -> [ClosedRange<Int>] {
        let lower = max(0, visibleRange.lowerBound)
        let upper = max(lower, visibleRange.upperBound)
        let viewportCount = max(1, upper - lower + 1)
        let prefetch = Int(ceil(Double(viewportCount) / 2))
        let prefetchLower = max(0, lower - prefetch)
        let prefetchUpper = upper + prefetch

        var ranges = [initialRange]
        var blockStart = max(blockSize, (prefetchLower / blockSize) * blockSize)
        while blockStart <= prefetchUpper {
            ranges.append(blockStart ... (blockStart + blockSize - 1))
            blockStart += blockSize
        }
        guard ranges.count > maximumRangePairs else { return ranges }
        let nonInitial = Array(ranges.dropFirst())
        let leadingCount = (maximumRangePairs - 1) / 2
        let trailingCount = maximumRangePairs - 1 - leadingCount
        return [initialRange]
            + nonInitial.prefix(leadingCount)
            + nonInitial.suffix(trailingCount)
    }

    static func retainedMemberListOrder(
        selecting memberListID: String,
        from current: [String]
    ) -> [String] {
        Array(
            (current.filter { $0 != memberListID } + [memberListID])
                .suffix(maximumSubscribedMemberLists)
        )
    }

    static func subscriptionState(
        selecting memberListID: String,
        channelID: ChannelID,
        ranges: [ClosedRange<Int>],
        currentSubscriptions: [String: DiscordMemberListSubscription],
        currentOrder: [String]
    ) -> SubscriptionState {
        let memberListOrder = retainedMemberListOrder(
            selecting: memberListID, from: currentOrder
        )
        var subscriptions = currentSubscriptions
        subscriptions[memberListID] = DiscordMemberListSubscription(
            channelID: channelID, ranges: ranges
        )
        subscriptions = subscriptions.filter { memberListOrder.contains($0.key) }
        return SubscriptionState(
            memberListOrder: memberListOrder,
            subscriptionsByMemberListID: subscriptions
        )
    }

    static func requiresSubscriptionUpdate(
        memberListID: String,
        ranges: [ClosedRange<Int>],
        currentSubscriptions: [String: DiscordMemberListSubscription]
    ) -> Bool {
        currentSubscriptions[memberListID]?.ranges != ranges
    }
}

struct DiscordMemberListSubscription: Equatable {
    let channelID: ChannelID
    let ranges: [ClosedRange<Int>]
}

enum DiscordMemberListIdentity {
    private static let viewChannel: UInt64 = 1 << 10

    static func id(for channel: Channel, guildID: GuildID, roles: [GuildRoleDTO]) -> String {
        if let memberListID = channel.memberListID, !memberListID.isEmpty {
            return memberListID
        }
        let everyonePermissions = roles.first(where: { $0.id == guildID.description })
            .flatMap(\.permissions).flatMap(UInt64.init) ?? 0
        let everyoneCanView = everyonePermissions & viewChannel != 0
        let overwrites = channel.permissionOverwrites ?? []
        if everyoneCanView, !overwrites.contains(where: { $0.deny & viewChannel != 0 }) {
            return "everyone"
        }
        let permissionShape = overwrites.compactMap { overwrite -> String? in
            if overwrite.allow & viewChannel != 0 { return "allow:\(overwrite.id)" }
            if overwrite.deny & viewChannel != 0 { return "deny:\(overwrite.id)" }
            return nil
        }.sorted().joined(separator: ",")
        return String(murmurHash3(permissionShape.utf8))
    }

    private static func murmurHash3(_ bytes: String.UTF8View) -> UInt32 {
        let data = Array(bytes)
        var hash: UInt32 = 0
        let count = data.count
        let blockCount = count / 4
        for block in 0 ..< blockCount {
            let offset = block * 4
            var key = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            key &*= 0xcc9e2d51
            key = (key << 15) | (key >> 17)
            key &*= 0x1b873593
            hash ^= key
            hash = (hash << 13) | (hash >> 19)
            hash = hash &* 5 &+ 0xe6546b64
        }
        var tail: UInt32 = 0
        let tailOffset = blockCount * 4
        switch count & 3 {
        case 3:
            tail ^= UInt32(data[tailOffset + 2]) << 16
            fallthrough
        case 2:
            tail ^= UInt32(data[tailOffset + 1]) << 8
            fallthrough
        case 1:
            tail ^= UInt32(data[tailOffset])
            tail &*= 0xcc9e2d51
            tail = (tail << 15) | (tail >> 17)
            tail &*= 0x1b873593
            hash ^= tail
        default:
            break
        }
        hash ^= UInt32(count)
        hash ^= hash >> 16
        hash &*= 0x85ebca6b
        hash ^= hash >> 13
        hash &*= 0xc2b2ae35
        hash ^= hash >> 16
        return hash
    }
}

struct PrivateCallEligibilityDTO: Decodable {
    var ringable: Bool
}

struct PrivateCallDTO: Decodable {
    var channelID: String
    var messageID: String?
    var region: String?
    var ongoingRings: [String: String?]?
    var voiceStates: [VoiceStateUpdateDTO]?
    var unavailable: Bool?

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case messageID = "message_id"
        case region
        case ongoingRings = "ongoing_rings"
        case voiceStates = "voice_states"
        case unavailable
    }

    func domain() -> PrivateCall? {
        guard let channelID = ChannelID(channelID) else { return nil }
        let rings = (ongoingRings ?? [:]).compactMap { recipient, sender -> PrivateCallRing? in
            guard let recipientID = UserID(recipient),
                  let sender,
                  let senderID = UserID(sender)
            else { return nil }
            return PrivateCallRing(recipientID: recipientID, senderID: senderID)
        }
        .sorted { $0.recipientID.rawValue < $1.recipientID.rawValue }
        return PrivateCall(
            channelID: channelID,
            messageID: messageID.flatMap(MessageID.init),
            region: region,
            ongoingRings: rings,
            voiceStates: voiceStates?.compactMap { $0.domain() },
            isUnavailable: unavailable ?? false
        )
    }
}

struct PrivateCallDeleteDTO: Decodable {
    var channelID: String
    var unavailable: Bool?

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case unavailable
    }
}

struct PendingRoleMemberRequest {
    var guildID: GuildID
    var requestedUserIDs: Set<UserID>
    var members: [Member]
    var receivedChunks: Set<Int>
    var continuation: CheckedContinuation<[Member], any Error>
    var timeoutTask: Task<Void, Never>
}

struct PendingMemberSearchRequest {
    var guildID: GuildID
    var maximumResults: Int
    var members: [Member]
    var receivedChunks: Set<Int>
    var continuation: CheckedContinuation<[Member], any Error>
    var timeoutTask: Task<Void, Never>
}

enum DiscordMemberChunkRouting {
    static func pendingRequestID(
        guildID: GuildID,
        responseUserIDs: Set<UserID>,
        requests: [DiscordPendingMemberRequestDescriptor]
    ) -> String? {
        let guildRequests = requests.filter { $0.guildID == guildID }
        guard !responseUserIDs.isEmpty else { return nil }

        // Discord currently omits the request nonce from user-ID member chunks.
        // Prefer an exact ID-set match, then accept a subset for chunked replies.
        return guildRequests.first { $0.requestedUserIDs == responseUserIDs }?.id
            ?? guildRequests.first {
                $0.requestedUserIDs.isSuperset(of: responseUserIDs)
            }?.id
    }
}

struct DiscordPendingMemberRequestDescriptor {
    var id: String
    var guildID: GuildID
    var requestedUserIDs: Set<UserID>
}

enum DiscordMemberStoreOrdering {
    static func merging(existing: [Member], updates: [Member]) -> [Member] {
        var result = existing
        var indexByID = Dictionary(uniqueKeysWithValues: result.indices.map { (result[$0].id, $0) })
        for var member in updates {
            if let index = indexByID[member.id] {
                if member.memberListIndex == nil {
                    member.memberListIndex = result[index].memberListIndex
                }
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

enum DiscordMessageMemberHydration {
    /// A history page contains at most 100 messages. Authors are prioritized so
    /// resolving a page needs at most one bounded Gateway member request; any
    /// remaining capacity mirrors Discord and Paicord by including mentions.
    static let maximumUserIDsPerHistoryPage = 100

    static func missingUserIDs(
        in messages: [Message],
        cached: Set<UserID>,
        requested: Set<UserID>
    ) -> [UserID] {
        var seen = cached.union(requested)
        var result: [UserID] = []

        func append(_ userID: UserID) {
            guard result.count < maximumUserIDsPerHistoryPage, seen.insert(userID).inserted else {
                return
            }
            result.append(userID)
        }

        for message in messages {
            append(message.author.id)
            if let replyAuthorID = message.replyPreview?.author.id {
                append(replyAuthorID)
            }
        }
        for message in messages {
            for user in message.mentionedUsers {
                append(user.id)
            }
        }
        return result
    }

    static func hydrate(message: inout Message, membersByID: [UserID: Member]) {
        if let member = membersByID[message.author.id] {
            message.guildMember = MessageGuildMember.merging(
                incoming: MessageGuildMember(member: member),
                existing: message.guildMember
            )
        }
        if var preview = message.replyPreview,
           let member = membersByID[preview.author.id]
        {
            preview.guildMember = MessageGuildMember.merging(
                incoming: MessageGuildMember(member: member),
                existing: preview.guildMember
            )
            message.replyPreview = preview
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

struct PendingVoiceNegotiation {
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

struct GatewayActivityParticipantDTO: Decodable {
    var member: GuildMemberDTO?
}

struct GatewayActivityInstanceDTO: Decodable {
    var participants: [GatewayActivityParticipantDTO]

    private enum CodingKeys: String, CodingKey {
        case participants
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        participants = (try? container.decode(
            LossyList<GatewayActivityParticipantDTO>.self,
            forKey: .participants
        ))?.elements ?? []
    }
}

struct GatewayReadyGuildsDTO: Decodable {
    struct GuildReference: Decodable {
        var id: String
        var name: String?
        var icon: String?
        var owner: Bool?
        var ownerID: String?
        var permissions: String?
        var rulesChannelID: String?
        var defaultMessageNotifications: Int?
        var features: Set<String>
        var voiceStates: [VoiceStateUpdateDTO]
        var emojis: GatewayGuildEmojiCollectionDTO?
        var channels: [ChannelDTO]
        var threads: [ChannelDTO]
        var roles: [GuildRoleDTO]
        var members: [GuildMemberDTO]
        var activityInstances: [GatewayActivityInstanceDTO]

        enum CodingKeys: String, CodingKey {
            case id, name, icon, owner, permissions, properties, features
            case ownerID = "owner_id"
            case rulesChannelID = "rules_channel_id"
            case defaultMessageNotifications = "default_message_notifications"
            case voiceStates = "voice_states"
            case emojis
            case channels, threads, roles, members
            case activityInstances = "activity_instances"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let nested = try? container.decode(
                GatewayGuildPropertiesDTO.self, forKey: .properties
            )
            id = try container.decode(String.self, forKey: .id)
            name = (try? container.decode(String.self, forKey: .name)) ?? nested?.name
            icon = (try? container.decode(String.self, forKey: .icon)) ?? nested?.icon
            owner = (try? container.decode(Bool.self, forKey: .owner)) ?? nested?.owner
            ownerID = (try? container.decode(String.self, forKey: .ownerID))
                ?? nested?.ownerID
            permissions = (try? container.decode(
                StringOrIntegerDTO.self, forKey: .permissions
            ).value) ?? nested?.permissions
            rulesChannelID = (try? container.decode(
                String.self, forKey: .rulesChannelID
            )) ?? nested?.rulesChannelID
            defaultMessageNotifications = (try? container.decode(
                Int.self,
                forKey: .defaultMessageNotifications
            )) ?? nested?.defaultMessageNotifications
            features = (try? container.decode(Set<String>.self, forKey: .features))
                ?? nested?.features ?? []
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
            activityInstances =
                (try? container.decode(
                    LossyList<GatewayActivityInstanceDTO>.self,
                    forKey: .activityInstances
                ))?.elements ?? []
        }

        func domain(currentUserID: UserID?) -> Guild? {
            guard let id = GuildID(id), let name else { return nil }
            let iconURL = icon.flatMap { hash in
                URL(
                    string:
                        "https://cdn.discordapp.com/icons/\(id)/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                )
            }
            let isOwnedByCurrentUser = owner
                ?? ownerID.map { $0 == currentUserID?.description }
            return Guild(
                id: id,
                name: name,
                iconURL: iconURL,
                isOwnedByCurrentUser: isOwnedByCurrentUser,
                currentUserPermissions: permissions.flatMap(UInt64.init),
                rulesChannelID: rulesChannelID.flatMap(ChannelID.init),
                features: features,
                defaultMessageNotifications:
                    defaultMessageNotifications.flatMap(
                        MessageNotificationLevel.init(rawValue:)
                    ) ?? .onlyMentions
            )
        }
    }

    var guilds: [GuildReference]
    var privateChannels: [ChannelDTO]
    var lazyPrivateChannels: [ChannelDTO]
    var currentUser: UserDTO?
    var users: [UserDTO]
    var friendUserIDs: Set<UserID>
    var blockedOrIgnoredUserIDs: Set<UserID>
    var relationshipNicknamesByUserID: [UserID: String]
    var presences: [PresenceUpdateDTO]
    var mergedPresences: GatewayMergedPresencesDTO
    var mergedMembers: [[ReadyMergedMemberDTO]]
    var userSettingsProto: String?
    var readState: GatewayReadStateDTO
    var userGuildSettings: [GatewayUserGuildSettingsDTO]
    var userGuildSettingsPartial: Bool
    var usesNewNotifications: Bool

    enum CodingKeys: String, CodingKey {
        case guilds
        case privateChannels = "private_channels"
        case lazyPrivateChannels = "lazy_private_channels"
        case currentUser = "user"
        case users
        case relationships
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
        struct RelationshipDTO: Decodable {
            var id: String
            var type: Int
            var nickname: String?
            var user: UserDTO?

            var userIgnored: Bool?

            enum CodingKeys: String, CodingKey {
                case id, type, nickname, user
                case userIgnored = "user_ignored"
            }
        }
        let relationships =
            (try? container.decode(
                LossyList<RelationshipDTO>.self, forKey: .relationships
            ))?.elements ?? []
        friendUserIDs = Set(relationships.compactMap {
            $0.type == 1 ? UserID($0.id) : nil
        })
        blockedOrIgnoredUserIDs = Set(relationships.compactMap {
            $0.type == 2 || $0.userIgnored == true ? UserID($0.id) : nil
        })
        relationshipNicknamesByUserID = Dictionary(
            relationships.compactMap { relationship in
                guard let id = UserID(relationship.id),
                      let nickname = relationship.nickname?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !nickname.isEmpty
                else { return nil }
                return (id, nickname)
            },
            uniquingKeysWith: { _, newer in newer }
        )
        for relationship in relationships {
            guard let user = relationship.user,
                  !users.contains(where: { $0.id == user.id })
            else { continue }
            users.append(user)
        }
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

struct GatewayAccountNotificationSettingsDTO: Decodable {
    var flags: UInt64
}

struct GatewayUserGuildSettingsCollectionDTO: Decodable {
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

struct GatewayUserGuildSettingsDTO: Decodable {
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
        var collapsed: Bool?

        enum CodingKeys: String, CodingKey {
            case channelID = "channel_id"
            case messageNotifications = "message_notifications"
            case muted
            case muteConfig = "mute_config"
            case flags
            case collapsed
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
                flags: flags ?? 0,
                isCollapsed: collapsed
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
    var version: Int?
    var channelEntriesByID: [ChannelID: Entry] {
        Dictionary(
            entries.compactMap { entry in
                guard entry.readStateType == 0, let id = ChannelID(entry.id) else { return nil }
                return (id, entry)
            },
            uniquingKeysWith: { _, newer in newer }
        )
    }

    init(entries: [Entry]) {
        self.entries = entries
        version = nil
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries =
            (try? values.decode(LossyList<Entry>.self, forKey: .entries))?.elements ?? []
        version = try? values.decode(Int.self, forKey: .version)
    }

    private enum CodingKeys: String, CodingKey { case entries, version }
}

struct ReadyMergedMemberDTO: Decodable {
    var userID: String
    var nick: String?
    var roles: [String]?
    var presence: GuildPresenceDTO?
    var avatar: String?
    var banner: String?
    var bio: String?
    var pending: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case nick, roles, presence, avatar, banner, bio, pending
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
            bio: bio,
            pending: pending
        )
    }
}

struct GatewayGuildCatalogDTO: Decodable {
    var id: String
    var rulesChannelID: String?
    var channels: [ChannelDTO]?
    var threads: [ChannelDTO]?
    var roles: [GuildRoleDTO]?
    var members: [GuildMemberDTO]?

    enum CodingKeys: String, CodingKey {
        case id, channels, threads, roles, members
        case rulesChannelID = "rules_channel_id"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        rulesChannelID = try values.decodeIfPresent(String.self, forKey: .rulesChannelID)
        channels = try values.decodeIfPresent(
            LossyList<ChannelDTO>.self, forKey: .channels
        )?.elements
        threads = try values.decodeIfPresent(
            LossyList<ChannelDTO>.self, forKey: .threads
        )?.elements
        roles = try values.decodeIfPresent(
            LossyList<GuildRoleDTO>.self, forKey: .roles
        )?.elements
        members = try values.decodeIfPresent(
            LossyList<GuildMemberDTO>.self, forKey: .members
        )?.elements
    }
}

struct GatewayGuildMetadataDTO: Decodable {
    var id: String
    var rulesChannelID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case rulesChannelID = "rules_channel_id"
    }
}

struct GatewayThreadDeleteDTO: Decodable {
    var id: String
    var parentID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
    }
}

struct GatewayMessageAckDTO: Decodable {
    var channelID: String
    var messageID: String?
    var mentionCount: Int?
    var manual: Bool?
    var flags: UInt64?
    var lastViewed: Int?
    var version: Int?

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case messageID = "message_id"
        case mentionCount = "mention_count"
        case manual
        case flags
        case lastViewed = "last_viewed"
        case version
    }
}

struct GatewayThreadListSyncDTO: Decodable {
    var guildID: String
    var channelIDs: [String]
    var threads: [ChannelDTO]
    var members: [ThreadMemberDTO]

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case channelIDs = "channel_ids"
        case threads, members
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try values.decode(String.self, forKey: .guildID)
        channelIDs = try values.decodeIfPresent([String].self, forKey: .channelIDs) ?? []
        threads =
            try values.decodeIfPresent(
                LossyList<ChannelDTO>.self, forKey: .threads
            )?.elements ?? []
        members =
            try values.decodeIfPresent(
                LossyList<ThreadMemberDTO>.self, forKey: .members
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
