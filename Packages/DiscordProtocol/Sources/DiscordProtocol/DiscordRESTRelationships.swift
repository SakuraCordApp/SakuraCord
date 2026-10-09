import Foundation
import SakuraCordModels

/// One relationship record from READY, `GET /users/@me/relationships`,
/// `RELATIONSHIP_ADD`, `RELATIONSHIP_UPDATE` or `RELATIONSHIP_REMOVE`.
struct GatewayRelationshipDTO: Decodable {
    var id: String
    var type: Int?
    var nickname: String?
    var since: String?
    var note: String?
    var isSpamRequest: Bool?
    var userIgnored: Bool?
    var user: UserDTO?

    enum CodingKeys: String, CodingKey {
        case id, type, nickname, since, note, user
        case isSpamRequest = "is_spam_request"
        case userIgnored = "user_ignored"
    }

    /// Discord's RelationshipStore keeps stored metadata when an add omits
    /// it; a snapshot row or an update replaces it, clearing absent values.
    func record(merging existing: RelationshipRecord?, replacing: Bool) -> RelationshipRecord? {
        guard let type = (type ?? existing?.type.rawValue).flatMap(RelationshipType.init(rawValue:)),
              type != .none else { return nil }
        let nickname = DiscordRESTProvider.normalizedFriendNickname(nickname)
        let since = since.flatMap(DiscordDate.parse)
        return RelationshipRecord(
            type: type,
            nickname: replacing ? nickname : nickname ?? existing?.nickname,
            since: replacing ? since : since ?? existing?.since,
            note: replacing ? note : note ?? existing?.note,
            isSpamRequest: isSpamRequest ?? (replacing ? false : existing?.isSpamRequest ?? false),
            isUserIgnored: userIgnored ?? (replacing ? false : existing?.isUserIgnored ?? false)
        )
    }
}

struct RelationshipRecord: Equatable, Sendable {
    var type: RelationshipType
    var nickname: String?
    var since: Date?
    var note: String?
    var isSpamRequest: Bool
    var isUserIgnored: Bool
}

/// Where a relationship removal starts; Discord reports it as request context.
public enum RelationshipRemoval: Sendable {
    case removeFriend, cancelOutgoingRequest, declineIncomingRequest, unblock
}

extension DiscordRESTProvider {
    static let maximumFriendNicknameLength = 32

    func handleGatewayRelationshipEvent(name: String, body: JSONValue) async -> Bool {
        switch name {
        case "RELATIONSHIP_ADD", "RELATIONSHIP_UPDATE", "RELATIONSHIP_REMOVE":
            guard let dto = try? JSONValueDecoder().decode(GatewayRelationshipDTO.self, from: body),
                  let userID = UserID(dto.id)
            else { return true }
            relationshipRevisions[userID, default: 0] &+= 1
            if let user = dto.user { cacheRelationshipUser(user) }
            var records = cachedRelationships
            switch name {
            case "RELATIONSHIP_REMOVE":
                records[userID] = nil
            case "RELATIONSHIP_UPDATE":
                records[userID] = dto.record(merging: records[userID], replacing: true)
            default:
                records[userID] = dto.record(merging: records[userID], replacing: false)
            }
            publishRelationships(records)
            return true
        default:
            return false
        }
    }

    /// Hydrates an embedded identity without admitting it to search stores.
    private func cacheRelationshipUser(_ user: UserDTO) {
        _ = cacheGatewayUser(user, forwardSearchEligible: false, includeInKnownUserStore: false, messageSearchEligible: false)
    }

    // Official stable633029 FriendsStore: one full read per connection,
    // started lazily by the first list other than Online or Add Friend.
    /// Reads every relationship once per Gateway connection. READY already
    /// lists them; this refreshes embedded identities and metadata. Records
    /// changed by Gateway while the read is in flight keep their newer state.
    public func loadRelationships() async throws {
        guard currentUser != nil else { throw ChatProviderError.unauthenticated }
        let generation = relationshipGeneration
        guard relationshipLoadGeneration != generation else { return }
        relationshipLoadGeneration = generation
        let revisions = relationshipRevisions
        let userRevisions = cachedUserRevisions
        let rows: [GatewayRelationshipDTO]
        do {
            let (data, response) = try await perform("/users/@me/relationships", method: "GET", query: [], body: nil)
            guard (200 ..< 300).contains(response.statusCode) else {
                throw apiDiagnostics.coalescing(ChatProviderError.transport(
                    status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id")
                ), with: response)
            }
            rows = try JSONDecoder().decode(LossyList<GatewayRelationshipDTO>.self, from: data).elements
        } catch {
            // A later explicit selection may read again on this connection.
            if relationshipLoadGeneration == generation { relationshipLoadGeneration = nil }
            throw error
        }
        guard relationshipGeneration == generation else { return }
        var records = cachedRelationships
        var listed: Set<UserID> = []
        for row in rows {
            guard let userID = UserID(row.id) else { continue }
            listed.insert(userID)
            guard relationshipRevisions[userID, default: 0] == revisions[userID, default: 0] else { continue }
            if cachedUserRevisions[row.id, default: 0] == userRevisions[row.id, default: 0], let user = row.user {
                cacheRelationshipUser(user)
            }
            records[userID] = row.record(merging: nil, replacing: true)
        }
        for userID in records.keys where !listed.contains(userID)
            && relationshipRevisions[userID, default: 0] == revisions[userID, default: 0] {
            records[userID] = nil
        }
        publishRelationships(records, force: true)
    }

