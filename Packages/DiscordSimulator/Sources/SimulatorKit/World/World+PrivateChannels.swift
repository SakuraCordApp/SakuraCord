import Foundation

/// Group DMs (rename, add or remove people, leave), closing a DM, and message requests.
extension World {
    /// `PATCH /channels/{id}` on a group DM: any member may rename it or change its icon.
    func editGroupDM(_ channelID: Snowflake, by userID: Snowflake, patch: JSON) async throws -> Channel {
        var channel = try groupDM(channelID, member: userID)
        var notices: [MessageDraft] = []
        if let name = patch["name"] {
            let trimmed = name.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard trimmed.count <= 100 else { throw WorldError.invalidBody("name: Must be 100 or fewer in length.") }
            channel.name = trimmed.isEmpty ? nil : trimmed
            var notice = MessageDraft(content: trimmed)
            notice.type = 4
            notices.append(notice)
        }
        if let icon = patch["icon"] {
            channel.icon = try icon.stringValue.map { try storeUploadedImage($0, path: { "/channel-icons/\(channelID)/\($0)" }) }
            var notice = MessageDraft()
            notice.type = 5
            notices.append(notice)
        }
        channels[channelID] = channel
        await emitToRecipients("CHANNEL_UPDATE", of: channel)
        for notice in notices { _ = try await sendSystemMessage(notice, as: userID, in: channelID) }
        return channel
    }

    /// `PUT /channels/{id}/recipients/{id}`: a member adds a friend, who gets the group in their DM list.
    func addGroupRecipient(_ channelID: Snowflake, _ added: Snowflake, by userID: Snowflake) async throws {
        var channel = try groupDM(channelID, member: userID)
        _ = try user(added)
        guard !channel.recipients.contains(added) else { return }
        // Not captured: the friends-only rule, the ten-person cap and their errors follow Discord's documentation.
        guard relationships[userID]?[added]?.type == .friend else { throw WorldError(status: 403, code: 50007, message: "Cannot send messages to this user") }
        guard channel.recipients.count < 10 else { throw WorldError(status: 400, code: 30011, message: "Maximum number of group DM recipients reached (10)") }
        channel.recipients.append(added)
        channels[channelID] = channel
        if openPrivateChannels[added]?.contains(channelID) != true { openPrivateChannels[added, default: []].append(channelID) }
        await emit("CHANNEL_CREATE", renderChannel(channel, viewer: added), to: .users([added]))
        await emit("CHANNEL_RECIPIENT_ADD", recipientPayload(channelID, added), to: .users(Set(channel.recipients).subtracting([added])))
        try await postRecipientNotice(type: 1, about: added, by: userID, in: channelID)
    }

    /// `DELETE /channels/{id}/recipients/{id}`: the owner removes someone; they lose the group.
    func removeGroupRecipient(_ channelID: Snowflake, _ removed: Snowflake, by userID: Snowflake) async throws {
        let channel = try groupDM(channelID, member: userID)
        guard channel.ownerID == userID else { throw WorldError.missingPermissions }
        guard channel.recipients.contains(removed) else { return }
        try await dropRecipient(removed, from: channel, by: userID)
    }

    /// `DELETE /channels/{id}` on a private channel: leaving a group, or closing a DM (which only hides it).
    /// Closing a 1:1 DM was never captured; it mirrors leaving a group for the closer.
    func closePrivateChannel(_ channelID: Snowflake, by userID: Snowflake) async throws -> JSON {
        let channel = try channel(channelID)
        guard channel.recipients.contains(userID) else { throw WorldError.missingAccess }
        let rendered = renderChannel(channel, viewer: userID)
        if channel.type == .groupDM {
            try await dropRecipient(userID, from: channel, by: userID)
        } else {
            openPrivateChannels[userID]?.removeAll { $0 == channelID }
            await emit("CHANNEL_DELETE", rendered, to: .users([userID]))
        }
        return rendered
    }

