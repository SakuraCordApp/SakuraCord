import Foundation
import SakuraCordModels

/// Offline account state and lifecycle. Domain extensions implement the same
/// provider contract using this actor-isolated state and event stream.
public actor MockChatProvider: ChatProvider {
    let currentUser: User
    var snapshot: BootstrapSnapshot
    var membersByGuild: [GuildID: [Member]]
    var emojisByGuild: [GuildID: [DiscordEmoji]]
    var messagesByChannel: [ChannelID: [Message]]
    var pinnedAtByMessageID: [MessageID: Date]
    let pinMutationFailureStatus: Int?
    var forumPostsByChannel: [ChannelID: [ForumPost]]
    private var profilesByUser: [UserID: UserProfile]
    var privateCallsByChannel: [ChannelID: PrivateCall] = [:]
    var inboxSettingsValue = InboxSettings()
    var dismissedInboxMentions: Set<MessageID> = []
    var favoriteGIFValues: [GIFSearchResult] = []
    var favoriteEmojiKeys: [String]?
    var savedEmojiFrecency: (messages: DiscordFrecencyHistory, reactions: DiscordFrecencyHistory)?
    var soundboardSoundsByGuild: [GuildID: [SoundboardSound]] = [:]
    var soundboardSettings = SoundboardUserSettings()
    var continuation: AsyncStream<ClientEvent>.Continuation?
    var nextMessageID: UInt64
    public internal(set) var typingRequests: [ChannelID] = []
    public internal(set) var pinMutationRequests: [PinMutationRequest] = []
    public internal(set) var attachmentURLRefreshRequests: [URL] = []
    public internal(set) var voiceJoinRequests: [VoiceJoinRequest] = []
    public internal(set) var soundboardSendRequests: [SoundboardSendRequest] = []
    public internal(set) var acknowledgementRequests: [AcknowledgementRequest] = []
    public internal(set) var bulkAcknowledgementRequests:
        [[BulkReadStateAcknowledgement]] = []
    var bulkAckAcceptedPrefixBeforeFailure: Int?
    public internal(set) var guildNotificationRequests: [GuildNotificationRequest] = []
    public internal(set) var channelNotificationRequests: [ChannelNotificationRequest] = []
    public internal(set) var categoryNotificationRequests: [CategoryNotificationRequest] = []
    var categoryCollapsedUpdatesAreSuspended = false
    var categoryCollapsedUpdateWaiters: [CheckedContinuation<Void, Never>] = []
    public internal(set) var threadNotificationRequests: [ThreadNotificationRequest] = []
    var forumQueriesByChannel: [ChannelID: [ForumPostQuery]] = [:]
    var relationshipPresences: [UserID: UserPresence]?
    var presenceChurnTask: Task<Void, Never>?

    public init(
        includesLongServerList: Bool = false,
        forumPostCount: Int? = nil,
        timelineMessageCount: Int? = nil,
        pinnedMessageCount: Int? = nil,
        pinMutationFailureStatus: Int? = nil,
        timelineIncludesAnimatedMedia: Bool = false,
        includesIncomingPrivateCall: Bool = false,
        friendCount: Int? = nil
    ) {
        let fixture = MockChatFixture.make(
            includesLongServerList: includesLongServerList,
            timelineMessageCount: timelineMessageCount,
            timelineIncludesAnimatedMedia: timelineIncludesAnimatedMedia
        )
        currentUser = fixture.currentUser
        self.pinMutationFailureStatus = pinMutationFailureStatus
        nextMessageID = UInt64(ClientNonce.make()) ?? 9000
        snapshot = fixture.snapshot
        for (index, guild) in fixture.snapshot.guilds.enumerated() {
            soundboardSoundsByGuild[guild.id] = (0 ..< 9).map { soundIndex in
                SoundboardSound(
                    id: String(70_000 + index * 100 + soundIndex),
                    name: ["Cherry Pop", "Rain Bell", "Tiny Drum", "Night Bloom"][soundIndex % 4],
                    volume: 0.9,
                    emojiID: soundIndex.isMultiple(of: 2)
                        ? fixture.snapshot.guilds.first?.id.description
                        : nil,
                    emojiName: soundIndex.isMultiple(of: 2) ? "sakura" : "🌸",
                    guildID: guild.id,
                    userID: fixture.currentUser.id
                )
            }
        }
        membersByGuild = fixture.membersByGuild
        emojisByGuild = fixture.emojisByGuild
        messagesByChannel = fixture.messagesByChannel
        if let pinnedMessageCount,
           var messages = messagesByChannel[ChannelID(rawValue: 210)]
        {
            for index in messages.indices.suffix(max(0, pinnedMessageCount)) {
                messages[index].isPinned = true
            }
            messagesByChannel[ChannelID(rawValue: 210)] = messages
        }
        pinnedAtByMessageID = Dictionary(
            uniqueKeysWithValues: messagesByChannel.values.flatMap { messages in
                messages.filter(\.isPinned).map { ($0.id, $0.timestamp) }
            }
        )
        let forumFixture = Self.makeForumPosts(
            channelID: ChannelID(rawValue: 220),
            authors: fixture.membersByGuild[GuildID(rawValue: 100)]?.map(\.user) ?? [
                fixture.currentUser
            ],
            count: forumPostCount ?? 6
        )
        let bugForumFixture = Self.makeForumPosts(
            channelID: ChannelID(rawValue: 221),
            authors: fixture.membersByGuild[GuildID(rawValue: 100)]?.map(\.user) ?? [
                fixture.currentUser
            ]
        )
        forumPostsByChannel = [
            ChannelID(rawValue: 220): forumFixture,
            ChannelID(rawValue: 221): bugForumFixture,
        ]
        for post in forumFixture + bugForumFixture {
            if let message = post.firstMessage {
                messagesByChannel[post.id] = [message]
            }
        }
        profilesByUser = fixture.profilesByUser
        if let friendCount {
            let fixture = Self.performanceRelationships(friendCount: friendCount)
            snapshot.relationships += fixture.relationships
            snapshot.friendUserIDs = snapshot.relationships.friendUserIDs
            snapshot.relationshipNicknamesByUserID = snapshot.relationships.nicknamesByUserID
            relationshipPresences = fixture.presences
        }
        if includesIncomingPrivateCall {
            let channelID = ChannelID(rawValue: 400)
            let callerID = UserID(rawValue: 2)
            privateCallsByChannel[channelID] = PrivateCall(
                channelID: channelID,
                messageID: MessageID(rawValue: nextMessageID),
                region: "mock",
                ongoingRings: [
                    PrivateCallRing(
                        recipientID: fixture.currentUser.id,
                        senderID: callerID
                    )
                ],
                voiceStates: [
                    VoiceParticipantState(
                        userID: callerID,
                        channelID: channelID,
                        guildID: nil,
                        sessionID: "mock-incoming-private-call"
                    )
                ]
            )
        }
    }

    /// A self-contained local conversation for interactive previews.
    public init(snapshot: BootstrapSnapshot, messages: [Message]) {
        currentUser = snapshot.currentUser
        self.snapshot = snapshot
        membersByGuild = [:]
        emojisByGuild = [:]
        messagesByChannel = Dictionary(grouping: messages, by: \.channelID)
        pinnedAtByMessageID = Dictionary(
            uniqueKeysWithValues: messages.filter(\.isPinned).map { ($0.id, $0.timestamp) }
        )
        pinMutationFailureStatus = nil
        forumPostsByChannel = [:]
        profilesByUser = Dictionary(uniqueKeysWithValues: snapshot.knownUsers.map {
            ($0.id, UserProfile(user: $0))
        })
        nextMessageID = (messages.map { $0.id.rawValue }.max() ?? 9000) + 1
    }

    public func accountDetails() async throws -> AccountDetails {
        AccountDetails(
            userID: currentUser.id, username: currentUser.username,
            email: "nova@example.com", phoneNumber: nil, isMFAEnabled: true
        )
    }

    public func accountDevices() async throws -> [AccountDevice] {
        [
            AccountDevice(id: "demo-mac", operatingSystem: "Mac OS X", platform: "SakuraCord", location: "Kyiv, Ukraine", lastUsedAt: .now, isCurrentSession: true),
            AccountDevice(id: "demo-phone", operatingSystem: "iOS", platform: "Discord iOS", location: "Kyiv, Ukraine", lastUsedAt: .now.addingTimeInterval(-7200), isCurrentSession: false),
            AccountDevice(id: "demo-browser", operatingSystem: "Mac OS X", platform: "Chrome", location: "Kyiv, Ukraine", lastUsedAt: .now.addingTimeInterval(-86400), isCurrentSession: false),
        ]
    }

    public func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.connecting))
        try await Task.sleep(for: .milliseconds(180))
        continuation?.yield(.connectionChanged(.ready))
        let referenceMembers = Dictionary(
            (membersByGuild[GuildID(rawValue: 100)] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        var presences = Dictionary(uniqueKeysWithValues: snapshot.relationships.map { relationship in
            let member = referenceMembers[relationship.id]
            return (relationship.id, UserPresence(
                status: member?.status ?? .offline,
                customStatus: member?.customStatus, activityText: member?.activityText,
                isListeningToMusic: member?.isListeningToMusic ?? false, isMobileOnly: member?.isMobileOnly ?? false
            ))
        })
        presences.merge(relationshipPresences ?? [:]) { _, fixture in fixture }
        continuation?.yield(.relationshipPresencesChanged(presences, isComplete: true))
        return snapshot
    }

    public func channels(in guildID: GuildID?) async throws -> [Channel] {
        snapshot.channels.filter { $0.guildID == guildID }
    }

    private var privateChannels: [Channel] {
        snapshot.channels.filter { $0.guildID == nil }
    }

    public func members(in guildID: GuildID?) async throws -> [Member] {
        guard let guildID else {
            var usersByID = Dictionary(
                privateChannels.flatMap(\.recipients).map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            usersByID[currentUser.id] = currentUser
            let referenceMembersByID = Dictionary(
                (membersByGuild[GuildID(rawValue: 100)] ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            return usersByID.values.map {
                let reference = referenceMembersByID[$0.id]
                var member = Member(
                    user: $0,
                    roleName: $0.id == currentUser.id ? "You" : "Direct Message",
                    status: $0.id == currentUser.id ? .online : reference?.status ?? .offline,
                    activityText: reference?.activityText,
                    customStatus: reference?.customStatus,
                    isListeningToMusic: reference?.isListeningToMusic ?? false
                )
                if let nickname = snapshot.relationshipNicknamesByUserID[$0.id] {
                    member.globalDisplayName = $0.displayName
                    member.user.displayName = nickname
                }
                return member
            }
        }
        return membersByGuild[guildID] ?? []
    }

    public func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        guard let profile = profilesByUser[userID] else {
            throw ChatProviderError.invalidRequest("That demo profile is unavailable.")
        }
        return profile
    }

    public func profileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot {
        let presentation = try await profile(for: currentUser.id, in: scope.guildID)
        let identity = ProfileIdentityFields(
            name: .value(presentation.user.displayName),
            displayNameStyle: presentation.user.displayNameStyle.map { .value($0) } ?? .null
        )
        let colors = presentation.themeHexes
        let metadata = ProfileMetadataFields(
            bio: .value(presentation.bio ?? ""),
            pronouns: .value(presentation.pronouns ?? ""),
            accentColor: presentation.accentHex.map { .value($0) } ?? .null,
            themeColors: colors.count == 2
                ? .value(ProfileThemeColors(primary: colors[0], accent: colors[1])) : .null
        )
        return ProfileEditingSnapshot(
            scope: scope,
            mainIdentity: identity,
            mainMetadata: metadata,
            serverIdentity: scope.guildID.map { _ in ProfileIdentityFields() },
            serverMetadata: scope.guildID.map { _ in ProfileMetadataFields() },
            presentation: presentation,
            widgetEligibility: ProfileWidgetEligibility(
                hasFullNitro: currentUser.premiumType == 2, hasPersonalWidgetAccess: false
            )
        )
    }

    public func currentStatus() async -> PresenceStatus {
        .online
    }

    public func updateStatus(_ status: PresenceStatus) async throws {
        for guildID in Array(membersByGuild.keys) {
            membersByGuild[guildID] = membersByGuild[guildID]?.map { member in
                guard member.user.id == snapshot.currentUser.id else { return member }
                var updatedMember = member
                updatedMember.status = status
                return updatedMember
            }
        }
        snapshot.members =
            membersByGuild[snapshot.guilds.first?.id ?? GuildID(rawValue: 0)] ?? snapshot.members
        continuation?.yield(.snapshotChanged(snapshot))
        continuation?.yield(.currentUserStatusChanged(status))
    }

    public func emit(_ event: ClientEvent) {
        continuation?.yield(event)
    }

    public func supports(_ capability: ChatCapability) async -> Bool {
        capability == .forums || capability == .gifs || capability == .stickers
            || capability == .stickerSending
            || capability == .components || capability == .modals
            || capability == .remoteComponentChoices
            || capability == .slashCommands || capability == .messageForwarding
            || capability == .soundboard
    }

    public func eventStream() async -> AsyncStream<ClientEvent> {
        let stream = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        continuation = stream.continuation
        for call in privateCallsByChannel.values {
            stream.continuation.yield(.privateCallChanged(call))
        }
        return stream.stream
    }

    public func disconnect() async {
        continuation?.yield(.connectionChanged(.disconnected))
        continuation?.finish()
        continuation = nil
    }

    public func updateGuildRailLayout(_ items: [GuildRailItem]) async throws {
        let guildsByID = Dictionary(snapshot.guilds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshot.guildRailItems = items
        snapshot.guilds = items.flattenedGuildIDs.compactMap { guildsByID[$0] }
    }

    public func createServerInvite(in channelID: ChannelID, guildID: GuildID, settings: ServerInviteSettings) async throws -> CreatedServerInvite {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0 ..< 8).map { _ in alphabet.randomElement()! })
        let now = Date.now
        return CreatedServerInvite(
            reference: ServerInviteReference(code)!, guildID: guildID, channelID: channelID, createdAt: now,
            expiresAt: settings.maxAge == .never ? nil : now.addingTimeInterval(TimeInterval(settings.maxAge.rawValue)),
            maxAge: settings.maxAge.rawValue, maxUses: settings.maxUses.rawValue
        )
    }
}
