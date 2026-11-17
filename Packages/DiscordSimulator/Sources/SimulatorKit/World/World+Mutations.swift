import Foundation

/// What a client asked to post; shared by the REST route and the control API.
public struct MessageDraft: Sendable {
    public var content = ""
    public var nonce: String?
    public var tts = false
    public var flags = 0
    public var embeds: [JSON] = []
    public var components: [JSON] = []
    public var attachments: [Attachment] = []
    public var reference: MessageReference?
    public var poll: Poll?
    public var stickerIDs: [Snowflake] = []
    public var type = 0
    public var call: JSON?
    /// `allowed_mentions.parse` (nil means Discord's default: everything) and
    /// `replied_user`, which decides whether a reply pings its author.
    public var allowedMentionsParse: Set<String>?
    public var mentionsRepliedUser = true
    /// A forum post's starter message shares the post's ID.
    public var id: Snowflake?
    /// For forwards: the original message as Discord snapshots it.
    public var forwardSnapshot: JSON?
    /// For a bot's interaction response: its application and the interaction it answers.
    public var applicationID: Snowflake?
    public var interaction: InteractionRecord?

    public init(content: String = "") { self.content = content }
}

public extension World {
    // MARK: Messages

    @discardableResult
    func sendMessage(_ draft: MessageDraft, as authorID: Snowflake, in channelID: Snowflake, checkPermissions: Bool = true) async throws -> Message {
        var channel = try channel(channelID)
        guard channel.type.holdsMessages else { throw WorldError(status: 400, code: 50008, message: "Cannot send messages in a non-text channel") }
        // Documented, not captured: only thread managers can post in (and so reopen) an archived locked thread.
        if checkPermissions, let metadata = channel.thread, metadata.archived, metadata.locked,
           !permissions(of: authorID, in: channel).contains(.manageThreads) {
            throw WorldError(status: 400, code: 50083, message: "Operation cannot be performed on an archived thread")
        }
        let autoModAlert = checkPermissions ? try await checkSend(draft, by: authorID, in: channel) : nil
        let trimmed = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, draft.attachments.isEmpty, draft.embeds.isEmpty, draft.poll == nil, draft.stickerIDs.isEmpty,
           draft.forwardSnapshot == nil {
            throw WorldError(status: 400, code: 50006, message: "Cannot send an empty message")
        }
        var message = Message(id: draft.id ?? nextID(), channelID: channelID, authorID: authorID, content: draft.content)
        message.type = draft.reference?.type == 0 && draft.reference?.messageID != nil && draft.type == 0 ? 19 : draft.type
        message.flags = draft.flags
        message.tts = draft.tts
        message.nonce = draft.nonce
        message.embeds = draft.embeds
        message.components = draft.components
        message.attachments = draft.attachments
        message.reference = draft.reference
        message.poll = draft.poll
        message.stickerIDs = draft.stickerIDs
        if let snapshot = draft.forwardSnapshot { message.messageSnapshots = [snapshot] }
        // Interaction responses come through the application's webhook.
        message.applicationID = draft.applicationID
        message.webhookID = draft.applicationID
        message.interaction = draft.interaction
        resolveMentions(draft.content, parse: draft.allowedMentionsParse, pingsRepliedUser: draft.mentionsRepliedUser,
                        reference: draft.reference, author: authorID, in: channel, checkPermissions: checkPermissions).apply(to: &message)
        // Ephemeral interaction replies reach only the user who interacted and never join the history.
        if message.flags & 64 != 0, let viewer = draft.interaction?.userID {
            await emit("MESSAGE_CREATE", renderMessageEvent(message), to: .users([viewer]))
            return message
        }
        if channel.type.isThread, !channel.threadMembers.contains(authorID) { channel.threadMembers.append(authorID) }
        // Posting reopens an archived thread; captured, THREAD_UPDATE and the author's membership come before the message.
        if channel.thread?.archived == true {
            channel.thread?.archived = false
            channel.thread?.archiveTimestamp = clock.now
            channels[channelID] = channel
            await emit("THREAD_UPDATE", renderThread(channel, viewer: nil), to: audience(for: channels[channel.parentID ?? channelID] ?? channel))
            await emitThreadMemberUpdate(channel, userID: authorID)
        }
        channel.messages.append(message)
        channel.totalMessageSent += 1
        channels[channelID] = channel
        // The author has read their own message.
        readStates[authorID, default: [:]][channelID] = ReadState(lastAckedID: message.id, mentionCount: 0)
        for mentioned in mentionedUsers(message, in: channel) where mentioned != authorID {
            readStates[mentioned, default: [:]][channelID, default: ReadState()].mentionCount += 1
        }
        if channel.type.isPrivate {
            for recipient in channel.recipients where openPrivateChannels[recipient]?.contains(channelID) != true {
                openPrivateChannels[recipient, default: []].append(channelID)
                await emit("CHANNEL_CREATE", renderChannel(channel, viewer: recipient), to: .users([recipient]))
            }
        }
        await emit("MESSAGE_CREATE", renderMessageEvent(message), to: audience(for: channel))
        if let autoModAlert { try await postAutoModAlert(autoModAlert.rule, keyword: autoModAlert.keyword, for: message) }
        return message
    }