    /// `PUT /channels/{id}/recipients/@me` with `consent_status` 2 (accepted). No simulated DM is a
    /// message request, so accepting one changes nothing and sends no event.
    func acceptMessageRequest(_ channelID: Snowflake, by userID: Snowflake, consent: JSON?) throws {
        _ = try directMessage(channelID, member: userID)
        guard consent?.intValue == 2 else { throw WorldError.invalidBody("consent_status") }
    }

    /// `DELETE /channels/{id}/recipients/@me`: ignoring a request closes the DM for this user only.
    func ignoreMessageRequest(_ channelID: Snowflake, by userID: Snowflake) async throws {
        _ = try directMessage(channelID, member: userID)
        _ = try await closePrivateChannel(channelID, by: userID)
    }

    /// "Don't leave" on a group's blocked-member warning; READY then carries `blocked_user_warning_dismissed`.
    func dismissBlockedUserWarning(in channelID: Snowflake, by userID: Snowflake) throws {
        let channel = try channel(channelID)
        guard channel.type.isPrivate else { throw WorldError.wrongChannelType }
        dismissedBlockedUserWarnings[userID, default: []].insert(channelID)
    }

    /// The person leaves the group: they get CHANNEL_DELETE and an ack of the last message;
    /// the rest see them go, and a new owner if the owner left.
    private func dropRecipient(_ removed: Snowflake, from channel: Channel, by userID: Snowflake) async throws {
        var channel = channel
        channel.recipients.removeAll { $0 == removed }
        // Not captured (the owner stayed): ownership passes to the next member, as Discord documents.
        let ownerLeft = channel.ownerID == removed
        if ownerLeft { channel.ownerID = channel.recipients.first }
        openPrivateChannels[removed]?.removeAll { $0 == channel.id }
        await emit("CHANNEL_DELETE", renderChannel(channels[channel.id] ?? channel, viewer: removed), to: .users([removed]))
        if removed == userID, let last = channel.lastMessageID { try await acknowledge(last, in: channel.id, by: removed) }
        guard !channel.recipients.isEmpty else {
            channels[channel.id] = nil
            return
        }
        channels[channel.id] = channel
        await emit("CHANNEL_RECIPIENT_REMOVE", recipientPayload(channel.id, removed), to: .users(Set(channel.recipients)))
        if ownerLeft { await emitToRecipients("CHANNEL_UPDATE", of: channel) }
        try await postRecipientNotice(type: 2, about: removed, by: userID, in: channel.id)
    }

    private func groupDM(_ channelID: Snowflake, member userID: Snowflake) throws -> Channel {
        let channel = try channel(channelID)
        guard channel.type == .groupDM else { throw WorldError.wrongChannelType }
        guard channel.recipients.contains(userID) else { throw WorldError.missingAccess }
        return channel
    }

    private func directMessage(_ channelID: Snowflake, member userID: Snowflake) throws -> Channel {
        let channel = try channel(channelID)
        guard channel.type == .dm else { throw WorldError.wrongChannelType }
        guard channel.recipients.contains(userID) else { throw WorldError.missingAccess }
        return channel
    }

    private func emitToRecipients(_ name: String, of channel: Channel) async {
        for recipient in channel.recipients { await emit(name, renderChannel(channel, viewer: recipient), to: .users([recipient])) }
    }

    private func recipientPayload(_ channelID: Snowflake, _ userID: Snowflake) -> JSON {
        .object(JSONObject([("channel_id", channelID.json), ("user", renderUser(userID))]))
    }

    /// "X added/removed Y" (types 1 and 2), authored by whoever acted and mentioning who changed.
    private func postRecipientNotice(type: Int, about subject: Snowflake, by userID: Snowflake, in channelID: Snowflake) async throws {
        var message = Message(id: nextID(), channelID: channelID, authorID: userID, content: "")
        message.type = type
        message.mentions = [subject]
        channels[channelID]?.messages.append(message)
        await emit("MESSAGE_CREATE", renderMessageEvent(message), to: audience(for: try channel(channelID)))
    }
}
