import Foundation

/// Channel and message routes.
enum MessageRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        registerMessages(into: &routes)
        registerReactions(into: &routes)
        registerReadStates(into: &routes)
        registerPins(into: &routes)
        registerPollsAndUploads(into: &routes)
    }

    private static func registerMessages(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/channels/{id}"] = { context in
            let channel = try await context.world.channel(try context.id(0))
            guard await context.world.canView(context.userID, channel) else { throw WorldError.missingAccess }
            if channel.type.isThread { return .json(await context.world.renderThread(channel, viewer: context.userID)) }
            return .json(await context.world.renderChannel(channel, viewer: context.userID))
        }

        routes["GET /api/v9/channels/{id}/messages"] = { context in
            let world = context.world
            let channel = try await world.channel(try context.id(0))
            try await world.require(.readMessageHistory, context.userID, channel)
            let limit = min(100, max(1, Int(context.query("limit") ?? "50") ?? 50))
            let all = channel.messages
            var page: ArraySlice<Message>
            if let before = context.query("before").flatMap(Snowflake.init) {
                page = all.filter { $0.id < before }.suffix(limit)
            } else if let after = context.query("after").flatMap(Snowflake.init) {
                page = all.filter { $0.id > after }.prefix(limit)
            } else if let around = context.query("around").flatMap(Snowflake.init) {
                let index = all.firstIndex { $0.id >= around } ?? all.count
                let half = limit / 2
                page = all[max(0, index - half) ..< min(all.count, index - half + limit)]
            } else {
                page = all.suffix(limit)
            }
            var rendered: [JSON] = []
            for message in page.reversed() { rendered.append(await world.renderMessage(message, viewer: context.userID)) }
            return .json(.array(rendered))
        }

        routes["GET /api/v9/channels/{id}/messages/{id}"] = { context in
            let message = try await context.world.message(try context.id(1), in: try context.id(0))
            return .json(await context.world.renderMessage(message, viewer: context.userID))
        }

        routes["POST /api/v9/channels/{id}/messages"] = { context in
            let channelID = try context.id(0)
            let (body, files) = try MultipartForm.messageBody(context.request)
            var draft = try await MessageRoutes.draft(from: body, channelID: channelID, files: files, world: context.world,
                                                      uploader: context.userID)
            draft.nonce = body["nonce"]?.stringValue ?? body["nonce"]?.intValue.map(String.init)
            let message = try await context.world.sendMessage(draft, as: context.userID, in: channelID)
            await context.world.unfurlLinks(in: message)
            return .json(await context.world.renderMessage(message, viewer: context.userID))
        }

        routes["PATCH /api/v9/channels/{id}/messages/{id}"] = { context in
            let body = try context.json
            let message = try await context.world.editMessage(
                try context.id(1), in: try context.id(0), by: context.userID,
                content: body["content"]?.stringValue, embeds: body["embeds"]?.arrayValue, flags: body["flags"]?.intValue.map { Int($0) }
            )
            return .json(await context.world.renderMessage(message, viewer: context.userID))
        }

        routes["DELETE /api/v9/channels/{id}/messages/{id}"] = { context in
            try await context.world.deleteMessage(try context.id(1), in: try context.id(0), by: context.userID)
            return .empty()
        }

    }

    private static func registerReactions(into routes: inout [String: RouteHandler]) {
        // Reactions: `/reactions/{emoji}/@me`, and `/reactions/{emoji}/{type}/@me` for removal.
        let react: RouteHandler = { context in
            let (name, id) = try MessageRoutes.emoji(context.parameters[2])
            let burst = context.query("type") == "1"
            try await context.world.react(try context.id(1), in: try context.id(0), by: context.userID, emojiName: name, emojiID: id, burst: burst)
            return .empty()
        }
        routes["PUT /api/v9/channels/{id}/messages/{id}/reactions/{emoji}/@me"] = react
        let unreact: RouteHandler = { context in
            let (name, id) = try MessageRoutes.emoji(context.parameters[2])
            let segments = context.request.path.split(separator: "/")
            let burst = segments.count >= 2 && segments[segments.count - 2] == "1"
            try await context.world.unreact(try context.id(1), in: try context.id(0), by: context.userID, emojiName: name, emojiID: id, burst: burst)
            return .empty()
        }
        routes["DELETE /api/v9/channels/{id}/messages/{id}/reactions/{emoji}/@me"] = unreact
        routes["DELETE /api/v9/channels/{id}/messages/{id}/reactions/{emoji}/0/@me"] = unreact
        routes["DELETE /api/v9/channels/{id}/messages/{id}/reactions/{emoji}/1/@me"] = unreact
        routes["GET /api/v9/channels/{id}/messages/{id}/reactions/{emoji}"] = { context in
            let (name, id) = try MessageRoutes.emoji(context.parameters[2])
            let message = try await context.world.message(try context.id(1), in: try context.id(0))
            let key = id.map { "\(name):\($0)" } ?? name
            let reaction = message.reactions.first { $0.key == key }
            let users = context.query("type") == "1" ? reaction?.burstUsers ?? [] : reaction?.users ?? []
            let after = context.query("after").flatMap(Snowflake.init)
            let limit = Int(context.query("limit") ?? "25") ?? 25
            var rendered: [JSON] = []
            for user in users.sorted().filter({ after == nil || $0 > after! }).prefix(limit) {
                rendered.append(await context.world.renderUser(user))
            }
            return .json(.array(rendered))
        }

    }

    private static func registerReadStates(into routes: inout [String: RouteHandler]) {
        routes["POST /api/v9/channels/{id}/typing"] = { context in
            try await context.world.startTyping(context.userID, in: try context.id(0))
            return .empty()
        }

        routes["POST /api/v9/channels/{id}/messages/{id}/ack"] = { context in
            let body = try context.json
            try await context.world.acknowledge(try context.id(1), in: try context.id(0), by: context.userID,
                                                manual: body["manual"]?.boolValue ?? false)
            return .json(.object(JSONObject([("token", .null)])))
        }

        routes["DELETE /api/v9/channels/{id}/messages/ack"] = { _ in .empty() }

        routes["POST /api/v9/read-states/ack-bulk"] = { context in
            for entry in try context.json["read_states"]?.arrayValue ?? [] {
                guard let channel = entry["channel_id"]?.stringValue.flatMap(Snowflake.init),
                      let message = entry["message_id"]?.stringValue.flatMap(Snowflake.init) else { continue }
                try await context.world.acknowledge(message, in: channel, by: context.userID)
            }
            return .empty()
        }

    }

    private static func registerPins(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/channels/{id}/messages/pins"] = { context in
            let channel = try await context.world.channel(try context.id(0))
            let limit = Int(context.query("limit") ?? "50") ?? 50
            let before = context.query("before")
            // Newest pin first; `before` is a pin time, as Discord paginates pins.
            var pinned = channel.messages.filter(\.pinned).sorted { ($0.pinnedAt ?? $0.timestamp) > ($1.pinnedAt ?? $1.timestamp) }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let before, let date = formatter.date(from: before) ?? ISO8601DateFormatter().date(from: before) {
                pinned = pinned.filter { ($0.pinnedAt ?? $0.timestamp) < date }
            }
            var items: [JSON] = []
            for message in pinned.prefix(limit) {
                items.append(.object(JSONObject([
                    ("pinned_at", World.timestamp(message.pinnedAt ?? message.timestamp)),
                    ("message", await context.world.renderMessage(message, viewer: context.userID)),
                ])))
            }
            return .json(.object(JSONObject([("items", .array(items)), ("has_more", .bool(pinned.count > limit))])))
        }
        routes["PUT /api/v9/channels/{id}/messages/pins/{id}"] = { context in
            try await context.world.setPinned(try context.id(1), in: try context.id(0), by: context.userID, pinned: true)
            return .empty()
        }
        routes["DELETE /api/v9/channels/{id}/messages/pins/{id}"] = { context in
            try await context.world.setPinned(try context.id(1), in: try context.id(0), by: context.userID, pinned: false)
            return .empty()
        }

    }

    private static func registerPollsAndUploads(into routes: inout [String: RouteHandler]) {
        routes["PUT /api/v9/channels/{id}/polls/{id}/answers/@me"] = { context in
            let answers = (try context.json["answer_ids"]?.arrayValue ?? []).compactMap { $0.intValue.map(Int.init) ?? $0.stringValue.flatMap(Int.init) }
            try await context.world.vote(try context.id(1), in: try context.id(0), by: context.userID, answers: answers)
            return .empty()
        }
        routes["GET /api/v9/channels/{id}/polls/{id}/answers/{answer_id}"] = { context in
            let message = try await context.world.message(try context.id(1), in: try context.id(0))
            let answerID = Int(context.parameters[2]) ?? 0
            var users: [JSON] = []
            for voter in message.poll?.answers.first(where: { $0.id == answerID })?.voters ?? [] {
                users.append(await context.world.renderUser(voter))
            }
            return .json(.object(JSONObject([("users", .array(users))])))
        }

        routes["POST /api/v9/channels/{id}/attachments"] = { context in
            let body = try context.json
            var slots: [JSON] = []
            for (index, file) in (body["files"]?.arrayValue ?? []).enumerated() {
                let filename = file["filename"]?.stringValue ?? "file"
                let uploadName = await context.world.reserveUpload(filename: filename, owner: context.userID, channel: try context.id(0))
                let path = "/discord-attachments-uploads-prd/\(uploadName)?upload_id=\(uploadName.split(separator: "/").first ?? "")"
                slots.append(.object(JSONObject([
                    ("id", file["id"].flatMap { $0.intValue }.map { .int($0) } ?? .int(Int64(index))),
                    ("upload_url", .string("https://discord-attachments-uploads-prd.storage.googleapis.com\(path)")),
                    ("upload_filename", .string(uploadName)),
                ])))
            }
            return .json(.object(JSONObject([("attachments", .array(slots))])))
        }
        routes["DELETE /api/v9/attachments/{upload_filename}"] = { _ in .empty() }
    }

    /// `👍`, `name:123`, or `name%3A123` in a reaction path.
    static func emoji(_ segment: String) throws -> (String, Snowflake?) {
        let decoded = segment.removingPercentEncoding ?? segment
        let parts = decoded.split(separator: ":")
        if parts.count == 2, let id = Snowflake(String(parts[1])) { return (String(parts[0]), id) }
        guard !decoded.isEmpty else { throw WorldError(status: 400, code: 10014, message: "Unknown Emoji") }
        return (decoded, nil)
    }

    static func draft(from body: JSON, channelID: Snowflake, files: [MultipartForm.File], world: World,
                      uploader: Snowflake) async throws -> MessageDraft {
        var draft = MessageDraft(content: body["content"]?.stringValue ?? "")
        draft.tts = body["tts"]?.boolValue ?? false
        if let allowed = body["allowed_mentions"]?.objectValue {
            draft.allowedMentionsParse = Set((allowed["parse"]?.arrayValue ?? []).compactMap(\.stringValue))
            draft.mentionsRepliedUser = allowed["replied_user"]?.boolValue ?? true
        }
        draft.flags = Int(body["flags"]?.intValue ?? 0)
        draft.embeds = body["embeds"]?.arrayValue ?? []
        draft.stickerIDs = (body["sticker_ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Snowflake.init) }
        if let reference = body["message_reference"], let channel = reference["channel_id"]?.stringValue.flatMap(Snowflake.init) ?? Optional(channelID) {
            draft.reference = MessageReference(
                type: Int(reference["type"]?.intValue ?? 0),
                messageID: reference["message_id"]?.stringValue.flatMap(Snowflake.init),
                channelID: channel,
                guildID: reference["guild_id"]?.stringValue.flatMap(Snowflake.init)
            )
            if draft.reference?.type == 1, let source = draft.reference, let id = source.messageID {
                let original = try await world.message(id, in: source.channelID)
                draft.reference?.guildID = try await world.channel(source.channelID).guildID
                draft.forwardSnapshot = await world.renderForwardSnapshot(original)
            }
        }
        if let poll = body["poll"] {
            let answers = (poll["answers"]?.arrayValue ?? []).enumerated().map { index, answer in
                Poll.Answer(id: index + 1, text: answer["poll_media"]?["text"]?.stringValue ?? "",
                            emoji: answer["poll_media"]?["emoji"]?["name"]?.stringValue)
            }
            let hours = Double(poll["duration"]?.intValue ?? 24)
            draft.poll = Poll(question: poll["question"]?["text"]?.stringValue ?? "", answers: answers,
                              expiry: world.clock.now.addingTimeInterval(hours * 3600),
                              allowMultiselect: poll["allow_multiselect"]?.boolValue ?? false,
                              layoutType: Int(poll["layout_type"]?.intValue ?? 1))
        }
        for (index, entry) in (body["attachments"]?.arrayValue ?? []).enumerated() {
            let filename = entry["filename"]?.stringValue ?? "file"
            var data: Data?
            if let uploaded = entry["uploaded_filename"]?.stringValue {
                data = await world.takeUpload(uploaded, owner: uploader, channel: channelID)
                guard data != nil else { throw WorldError.invalidBody("attachments.\(index).uploaded_filename: unknown upload") }
            } else if let id = entry["id"]?.intValue ?? entry["id"]?.stringValue.flatMap(Int64.init) {
                data = files.first { $0.fieldName == "files[\(id)]" }?.data
            }
            guard let data else { throw WorldError.invalidBody("attachments.\(index): no file data") }
            draft.attachments.append(await world.storeAttachment(
                data, filename: filename, channelID: channelID,
                description: entry["description"]?.stringValue,
                durationSeconds: entry["duration_secs"].flatMap { if case let .double(value) = $0 { value } else { $0.intValue.map(Double.init) } },
                waveform: entry["waveform"]?.stringValue,
                flags: Int(entry["flags"]?.intValue ?? 0)
            ))
        }
        return draft
    }
}