    /// Sends a friend request by username; one POST, never replayed except
    /// once after a completed human challenge. The Sent row arrives through
    /// `RELATIONSHIP_ADD`, not the empty response.
    public func sendFriendRequest(
        username: String, discriminator: Int?, note: String? = nil, captchaHandler: DiscordCaptchaHandler?
    ) async throws {
        let tag = discriminator.map { "\(username)#\(String(format: "%04d", $0))" } ?? username
        var body: [String: JSONValue] = [
            "username": .string(username),
            "discriminator": discriminator.map { .number(Double($0)) } ?? .null,
        ]
        if let note = try FriendRequestNote.normalized(note) { body["note"] = .string(note) }
        try await relationshipMutation(
            "/users/@me/relationships", method: "POST", body: body, location: "Add Friend",
            captchaHandler: captchaHandler, failure: { Self.friendRequestFailureMessage(code: $0, status: $1, discordTag: tag) }
        )
    }

    /// Accepts an incoming request. Discord answers code 80013 when it wants
    /// confirmation the requester is known; only an explicit confirmation
    /// repeats the request with `confirm_stranger_request: true`.
    public func acceptFriendRequest(
        from userID: UserID, confirmingStranger: Bool, captchaHandler: DiscordCaptchaHandler?
    ) async throws {
        try await relationshipMutation(
            "/users/@me/relationships/\(userID)", method: "PUT",
            body: ["confirm_stranger_request": .bool(confirmingStranger)], location: "Friends",
            captchaHandler: captchaHandler, failure: { code, status in
                code == 80013 && !confirmingStranger ? nil : Self.relationshipUpdateFailureMessage(code: code, status: status)
            }
        )
    }

    /// Removes a friend, cancels or declines a request, or unblocks. Each is
    /// one DELETE of the per-user relationship.
    public func removeRelationship(with userID: UserID, as removal: RelationshipRemoval) async throws {
        try await relationshipMutation(
            "/users/@me/relationships/\(userID)", method: "DELETE", body: nil,
            location: removal == .unblock ? nil : "Friends", captchaHandler: nil,
            failure: { Self.relationshipUpdateFailureMessage(code: $0, status: $1) }
        )
    }

    /// Blocks a user, replacing any friendship or request.
    public func blockUser(_ userID: UserID, captchaHandler: DiscordCaptchaHandler? = nil) async throws {
        try await relationshipMutation(
            "/users/@me/relationships/\(userID)", method: "PUT", body: ["type": .number(Double(RelationshipType.blocked.rawValue))],
            location: "ContextMenu", captchaHandler: captchaHandler,
            failure: { Self.relationshipUpdateFailureMessage(code: $0, status: $1) }
        )
    }