    /// Send permissions, then AutoMod; returns an alert-only AutoMod match to report once the message is posted.
    private func checkSend(_ draft: MessageDraft, by authorID: Snowflake, in channel: Channel) async throws -> (rule: AutoModRule, keyword: String)? {
        try require(channel.type.isThread ? .sendMessagesInThreads : .sendMessages, authorID, channel)
        if !draft.attachments.isEmpty { try require(.attachFiles, authorID, channel) }
        return try await enforceAutoMod(draft.content, by: authorID, in: channel)
    }

    internal struct Mentions {
        var users: [Snowflake] = []
        var roles: [Snowflake] = []
        var everyone = false

        func apply(to message: inout Message) {
            message.mentions = users
            message.mentionRoles = roles
            message.mentionEveryone = everyone
        }
    }

    /// Who a message pings, on send and edit: mentions in the content, narrowed by `allowed_mentions.parse`,
    /// @everyone only with Mention Everyone, and the replied-to author when the reply pings them.
    internal func resolveMentions(_ content: String, parse: Set<String>?, pingsRepliedUser: Bool, reference: MessageReference?,
                                  author: Snowflake, in channel: Channel, checkPermissions: Bool) -> Mentions {
        var mentions = parseMentions(content, in: channel)
        if let parse {
            if !parse.contains("users") { mentions.users = [] }
            if !parse.contains("roles") { mentions.roles = [] }
            if !parse.contains("everyone") { mentions.everyone = false }
        }
        if checkPermissions, mentions.everyone, !permissions(of: author, in: channel).contains(.mentionEveryone) { mentions.everyone = false }
        if pingsRepliedUser, let reference, reference.type == 0, let repliedID = reference.messageID,
           let replied = channels[reference.channelID]?.messages.first(where: { $0.id == repliedID }),
           !mentions.users.contains(replied.authorID), replied.authorID != author {
            mentions.users.append(replied.authorID)
        }
        return mentions
    }

    /// `allowed_mentions` as sent: an object without `parse` allows no parsed mentions; nil fields mean it wasn't sent.
    internal nonisolated static func allowedMentions(_ value: JSON?) -> (parse: Set<String>?, repliedUser: Bool?) {
        guard let allowed = value?.objectValue else { return (nil, nil) }
        return (Set((allowed["parse"]?.arrayValue ?? []).compactMap(\.stringValue)), allowed["replied_user"]?.boolValue)
    }

    /// Everyone a message pings: direct mentions, members of mentioned roles,
    /// and for @everyone/@here everyone who can see the channel.
    /// The read-state mentions `message` gives. Every DM and group DM message counts for
    /// each other recipient, which is what the count badge on an unread DM shows.
    internal func mentionedUsers(_ message: Message, in channel: Channel) -> Set<Snowflake> {
        var users = Set(message.mentions)
        if channel.type.isPrivate { return Set(channel.recipients).subtracting([message.authorID]) }
        if message.mentionEveryone {
            users.formUnion(recipients(of: audience(for: channel)))
        } else if !message.mentionRoles.isEmpty, let guildID = channel.guildID, let guild = guilds[guildID] {
            for (id, member) in guild.members where !Set(member.roles).isDisjoint(with: message.mentionRoles) && canView(id, channel) {
                users.insert(id)
            }
        }
        users.remove(message.authorID)
        return users
    }

    func mentionCount(of userID: Snowflake, in channel: Channel, after messageID: Snowflake) -> Int {
        channel.messages.count { $0.id > messageID && mentionedUsers($0, in: channel).contains(userID) }
    }

