import Foundation

/// A message a user asked Discord to send later. Discord keeps the create
/// request and replays it at `sendAt`; nothing is dispatched until then.
public struct ScheduledMessage: Sendable {
    public var id: Snowflake
    public var userID: Snowflake
    public var channelID: Snowflake
    public var sendAt: Date
    /// The `POST /users/@me/scheduled-messages` body as sent, later edits applied.
    public var body: JSONObject
}

extension World {
    /// Accounts without Nitro may keep one scheduled message (captured). The
    /// Nitro limit was never captured; it only needs to be above anything a test schedules.
    static let scheduledMessageLimit = (standard: 1, premium: 50)

    func scheduleMessage(_ body: JSONObject, by userID: Snowflake) async throws -> ScheduledMessage {
        guard let channelID = body["channel_id"]?.stringValue.flatMap(Snowflake.init) else { throw WorldError.invalidBody("channel_id") }
        let channel = try channel(channelID)
        try require(channel.type.isThread ? .sendMessagesInThreads : .sendMessages, userID, channel)
        let sendAt = try Self.scheduledDate(body["scheduled_timestamp"])
        let limit = try user(userID).premiumType == .none ? Self.scheduledMessageLimit.standard : Self.scheduledMessageLimit.premium
        guard scheduledMessages.values.count(where: { $0.userID == userID }) < limit else {
            throw WorldError(status: 400, code: 640_003, message: "You have too many scheduled messages")
        }
        for upload in body["attachments"]?.arrayValue ?? [] {
            guard let name = upload["uploaded_filename"]?.stringValue, let pending = pendingUploads[name],
                  pending.owner == userID, pending.channel == channelID, pending.data != nil
            else { throw WorldError.invalidBody("attachments: unknown upload") }
        }
        let scheduled = ScheduledMessage(id: nextID(), userID: userID, channelID: channelID, sendAt: sendAt, body: body)
        scheduledMessages[scheduled.id] = scheduled
        sendWhenDue(scheduled)
        return scheduled
    }

    func editScheduledMessage(_ id: Snowflake, by userID: Snowflake, patch: JSONObject) throws -> ScheduledMessage {
        var scheduled = try scheduledMessage(id, of: userID)
        for (key, value) in patch where key != "scheduled_timestamp" { scheduled.body[key] = value }
        if let timestamp = patch["scheduled_timestamp"] {
            scheduled.sendAt = try Self.scheduledDate(timestamp)
            scheduled.body["scheduled_timestamp"] = timestamp
        }
        scheduledMessages[id] = scheduled
        sendWhenDue(scheduled)
        return scheduled
    }

    func cancelScheduledMessage(_ id: Snowflake, by userID: Snowflake) throws {
        _ = try scheduledMessage(id, of: userID)
        scheduledMessages[id] = nil
    }

    /// Sends a scheduled message now, as a normal message with a new ID.
    func sendScheduledMessage(_ id: Snowflake, by userID: Snowflake) async throws -> Message {
        let scheduled = try scheduledMessage(id, of: userID)
        scheduledMessages[id] = nil
        let draft = try await MessageRoutes.draft(from: .object(scheduled.body), channelID: scheduled.channelID, files: [],
                                                  world: self, uploader: userID)
        return try await sendMessage(draft, as: userID, in: scheduled.channelID)
    }

    func scheduledMessages(of userID: Snowflake) async -> [ScheduledMessage] {
        await sendDueScheduledMessages()
        return scheduledMessages.values.filter { $0.userID == userID }.sorted { $0.sendAt < $1.sendAt }
    }

    func sendDueScheduledMessages() async {
        let now = clock.now
        for scheduled in scheduledMessages.values.filter({ $0.sendAt <= now }).sorted(by: { $0.sendAt < $1.sendAt }) {
            // Not captured: a message that can no longer be sent (channel gone, access lost) is dropped.
            _ = try? await sendScheduledMessage(scheduled.id, by: scheduled.userID)
        }
    }

