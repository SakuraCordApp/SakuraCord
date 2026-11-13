import Foundation
import SakuraCordModels

/// Scheduled messages, as the official client sends them (web build 670026).
/// Discord sends no Gateway event for these; the list is read when shown.
public extension DiscordRESTProvider {
    func scheduledMessages() async throws -> [ScheduledMessage] {
        let payload: [ScheduledMessageDTO] = try await request("/users/@me/scheduled-messages")
        return payload.map(\.domain)
    }

    /// Stores the files as a send does, then has Discord post the message at `date`.
    func scheduleMessage(_ draft: SendMessageDraft, at date: Date) async throws -> ScheduledMessage {
        try requireGuildCommunication(in: draft.channelID)
        var body: [String: JSONValue] = [
            "channel_id": .string(draft.channelID.description),
            "content": .string(draft.content),
            "scheduled_timestamp": .string(DiscordDate.format(date)),
            "flags": .number(0),
        ]
        if let replyTo = draft.replyTo {
            var reference: [String: JSONValue] = [
                "channel_id": .string(draft.channelID.description),
                "message_id": .string(replyTo.description),
            ]
            if let guildID = cachedChannels.values.lazy.flatMap(\.self).first(where: { $0.id == draft.channelID })?.guildID
                ?? cachedJoinedThreads[draft.channelID]?.guildID
            {
                reference["guild_id"] = .string(guildID.description)
            }
            body["message_reference"] = .object(reference)
            if let allowedMentions = draft.replyAllowedMentionsPayload {
                body["allowed_mentions"] = allowedMentions
            }
        }
        if !draft.stickerIDs.isEmpty {
            body["sticker_ids"] = .array(draft.stickerIDs.map(JSONValue.string))
        }
        body["attachments"] = try await .array(
            uploadForumAttachments(draft.attachments, channelID: draft.channelID, progress: { _ in })
        )
        // As for a send, a stored file the post refers to can no longer be stopped.
        postingAttachmentUploads.formUnion(draft.attachments.map(\.id))
        defer { postingAttachmentUploads.subtract(draft.attachments.map(\.id)) }
        let path = "/users/@me/scheduled-messages"
        let dto: ScheduledMessageDTO
        do {
            dto = try await request(path, method: "POST", body: body, mapFailure: Self.scheduledMessageFailure)
        } catch {
            settlePreuploads(of: draft, after: error)
            throw error
        }
        settlePreuploads(of: draft)
        return dto.domain
    }

    func rescheduleMessage(_ id: ScheduledMessageID, at date: Date) async throws -> ScheduledMessage {
        try await updateScheduledMessage(id, body: ["scheduled_timestamp": .string(DiscordDate.format(date))])
    }

    /// Keeps the message's flags, as the official inline editor does.
    func editScheduledMessage(_ id: ScheduledMessageID, content: String, flags: MessageFlags) async throws -> ScheduledMessage {
        try await updateScheduledMessage(id, body: ["content": .string(content), "flags": .number(Double(flags.rawValue))])
    }

    /// The posted message arrives through the Gateway, usually before this returns.
    func sendScheduledMessageNow(_ id: ScheduledMessageID) async throws {
        try await requestEmpty("/users/@me/scheduled-messages/\(id)/send", method: "POST")
    }

    func cancelScheduledMessage(_ id: ScheduledMessageID) async throws {
        try await requestEmpty("/users/@me/scheduled-messages/\(id)", method: "DELETE")
    }
}

extension DiscordRESTProvider {
    private func updateScheduledMessage(_ id: ScheduledMessageID, body: [String: JSONValue]) async throws -> ScheduledMessage {
        let dto: ScheduledMessageDTO = try await request(
            "/users/@me/scheduled-messages/\(id)", method: "PATCH", body: body, mapFailure: Self.scheduledMessageFailure
        )
        return dto.domain
    }

    /// Discord's own reasons, which the official client shows after its failure title.
    nonisolated static func scheduledMessageFailure(status: Int, code: Int?) -> (any Error)? {
        switch code {
        case 640_001: ChatProviderError.invalidRequest("Message cannot be scheduled for the past")
        case 640_002: ChatProviderError.invalidRequest("Message cannot be scheduled that far in the future")
        case 640_003: ChatProviderError.scheduledMessageLimitReached
        case 640_004: ChatProviderError.invalidRequest("Message must be scheduled further in the future")
        default: nil
        }
    }
}

private struct ScheduledMessageDTO: Decodable {
    struct CreateArguments: Decodable {
        var channelID: ChannelID
        var content: String?
        var flags: UInt64?
        var messageReference: ScheduledMessageReferenceDTO?

        enum CodingKeys: String, CodingKey {
            case channelID = "channel_id"
            case content, flags
            case messageReference = "message_reference"
        }
    }

    struct Upload: Decodable {}

    var id: ScheduledMessageID
    var createArgs: CreateArguments
    var sendAtTimestamp: DiscordTimestampDTO
    var state: Int?
    var attachmentUploads: [Upload]?
    /// The message as it will be posted, as Discord's list draws it.
    var messagePreview: MessageDTO?

    var domain: ScheduledMessage {
        ScheduledMessage(
            id: id,
            channelID: createArgs.channelID,
            sendAt: sendAtTimestamp.date,
            content: createArgs.content ?? "",
            flags: MessageFlags(rawValue: createArgs.flags ?? 0),
            replyTo: createArgs.messageReference?.messageID,
            state: state.flatMap(ScheduledMessage.State.init(rawValue:)) ?? .sendFailed,
            attachmentCount: attachmentUploads?.count ?? 0,
            preview: try? messagePreview?.domain()
        )
    }

    enum CodingKeys: String, CodingKey {
        case id = "scheduled_message_id"
        case createArgs = "create_args"
        case sendAtTimestamp = "send_at_timestamp"
        case state
        case attachmentUploads = "attachment_uploads"
        case messagePreview = "message_preview"
    }
}

private struct ScheduledMessageReferenceDTO: Decodable {
    var messageID: MessageID?
    enum CodingKeys: String, CodingKey { case messageID = "message_id" }
}

public extension ChatProvider {
    func scheduledMessages() async throws -> [ScheduledMessage] { [] }

    func scheduleMessage(_ draft: SendMessageDraft, at date: Date) async throws -> ScheduledMessage {
        throw ChatProviderError.invalidRequest("Scheduled messages are unavailable.")
    }

    func rescheduleMessage(_ id: ScheduledMessageID, at date: Date) async throws -> ScheduledMessage {
        throw ChatProviderError.invalidRequest("Scheduled messages are unavailable.")
    }

    func editScheduledMessage(_ id: ScheduledMessageID, content: String, flags: MessageFlags) async throws -> ScheduledMessage {
        throw ChatProviderError.invalidRequest("Scheduled messages are unavailable.")
    }

    func sendScheduledMessageNow(_ id: ScheduledMessageID) async throws {
        throw ChatProviderError.invalidRequest("Scheduled messages are unavailable.")
    }

    func cancelScheduledMessage(_ id: ScheduledMessageID) async throws {
        throw ChatProviderError.invalidRequest("Scheduled messages are unavailable.")
    }
}