    internal func parseMentions(_ content: String, in channel: Channel) -> Mentions {
        var users: [Snowflake] = [], roles: [Snowflake] = []
        for match in content.matches(of: /<@(!|&)?(\d{15,21})>/) {
            let isRole = match.output.1 == "&"
            guard let id = Snowflake(String(match.output.2)) else { continue }
            if isRole {
                if !roles.contains(id) { roles.append(id) }
            } else if self.users[id] != nil, !users.contains(id) {
                users.append(id)
            }
        }
        let everyone = content.contains("@everyone") || content.contains("@here")
        return Mentions(users: users, roles: roles, everyone: everyone)
    }

    func message(_ messageID: Snowflake, in channelID: Snowflake) throws -> Message {
        guard let message = try channel(channelID).messages.first(where: { $0.id == messageID }) else {
            throw WorldError.unknown("Message", code: 10008)
        }
        return message
    }

    internal func updateMessage(_ messageID: Snowflake, in channelID: Snowflake, _ change: (inout Message) -> Void) throws -> Message {
        guard let index = try channel(channelID).messages.firstIndex(where: { $0.id == messageID }) else {
            throw WorldError.unknown("Message", code: 10008)
        }
        change(&channels[channelID]!.messages[index])
        return channels[channelID]!.messages[index]
    }

    @discardableResult
    func editMessage(_ messageID: Snowflake, in channelID: Snowflake, by userID: Snowflake,
                     content: String?, embeds: [JSON]?, flags: Int?, allowedMentions: JSON? = nil) async throws -> Message {
        let existing = try message(messageID, in: channelID)
        guard existing.authorID == userID else { throw WorldError(status: 403, code: 50005, message: "Cannot edit a message authored by another user") }
        let channel = try channel(channelID)
        // Edits resolve mentions like a send. Not captured: without `replied_user`, a reply keeps pinging only if it did before.
        let allowed = Self.allowedMentions(allowedMentions)
        let repliedAuthor = existing.reference.flatMap { ref in ref.messageID.flatMap { id in channels[ref.channelID]?.messages.first { $0.id == id }?.authorID } }
        let mentions = content.map { content in
            resolveMentions(content, parse: allowed.parse, pingsRepliedUser: allowed.repliedUser ?? repliedAuthor.map(existing.mentions.contains) ?? false,
                            reference: existing.reference, author: userID, in: channel, checkPermissions: true)
        }
        let updated = try updateMessage(messageID, in: channelID) { message in
            if let content { message.content = content }
            if let embeds { message.embeds = embeds }
            if let flags { message.flags = flags }
            mentions?.apply(to: &message)
            message.editedAt = clock.now
        }
        await emit("MESSAGE_UPDATE", renderMessageEvent(updated), to: audience(for: channel))
        return updated
    }

    /// Replaces a message's embeds the way Discord's unfurler does after a link is posted.
    func attachUnfurledEmbeds(_ messageID: Snowflake, in channelID: Snowflake, embeds: [JSON]) async throws {
        let updated = try updateMessage(messageID, in: channelID) { $0.embeds = embeds }
        await emit("MESSAGE_UPDATE", renderMessageEvent(updated), to: audience(for: try channel(channelID)))
    }

    func deleteMessage(_ messageID: Snowflake, in channelID: Snowflake, by userID: Snowflake) async throws {
        let channel = try channel(channelID)
        let existing = try message(messageID, in: channelID)
        if existing.authorID != userID { try require(.manageMessages, userID, channel) }
        channels[channelID]?.messages.removeAll { $0.id == messageID }
        var payload = JSONObject([("id", messageID.json), ("channel_id", channelID.json)])
        if let guildID = channel.guildID { payload["guild_id"] = guildID.json }
        await emit("MESSAGE_DELETE", .object(payload), to: audience(for: channel))
    }

    // MARK: Reactions

