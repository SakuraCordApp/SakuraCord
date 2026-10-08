import Foundation
import SakuraCordModels

public extension MockChatProvider {
    func setMemberNickname(_ nickname: String, for userID: UserID, in guildID: GuildID) async throws -> String? {
        let value = nickname.isEmpty ? nil : nickname
        guard var members = membersByGuild[guildID], let index = members.firstIndex(where: { $0.id == userID }) else {
            throw ChatProviderError.invalidRequest("That demo member is unavailable.")
        }
        let globalName = members[index].globalDisplayName ?? members[index].user.displayName
        members[index].globalDisplayName = globalName
        members[index].guildNickname = value
        members[index].user.displayName = value ?? globalName
        membersByGuild[guildID] = members
        continuation?.yield(.membersChanged(guildID: guildID, members: members, groups: []))
        return value
    }

    func setFriendNickname(_ nickname: String?, for userID: UserID) async throws -> String? {
        let value = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = snapshot.relationships.firstIndex(where: { $0.id == userID }) {
            snapshot.relationships[index].nickname = value?.isEmpty == false ? value : nil
        }
        publishRelationships()
        // Like the live provider, retitle unnamed DMs and group DMs.
        let nicknames = snapshot.relationshipNicknamesByUserID
        snapshot.channels = snapshot.channels.map { channel in
            guard channel.guildID == nil, !channel.hasExplicitName, !channel.recipients.isEmpty else { return channel }
            var channel = channel
            channel.name = channel.recipients.map { nicknames[$0.id] ?? $0.displayName }.joined(separator: ", ")
            return channel
        }
        continuation?.yield(.channelsChanged(guildID: nil, channels: snapshot.channels.filter { $0.guildID == nil }))
        continuation?.yield(.privateMembersChanged(try await members(in: nil)))
        return nicknames[userID]
    }

    func sendFriendRequest(username: String, discriminator: Int?, note: String? = nil, captchaHandler: DiscordCaptchaHandler?) async throws {
        let known = snapshot.knownUsers + snapshot.relationships.compactMap(\.user)
        guard let user = known.first(where: { $0.username == username }), user.id != currentUser.id else {
            throw RelationshipActionError.failed("Hm, didn’t work. Double check that the username is correct.")
        }
        if snapshot.relationships.contains(where: { $0.id == user.id && $0.type == .friend }) {
            throw RelationshipActionError.failed("You’re already friends with that user!")
        }
        setRelationship(Relationship(id: user.id, type: .outgoingRequest, user: user, note: try FriendRequestNote.normalized(note)))
    }

    func acceptFriendRequest(from userID: UserID, confirmingStranger: Bool, captchaHandler: DiscordCaptchaHandler?) async throws {
        guard var relationship = snapshot.relationships.first(where: { $0.id == userID && $0.type == .incomingRequest }) else {
            throw RelationshipActionError.failed("Discord couldn’t update this relationship. Try again.")
        }
        relationship.type = .friend
        relationship.since = .now
        setRelationship(relationship)
    }

    func removeRelationship(with userID: UserID, as removal: RelationshipRemoval) async throws {
        snapshot.relationships.removeAll { $0.id == userID }
        publishRelationships()
    }

    func blockUser(_ userID: UserID, captchaHandler: DiscordCaptchaHandler? = nil) async throws {
        let user = snapshot.relationships.first { $0.id == userID }?.user
            ?? snapshot.knownUsers.first { $0.id == userID }
        setRelationship(Relationship(id: userID, type: .blocked, user: user))
    }

    private func setRelationship(_ relationship: Relationship) {
        snapshot.relationships.removeAll { $0.id == relationship.id }
        snapshot.relationships.append(relationship)
        publishRelationships()
    }

    private func publishRelationships() {
        snapshot.friendUserIDs = snapshot.relationships.friendUserIDs
        snapshot.relationshipNicknamesByUserID = snapshot.relationships.nicknamesByUserID
        continuation?.yield(.relationshipsChanged(snapshot.relationships))
    }
}
