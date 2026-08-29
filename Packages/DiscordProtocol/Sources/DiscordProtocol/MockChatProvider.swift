import Foundation
import SakuraCordModels
import UniformTypeIdentifiers

public actor MockChatProvider: ChatProvider {
    private let currentUser: User
    private var snapshot: BootstrapSnapshot
    private var membersByGuild: [GuildID: [Member]]
    private var emojisByGuild: [GuildID: [DiscordEmoji]]
    private var messagesByChannel: [ChannelID: [Message]]
    private var forumPostsByChannel: [ChannelID: [ForumPost]]
    private var profilesByUser: [UserID: UserProfile]
    private var privateCallsByChannel: [ChannelID: PrivateCall] = [:]
    private var favoriteGIFValues: [GIFSearchResult] = []
    private var favoriteEmojiKeys: [String]?
    private var continuation: AsyncStream<ClientEvent>.Continuation?
    private var nextMessageID: UInt64
    public private(set) var typingRequests: [ChannelID] = []
    public struct VoiceJoinRequest: Equatable, Sendable {
        public var channelID: ChannelID
        public var guildID: GuildID?
        public var selfMute: Bool
        public var selfDeaf: Bool

        public init(
            channelID: ChannelID,
            guildID: GuildID?,
            selfMute: Bool,
            selfDeaf: Bool
        ) {
            self.channelID = channelID
            self.guildID = guildID
            self.selfMute = selfMute
            self.selfDeaf = selfDeaf
        }
    }

    public private(set) var voiceJoinRequests: [VoiceJoinRequest] = []
    public struct AcknowledgementRequest: Equatable, Sendable {
        public var channelID: ChannelID
        public var messageID: MessageID
        public var token: String?
        public var manual: Bool
        public var mentionCount: Int?
        public var flags: UInt64?
        public var lastViewed: Int?
    }

    public private(set) var acknowledgementRequests: [AcknowledgementRequest] = []
    public private(set) var bulkAcknowledgementRequests:
        [[BulkReadStateAcknowledgement]] = []
    private var bulkAckAcceptedPrefixBeforeFailure: Int?
    public struct GuildNotificationRequest: Equatable, Sendable {
        public var guildID: GuildID
        public var level: MessageNotificationLevel?
        public var isMuted: Bool?
        public var muteEndTime: Date?
        public var toggle: GuildNotificationToggle?
        public var isEnabled: Bool?
    }

    public private(set) var guildNotificationRequests: [GuildNotificationRequest] = []
    public struct ChannelNotificationRequest: Equatable, Sendable {
        public var guildID: GuildID?
        public var channelID: ChannelID
        public var level: MessageNotificationLevel?
        public var isMuted: Bool?
        public var muteEndTime: Date?
    }

    public private(set) var channelNotificationRequests: [ChannelNotificationRequest] = []
    public struct CategoryNotificationRequest: Equatable, Sendable {
        public var guildID: GuildID
        public var categoryID: ChannelID
        public var level: MessageNotificationLevel?
        public var isMuted: Bool?
        public var muteEndTime: Date?
        public var isCollapsed: Bool?
    }

    public private(set) var categoryNotificationRequests: [CategoryNotificationRequest] = []
    private var categoryCollapsedUpdatesAreSuspended = false
    private var categoryCollapsedUpdateWaiters: [CheckedContinuation<Void, Never>] = []
    public struct ThreadNotificationRequest: Equatable, Sendable {
        public var threadID: ChannelID
        public var level: MessageNotificationLevel?
        public var isMuted: Bool?
        public var muteEndTime: Date?
    }

    public private(set) var threadNotificationRequests: [ThreadNotificationRequest] = []
    private var forumQueriesByChannel: [ChannelID: [ForumPostQuery]] = [:]

    public init(
        includesLongServerList: Bool = false,
        forumPostCount: Int? = nil,
        timelineMessageCount: Int? = nil,
        timelineIncludesAnimatedMedia: Bool = false,
        includesIncomingPrivateCall: Bool = false
    ) {
        let fixture = MockChatFixture.make(
            includesLongServerList: includesLongServerList,
            timelineMessageCount: timelineMessageCount,
            timelineIncludesAnimatedMedia: timelineIncludesAnimatedMedia
        )
        currentUser = fixture.currentUser
        nextMessageID = UInt64(ClientNonce.make()) ?? 9000
        snapshot = fixture.snapshot
        membersByGuild = fixture.membersByGuild
        emojisByGuild = fixture.emojisByGuild
        messagesByChannel = fixture.messagesByChannel
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

    public func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.connecting))
        try await Task.sleep(for: .milliseconds(180))
        continuation?.yield(.connectionChanged(.ready))
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
                return Member(
                    user: $0,
                    roleName: $0.id == currentUser.id ? "You" : "Direct Message",
                    status: $0.id == currentUser.id ? .online : reference?.status ?? .offline,
                    activityText: reference?.activityText,
                    customStatus: reference?.customStatus
                )
            }
        }
        return membersByGuild[guildID] ?? []
    }

    public func emojis(in guildID: GuildID) async throws -> [DiscordEmoji] {
        emojisByGuild[guildID] ?? []
    }

    public func emojiUserSettings() async throws -> EmojiUserSettings {
        EmojiUserSettings(
            favoriteKeys: favoriteEmojiKeys ?? [
                "custom:900000000000000201", "white_check_mark", "x", "neutral_face",
                "broken_heart", "hot_face",
                "smiling_face_with_3_hearts", "cry", "fire", "thumbsup", "sob",
            ],
            frequentlyUsedKeys: [
                "custom:900000000000000202", "broken_heart", "white_check_mark", "neutral_face",
                "sob", "pray", "fire",
                "cry", "wilted_flower", "person_shrugging", "white_heart", "thumbsup", "x",
                "unamused", "hot_face", "pleading_face", "smiley_cat", "eyes",
            ],
            usageScores: [:],
            guildAndChannelUsageScores: Dictionary(
                uniqueKeysWithValues: snapshot.channels.enumerated().map { index, channel in
                    (channel.id.description, max(1, snapshot.channels.count - index))
                }
            )
        )
    }

    public func setEmojiFavorite(
        _ key: String,
        isFavorite: Bool
    ) async throws -> EmojiUserSettings {
        var settings = try await emojiUserSettings()
        settings.favoriteKeys.removeAll { $0 == key }
        if isFavorite {
            settings.favoriteKeys.append(key)
        }
        favoriteEmojiKeys = settings.favoriteKeys
        return settings
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
        acknowledgementRequests.append(
            AcknowledgementRequest(
                channelID: channelID,
                messageID: messageID,
                token: token,
                manual: manual,
                mentionCount: mentionCount,
                flags: flags,
                lastViewed: lastViewed
            )
        )
        let version = (snapshot.readStates.compactMap(\.version).max() ?? 0) + 1
        let existing = snapshot.readStates.first { $0.channelID == channelID }
        let latestMessageID = snapshot.channels.first { $0.id == channelID }?.lastMessageID
        let acknowledgedMessageID = manual
            ? messageID
            : max(existing?.lastAcknowledgedMessageID ?? messageID, messageID)
        let clearsKnownMessages = latestMessageID.map { messageID >= $0 } ?? true
        let updated = ChannelReadState(
            channelID: channelID,
            lastAcknowledgedMessageID: acknowledgedMessageID,
            mentionCount: mentionCount ?? (clearsKnownMessages ? 0 : existing?.mentionCount ?? 0),
            isManual: manual,
            flags: flags ?? existing?.flags,
            lastViewed: lastViewed ?? existing?.lastViewed,
            version: version
        )
        if let index = snapshot.readStates.firstIndex(where: { $0.channelID == channelID }) {
            snapshot.readStates[index] = updated
        } else {
            snapshot.readStates.append(updated)
        }
        continuation?.yield(.readStateChanged(updated))
        return ReadAcknowledgementResponse(token: "mock-ack-token")
    }

    public func updateChannelNotificationLevel(
        guildID: GuildID?,
        channelID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        channelNotificationRequests.append(
            ChannelNotificationRequest(
                guildID: guildID,
                channelID: channelID,
                level: level
            )
        )
    }

    public func acknowledgeBulk(
        _ readStates: [BulkReadStateAcknowledgement]
    ) async throws {
        bulkAcknowledgementRequests.append(readStates)
        if let acceptedCount = bulkAckAcceptedPrefixBeforeFailure {
            throw PartialBulkReadAcknowledgementError(
                acceptedReadStates: Array(readStates.prefix(acceptedCount)),
                failureDescription: "Synthetic later-batch failure"
            )
        }
    }

    public func failBulkAcknowledgement(afterAcceptedCount acceptedCount: Int) {
        bulkAckAcceptedPrefixBeforeFailure = max(0, acceptedCount)
    }

    public func updateGuildNotificationLevel(
        guildID: GuildID,
        level: MessageNotificationLevel
    ) async throws {
        guildNotificationRequests.append(
            GuildNotificationRequest(guildID: guildID, level: level)
        )
    }

    public func updateGuildMute(
        guildID: GuildID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        guildNotificationRequests.append(
            GuildNotificationRequest(
                guildID: guildID,
                isMuted: isMuted,
                muteEndTime: until
            )
        )
    }

    public func updateGuildNotificationToggle(
        guildID: GuildID,
        toggle: GuildNotificationToggle,
        isEnabled: Bool
    ) async throws {
        guildNotificationRequests.append(
            GuildNotificationRequest(
                guildID: guildID,
                toggle: toggle,
                isEnabled: isEnabled
            )
        )
    }

    public func updateChannelMute(
        guildID: GuildID?,
        channelID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        channelNotificationRequests.append(
            ChannelNotificationRequest(
                guildID: guildID,
                channelID: channelID,
                isMuted: isMuted,
                muteEndTime: until
            )
        )
    }

    public func updateCategoryNotificationLevel(
        guildID: GuildID,
        categoryID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        categoryNotificationRequests.append(
            CategoryNotificationRequest(
                guildID: guildID,
                categoryID: categoryID,
                level: level
            )
        )
    }

    public func updateCategoryMute(
        guildID: GuildID,
        categoryID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        categoryNotificationRequests.append(
            CategoryNotificationRequest(
                guildID: guildID,
                categoryID: categoryID,
                isMuted: isMuted,
                muteEndTime: until
            )
        )
    }

    public func updateCategoryCollapsed(
        guildID: GuildID,
        categoryID: ChannelID,
        isCollapsed: Bool
    ) async throws {
        categoryNotificationRequests.append(
            CategoryNotificationRequest(
                guildID: guildID,
                categoryID: categoryID,
                isCollapsed: isCollapsed
            )
        )
        if categoryCollapsedUpdatesAreSuspended {
            await withCheckedContinuation { continuation in
                categoryCollapsedUpdateWaiters.append(continuation)
            }
        }
    }

    public func suspendCategoryCollapsedUpdates() {
        categoryCollapsedUpdatesAreSuspended = true
    }

    public func resumeCategoryCollapsedUpdates() {
        categoryCollapsedUpdatesAreSuspended = false
        let waiters = categoryCollapsedUpdateWaiters
        categoryCollapsedUpdateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        guard let profile = profilesByUser[userID] else {
            throw ChatProviderError.invalidRequest("That demo profile is unavailable.")
        }
        return profile
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
        if var profile = profilesByUser[currentUser.id] {
            profile.status = status
            profilesByUser[currentUser.id] = profile
        }
        continuation?.yield(.snapshotChanged(snapshot))
    }

    public func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        try await messages(
            in: channelID,
            anchoredAt: before.map(MessageHistoryAnchor.before) ?? .newest,
            limit: limit
        )
    }

    public func messages(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage {
        guard
            snapshot.channels.contains(where: { $0.id == channelID })
            || messagesByChannel[channelID] != nil
        else {
            throw ChatProviderError.channelNotFound
        }
        let messages = messagesByChannel[channelID] ?? []
        let boundedLimit = min(max(1, limit), 100)

        func lowerBound(for messageID: MessageID) -> Int {
            var lowerBound = messages.startIndex
            var upperBound = messages.endIndex
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                if messages[middle].id < messageID {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            return lowerBound
        }

        let pageStart: Int
        let pageEnd: Int
        switch anchor {
        case .newest:
            pageEnd = messages.endIndex
            pageStart = max(messages.startIndex, pageEnd - boundedLimit)
        case .before(let messageID):
            pageEnd = lowerBound(for: messageID)
            pageStart = max(messages.startIndex, pageEnd - boundedLimit)
        case .after(let messageID):
            let boundary = lowerBound(for: messageID)
            pageStart = messages.indices.contains(boundary)
                && messages[boundary].id == messageID
                ? boundary + 1
                : boundary
            pageEnd = min(messages.endIndex, pageStart + boundedLimit)
        case .around(let messageID):
            let target = min(lowerBound(for: messageID), messages.endIndex)
            let proposedStart = max(
                messages.startIndex,
                target - boundedLimit / 2
            )
            pageEnd = min(messages.endIndex, proposedStart + boundedLimit)
            pageStart = max(messages.startIndex, pageEnd - boundedLimit)
        }
        let page = Array(messages[pageStart ..< pageEnd])
        return MessagePage(
            messages: page,
            hasMoreBefore: pageStart > messages.startIndex,
            hasMoreAfter: pageEnd < messages.endIndex
        )
    }

    public func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        forumQueriesByChannel[channelID, default: []].append(query)
        guard snapshot.channels.contains(where: { $0.id == channelID && $0.kind == .forum }) else {
            throw ChatProviderError.channelNotFound
        }
        var posts = forumPostsByChannel[channelID] ?? []
        switch query.scope {
        case .active:
            let active = query.offset == 0 ? posts.filter { !$0.thread.isArchived } : []
            var older = posts.filter(\.thread.isArchived)
            older.sort {
                ($0.thread.archiveTimestamp ?? .distantPast)
                    > ($1.thread.archiveTimestamp ?? .distantPast)
            }
            let pageStart = min(query.offset, older.count)
            let pageEnd = min(pageStart + query.limit, older.count)
            let olderPage = Array(older[pageStart ..< pageEnd])
            posts = active + olderPage
            posts = filterAndSortForumPosts(posts, query: query)
            return ForumPostPage(
                posts: posts,
                hasMore: pageEnd < older.count,
                nextOffset: pageEnd < older.count ? pageEnd : nil
            )
        case .search(let text):
            posts.removeAll {
                !$0.thread.name.localizedCaseInsensitiveContains(text)
            }
        }
        posts = ForumPostQueryPolicy.filteredAndSorted(
            posts,
            selectedTagIDs: query.selectedTagIDs,
            tagMatch: query.tagMatch,
            sortOrder: query.sortOrder
        )
        return ForumPostPage(posts: posts, hasMore: false, nextOffset: nil)
    }

    public func forumQueries(in channelID: ChannelID) -> [ForumPostQuery] {
        forumQueriesByChannel[channelID] ?? []
    }

    public func emit(_ event: ClientEvent) {
        continuation?.yield(event)
    }

    /// Feeds the normal Gateway-event path with deterministic high-volume
    /// arrivals. This is offline-only test infrastructure; it never performs
    /// a network request or user-visible account action.
    public func emitTimelineStressMessages(
        in channelID: ChannelID,
        count: Int,
        burstSize: Int = 4,
        burstInterval: Duration = .milliseconds(32)
    ) async {
        guard count > 0,
              burstSize > 0,
              let channel = snapshot.channels.first(where: { $0.id == channelID })
        else { return }
        let authors =
            channel.guildID.flatMap { membersByGuild[$0]?.map(\.user) }
            ?? [currentUser]
        guard !authors.isEmpty else { return }
        let latestTimestamp =
            messagesByChannel[channelID]?.last?.timestamp
            ?? Date(timeIntervalSince1970: 1_700_000_000)
        var emitted = 0
        while emitted < count, !Task.isCancelled {
            let batchCount = min(burstSize, count - emitted)
            for offset in 0 ..< batchCount {
                nextMessageID &+= 1
                let index = emitted + offset
                let author = authors[index % authors.count]
                let content =
                    switch index % 5 {
                    case 0:
                        "Live arrival \(index) exercises the compact append path."
                    case 1:
                        "A new message is landing while the timeline keeps scrolling smoothly."
                    case 2:
                        "Live arrival \(index) wraps onto a second line to vary row height without blocking the viewport renderer."
                    case 3:
                        "**Incoming \(index)** includes `inline code`, a link, and emoji ✨."
                    default:
                        "Burst message \(index)\nSecond line arrives in the same offline batch."
                    }
                let message = Message(
                    id: MessageID(rawValue: nextMessageID),
                    channelID: channelID,
                    author: author,
                    content: content,
                    timestamp: latestTimestamp.addingTimeInterval(Double(index + 1)),
                    reactions: index.isMultiple(of: 11)
                        ? [Reaction(emoji: "⚡️", count: 3)]
                        : [],
                    guildID: channel.guildID
                )
                messagesByChannel[channelID, default: []].append(message)
                continuation?.yield(.messageCreated(message))
            }
            emitted += batchCount
            guard emitted < count else { return }
            do {
                try await Task.sleep(for: burstInterval)
            } catch {
                return
            }
        }
    }

    /// Interleaves deterministic update and deletion Gateway events with the
    /// offline timeline benchmark. This never performs a network request and
    /// is reachable only through explicit test infrastructure.
    public func emitTimelineMutationStress(
        in channelID: ChannelID,
        operationCount: Int,
        deleteEvery: Int = 5,
        lookback: Int = 600,
        initialDelay: Duration = .milliseconds(500),
        operationInterval: Duration = .milliseconds(32)
    ) async {
        guard operationCount > 0,
              deleteEvery > 0,
              lookback > 0
        else { return }
        do {
            try await Task.sleep(for: initialDelay)
        } catch {
            return
        }
        for operation in 0 ..< operationCount {
            guard !Task.isCancelled,
                  let messageCount = messagesByChannel[channelID]?.count,
                  messageCount > 0
            else { return }
            let availableLookback = min(lookback, messageCount)
            let offset = (operation * 17) % availableLookback
            let index = messageCount - 1 - offset
            guard let messageID = messagesByChannel[channelID]?[index].id else {
                return
            }
            if (operation + 1).isMultiple(of: deleteEvery),
               messageCount > 1
            {
                messagesByChannel[channelID]?.remove(at: index)
                continuation?.yield(.messageDeleted(
                    channelID: channelID,
                    messageID: messageID
                ))
            } else {
                let content =
                    switch operation % 4 {
                    case 0:
                        "Edited during offline timeline stress \(operation)."
                    case 1:
                        "Edited stress message \(operation) wraps onto a second line to change row height while scrolling remains anchored."
                    case 2:
                        "Edited stress message \(operation).\nA deterministic second line exercises regrouping."
                    default:
                        "**Edited \(operation)** keeps `inline code`, a link, and emoji ✨ in the mutation path."
                    }
                guard let timestamp =
                    messagesByChannel[channelID]?[index].timestamp
                else { return }
                messagesByChannel[channelID]?[index].content = content
                messagesByChannel[channelID]?[index].editedTimestamp =
                    timestamp.addingTimeInterval(
                        Double(operation + 1)
                    )
                guard let message = messagesByChannel[channelID]?[index] else {
                    return
                }
                continuation?.yield(.messageUpdated(message))
            }
            guard operation + 1 < operationCount else { return }
            do {
                try await Task.sleep(for: operationInterval)
            } catch {
                return
            }
        }
    }

    public func forumPost(threadID: ChannelID) async throws -> ForumPost {
        guard let post = forumPostsByChannel.values.lazy.flatMap(\.self).first(where: {
            $0.id == threadID
        }) else {
            throw ChatProviderError.channelNotFound
        }
        return post
    }

    private func filterAndSortForumPosts(
        _ incomingPosts: [ForumPost], query: ForumPostQuery
    ) -> [ForumPost] {
        ForumPostQueryPolicy.filteredAndSorted(
            incomingPosts,
            selectedTagIDs: query.selectedTagIDs,
            tagMatch: query.tagMatch,
            sortOrder: query.sortOrder
        )
    }

    public func createForumPost(
        _ draft: CreateForumPostDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> ForumPost {
        guard
            let channel = snapshot.channels.first(where: {
                $0.id == draft.channelID && $0.kind == .forum
            })
        else { throw ChatProviderError.channelNotFound }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedTags = DiscordRESTProvider.orderedUniqueForumTagIDs(
            draft.appliedTagIDs,
            availableTags: channel.availableTags
        )
        guard (1 ... 100).contains(title.count), draft.content.count <= 2_000,
              !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !draft.attachments.isEmpty,
              !channel.requiresForumTag || !selectedTags.isEmpty,
              selectedTags.count <= 5,
              Set(selectedTags) == Set(draft.appliedTagIDs),
              draft.attachments.count <= 10,
              DiscordRESTProvider.validForumAutoArchiveDurations.contains(
                  draft.autoArchiveDuration
              )
        else {
            throw ChatProviderError.invalidRequest(
                "The forum post does not meet this channel's requirements.")
        }
        progress(.preparing)
        nextMessageID += 1
        let threadID = ChannelID(rawValue: nextMessageID)
        let attachments = try draft.attachments.enumerated().map { index, item in
            var value = try Self.stageAttachment(item.url, messageID: nextMessageID, index: index)
            value.filename = item.filename
            value.description = item.description.isEmpty ? nil : item.description
            value.isSpoiler = item.isSpoiler
            if item.isSpoiler, !value.filename.hasPrefix("SPOILER_") {
                value.filename = "SPOILER_\(value.filename)"
            }
            return value
        }
        progress(.submitting)
        let message = Message(
            id: MessageID(rawValue: nextMessageID), channelID: threadID, author: currentUser,
            content: draft.content, timestamp: .now, attachments: attachments
        )
        let post = ForumPost(
            thread: MessageThreadSummary(
                id: threadID, guildID: channel.guildID, parentID: channel.id, name: title,
                messageCount: 1, memberCount: 1, lastMessageID: message.id,
                ownerID: currentUser.id, appliedTagIDs: selectedTags,
                createdAt: message.timestamp, autoArchiveDuration: draft.autoArchiveDuration,
                totalMessageSent: 1,
                notificationSettings: ThreadNotificationSettings()
            ),
            owner: currentUser, firstMessage: message, mostRecentMessage: message
        )
        forumPostsByChannel[channel.id, default: []].insert(post, at: 0)
        messagesByChannel[threadID] = [message]
        continuation?.yield(
            .forumPostsChanged(channelID: channel.id, posts: forumPostsByChannel[channel.id] ?? []))
        progress(.completed(messageID: message.id))
        return post
    }

    public func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws
        -> ForumPost
    {
        guard let parentID = post.thread.parentID,
              var posts = forumPostsByChannel[parentID],
              let index = posts.firstIndex(where: { $0.id == post.id })
        else { throw ChatProviderError.channelNotFound }
        var updated = posts[index]
        switch mutation {
        case .tags(let tags):
            guard let channel = snapshot.channels.first(where: { $0.id == parentID }) else {
                throw ChatProviderError.channelNotFound
            }
            let selectedTags = DiscordRESTProvider.orderedUniqueForumTagIDs(
                tags,
                availableTags: channel.availableTags
            )
            guard selectedTags.count <= 5, Set(selectedTags) == Set(tags) else {
                throw ChatProviderError.invalidRequest("One or more selected tags are unavailable.")
            }
            guard !channel.requiresForumTag || !selectedTags.isEmpty else {
                throw ChatProviderError.invalidRequest(
                    "This forum requires every post to have at least one tag."
                )
            }
            updated.thread.appliedTagIDs = selectedTags
        case .archived(let value): updated.thread.isArchived = value
        case .locked(let value): updated.thread.isLocked = value
        case .pinned(let value):
            if value { updated.thread.flags |= 1 << 1 } else { updated.thread.flags &= ~(1 << 1) }
        }
        posts[index] = updated
        forumPostsByChannel[parentID] = posts
        continuation?.yield(
            .forumPostsChanged(channelID: parentID, posts: forumPostsByChannel[parentID] ?? []))
        return updated
    }

    public func deleteForumPost(_ post: ForumPost) async throws {
        guard let parentID = post.thread.parentID,
              var posts = forumPostsByChannel[parentID],
              let index = posts.firstIndex(where: { $0.id == post.id })
        else { throw ChatProviderError.channelNotFound }
        posts.remove(at: index)
        forumPostsByChannel[parentID] = posts
        messagesByChannel[post.id] = nil
        continuation?.yield(
            .forumPostsChanged(channelID: parentID, posts: forumPostsByChannel[parentID] ?? []))
    }

    public func updateForumPostNotificationLevel(
        _ post: ForumPost,
        level: MessageNotificationLevel
    ) async throws {
        threadNotificationRequests.append(
            ThreadNotificationRequest(threadID: post.id, level: level)
        )
        try updateForumPostNotificationSettings(post) {
            $0.flags = $0.flags(setting: level)
        }
    }

    public func updateForumPostMute(
        _ post: ForumPost,
        isMuted: Bool,
        until: Date?
    ) async throws {
        threadNotificationRequests.append(
            ThreadNotificationRequest(
                threadID: post.id,
                isMuted: isMuted,
                muteEndTime: until
            )
        )
        try updateForumPostNotificationSettings(post) {
            $0.isMuted = isMuted
            $0.muteConfiguration =
                isMuted ? DiscordMuteConfiguration(endTime: until) : nil
        }
    }

    private func updateForumPostNotificationSettings(
        _ post: ForumPost,
        mutation: (inout ThreadNotificationSettings) -> Void
    ) throws {
        guard let parentID = post.thread.parentID,
              var posts = forumPostsByChannel[parentID],
              let index = posts.firstIndex(where: { $0.id == post.id })
        else { throw ChatProviderError.channelNotFound }
        var settings =
            posts[index].thread.notificationSettings
            ?? ThreadNotificationSettings()
        mutation(&settings)
        posts[index].thread.notificationSettings = settings
        forumPostsByChannel[parentID] = posts
        continuation?.yield(
            .forumPostsChanged(channelID: parentID, posts: posts)
        )
    }

    public func sendTyping(in channelID: ChannelID) async throws {
        guard let channel = snapshot.channels.first(where: { $0.id == channelID }) else {
            throw ChatProviderError.channelNotFound
        }
        guard channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown else {
            throw ChatProviderError.invalidRequest("Typing is unavailable in this demo channel.")
        }
        typingRequests.append(channelID)
    }

    public func send(_ draft: SendMessageDraft) async throws -> Message {
        guard draft.attachmentURLs.count <= SendMessageDraft.maximumAttachmentCount else {
            throw ChatProviderError.invalidRequest(
                "A message can include at most \(SendMessageDraft.maximumAttachmentCount) attachments."
            )
        }
        guard
            !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.attachmentURLs.isEmpty || !draft.stickerIDs.isEmpty
        else {
            throw ChatProviderError.invalidRequest("A message needs text or an attachment.")
        }
        nextMessageID += 1
        let attachments = try draft.attachments.enumerated().map { index, attachment in
            var staged = try Self.stageAttachment(
                attachment.url,
                messageID: nextMessageID,
                index: index
            )
            let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            staged.filename =
                attachment.isSpoiler && !filename.hasPrefix("SPOILER_")
                    ? "SPOILER_\(filename)" : filename
            staged.description = attachment.description
            return staged
        }
        let replyPreview = draft.replyTo.flatMap { messageID in
            messagesByChannel[draft.channelID]?.first(where: { $0.id == messageID }).map {
                MessageReplyPreview(message: $0)
            }
        }
        let message = Message(
            id: MessageID(rawValue: nextMessageID), channelID: draft.channelID, author: currentUser,
            content: draft.content, replyTo: draft.replyTo, replyPreview: replyPreview,
            attachments: attachments,
            nonce: draft.nonce,
            stickers: draft.stickerIDs.map {
                MessageSticker(id: $0, name: "Demo sticker", format: .png)
            }
        )
        messagesByChannel[draft.channelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        return message
    }

    public func forward(_ draft: ForwardMessageDraft) async throws -> Message {
        guard snapshot.channels.contains(where: { $0.id == draft.destinationChannelID }) else {
            throw ChatProviderError.channelNotFound
        }
        guard let source = messagesByChannel[draft.sourceChannelID]?.first(where: {
            $0.id == draft.sourceMessageID
        }) else {
            throw ChatProviderError.messageNotFound
        }
        nextMessageID += 1
        let forwardedSnapshot = ForwardedMessageSnapshot(
            type: source.type,
            content: source.content,
            timestamp: source.timestamp,
            editedTimestamp: source.editedTimestamp,
            flags: source.flags,
            attachments: source.attachments,
            embeds: source.embeds,
            components: source.components,
            stickers: source.stickers,
            mentionedUsers: source.mentionedUsers,
            mentionedRoleIDs: source.mentionedRoleIDs
        )
        let message = Message(
            id: MessageID(rawValue: nextMessageID),
            channelID: draft.destinationChannelID,
            author: currentUser,
            content: forwardedSnapshot.content,
            timestamp: .now,
            editedTimestamp: forwardedSnapshot.editedTimestamp,
            attachments: forwardedSnapshot.attachments,
            nonce: draft.nonce,
            type: forwardedSnapshot.type,
            flags: forwardedSnapshot.flags,
            guildID: snapshot.channels.first(where: {
                $0.id == draft.destinationChannelID
            })?.guildID,
            embeds: forwardedSnapshot.embeds,
            components: forwardedSnapshot.components,
            stickers: forwardedSnapshot.stickers,
            mentionedUsers: forwardedSnapshot.mentionedUsers,
            mentionedRoleIDs: forwardedSnapshot.mentionedRoleIDs,
            messageReference: DiscordMessageReference(
                type: .forward,
                messageID: draft.sourceMessageID,
                channelID: draft.sourceChannelID,
                guildID: draft.sourceGuildID
            ),
            forwardedSnapshot: forwardedSnapshot
        )
        messagesByChannel[draft.destinationChannelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        return message
    }

    public func supports(_ capability: ChatCapability) async -> Bool {
        capability == .forums || capability == .gifs || capability == .stickers
            || capability == .stickerSending
            || capability == .components || capability == .modals
            || capability == .remoteComponentChoices
            || capability == .slashCommands || capability == .messageForwarding
    }

    public func componentChoices(
        kind: ComponentSelectKind,
        query: String,
        guildID: GuildID?,
        channelID _: ChannelID
    ) async throws -> [ComponentSelectOption] {
        let members = try await members(in: guildID)
        let roles = Dictionary(
            members.flatMap(\.roles).map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        ).values
        let choices: [ComponentSelectOption]
        switch kind {
        case .string:
            choices = []
        case .user:
            choices = members.map(Self.componentChoice)
        case .role:
            choices = roles.map(Self.componentChoice)
        case .mentionable:
            choices =
                members.map(Self.componentChoice)
                + roles.map(Self.componentChoice)
        case .channel:
            choices = try await channels(in: guildID).map {
                ComponentSelectOption(
                    label: "#\($0.name)",
                    value: String($0.id.rawValue),
                    imageURL: $0.iconURL,
                    imageShape: .roundedRectangle
                )
            }
        }
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return choices
            .filter {
                normalizedQuery.isEmpty
                    || $0.label.localizedCaseInsensitiveContains(
                        normalizedQuery
                    )
                    || $0.description?.localizedCaseInsensitiveContains(
                        normalizedQuery
                    ) == true
            }
            .sorted {
                let comparison = $0.label.localizedCaseInsensitiveCompare(
                    $1.label
                )
                return comparison == .orderedSame
                    ? $0.value < $1.value
                    : comparison == .orderedAscending
            }
            .prefix(25)
            .map(\.self)
    }

    private static func componentChoice(
        for member: Member
    ) -> ComponentSelectOption {
        ComponentSelectOption(
            label: member.user.displayName,
            value: String(member.id.rawValue),
            description: "@\(member.user.username)",
            imageURL: member.user.avatarURL
        )
    }

    private static func componentChoice(
        for role: GuildRole
    ) -> ComponentSelectOption {
        ComponentSelectOption(
            label: "@\(role.name)",
            value: String(role.id.rawValue),
            imageURL: role.iconURL,
            imageShape: .roundedRectangle
        )
    }

    private static func makeForumPosts(
        channelID: ChannelID,
        authors: [User],
        count: Int = 6
    ) -> [ForumPost] {
        let authors =
            authors.isEmpty
                ? [User(id: UserID(rawValue: 1), username: "offline", displayName: "Offline User")]
                : authors
        let titles = [
            "Media viewer should use a native presentation",
            "Reaction state should update without reloading",
            "Channel links should open inside SakuraCord",
            "Markdown custom emoji are not rendered",
            "Forum channels need a dedicated browser",
            "Keyboard navigation for long post lists",
        ]
        let bodies = [
            "Replace the temporary viewer with Quick Look or a polished native gallery.",
            "Gateway reaction events should reconcile the visible post card immediately.",
            "Keep the user in context and reveal the target channel and message.",
            "Custom emoji tokens in markdown should resolve through the guild catalog.",
            "The normal text timeline is not the right information hierarchy for posts.",
            "Arrow keys and VoiceOver should move through stable post identities.",
        ]
        let tagSets: [[ForumTagID]] = [
            [.init(rawValue: 8_001), .init(rawValue: 8_005)],
            [.init(rawValue: 8_002), .init(rawValue: 8_003)],
            [.init(rawValue: 8_002)],
            [.init(rawValue: 8_001)],
            [.init(rawValue: 8_001), .init(rawValue: 8_004)],
            [.init(rawValue: 8_002), .init(rawValue: 8_005)],
        ]
        let now = Date.now
        return (0 ..< max(0, count)).map { index in
            let rawID = channelID.rawValue * 100 + UInt64(index + 1)
            let threadID = ChannelID(rawValue: rawID)
            let timestamp = now.addingTimeInterval(Double(-index * 7_200 - 900))
            let author = authors[index % authors.count]
            let templateIndex = index % titles.count
            let title = index < titles.count
                ? titles[templateIndex]
                : "\(titles[templateIndex]) \(index + 1)"
            let attachments: [Attachment]
            if count > titles.count, index.isMultiple(of: 5), let imageURL = author.avatarURL {
                attachments = [
                    Attachment(
                        id: "\(rawID)-preview",
                        filename: "forum-preview.png",
                        url: imageURL,
                        mediaType: "image/png",
                        width: 256,
                        height: 256
                    )
                ]
            } else {
                attachments = []
            }
            let message = Message(
                id: MessageID(rawValue: rawID), channelID: threadID, author: author,
                content: bodies[templateIndex], timestamp: timestamp,
                attachments: attachments,
                reactions: [
                    Reaction(
                        emoji: "👍",
                        count: max(1, 6 - index),
                        reactors: [ReactionReactor(user: author)]
                    )
                ]
            )
            return ForumPost(
                thread: MessageThreadSummary(
                    id: threadID, guildID: GuildID(rawValue: 100), parentID: channelID,
                    name: title, messageCount: index + 2, memberCount: index + 1,
                    lastMessageID: message.id, isArchived: index >= count / 2,
                    isLocked: index.isMultiple(of: 17),
                    ownerID: author.id, appliedTagIDs: tagSets[templateIndex],
                    flags: index == 0 ? 1 << 1 : 0,
                    archiveTimestamp: index >= count / 2 ? timestamp : nil,
                    createdAt: timestamp.addingTimeInterval(-1_800), totalMessageSent: index + 2
                ),
                owner: author, firstMessage: message, mostRecentMessage: message,
                isUnread: index % 7 == 1 || index % 7 == 3
            )
        }
    }

}

public extension MockChatProvider {
    func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    {
        MockApplicationCommands.catalog(
            target: target,
            guildID: {
                if case .guild(let id) = target { return id }
                return nil
            }(),
            currentUser: currentUser
        )
    }

    func requestApplicationCommandAutocomplete(
        _ request: ApplicationCommandAutocompleteRequest
    ) async throws {
        _ = try ApplicationCommandPayloadBuilder.autocomplete(request)
        try await Task.sleep(for: .milliseconds(90))
        continuation?.yield(
            .applicationCommandAutocomplete(
                ApplicationCommandAutocompleteResult(
                    nonce: request.nonce,
                    choices: MockApplicationCommands.autocomplete(query: request.query)
                )
            )
        )
    }

    func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws {
        let payload = try ApplicationCommandPayloadBuilder.execution(invocation)
        progress(.preparing)
        if !payload.attachmentURLs.isEmpty {
            progress(.reserving(files: payload.attachmentURLs.count))
            for url in payload.attachmentURLs {
                let size =
                    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                            as? NSNumber)?
                        .int64Value ?? 0
                progress(.uploading(fileName: url.lastPathComponent, completed: size, total: size))
            }
        }
        progress(.submitting(nonce: invocation.nonce))
        try await Task.sleep(for: .milliseconds(120))
        nextMessageID += 1
        continuation?.yield(
            .interaction(
                .created(nonce: invocation.nonce, interactionID: String(nextMessageID))
            )
        )
        progress(.awaitingResponse(nonce: invocation.nonce))
        let responseMode =
            invocation.command.name == "response"
                ? invocation.command.subcommandPath.last?.name
                : nil
        if responseMode == "failure" {
            continuation?.yield(
                .interaction(
                    .failed(
                        nonce: invocation.nonce,
                        message: "Synthetic interaction failure. No retry was attempted."
                    )
                )
            )
            return
        }
        let application = invocation.command.application
        let author =
            application.bot
                ?? User(
                    id: UserID(rawValue: 900_000_000_000_000_101), username: "verified",
                    displayName: application.name, isBot: true
                )
        let message = commandResponseMessage(
            for: invocation,
            responseMode: responseMode,
            application: application,
            author: author
        )
        messagesByChannel[invocation.channelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        continuation?.yield(.interaction(.succeeded(nonce: invocation.nonce)))
        try await completeCommandResponse(
            message,
            invocation: invocation,
            responseMode: responseMode,
            application: application,
            author: author
        )
    }

    private func commandResponseMessage(
        for invocation: ApplicationCommandInvocation,
        responseMode: String?,
        application: ApplicationCommandApplication,
        author: User
    ) -> Message {
        Message(
            id: MessageID(rawValue: nextMessageID),
            channelID: invocation.channelID,
            author: author,
            content: responseMode == "deferred"
                ? "The offline app is working…"
                : "Offline command **/\(invocation.command.displayName)** completed successfully.",
            nonce: invocation.nonce,
            type: .chatInputCommand,
            flags: responseMode == "ephemeral"
                ? .ephemeral
                : (responseMode == "deferred" ? .loading : []),
            applicationID: ApplicationID(MockApplicationCommands.applicationID),
            application: application,
            interactionMetadata: MessageInteractionMetadata(
                id: String(nextMessageID), type: 2,
                name: invocation.command.displayName,
                user: currentUser,
                applicationID: invocation.command.applicationID
            ),
            guildID: invocation.guildID,
            components: [
                .container(
                    id: "offline-command-container", accentColor: 0x57F287, spoiler: false,
                    children: [
                        .textDisplay(
                            id: "offline-command-text",
                            content:
                            "### Verified\nThis response is a deterministic Components V2 fixture."
                        ),
                        .separator(id: "offline-command-separator", divider: true, spacing: 1),
                        .textDisplay(
                            id: "offline-command-state",
                            content: "No Discord request was made."
                        ),
                    ]
                )
            ],
            mentionedUsers: [currentUser]
        )
    }

    private func completeCommandResponse(
        _ initialMessage: Message,
        invocation: ApplicationCommandInvocation,
        responseMode: String?,
        application: ApplicationCommandApplication,
        author: User
    ) async throws {
        var message = initialMessage
        if responseMode == "deferred" {
            try await Task.sleep(for: .milliseconds(120))
            message.content = "The deferred offline response completed successfully."
            message.flags.remove(.loading)
            message.editedTimestamp = .now
            if let index = messagesByChannel[invocation.channelID]?.firstIndex(where: {
                $0.id == message.id
            }) {
                messagesByChannel[invocation.channelID]?[index] = message
            }
            continuation?.yield(.messageUpdated(message))
        } else if responseMode == "followup" {
            nextMessageID += 1
            let followup = Message(
                id: MessageID(rawValue: nextMessageID),
                channelID: invocation.channelID,
                author: author,
                content: "This is the synthetic follow-up response.",
                applicationID: ApplicationID(MockApplicationCommands.applicationID),
                application: application,
                guildID: invocation.guildID
            )
            messagesByChannel[invocation.channelID, default: []].append(followup)
            continuation?.yield(.messageCreated(followup))
        }
    }

    func submitComponentInteraction(_ submission: ComponentInteractionSubmission)
        async throws
    {
        if submission.customID == "offline-modal" {
            let modal = InteractionModal(
                customID: "offline-feedback", title: "Offline feedback",
                controls: [
                    .label(
                        id: "label", label: "Feedback",
                        description: "This synthetic modal never contacts Discord.",
                        child: .textInput(
                            id: "text", customID: "feedback", style: 2, label: nil, value: nil,
                            placeholder: "What should improve?", required: true, minLength: 3,
                            maxLength: 500
                        )
                    ),
                    .checkbox(
                        id: "checkbox", customID: "follow-up", label: "Allow a fictional follow-up",
                        value: false
                    ),
                ]
            )
            continuation?.yield(.interaction(.presentModal(nonce: submission.nonce, modal: modal)))
        } else {
            continuation?.yield(.interaction(.succeeded(nonce: submission.nonce)))
        }
    }

    func submitModal(_ submission: ModalSubmission, nonce: String) async throws {
        continuation?.yield(.interaction(.succeeded(nonce: nonce)))
    }

    func trendingGIFs() async throws -> [GIFSearchResult] {
        try Self.demoGIFs(query: "Trending")
    }

    func searchGIFs(query: String) async throws -> [GIFSearchResult] {
        try Self.demoGIFs(query: query.isEmpty ? "GIF" : query)
    }

    func gifPickerLanding() async throws -> GIFPickerLanding {
        let preview = try Self.demoGIFs(query: "Category").first?.previewURL
        return GIFPickerLanding(
            categories: [
                "hello", "lol", "love", "happy birthday", "thank you", "excited",
                "yes", "no", "sorry", "happy", "sad", "thumbs up",
            ]
                .map {
                    GIFPickerCategory(id: $0, name: $0, query: $0, previewURL: preview)
                },
            trendingPreviewURL: preview
        )
    }

    func favoriteGIFs() async throws -> [GIFSearchResult] {
        favoriteGIFValues
    }

    func setGIFFavorite(_ gif: GIFSearchResult, isFavorite: Bool) async throws
        -> [GIFSearchResult]
    {
        favoriteGIFValues.removeAll { $0.url == gif.url }
        if isFavorite {
            favoriteGIFValues.insert(gif, at: 0)
        }
        return favoriteGIFValues
    }

    func stickers(in guildID: GuildID) async throws -> [MessageSticker] {
        try [
            MessageSticker(
                id: "demo-wave", name: "Wave", description: "Offline demo sticker",
                tags: "wave,hello",
                format: .png, guildID: guildID, assetURL: Self.demoGIFs(query: "Sticker").first?.url
            )
        ]
    }

    private static func demoGIFs(query: String) throws -> [GIFSearchResult] {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "SakuraCordDemoMedia", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "demo.gif")
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = Data(
                base64Encoded: "R0lGODlhAQABAPAAAP///wAAACH5BAAAAAAALAAAAAABAAEAAAICRAEAOw=="
            )!
            try data.write(to: url, options: .atomic)
        }
        let sizes = [(640, 640), (498, 210), (374, 352), (498, 498), (200, 150), (640, 492)]
        return (0 ..< 50).map { index in
            let size = sizes[index % sizes.count]
            return GIFSearchResult(
                id: "demo-gif-\(index)",
                title: "\(query) demo \(index + 1)",
                url: URL(string: "https://example.invalid/mock-gif/\(index)")!,
                previewURL: url,
                width: size.0,
                height: size.1,
                thumbnailURL: url,
                mediaURL: url
            )
        }
    }

    private static func stageAttachment(_ sourceURL: URL, messageID: UInt64, index: Int) throws
        -> Attachment
    {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SakuraCordDemoAttachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension
        let filename =
            sourceURL.lastPathComponent.isEmpty
                ? "attachment-\(index)" : sourceURL.lastPathComponent
        let destination = directory.appending(
            path: "\(messageID)-\(index)\(fileExtension.isEmpty ? "" : ".\(fileExtension)")"
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        let mediaType = UTType(filenameExtension: fileExtension)?.preferredMIMEType
        return Attachment(
            id: "\(messageID)-\(index)",
            filename: filename,
            url: destination,
            mediaType: mediaType,
            size: values.fileSize ?? 0
        )
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws
        -> Message
    {
        guard var messages = messagesByChannel[channelID],
              let index = messages.firstIndex(where: { $0.id == messageID })
        else {
            throw ChatProviderError.messageNotFound
        }
        messages[index].content = content
        messages[index].editedTimestamp = .now
        let message = messages[index]
        messagesByChannel[channelID] = messages
        continuation?.yield(.messageUpdated(message))
        return message
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {
        guard var messages = messagesByChannel[channelID],
              let index = messages.firstIndex(where: { $0.id == messageID })
        else {
            throw ChatProviderError.messageNotFound
        }
        messages.remove(at: index)
        messagesByChannel[channelID] = messages
        continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
    }

    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID)
        async throws
    {
        guard let message = messagesByChannel[channelID]?.first(where: { $0.id == messageID }) else {
            throw ChatProviderError.messageNotFound
        }
        let reactionID = Reaction(emoji: emoji, count: 0).id
        let reacted =
            message.reactions.first(where: { $0.id == reactionID })?.didCurrentUserReact ?? false
        try await setReaction(
            emoji,
            reacted: !reacted,
            messageID: messageID,
            channelID: channelID
        )
    }

    func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        guard var messages = messagesByChannel[channelID],
              let index = messages.firstIndex(where: { $0.id == messageID })
        else {
            throw ChatProviderError.messageNotFound
        }
        var message = messages[index]
        let reactionID = Reaction(emoji: emoji, count: 0).id
        if let reactionIndex = message.reactions.firstIndex(where: { $0.id == reactionID }) {
            let active = message.reactions[reactionIndex].didCurrentUserReact
            guard active != reacted else { return }
            message.reactions[reactionIndex].didCurrentUserReact = reacted
            message.reactions[reactionIndex].count += reacted ? 1 : -1
            if !reacted {
                message.reactions[reactionIndex].reactors.removeAll {
                    $0.id == snapshot.currentUser.id
                }
            } else if !message.reactions[reactionIndex].reactors.contains(where: {
                $0.id == snapshot.currentUser.id
            }) {
                message.reactions[reactionIndex].reactors.append(
                    ReactionReactor(user: snapshot.currentUser)
                )
            }
            if message.reactions[reactionIndex].count == 0 {
                message.reactions.remove(at: reactionIndex)
            }
        } else if reacted {
            message.reactions.append(
                Reaction(
                    emoji: emoji,
                    count: 1,
                    didCurrentUserReact: true,
                    reactors: [ReactionReactor(user: snapshot.currentUser)]
                )
            )
        } else {
            return
        }
        messages[index] = message
        messagesByChannel[channelID] = messages
        continuation?.yield(.messageUpdated(message))
    }

    func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        guard let message = messagesByChannel[channelID]?.first(where: { $0.id == messageID }),
              let reaction = message.reactions.first(where: {
                  $0.id
                      == Reaction(
                          emoji: emoji,
                          count: reactionCount
                      ).id
              })
        else {
            throw ChatProviderError.messageNotFound
        }
        return Array(reaction.reactors.prefix(5))
    }

    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        guard snapshot.channels.contains(where: {
            $0.id == channelID
                && ($0.kind == .voice
                    || $0.kind == .directMessage
                    || $0.kind == .groupDirectMessage)
        }) else {
            throw ChatProviderError.invalidRequest("That demo voice channel is unavailable.")
        }
        voiceJoinRequests.append(VoiceJoinRequest(
            channelID: channelID,
            guildID: guildID,
            selfMute: selfMute,
            selfDeaf: selfDeaf
        ))
        let state = VoiceParticipantState(
            userID: currentUser.id,
            channelID: channelID,
            guildID: guildID,
            sessionID: "demo-session",
            isSelfMuted: selfMute,
            isSelfDeafened: selfDeaf
        )
        continuation?.yield(.voiceStateChanged(state))
        if guildID == nil {
            var call =
                privateCallsByChannel[channelID]
                ?? PrivateCall(
                    channelID: channelID,
                    messageID: MessageID(rawValue: nextMessageID),
                    region: "mock",
                    voiceStates: []
                )
            var states = call.voiceStates ?? []
            states.removeAll { $0.userID == currentUser.id }
            states.append(state)
            call.voiceStates = states
            privateCallsByChannel[channelID] = call
            continuation?.yield(.privateCallChanged(call))
        }
        return VoiceConnectionInfo(
            serverID: guildID?.description ?? channelID.description,
            channelID: channelID,
            guildID: guildID,
            userID: currentUser.id,
            sessionID: state.sessionID,
            token: "demo-token",
            endpoint: "mock.sakuracord.invalid"
        )
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        continuation?.yield(
            .voiceStateChanged(
                VoiceParticipantState(
                    userID: currentUser.id,
                    channelID: channelID,
                    guildID: guildID,
                    sessionID: "demo-session",
                    isSelfMuted: selfMute,
                    isSelfDeafened: selfDeaf,
                    isVideoEnabled: selfVideo
                )
            )
        )
        if guildID == nil {
            if let channelID, var call = privateCallsByChannel[channelID] {
                var states = call.voiceStates ?? []
                states.removeAll { $0.userID == currentUser.id }
                states.append(
                    VoiceParticipantState(
                        userID: currentUser.id,
                        channelID: channelID,
                        guildID: nil,
                        sessionID: "demo-session",
                        isSelfMuted: selfMute,
                        isSelfDeafened: selfDeaf,
                        isVideoEnabled: selfVideo
                    )
                )
                call.voiceStates = states
                privateCallsByChannel[channelID] = call
                continuation?.yield(.privateCallChanged(call))
            } else if channelID == nil {
                for (id, var call) in privateCallsByChannel {
                    call.voiceStates?.removeAll { $0.userID == currentUser.id }
                    privateCallsByChannel[id] = call
                    continuation?.yield(.privateCallChanged(call))
                }
            }
        }
    }

    func subscribeToPrivateCall(channelID: ChannelID) async throws {
        if let call = privateCallsByChannel[channelID] {
            continuation?.yield(.privateCallChanged(call))
        }
    }

    func privateCallIsRingable(channelID: ChannelID) async throws -> Bool {
        snapshot.channels.contains {
            $0.id == channelID && $0.kind == .directMessage
        }
    }

    func ringPrivateCall(channelID: ChannelID, recipients: [UserID]?) async throws {
        guard let channel = snapshot.channels.first(where: { $0.id == channelID }),
              channel.kind == .directMessage || channel.kind == .groupDirectMessage
        else {
            throw ChatProviderError.channelNotFound
        }
        var call =
            privateCallsByChannel[channelID]
            ?? PrivateCall(
                channelID: channelID,
                messageID: MessageID(rawValue: nextMessageID),
                region: "mock",
                voiceStates: []
            )
        let targets = recipients ?? channel.recipients.map(\.id)
        call.ongoingRings = targets
            .filter { $0 != currentUser.id }
            .map { PrivateCallRing(recipientID: $0, senderID: currentUser.id) }
        privateCallsByChannel[channelID] = call
        continuation?.yield(.privateCallChanged(call))
    }

    func stopRingingPrivateCall(channelID: ChannelID, recipients: [UserID]) async throws {
        guard var call = privateCallsByChannel[channelID] else { return }
        let targetIDs = Set(recipients)
        call.ongoingRings.removeAll { targetIDs.contains($0.recipientID) }
        privateCallsByChannel[channelID] = call
        continuation?.yield(.privateCallChanged(call))
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        let stream = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        continuation = stream.continuation
        for call in privateCallsByChannel.values {
            stream.continuation.yield(.privateCallChanged(call))
        }
        return stream.stream
    }

    func disconnect() async {
        continuation?.yield(.connectionChanged(.disconnected))
        continuation?.finish()
        continuation = nil
    }
}