    func react(_ messageID: Snowflake, in channelID: Snowflake, by userID: Snowflake,
               emojiName: String, emojiID: Snowflake?, burst: Bool) async throws {
        let channel = try channel(channelID)
        try require(.addReactions, userID, channel)
        let existing = try message(messageID, in: channelID)
        var added = false
        _ = try updateMessage(messageID, in: channelID) { message in
            let key = emojiID.map { "\(emojiName):\($0)" } ?? emojiName
            var index = message.reactions.firstIndex { $0.key == key }
            if index == nil {
                message.reactions.append(Reaction(emojiName: emojiName, emojiID: emojiID))
                index = message.reactions.count - 1
            }
            if burst {
                if !message.reactions[index!].burstUsers.contains(userID) { message.reactions[index!].burstUsers.append(userID); added = true }
            } else if !message.reactions[index!].users.contains(userID) {
                message.reactions[index!].users.append(userID); added = true
            }
        }
        guard added else { return }
        var payload = reactionPayload(existing, channel: channel, userID: userID, emojiName: emojiName, emojiID: emojiID, burst: burst)
        payload["message_author_id"] = existing.authorID.json
        if let guildID = channel.guildID, let member = guilds[guildID]?.members[userID] {
            payload["member"] = renderMember(member, guildID: guildID, includeUser: true)
        }
        await emit("MESSAGE_REACTION_ADD", .object(payload), to: audience(for: channel))
    }

    func unreact(_ messageID: Snowflake, in channelID: Snowflake, by userID: Snowflake,
                 emojiName: String, emojiID: Snowflake?, burst: Bool) async throws {
        let channel = try channel(channelID)
        let existing = try message(messageID, in: channelID)
        var removed = false
        _ = try updateMessage(messageID, in: channelID) { message in
            let key = emojiID.map { "\(emojiName):\($0)" } ?? emojiName
            guard let index = message.reactions.firstIndex(where: { $0.key == key }) else { return }
            let before = message.reactions[index].users.count + message.reactions[index].burstUsers.count
            if burst { message.reactions[index].burstUsers.removeAll { $0 == userID } } else { message.reactions[index].users.removeAll { $0 == userID } }
            removed = before != message.reactions[index].users.count + message.reactions[index].burstUsers.count
            if message.reactions[index].users.isEmpty, message.reactions[index].burstUsers.isEmpty { message.reactions.remove(at: index) }
        }
        guard removed else { return }
        let payload = reactionPayload(existing, channel: channel, userID: userID, emojiName: emojiName, emojiID: emojiID, burst: burst)
        await emit("MESSAGE_REACTION_REMOVE", .object(payload), to: audience(for: channel))
    }

    private func reactionPayload(_ message: Message, channel: Channel, userID: Snowflake, emojiName: String,
                                 emojiID: Snowflake?, burst: Bool) -> JSONObject {
        var payload = JSONObject([
            ("user_id", userID.json), ("type", .int(burst ? 1 : 0)), ("message_id", message.id.json),
            ("emoji", renderReactionEmoji(Reaction(emojiName: emojiName, emojiID: emojiID))),
            ("channel_id", channel.id.json), ("burst", .bool(burst)),
        ])
        if let guildID = channel.guildID { payload["guild_id"] = guildID.json }
        return payload
    }

    // MARK: Pins, typing, read state

    func setPinned(_ messageID: Snowflake, in channelID: Snowflake, by userID: Snowflake, pinned: Bool) async throws {
        var channel = try channel(channelID)
        if !channel.type.isPrivate { try require(.manageMessages, userID, channel) }
        let now = clock.now
        let updated = try updateMessage(messageID, in: channelID) { message in
            message.pinned = pinned
            message.pinnedAt = pinned ? now : nil
        }
        channel = channels[channelID]!
        channel.lastPinTimestamp = channel.messages.contains(where: \.pinned) ? clock.now : nil
        channels[channelID] = channel
        var pins = JSONObject([("last_pin_timestamp", World.optionalTimestamp(channel.lastPinTimestamp)), ("channel_id", channelID.json)])
        if let guildID = channel.guildID { pins["guild_id"] = guildID.json }
        await emit("CHANNEL_PINS_UPDATE", .object(pins), to: audience(for: channel))
        await emit("MESSAGE_UPDATE", renderMessageEvent(updated), to: audience(for: channel))
        if pinned {
            await emit("CHANNEL_PINS_ACK", .object(JSONObject([
                ("channel_id", channelID.json), ("timestamp", World.timestamp(clock.now)),
                ("version", .int(Int64(clock.now.timeIntervalSince1970))),
            ])), to: .users([userID]))
            var notice = MessageDraft(content: "")
            notice.type = 6
            // Discord's pin notice references the message without a guild ID.
            notice.reference = MessageReference(type: 0, messageID: messageID, channelID: channelID, guildID: nil)
            _ = try await sendSystemMessage(notice, as: userID, in: channelID)
        }
    }

