import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func sendTyping(in channelID: ChannelID) async throws {
        try requireGuildCommunication(in: channelID)
        guard let channel = cachedChannel(channelID) else { throw ChatProviderError.channelNotFound }
        guard channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown else {
            throw ChatProviderError.invalidRequest("Typing is unavailable in this channel.")
        }
        // Discord documents this mutation as an empty POST returning 204. It goes
        // through the shared scheduler and, like every mutation, is attempted once.
        try await requestEmpty("/channels/\(channelID)/typing", method: "POST")
    }

    func acknowledge(
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

    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?,
        manual: Bool,
        mentionCount: Int?,
        flags: UInt64?,
        lastViewed: Int?
    ) async throws -> ReadAcknowledgementResponse {
        // Mark Unread posts exactly `manual` and the mention count
        // (module 439147, build 649389); a read posts the token and metadata.
        var body: [String: JSONValue]
        if manual {
            body = ["manual": .bool(true), "mention_count": .number(Double(max(0, mentionCount ?? 0)))]
        } else {
            body = ["token": token.map(JSONValue.string) ?? .null]
            if let flags {
                body["flags"] = .number(Double(flags))
            }
            if let lastViewed {
                body["last_viewed"] = .number(Double(lastViewed))
            }
        }
        let (data, response) = try await perform(
            "/channels/\(channelID)/messages/\(messageID)/ack",
            method: "POST",
            body: body
        )
        try validateEmptyResponse(data, response)
        guard !data.isEmpty else { return ReadAcknowledgementResponse(token: token) }
        return try JSONDecoder().decode(ReadAcknowledgementResponse.self, from: data)
    }

    func acknowledgeBulk(
        _ readStates: [BulkReadStateAcknowledgement]
    ) async throws {
        for (index, batch) in readStates.chunked(into: 100).enumerated() {
            if index > 0 {
                // Discord's BULK_ACK queue spaces successful batches by one second.
                try await Task.sleep(for: .seconds(1))
            }
            try await requestEmpty(
                "/read-states/ack-bulk",
                method: "POST",
                body: [
                    "read_states": .array(
                        batch.map { readState in
                            .object([
                                "channel_id": .string(readState.channelID.description),
                                "message_id": .string(readState.messageID.description),
                                "read_state_type": .number(Double(readState.readStateType)),
                            ])
                        }
                    )
                ]
            )
        }
    }
}
