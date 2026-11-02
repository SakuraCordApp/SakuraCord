import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    /// Refuses content, reactions, poll votes and interactions where the
    /// account may not communicate: a guild timeout, or a message request not
    /// yet accepted, which also takes no call rings.
    func requireCommunicationForRequest(path: String, method: String, body: [String: JSONValue]?) throws {
        let parts = path.split(separator: "/")
        if parts.count >= 3, parts[0] == "channels", let channelID = ChannelID(String(parts[1])) {
            let createsContent = method == "POST" && (
                (parts.count == 3 && ["messages", "threads", "typing", "send-soundboard-sound"].contains(parts[2]))
                    || (parts.count == 5 && parts[2] == "messages" && parts[4] == "threads")
            )
            let changesReaction = ["PUT", "DELETE"].contains(method) && parts.count >= 5
                && parts[2] == "messages" && parts[4] == "reactions"
            let editsContent = method == "PATCH" && parts.count == 4
                && parts[2] == "messages" && body?["content"] != nil
            let setsPollVote = method == "PUT" && parts.count == 6
                && parts[2] == "polls" && parts[4] == "answers" && parts[5] == "@me"
            let ringsCall = method == "POST" && parts.count == 4 && parts[2] == "call" && parts[3] == "ring"
            let communicates = createsContent || changesReaction || editsContent
            if communicates || setsPollVote || ringsCall {
                try requireAcceptedMessageRequest(in: channelID)
            }
            // A timeout still lets a member withdraw a vote.
            if communicates || (setsPollVote && body?["answer_ids"] != .array([])) {
                try requireGuildCommunication(in: channelID)
            }
        } else if path == "/interactions", method == "POST",
                  case let .string(rawID) = body?["channel_id"], let channelID = ChannelID(rawID) {
            try requireAcceptedMessageRequest(in: channelID)
            if body?["type"] == .number(2) { try requireGuildCommunication(in: channelID) }
        }
    }

    private func requireAcceptedMessageRequest(in channelID: ChannelID) throws {
        guard privateChannel(id: channelID)?.messageRequest == nil else {
            throw ChatProviderError.invalidRequest("Accept this message request first.")
        }
    }

    /// Recheck confirmed membership at the delivery boundary, including work
    /// queued before a live timeout update. This performs no additional reads.
    func requireGuildCommunication(in channelID: ChannelID, guildID: GuildID? = nil, now: Date = .now) throws {
        let guildID = guildID
            ?? cachedJoinedThreads[channelID]?.guildID
            ?? cachedChannels.values.lazy.flatMap(\.self).first(where: { $0.id == channelID })?.guildID
            ?? cachedForumPosts.values.lazy.compactMap { $0[channelID]?.thread.guildID }.first
            ?? cachedMessages.values.lazy.compactMap { $0.channelID == channelID ? $0.guildID : nil }.first
        guard let guildID, let userID = currentUser?.id,
              let member = cachedMemberIndex(guildID: guildID)[userID],
              let until = member.communicationDisabledUntil,
              until > now, cachedGuilds[guildID]?.isOwnedByCurrentUser != true
        else { return }
        let roleIDs = Set(member.roleIDs.map(\.description))
        let permissions = cachedGuilds[guildID]?.currentUserPermissions
            ?? (cachedGuildRoles[guildID] ?? []).filter {
                $0.id == guildID.description || roleIDs.contains($0.id)
            }.reduce(UInt64(0)) { $0 | ($1.permissions.flatMap(UInt64.init) ?? 0) }
        guard permissions & (1 << 3) == 0 else { return }
        throw ChatProviderError.invalidRequest("You are timed out in this server.")
    }
}