    internal func sendSystemMessage(_ draft: MessageDraft, as authorID: Snowflake, in channelID: Snowflake) async throws -> Message {
        var message = Message(id: nextID(), channelID: channelID, authorID: authorID, content: draft.content)
        message.type = draft.type
        message.reference = draft.reference
        message.call = draft.call
        channels[channelID]?.messages.append(message)
        await emit("MESSAGE_CREATE", renderMessageEvent(message), to: audience(for: try channel(channelID)))
        return message
    }

    func startTyping(_ userID: Snowflake, in channelID: Snowflake) async throws {
        let channel = try channel(channelID)
        try require(.sendMessages, userID, channel)
        var payload = JSONObject([("user_id", userID.json), ("timestamp", .int(Int64(clock.now.timeIntervalSince1970))),
                                  ("channel_id", channelID.json)])
        if let guildID = channel.guildID {
            payload["guild_id"] = guildID.json
            if let member = guilds[guildID]?.members[userID] { payload["member"] = renderMember(member, guildID: guildID, includeUser: true) }
        }
        await emit("TYPING_START", .object(payload), to: audience(for: channel))
    }

    func acknowledge(_ messageID: Snowflake, in channelID: Snowflake, by userID: Snowflake, manual: Bool = false) async throws {
        let channel = try channel(channelID)
        var state = readStates[userID]?[channelID] ?? ReadState()
        state.lastAckedID = messageID
        // Mentions after the acknowledged message stay unread.
        state.mentionCount = mentionCount(of: userID, in: channel, after: messageID)
        state.lastViewed = Int(clock.now.timeIntervalSince(Date(timeIntervalSince1970: Double(Snowflake.discordEpochMilliseconds) / 1000)) / 86_400)
        readStates[userID, default: [:]][channelID] = state
        await emit("MESSAGE_ACK", .object(JSONObject([
            ("version", .int(Int64(clock.now.timeIntervalSince1970))), ("message_id", messageID.json),
            ("last_viewed", .optional(state.lastViewed)), ("flags", 0), ("channel_id", channelID.json),
        ])), to: .users([userID]))
    }

    // MARK: Threads

    @discardableResult
    func createThread(in parentID: Snowflake, from messageID: Snowflake?, name: String, by userID: Snowflake,
                      type: ChannelType = .publicThread, appliedTags: [Snowflake] = [],
                      starter: MessageDraft? = nil) async throws -> Channel {
        let parent = try channel(parentID)
        // Forum and media posts need Send Messages; threads need Create Public Threads.
        try require(parent.type == .forum || parent.type == .media ? .sendMessages : .createPublicThreads, userID, parent)
        if let messageID, try message(messageID, in: parentID).threadID != nil {
            throw WorldError(status: 400, code: 160004, message: "A thread has already been created for this message")
        }
        let id = messageID ?? nextID()
        let now = clock.now
        var thread = Channel(id: id, type: type, guildID: parent.guildID, name: name)
        thread.parentID = parentID
        thread.ownerID = userID
        thread.rateLimitPerUser = 0
        thread.thread = ThreadMetadata(archiveTimestamp: now, createTimestamp: now)
        thread.threadMembers = [userID]
        thread.appliedTags = appliedTags
        addChannel(thread)
        if let messageID {
            let updated = try updateMessage(messageID, in: parentID) { $0.threadID = id }
            await emit("MESSAGE_UPDATE", renderMessageEvent(updated), to: audience(for: parent))
        }
        guard case var .object(created) = renderThread(thread, viewer: nil) else { return thread }
        created["newly_created"] = true
        await emit("THREAD_CREATE", .object(created), to: audience(for: parent))
        await emitThreadMemberUpdate(thread, userID: userID)
        if var starter {
            starter.id = id
            try await sendMessage(starter, as: userID, in: id)
        } else if let messageID {
            // A thread started from a message opens with a starter message pointing back at it.
            var notice = MessageDraft()
            notice.type = 21
            notice.reference = MessageReference(type: 0, messageID: messageID, channelID: parentID, guildID: parent.guildID)
            _ = try await sendSystemMessage(notice, as: userID, in: id)
        } else {
            var notice = MessageDraft(content: name)
            notice.type = 18
            notice.reference = MessageReference(type: 0, messageID: nil, channelID: id, guildID: parent.guildID)
            _ = try await sendSystemMessage(notice, as: userID, in: parentID)
        }
        return channels[id]!
    }

