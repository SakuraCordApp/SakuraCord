import Foundation

/// Friends, requests, blocking and ignoring. Each side hears about its own
/// relationship: RELATIONSHIP_ADD for a new one, _UPDATE for a changed one,
/// _REMOVE when it ends.
extension World {
    /// `PUT /users/@me/relationships/{id}`: `type` 2 blocks; otherwise it sends a
    /// friend request, or accepts the one the other person sent.
    func putRelationship(_ userID: Snowflake, with otherID: Snowflake, type: Int?) async throws {
        guard otherID != userID else { throw WorldError(status: 400, code: 80003, message: "Cannot send friend request to self") }
        _ = try user(otherID)
        let now = clock.now
        if type == RelationshipType.blocked.rawValue {
            // Blocking ends any friendship or pending request on the other side.
            if let theirs = relationships[otherID]?[userID], theirs.type != .blocked { await endRelationship(of: otherID, with: userID) }
            await addRelationship(userID, Relationship(userID: otherID, type: .blocked, since: now))
            return
        }
        switch relationships[userID]?[otherID]?.type {
        case .friend:
            throw WorldError(status: 400, code: 80007, message: "You are already friends with that user.")
        case .outgoing:
            return
        case .incoming:
            await addRelationship(userID, Relationship(userID: otherID, type: .friend, since: now))
            await addRelationship(otherID, Relationship(userID: userID, type: .friend, since: now))
        case .blocked:
            throw ChannelEditRoutes.NotSimulated(description: "friend request to someone you blocked (never captured)")
        case .unrelated, nil:
            if relationships[otherID]?[userID]?.type == .blocked {
                throw ChannelEditRoutes.NotSimulated(description: "friend request to someone who blocked you (never captured)")
            }
            await addRelationship(userID, Relationship(userID: otherID, type: .outgoing, since: now))
            await addRelationship(otherID, Relationship(userID: userID, type: .incoming, since: now))
        }
    }

    /// `POST /users/@me/relationships`: a friend request by username.
    func sendFriendRequest(_ userID: Snowflake, toUsername username: String) async throws {
        guard let other = users.values.first(where: { $0.username == username.lowercased() && !$0.bot }) else {
            throw WorldError(status: 400, code: 80004, message: "No users with this DiscordTag exist")
        }
        try await putRelationship(userID, with: other.id, type: nil)
    }

    /// `DELETE /users/@me/relationships/{id}`: unfriend, cancel or decline a request, or unblock.
    /// A friendship or request ends for both people; a block only for the blocker.
    func deleteRelationship(_ userID: Snowflake, with otherID: Snowflake) async throws {
        _ = try user(otherID)
        guard let mine = relationships[userID]?[otherID] else { return }
        await endRelationship(of: userID, with: otherID)
        if mine.type != .blocked, mine.type != .unrelated, relationships[otherID]?[userID]?.type != .blocked {
            await endRelationship(of: otherID, with: userID)
        }
    }

    /// Ignoring someone with no other relationship creates an ignored-only one; un-ignoring ends it.
    func setIgnored(_ userID: Snowflake, _ otherID: Snowflake, ignored: Bool) async throws {
        _ = try user(otherID)
        switch relationships[userID]?[otherID] {
        case nil where ignored:
            var relationship = Relationship(userID: otherID, type: .unrelated, since: clock.now)
            relationship.ignored = true
            await addRelationship(userID, relationship)
        case let existing? where existing.type == .unrelated && !ignored:
            await endRelationship(of: userID, with: otherID)
        case .some:
            try await updateRelationship(userID, with: otherID) { $0.ignored = ignored }
        case nil:
            return
        }
    }

    func updateRelationship(_ userID: Snowflake, with otherID: Snowflake, _ change: (inout Relationship) -> Void) async throws {
        _ = try user(otherID)
        guard var relationship = relationships[userID]?[otherID] else { throw WorldError.unknown("User", code: 10013) }
        change(&relationship)
        relationships[userID]?[otherID] = relationship
        await emit("RELATIONSHIP_UPDATE", relationshipPayload(relationship, includeUser: false), to: .users([userID]))
    }

    private func addRelationship(_ owner: Snowflake, _ relationship: Relationship) async {
        relationships[owner, default: [:]][relationship.userID] = relationship
        await emit("RELATIONSHIP_ADD", relationshipPayload(relationship, includeUser: true), to: .users([owner]))
    }

    private func endRelationship(of owner: Snowflake, with otherID: Snowflake) async {
        guard let relationship = relationships[owner]?.removeValue(forKey: otherID) else { return }
        await emit("RELATIONSHIP_REMOVE", relationshipPayload(relationship, includeUser: false), to: .users([owner]))
    }

    /// Discord sends `since` for friends, blocks and incoming requests, not for outgoing or ignored-only ones.
    func relationshipPayload(_ relationship: Relationship, includeUser: Bool) -> JSON {
        var payload = JSONObject([("id", relationship.userID.json)])
        if includeUser { payload["is_spam_request"] = false }
        payload["nickname"] = .optional(relationship.nickname)
        if [.friend, .blocked, .incoming].contains(relationship.type) { payload["since"] = World.timestamp(relationship.since) }
        payload["type"] = .int(relationship.type.rawValue)
        if includeUser { payload["user"] = renderUser(relationship.userID) }
        payload["user_ignored"] = .bool(relationship.ignored)
        return .object(payload)
    }
}