    /// `failure` returns nil for the stranger-confirmation response.
    private func relationshipMutation(
        _ path: String, method: String, body: [String: JSONValue]?, location: String?,
        captchaHandler: DiscordCaptchaHandler?, failure: (Int?, Int) -> String?
    ) async throws {
        guard let account = currentUser?.id else { throw ChatProviderError.unauthenticated }
        var headers: [String: String] = [:]
        if let location {
            let context = try JSONSerialization.data(withJSONObject: ["location": location], options: [.sortedKeys])
            headers["X-Context-Properties"] = context.base64EncodedString()
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await performChallengeable(
                path, method: method, query: [], body: body, headers: headers, captchaHandler: captchaHandler,
                replayIsCurrent: { [weak self] in await self?.currentUser?.id == account }
            )
        } catch let failure as CaptchaReplayFailure {
            throw RelationshipActionError.failed(failure.message)
        }
        guard !(200 ..< 300).contains(response.statusCode) else { return }
        // Another session already removed it; Gateway reconciles the list.
        if response.statusCode == 404, method == "DELETE" { return }
        if response.statusCode == 401 {
            authorizationValue = nil
            throw apiDiagnostics.coalescing(ChatProviderError.unauthenticated, with: response)
        }
        if method == "POST", path == "/users/@me/relationships",
           let fields = try? JSONDecoder().decode([String: JSONValue].self, from: data), fields["note"] != nil {
            throw RelationshipActionError.failed(FriendRequestNote.validationMessage)
        }
        let code = Self.discordErrorCode(from: data)
        if response.statusCode == 400 || response.statusCode == 429 || response.statusCode == 403 {
            guard let message = failure(code, response.statusCode) else {
                throw RelationshipActionError.strangerConfirmationRequired
            }
            throw RelationshipActionError.failed(message)
        }
        throw apiDiagnostics.coalescing(ChatProviderError.transport(
            status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id")
        ), with: response)
    }

    // Official stable633029 module395422 `vU` and module717398 HTTP 429 copy.
    static func friendRequestFailureMessage(code: Int?, status: Int, discordTag: String) -> String {
        if status == 429 { return "You’re sending friend requests too quickly!" }
        return switch code {
        case 80000: "\(discordTag) is not accepting friend requests. They’ll have to add you to become friends."
        case 30002: "You’ve maxed out your friend list. Welcome to the elite 1,000 friends club!"
        case 80007: "You’re already friends with that user!"
        case 30059: "You’ve maxed out your block list."
        case 30078: "You’ve maxed out your pending outgoing friend requests."
        default: "Hm, didn’t work. Double check that the username is correct."
        }
    }

    static func relationshipUpdateFailureMessage(code: Int?, status: Int) -> String {
        if status == 429 { return "Discord is limiting friend changes. Wait a moment before trying again." }
        return switch code {
        case 30002: "You’ve maxed out your friend list. Welcome to the elite 1,000 friends club!"
        case 30059: "You’ve maxed out your block list."
        default: "Discord couldn’t update this relationship. Try again."
        }
    }

    /// Sets or clears the private nickname shown only to the current account.
    /// One PATCH, never replayed; blank text clears it with `null`. A
    /// rejected value stays in the dialog, and `RELATIONSHIP_UPDATE`
    /// reconciles other sessions.
    public func setFriendNickname(_ nickname: String?, for userID: UserID) async throws -> String? {
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        let value = Self.normalizedFriendNickname(nickname)
        guard (value?.utf16.count ?? 0) <= Self.maximumFriendNicknameLength else {
            throw ChatProviderError.invalidRequest("Friend nicknames must be 32 characters or fewer.")
        }
        let revision = relationshipRevisions[userID, default: 0]
        let generation = profileEditingGeneration
        let path = "/users/@me/relationships/\(userID)"
        let (data, response) = try await perform(
            path, method: "PATCH", query: [], body: ["nickname": value.map(JSONValue.string) ?? .null]
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 400,
               let error = Self.profileValidationError(data: data, method: "PATCH", path: path)
            { throw apiDiagnostics.coalescing(error, with: response) }
            if response.statusCode == 401 {
                authorizationValue = nil
                throw apiDiagnostics.coalescing(ChatProviderError.unauthenticated, with: response)
            }
            throw apiDiagnostics.coalescing(ChatProviderError.transport(
                status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id")
            ), with: response)
        }
        // Only this friend's events supersede the save; the generation also
        // guards READY and disconnect, which clear the per-user revisions.
        guard currentUser?.id == user.id, profileEditingGeneration == generation,
              relationshipRevisions[userID, default: 0] == revision,
              var record = cachedRelationships[userID] else { return value }
        relationshipRevisions[userID, default: 0] &+= 1
        record.nickname = value
        var records = cachedRelationships
        records[userID] = record
        publishRelationships(records)
        return value
    }