    // MARK: Polls

    func vote(_ messageID: Snowflake, in channelID: Snowflake, by userID: Snowflake, answers: [Int]) async throws {
        let channel = try channel(channelID)
        guard let poll = try message(messageID, in: channelID).poll else { throw WorldError.invalidBody("message has no poll") }
        if poll.finalized || poll.expiry <= clock.now {
            throw WorldError(status: 400, code: 520_001, message: "This poll has already ended")
        }
        let validIDs = Set(poll.answers.map(\.id))
        guard answers.allSatisfy(validIDs.contains), poll.allowMultiselect || answers.count <= 1 else {
            throw WorldError.invalidBody("answer_ids")
        }
        var added: [Int] = [], removed: [Int] = []
        _ = try updateMessage(messageID, in: channelID) { message in
            guard var poll = message.poll else { return }
            for index in poll.answers.indices {
                let wants = answers.contains(poll.answers[index].id)
                let has = poll.answers[index].voters.contains(userID)
                if wants, !has { poll.answers[index].voters.append(userID); added.append(poll.answers[index].id) }
                if !wants, has { poll.answers[index].voters.removeAll { $0 == userID }; removed.append(poll.answers[index].id) }
            }
            message.poll = poll
        }
        for (name, ids) in [("MESSAGE_POLL_VOTE_REMOVE", removed), ("MESSAGE_POLL_VOTE_ADD", added)] {
            for answer in ids {
                var payload = JSONObject([("user_id", userID.json), ("message_id", messageID.json),
                                          ("channel_id", channelID.json), ("answer_id", .int(answer))])
                if let guildID = channel.guildID { payload["guild_id"] = guildID.json }
                await emit(name, .object(payload), to: audience(for: channel))
            }
        }
    }

    // MARK: Users, Nitro, boosts, presence

    func updateUser(_ userID: Snowflake, _ change: (inout User) -> Void) async throws {
        var user = try user(userID)
        change(&user)
        users[userID] = user
        await emit("USER_UPDATE", renderSelf(userID), to: .users([userID]))
        // Everyone sharing a server sees the public profile change through member updates.
        for guild in guilds(of: userID) {
            guard let member = guild.members[userID], case var .object(payload) = renderMember(member, guildID: guild.id, includeUser: true) else { continue }
            payload["guild_id"] = guild.id.json
            await emit("GUILD_MEMBER_UPDATE", .object(payload), to: .guild(guild.id, channel: nil))
        }
    }

    /// Sets a guild's active boosts. Each boost belongs to a member; boosting
    /// members get `premium_since`, and a new boost posts a system message.
    func setBoosts(_ guildID: Snowflake, boosters: [Snowflake]) async throws {
        var guild = try guild(guildID)
        let now = clock.now
        let previous = Set(guild.boosts.map(\.userID))
        guild.boosts = boosters.map { booster in (booster, guild.boosts.first { $0.userID == booster }?.since ?? now) }
        for (id, var member) in guild.members {
            let boosting = boosters.contains(id)
            if boosting, member.premiumSince == nil { member.premiumSince = now }
            if !boosting { member.premiumSince = nil }
            guild.members[id] = member
        }
        guilds[guildID] = guild
        await emit("GUILD_UPDATE", renderGuildUpdate(guild), to: .guild(guildID, channel: nil))
        for booster in boosters.filter({ !previous.contains($0) }) {
            if let member = guild.members[booster], case var .object(payload) = renderMember(member, guildID: guildID, includeUser: true) {
                payload["guild_id"] = guildID.json
                await emit("GUILD_MEMBER_UPDATE", .object(payload), to: .guild(guildID, channel: nil))
            }
            if let systemChannel = guild.systemChannelID {
                var notice = MessageDraft()
                notice.type = 8
                _ = try await sendSystemMessage(notice, as: booster, in: systemChannel)
            }
        }
    }

    func updatePresence(_ userID: Snowflake, _ presence: Presence) async {
        presences[userID] = presence
        for guild in guilds(of: userID) {
            await emit("PRESENCE_UPDATE", renderPresence(userID, guildID: guild.id), to: .guild(guild.id, channel: nil))
        }
        let friends = Set((relationships[userID] ?? [:]).values.filter { $0.type == .friend }.map(\.userID))
        if !friends.isEmpty { await emit("PRESENCE_UPDATE", renderPresence(userID, guildID: nil), to: .users(friends)) }
    }