    private func scheduledMessage(_ id: Snowflake, of userID: Snowflake) throws -> ScheduledMessage {
        guard let scheduled = scheduledMessages[id], scheduled.userID == userID else {
            // Not captured: the error for someone else's or an unknown scheduled message.
            throw WorldError(status: 404, code: 0, message: "404: Not Found")
        }
        return scheduled
    }

    private func sendWhenDue(_ scheduled: ScheduledMessage) {
        let delay = max(0, scheduled.sendAt.timeIntervalSince(clock.now))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.sendDueScheduledMessages()
        }
    }

    private static func scheduledDate(_ value: JSON?) throws -> Date {
        guard let date = value?.stringValue.flatMap(parseTimestamp) else { throw WorldError.invalidBody("scheduled_timestamp") }
        return date
    }

    // MARK: Rendering

    func renderScheduledMessage(_ scheduled: ScheduledMessage) -> JSON {
        let body = scheduled.body
        let isReply = body["message_reference"]?["message_id"] != nil
        var reference: JSON = .null
        if let ref = body["message_reference"]?.objectValue {
            var object = JSONObject([("type", 0)])
            for key in ["channel_id", "guild_id", "message_id"] { object[key] = ref[key] }
            reference = .object(object)
        }
        var allowedMentions: JSON = .null
        if let allowed = body["allowed_mentions"]?.objectValue {
            allowedMentions = .object(JSONObject([
                ("parse", .array((allowed["parse"]?.arrayValue ?? []).compactMap(\.stringValue).sorted().map(JSON.string))),
                ("users", allowed["users"] ?? []), ("roles", allowed["roles"] ?? []),
                ("replied_user", allowed["replied_user"] ?? false),
            ]))
        }
        let content = body["content"]?.stringValue ?? ""
        let flags = Int(body["flags"]?.intValue ?? 0)
        let createArgs = JSON.object(JSONObject([
            ("content", .string(content)), ("type", .int(isReply ? 19 : 0)), ("message_reference", reference),
            ("channel_id", scheduled.channelID.json), ("flags", .int(flags)), ("allowed_mentions", allowedMentions),
            ("poll", .null), ("sticker_ids", body["sticker_ids"] ?? []), ("forward_only", .null),
        ]))
        var preview = Message(id: scheduled.id, channelID: scheduled.channelID, authorID: scheduled.userID, content: content)
        preview.type = isReply ? 19 : 0
        preview.flags = flags
        if let channel = channels[scheduled.channelID] { parseMentions(content, in: channel).apply(to: &preview) }
        var previewObject = JSONObject()
        if case let .object(rendered) = renderMessage(preview, viewer: scheduled.userID, depth: 1) { previewObject = rendered }
        if isReply { previewObject["message_reference"] = reference }
        return .object(JSONObject([
            ("id", scheduled.id.json), ("create_args", createArgs), ("scheduled_message", createArgs),
            ("user_id", scheduled.userID.json), ("scheduled_message_id", scheduled.id.json),
            ("send_at_timestamp", .string(Self.wholeSecondTimestamp(scheduled.sendAt))), ("state", 0),
            ("attachment_uploads", .array((body["attachments"]?.arrayValue ?? []).map { upload in
                .object(JSONObject([
                    ("filename", upload["filename"] ?? ""), ("uploaded_filename", upload["uploaded_filename"] ?? ""),
                    ("description", upload["description"] ?? ""), ("title", upload["title"] ?? ""),
                    ("is_spoiler", .bool(upload["filename"]?.stringValue?.hasPrefix("SPOILER_") ?? false)),
                    ("duration_secs", upload["duration_secs"] ?? .null), ("waveform", upload["waveform"] ?? .null),
                ]))
            })),
            ("message_preview", .object(previewObject)),
        ]))
    }

    /// `2026-11-11T14:26:00+00:00`: send times are whole seconds and Discord drops the fraction.
    private static func wholeSecondTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
    }
}