    static func normalizedFriendNickname(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Decodes a DM or group DM with its friend-nickname title.
    func privateChannel(from dto: ChannelDTO) throws -> Channel {
        applyingFriendNicknames(to: try dto.domain(guildID: nil, knownUsersByID: cachedGatewayUsersByID))
    }

    /// Discord titles an unnamed DM or group DM from its recipients, using the
    /// friend nickname in place of that recipient's name.
    func applyingFriendNicknames(to channel: Channel) -> Channel {
        guard channel.guildID == nil, !channel.hasExplicitName else { return channel }
        var channel = channel
        if channel.recipients.isEmpty {
            // A group whose last other member left falls back like a new one.
            guard channel.kind == .groupDirectMessage else { return channel }
            let owner = channel.ownerID.flatMap { cachedGatewayUsersByID[$0.description] }.flatMap { try? $0.domain() }
            channel.name = owner.map { "\($0.displayName)'s Group" } ?? "Group Direct Message"
            return channel
        }
        channel.name = channel.recipients
            .map { cachedRelationshipNicknamesByUserID[$0.id] ?? $0.displayName }
            .joined(separator: ", ")
        return channel
    }

    /// Replaces READY's records without publishing; the bootstrap snapshot carries them.
    func adoptReadyRelationships(_ records: [UserID: RelationshipRecord]) {
        relationshipGeneration &+= 1
        relationshipLoadGeneration = nil
        cachedRelationships = records
        cachedFriendUserIDs = Set(records.lazy.filter { $0.value.type == .friend }.map(\.key))
        cachedRelationshipNicknamesByUserID = records.compactMapValues(\.nickname)
    }

    /// Relationship records with their hydrated identities.
    func publishedRelationships() -> [Relationship] {
        cachedRelationships.map { userID, record in
            Relationship(
                id: userID, type: record.type,
                user: cachedGatewayUsersByID[userID.description].flatMap { try? $0.domain() },
                nickname: record.nickname, since: record.since, note: record.note,
                isSpamRequest: record.isSpamRequest, isUserIgnored: record.isUserIgnored
            )
        }
    }

    private func publishRelationships(_ records: [UserID: RelationshipRecord], force: Bool = false) {
        guard force || records != cachedRelationships else { return }
        let blocked = Set(records.lazy.filter { $0.value.type == .blocked || $0.value.isUserIgnored }.map(\.key))
        let blockedChanged = blocked != cachedBlockedOrIgnoredUserIDs
        cachedBlockedOrIgnoredUserIDs = blocked
        let nicknames = records.compactMapValues(\.nickname)
        let nicknamesChanged = nicknames != cachedRelationshipNicknamesByUserID
        cachedRelationships = records
        cachedFriendUserIDs = Set(records.lazy.filter { $0.value.type == .friend }.map(\.key))
        cachedRelationshipNicknamesByUserID = nicknames
        continuation?.yield(.relationshipsChanged(publishedRelationships()))
        publishRelationshipPresences(complete: true)
        if blockedChanged { continuation?.yield(.knownUsersChanged(currentKnownUsers())) }
        guard nicknamesChanged else { return }
        if let channels = cachedChannels[nil] {
            let renamed = channels.map(applyingFriendNicknames)
            if renamed != channels {
                cachedChannels[nil] = renamed
                continuation?.yield(.channelsChanged(guildID: nil, channels: renamed))
            }
        }
        continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
    }

    /// Batch identity changes from a Gateway payload or REST hydration into one
    /// list publication. READY and disconnect cancel work from the old session.
    func scheduleRelationshipUserPublication() {
        guard relationshipUserPublicationTask == nil else { return }
        let generation = profileEditingGeneration
        relationshipUserPublicationTask = Task { [weak self] in
            await Task.yield()
            await self?.publishChangedRelationshipUsers(generation: generation)
        }
    }

    private func publishChangedRelationshipUsers(generation: UInt64) {
        guard !Task.isCancelled, profileEditingGeneration == generation else { return }
        relationshipUserPublicationTask = nil
        continuation?.yield(.relationshipsChanged(publishedRelationships()))
    }

    // MARK: - Presence

    /// Account-wide presence from the private presence cache. Other users'
    /// Invisible is never disclosed, so it reads as offline like an absent one.
    func relationshipPresence(for userID: UserID) -> UserPresence {
        guard let member = cachedPrivateMembersByID[userID], member.status.isVisibleOnline else {
            return UserPresence(status: .offline)
        }
        return UserPresence(
            status: member.status, customStatus: member.customStatus, activityText: member.activityText,
            isListeningToMusic: member.isListeningToMusic, isMobileOnly: member.isMobileOnly
        )
    }

    func publishRelationshipPresences(complete: Bool, userIDs: [UserID]? = nil) {
        let ids = userIDs ?? Array(cachedRelationships.keys)
        let presences = Dictionary(uniqueKeysWithValues: ids.lazy
            .filter { self.cachedRelationships[$0] != nil }
            .map { ($0, self.relationshipPresence(for: $0)) })
        guard complete || !presences.isEmpty else { return }
        continuation?.yield(.relationshipPresencesChanged(presences, isComplete: complete))
    }
}