    func renderPresence(_ userID: Snowflake, guildID: Snowflake?) -> JSON {
        let presence = presences[userID] ?? Presence()
        let status = presence.status == .invisible ? PresenceStatus.offline : presence.status
        var object = JSONObject()
        object["user"] = .object(JSONObject([("id", userID.json)]))
        object["status"] = .string(status.rawValue)
        object["client_status"] = .object(JSONObject(presence.clientStatus.isEmpty && status != .offline
            ? [("desktop", .string(status.rawValue))]
            : presence.clientStatus.map { ($0.key, .string($0.value.rawValue)) }))
        object["activities"] = .array(presence.activities.map(presenceActivity))
        object["processed_at_timestamp"] = .int(Int64(clock.now.timeIntervalSince1970 * 1000))
        if let guildID { object["guild_id"] = guildID.json }
        object["broadcast"] = .null
        return .object(object)
    }

    func renderGuildUpdate(_ guild: Guild) -> JSON {
        guard case var .object(object) = renderGuildProperties(guild) else { return .null }
        object["guild_id"] = guild.id.json
        object["premium_subscription_count"] = .int(guild.premiumSubscriptionCount)
        object["roles"] = .array(guild.roles.map(renderRole))
        object["emojis"] = .array(guild.emojis.map(renderEmoji))
        object["stickers"] = .array(guild.stickers.map { renderSticker($0, guildID: guild.id) })
        object["version"] = .int(Int64(clock.now.timeIntervalSince1970 * 1000))
        return .object(object)
    }

    func renderGuildProperties(_ guild: Guild) -> JSON {
        .object(JSONObject([
            ("id", guild.id.json), ("name", .string(guild.name)), ("icon", .optional(guild.icon)),
            ("description", .optional(guild.description)), ("home_header", .null), ("splash", .optional(guild.splash)),
            ("discovery_splash", .null), ("features", .array(guild.features.map(JSON.string))),
            ("banner", .optional(guild.banner)), ("owner_id", guild.ownerID.json), ("application_id", .null),
            ("region", "deprecated"), ("afk_channel_id", guild.afkChannelID?.json ?? .null), ("afk_timeout", 300),
            ("system_channel_id", guild.systemChannelID?.json ?? .null), ("system_channel_flags", 0),
            ("widget_enabled", false), ("widget_channel_id", .null), ("verification_level", .int(guild.verificationLevel)),
            ("default_message_notifications", 1), ("mfa_level", 0), ("explicit_content_filter", 2),
            ("max_presences", .null), ("max_members", 500_000), ("max_stage_video_channel_users", 50),
            ("max_video_channel_users", 25), ("vanity_url_code", .null), ("premium_tier", .int(guild.premiumTier)),
            ("premium_subscription_count", .int(guild.premiumSubscriptionCount)), ("preferred_locale", .string(guild.preferredLocale)),
            ("rules_channel_id", guild.rulesChannelID?.json ?? .null), ("safety_alerts_channel_id", .null),
            ("public_updates_channel_id", .null), ("hub_type", .null), ("premium_progress_bar_enabled", true),
            ("premium_progress_bar_enabled_user_updated_at", .null), ("latest_onboarding_question_id", .null),
            ("nsfw", false), ("nsfw_level", 0), ("owner_configured_content_level", 0), ("incidents_data", .null),
            ("verification_role_id", .null), ("linked_game_organization", .null), ("inventory_settings", .null),
            ("official_message_color", .null), ("moderator_reporting", .null), ("theme", .null),
            ("premium_features", .null), ("profile", .null), ("game_application_ids", .null),
            ("guild_space_settings", .object(JSONObject([("enabled", false), ("publish_status", 0)]))),
        ]))
    }
}

extension World {
    /// Presence activities carry server-side fields the client never sends.
    func presenceActivity(_ activity: JSON) -> JSON {
        guard case var .object(object) = activity else { return activity }
        if object["created_at"] == nil { object["created_at"] = .int(Int64(clock.now.timeIntervalSince1970 * 1000)) }
        if object["id"] == nil { object["id"] = .string(object["type"]?.intValue == 4 ? "custom" : "activity") }
        if object["official_game_id"] == nil { object["official_game_id"] = .null }
        if object["content_classification"] == nil {
            object["content_classification"] = .object(JSONObject([("data", .null), ("loaded", true)]))
        }
        return .object(object)
    }
}
