import SakuraCordModels

extension DiscordRESTProvider {
    /// The original request plus replays after server `429` cooldowns.
    static let maximumMessageSendAttempts = 5

    func performSend(
        _ draft: SendMessageDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
        if let poll = draft.poll {
            if let error = poll.validationError { throw ChatProviderError.invalidRequest(error) }
            guard draft.content.isEmpty, draft.attachments.isEmpty, draft.stickerIDs.isEmpty, draft.replyTo == nil else {
                throw ChatProviderError.invalidRequest("Send a poll separately from text, attachments, stickers, and replies.")
            }
        }
        progress(.preparing)
        guard draft.stickerIDs.isEmpty || draft.attachmentURLs.isEmpty else {
            throw ChatProviderError.invalidRequest(
                "A native sticker send cannot include uploaded attachments."
            )
        }
        guard draft.stickerIDs.count <= 1 else {
            throw ChatProviderError.invalidRequest("A message can include only one sticker.")
        }
        var body: [String: JSONValue] = [
            "content": .string(draft.content),
            "nonce": .string(draft.nonce),
            "tts": .bool(draft.isTTS),
            "flags": .number(0),
            // Chromium reports an unknown Network Information API connection
            // type on the current macOS desktop host. The first-party send
            // action forwards that value on every ordinary message POST.
            "mobile_network_type": .string("unknown"),
        ]
        if let poll = draft.poll {
            body["poll"] = poll.requestPayload
        } else if draft.stickerIDs.isEmpty {
            body["enforce_nonce"] = .bool(true)
        } else {
            body["sticker_ids"] = .array(draft.stickerIDs.map(JSONValue.string))
        }
        if let replyTo = draft.replyTo {
            body["message_reference"] = draft.replyReferencePayload(for: replyTo)
            if let allowedMentions = draft.replyAllowedMentionsPayload {
                body["allowed_mentions"] = allowedMentions
            }
        }
        if !draft.attachmentURLs.isEmpty {
            body["attachments"] = try await .array(
                uploadForumAttachments(
                    draft.attachments,
                    channelID: draft.channelID,
                    progress: progress
                )
            )
        }
        progress(.submitting)
        let path = "/channels/\(draft.channelID)/messages"
        // Like the first-party message queue, a rate-limited send waits out the
        // server cooldown and is replayed with its nonce. A 429 is a definite
        // rejection, so the replay cannot duplicate the message. Slowmode is
        // returned to the composer instead.
        let (data, response) = try await perform(
            path,
            method: "POST",
            query: [],
            body: body,
            headers: ["X-Context-Properties": draft.poll == nil ? DiscordClientMetadata.messageContextHeader : "eyJsb2NhdGlvbiI6InBvbGxfY3JlYXRpb24ifQ=="],
            maximumAttempts: Self.maximumMessageSendAttempts
        )
        let dto: MessageDTO = try decodedResponse(data, response, method: "POST", path: path)
        var message = try dto.domain()
        message.nonce = draft.nonce
        if draft.poll != nil, let current = cachedMessages[message.id]?.poll, current.results != nil {
            message.poll = current
        }
        cachedMessages[message.id] = message
        continuation?.yield(.messageCreated(message))
        progress(.completed(messageID: message.id))
        return message
    }
}
