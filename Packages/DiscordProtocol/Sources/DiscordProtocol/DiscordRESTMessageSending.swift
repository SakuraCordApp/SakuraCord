import SakuraCordModels

extension DiscordRESTProvider {
    func performSend(
        _ draft: SendMessageDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
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
            "tts": .bool(false),
            "flags": .number(0),
            // Chromium reports an unknown Network Information API connection
            // type on the current macOS desktop host. The first-party send
            // action forwards that value on every ordinary message POST.
            "mobile_network_type": .string("unknown"),
        ]
        if draft.stickerIDs.isEmpty {
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
        let dto: MessageDTO = try await request(
            "/channels/\(draft.channelID)/messages",
            method: "POST",
            body: body,
            headers: ["X-Context-Properties": DiscordClientMetadata.messageContextHeader]
        )
        var message = try dto.domain()
        message.nonce = draft.nonce
        cachedMessages[message.id] = message
        continuation?.yield(.messageCreated(message))
        progress(.completed(messageID: message.id))
        return message
    }
}
