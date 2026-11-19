import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func supports(_ capability: ChatCapability) async -> Bool {
        switch capability {
        case .slashCommands, .components, .modals, .remoteComponentChoices, .forums, .gifs,
             .messageForwarding, .soundboard, .stickers, .stickerSending:
            true
        }
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        try await send(draft, progress: { _ in })
    }

    func ensurePrivateChannel(for userID: UserID) async throws -> Channel {
        if let existing = (cachedChannels[nil] ?? []).first(where: {
            $0.kind == .directMessage && $0.recipients.contains { $0.id == userID }
        }) {
            return existing
        }
        if let task = privateChannelTasks[userID] {
            return try await task.value
        }
        let task = Task { [self] in
            try await createPrivateChannel(for: userID)
        }
        privateChannelTasks[userID] = task
        defer { privateChannelTasks[userID] = nil }
        return try await task.value
    }

    private func createPrivateChannel(for userID: UserID) async throws -> Channel {
        let dto: ChannelDTO = try await request(
            "/users/@me/channels",
            method: "POST",
            body: ["recipients": .array([.string(userID.description)])]
        )
        let channel = try privateChannel(from: dto)
        upsertPrivateChannel(channel)
        continuation?.yield(.channelsChanged(
            guildID: nil,
            channels: cachedChannels[nil] ?? []
        ))
        return channel
    }

    func forward(_ draft: ForwardMessageDraft) async throws -> Message {
        let key = "forward:\(draft.destinationChannelID):\(draft.nonce)"
        if let task = messageSendTasks[key] {
            return try await task.value
        }
        let task = Task { [self] in
            try await performForward(draft)
        }
        messageSendTasks[key] = task
        defer { messageSendTasks[key] = nil }
        return try await task.value
    }

    internal func performForward(_ draft: ForwardMessageDraft) async throws -> Message {
        try requireGuildCommunication(in: draft.destinationChannelID)
        let isKnownChannel = cachedChannel(draft.destinationChannelID) != nil
        let isKnownThread = cachedForumPosts.values.contains { posts in
            posts[draft.destinationChannelID] != nil
        }
        guard isKnownChannel || isKnownThread else {
            throw ChatProviderError.channelNotFound
        }
        var reference: [String: JSONValue] = [
            "type": .number(1),
            "message_id": .string(draft.sourceMessageID.description),
            "channel_id": .string(draft.sourceChannelID.description),
        ]
        if let sourceGuildID = draft.sourceGuildID {
            reference["guild_id"] = .string(sourceGuildID.description)
        }
        let body: [String: JSONValue] = [
            "content": .string(""),
            "nonce": .string(draft.nonce),
            "tts": .bool(false),
            "flags": .number(draft.suppressesNotifications ? Double(MessageFlags.suppressNotifications.rawValue) : 0),
            "mobile_network_type": .string("unknown"),
            "message_reference": .object(reference),
        ]
        let dto: MessageDTO = try await request(
            "/channels/\(draft.destinationChannelID)/messages",
            method: "POST",
            body: body,
            headers: ["X-Context-Properties": DiscordClientMetadata.forwardingContextHeader]
        )
        var message = try domainMessage(dto)
        message.nonce = draft.nonce
        cachedMessages[message.id] = message
        continuation?.yield(.messageCreated(message))
        return message
    }

    func send(
        _ draft: SendMessageDraft, progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
        guard draft.attachmentURLs.count <= SendMessageDraft.maximumAttachmentCount else {
            throw ChatProviderError.invalidRequest(
                "A message can include at most \(SendMessageDraft.maximumAttachmentCount) attachments."
            )
        }
        let key = "\(draft.channelID):\(draft.nonce)"
        if let task = messageSendTasks[key] {
            let message = try await task.value
            progress(.completed(messageID: message.id))
            return message
        }
        let task = Task { [self] in
            try await performSend(draft, progress: progress)
        }
        messageSendTasks[key] = task
        // Cleared in the job that answers the caller, so no stop is accepted
        // between the post finishing and the caller learning of it.
        defer {
            messageSendTasks[key] = nil
            postingAttachmentUploads.subtract(draft.attachments.map(\.id))
        }
        return try await settlingPreuploads(of: draft) { try await task.value }
    }

    func edit(_ message: Message, content: String) async throws -> Message {
        try requireGuildCommunication(in: message.channelID)
        var body: [String: JSONValue] = ["content": .string(content)]
        body["allowed_mentions"] = message.editAllowedMentionsPayload
        let dto: MessageDTO = try await request(
            "/channels/\(message.channelID)/messages/\(message.id)", method: "PATCH", body: body
        )
        let updated = try domainMessage(dto)
        cachedMessages[updated.id] = updated
        continuation?.yield(.messageUpdated(updated))
        return updated
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {
        try await requestEmpty("/channels/\(channelID)/messages/\(messageID)", method: "DELETE")
        cachedMessages[messageID] = nil
        continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
    }
}
