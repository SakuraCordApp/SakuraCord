import Foundation

/// Wire renderers. Each returns the fullest form of an object; routes and
/// events then conform it to the captured shape for that context.
public extension World {
    /// `2026-11-16T00:23:09.064000+00:00`, Discord's six-digit form.
    nonisolated static func timestamp(_ date: Date) -> JSON {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        var seconds = time_t(milliseconds / 1000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return .string(String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03lld000+00:00",
                              parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
                              parts.tm_hour, parts.tm_min, parts.tm_sec, milliseconds % 1000))
    }

    internal static func optionalTimestamp(_ date: Date?) -> JSON { date.map(timestamp) ?? .null }

    // MARK: Users

    func renderUser(_ id: Snowflake) -> JSON {
        guard let user = users[id] else { return .null }
        var object = JSONObject()
        object["id"] = id.json
        object["username"] = .string(user.username)
        object["avatar"] = .optional(user.avatar)
        object["discriminator"] = "0"
        object["public_flags"] = .int(user.publicFlags)
        object["flags"] = .int(user.publicFlags)
        object["bot"] = .bool(user.bot)
        if user.system { object["system"] = true }
        object["banner"] = .optional(user.banner)
        object["accent_color"] = .optional(user.accentColor)
        object["global_name"] = .optional(user.globalName)
        object["display_name"] = .optional(user.globalName)
        object["avatar_decoration_data"] = user.avatarDecoration ?? .null
        object["collectibles"] = user.collectibles ?? .null
        object["display_name_styles"] = .null
        object["banner_color"] = .optional(user.bannerColor)
        // `clan` is the older name of the same server tag.
        object["clan"] = user.primaryGuild ?? .null
        object["primary_guild"] = user.primaryGuild ?? .null
        return .object(object)
    }

    /// The signed-in user's own object, with private fields.
    func renderSelf(_ id: Snowflake) -> JSON {
        guard let user = users[id], case var .object(object) = renderUser(id) else { return .null }
        object["email"] = .optional(user.email)
        object["verified"] = true
        object["mfa_enabled"] = false
        object["phone"] = .null
        object["premium"] = .bool(user.premiumType != .none)
        object["premium_type"] = .int(user.premiumType.rawValue)
        object["nsfw_allowed"] = true
        object["bio"] = .string(user.bio)
        object["pronouns"] = .string(user.pronouns)
        object["locale"] = "en-US"
        object["desktop"] = true
        object["mobile"] = false
        object["purchased_flags"] = .int(user.premiumType == .none ? 0 : 2)
        object["premium_usage_flags"] = 0
        object["age_verification_status"] = 1
        object["typing_indicator_style"] = 0
        object["perks"] = .object(JSONObject([("active_perks_bitmask", []), ("config_by_perk", .object(JSONObject())),
                                              ("rules_version", 1), ("updated_at", World.timestamp(user.createdAt))]))
        object["premium_state"] = .object(JSONObject([("premium_source", 0), ("premium_subscription_group_role", 0),
                                                      ("premium_subscription_type", 0)]))
        object["authenticator_types"] = []
        object["linked_users"] = []
        object["app_transaction_ids"] = []
        object["store_country"] = .object(JSONObject([("country", "NL"), ("is_locked", false), ("set_at", .null)]))
        object["bot"] = .bool(user.bot)
        return .object(object)
    }

    // MARK: Guild pieces

    func renderRole(_ role: Role) -> JSON {
        .object(JSONObject([
            ("id", role.id.json), ("name", .string(role.name)), ("description", .null),
            ("permissions", .string(role.permissions.wireString)), ("position", .int(role.position)),
            ("color", .int(role.color)),
            ("colors", .object(JSONObject([("primary_color", .int(role.color)), ("secondary_color", .null), ("tertiary_color", .null)]))),
            ("hoist", .bool(role.hoist)), ("managed", .bool(role.managed)), ("mentionable", .bool(role.mentionable)),
            ("icon", .optional(role.icon)), ("unicode_emoji", .optional(role.unicodeEmoji)), ("flags", .int(role.flags)),
            ("tags", .object(JSONObject())),
        ]))
    }

    func renderMember(_ member: Member, guildID: Snowflake, includeUser: Bool) -> JSON {
        var object = JSONObject()
        if includeUser { object["user"] = renderUser(member.userID) }
        object["avatar"] = .optional(member.avatar)
        object["banner"] = .optional(member.banner)
        object["communication_disabled_until"] = World.optionalTimestamp(member.communicationDisabledUntil)
        object["deaf"] = .bool(member.deaf)
        object["flags"] = .int(member.flags)
        object["joined_at"] = World.timestamp(member.joinedAt)
        object["mute"] = .bool(member.mute)
        object["nick"] = .optional(member.nick)
        object["pending"] = .bool(member.pending)
        object["premium_since"] = World.optionalTimestamp(member.premiumSince)
        object["roles"] = .array(member.roles.map(\.json))
        object["user_id"] = member.userID.json
        object["unusual_dm_activity_until"] = .null
        object["member_gaming_leaderboard_data"] = .null
        // Per-server decorations are omitted, not null, when a member has none.
        return .object(object)
    }

    func renderEmoji(_ emoji: Emoji) -> JSON {
        .object(JSONObject([
            ("id", emoji.id.json), ("name", .string(emoji.name)), ("roles", .array(emoji.roles.map(\.json))),
            ("require_colons", true), ("managed", false), ("animated", .bool(emoji.animated)),
            ("available", .bool(emoji.available)),
        ]))
    }

    func renderSticker(_ sticker: Sticker, guildID: Snowflake?) -> JSON {
        var object = JSONObject([
            ("id", sticker.id.json), ("name", .string(sticker.name)), ("tags", .string(sticker.tags)),
            ("type", .int(guildID == nil ? 1 : 2)), ("format_type", .int(sticker.formatType)),
            ("description", .optional(sticker.description)), ("asset", ""), ("available", true),
        ])
        if let guildID { object["guild_id"] = guildID.json }
        return .object(object)
    }

    // MARK: Channels

    func renderOverwrite(_ overwrite: PermissionOverwrite) -> JSON {
        .object(JSONObject([
            ("id", overwrite.id.json), ("type", .int(overwrite.kind.rawValue)),
            ("allow", .string(overwrite.allow.wireString)), ("deny", .string(overwrite.deny.wireString)),
        ]))
    }

    func renderChannel(_ channel: Channel, viewer: Snowflake? = nil) -> JSON {
        var object = JSONObject()
        object["id"] = channel.id.json
        object["type"] = .int(channel.type.rawValue)
        object["flags"] = .int(channel.flags)
        if let guildID = channel.guildID { object["guild_id"] = guildID.json }
        if channel.type.isPrivate {
            object["last_message_id"] = channel.lastMessageID?.json ?? .null
            object["recipients"] = .array(channel.recipients.filter { $0 != viewer }.map(renderUser))
            object["recipient_ids"] = .array(channel.recipients.filter { $0 != viewer }.map(\.json))
            if channel.type == .groupDM {
                object["name"] = .optional(channel.name)
                object["icon"] = .optional(channel.icon)
                object["owner_id"] = channel.ownerID?.json ?? .null
            }
            if let pinned = channel.lastPinTimestamp { object["last_pin_timestamp"] = World.timestamp(pinned) }
            return .object(object)
        }
        object["name"] = .optional(channel.name)
        object["position"] = .int(channel.position)
        object["parent_id"] = channel.parentID?.json ?? .null
        object["permission_overwrites"] = .array(channel.overwrites.map(renderOverwrite))
        switch channel.type {
        case .voice, .stage:
            object["bitrate"] = .int(channel.bitrate)
            object["user_limit"] = .int(channel.userLimit)
            object["rtc_region"] = .null
            object["last_message_id"] = channel.lastMessageID?.json ?? .null
            object["rate_limit_per_user"] = .int(channel.rateLimitPerUser)
            object["nsfw"] = .bool(channel.nsfw)
            object["video_quality_mode"] = 1
        case .forum, .media:
            object["topic"] = .optional(channel.topic)
            object["nsfw"] = .bool(channel.nsfw)
            object["rate_limit_per_user"] = .int(channel.rateLimitPerUser)
            object["last_message_id"] = threads(in: channel.id).last?.id.json ?? .null
            object["available_tags"] = .array(channel.availableTags.map { tag in
                .object(JSONObject([("id", tag.id.json), ("name", .string(tag.name)), ("moderated", .bool(tag.moderated)),
                                    ("emoji_id", .null), ("emoji_name", .optional(tag.emojiName)), ("color", .null)]))
            })
            object["default_reaction_emoji"] = .null
            object["default_sort_order"] = .optional(channel.defaultSortOrder)
            object["default_forum_layout"] = .int(channel.defaultForumLayout)
            object["default_thread_rate_limit_per_user"] = 0
            object["default_auto_archive_duration"] = 4320
            object["template"] = ""
        case .category:
            break
        default:
            object["topic"] = .optional(channel.topic)
            object["nsfw"] = .bool(channel.nsfw)
            object["rate_limit_per_user"] = .int(channel.rateLimitPerUser)
            object["last_message_id"] = channel.lastMessageID?.json ?? .null
            if let pinned = channel.lastPinTimestamp { object["last_pin_timestamp"] = World.timestamp(pinned) }
            object["default_thread_rate_limit_per_user"] = 0
            object["default_auto_archive_duration"] = 4320
            object["icon_emoji"] = .null
            object["theme_color"] = .null
        }
        return .object(object)
    }

    /// Looks only through the parent's server: every forum in READY asks, and a big account has thousands of channels.
    internal func threads(in parentID: Snowflake) -> [Channel] {
        let ids = channels[parentID]?.guildID.flatMap { guilds[$0]?.channelIDs } ?? []
        return ids.compactMap { id in channels[id].flatMap { $0.parentID == parentID && $0.type.isThread ? $0 : nil } }.sorted { $0.id < $1.id }
    }

    func renderThread(_ thread: Channel, viewer: Snowflake?) -> JSON {
        guard case var .object(object) = renderChannel(thread, viewer: viewer), let metadata = thread.thread else { return .null }
        object["owner_id"] = thread.ownerID?.json ?? .null
        object["last_message_id"] = thread.lastMessageID?.json ?? .null
        object["message_count"] = .int(thread.messages.count)
        object["member_count"] = .int(thread.threadMembers.count)
        object["total_message_sent"] = .int(thread.totalMessageSent)
        object["member_ids_preview"] = .array(thread.threadMembers.prefix(8).map(\.json))
        object["applied_tags"] = .array(thread.appliedTags.map(\.json))
        object["thread_metadata"] = .object(JSONObject([
            ("archived", .bool(metadata.archived)), ("archive_timestamp", World.timestamp(metadata.archiveTimestamp)),
            ("auto_archive_duration", .int(metadata.autoArchiveDuration)), ("locked", .bool(metadata.locked)),
            ("create_timestamp", World.timestamp(metadata.createTimestamp)), ("invitable", .bool(metadata.invitable)),
        ]))
        if let guildID = thread.guildID, let owner = thread.ownerID, let member = guilds[guildID]?.members[owner] {
            object["owner"] = renderMember(member, guildID: guildID, includeUser: true)
        }
        object["bitrate"] = .int(thread.bitrate)
        object["user_limit"] = .int(thread.userLimit)
        object["rtc_region"] = .null
        if let viewer, thread.threadMembers.contains(viewer) {
            object["member"] = renderThreadMember(thread, userID: viewer, includeIDs: true)
        }
        return .object(object)
    }

    func renderThreadMember(_ thread: Channel, userID: Snowflake, includeIDs: Bool) -> JSON {
        var object = JSONObject()
        if includeIDs {
            object["id"] = thread.id.json
            object["user_id"] = userID.json
        }
        object["join_timestamp"] = World.timestamp(thread.thread?.createTimestamp ?? thread.id.date)
        object["flags"] = 1
        object["muted"] = .bool(thread.mutedThreadMembers.contains(userID))
        object["mute_config"] = .null
        return .object(object)
    }

    // MARK: Messages

    func attachmentURL(_ attachment: Attachment, host: String) -> String {
        attachmentURL(path: attachment.cdnPath, id: attachment.id, host: host)
    }

    /// Real attachment links are signed with expiry and hash parameters.
    func attachmentURL(path: String, id: Snowflake, host: String) -> String {
        let issued = UInt64(clock.now.timeIntervalSince1970)
        let expires = issued + 86_400
        let signature = String(format: "%016llx%016llx", id.rawValue &* 0x9e37_79b9_7f4a_7c15, expires)
        return "https://\(host)\(path)?ex=\(String(expires, radix: 16))&is=\(String(issued, radix: 16))&hm=\(signature)&"
    }

    func renderAttachment(_ attachment: Attachment) -> JSON {
        var object = JSONObject()
        object["id"] = attachment.id.json
        object["filename"] = .string(attachment.filename)
        object["size"] = .int(attachment.size)
        object["url"] = .string(attachmentURL(attachment, host: "cdn.discordapp.com"))
        object["proxy_url"] = .string(attachmentURL(attachment, host: "media.discordapp.net"))
        if let duration = attachment.durationSeconds { object["duration_secs"] = .double(duration) }
        if let waveform = attachment.waveform { object["waveform"] = .string(waveform) }
        if let width = attachment.width { object["width"] = .int(width) }
        if let height = attachment.height { object["height"] = .int(height) }
        if let description = attachment.description { object["description"] = .string(description) }
        if let contentType = attachment.contentType {
            object["content_type"] = .string(contentType)
            object["original_content_type"] = .string(contentType)
        }
        if let placeholder = attachment.placeholder {
            object["placeholder"] = .string(placeholder)
            object["placeholder_version"] = 1
        }
        object["content_scan_version"] = 3
        if attachment.flags != 0 || attachment.spoiler { object["flags"] = .int(attachment.flags) }
        return .object(object)
    }

    func renderReactions(_ message: Message, viewer: Snowflake?) -> JSON {
        .array(message.reactions.map { reaction in
            let normal = reaction.users.count, burst = reaction.burstUsers.count
            return .object(JSONObject([
                ("emoji", renderReactionEmoji(reaction)),
                ("count", .int(normal + burst)),
                ("count_details", .object(JSONObject([("burst", .int(burst)), ("normal", .int(normal))]))),
                ("burst_colors", .array(reaction.burstColors.map(JSON.string))),
                ("me_burst", .bool(viewer.map(reaction.burstUsers.contains) ?? false)),
                ("burst_me", .bool(viewer.map(reaction.burstUsers.contains) ?? false)),
                ("me", .bool(viewer.map(reaction.users.contains) ?? false)),
                ("burst_count", .int(burst)),
            ]))
        })
    }

    internal func renderReactionEmoji(_ reaction: Reaction) -> JSON {
        var emoji = JSONObject([("id", reaction.emojiID?.json ?? .null), ("name", .string(reaction.emojiName))])
        if reaction.emojiID != nil, reaction.animated { emoji["animated"] = true }
        return .object(emoji)
    }

    func renderPoll(_ poll: Poll, viewer: Snowflake?) -> JSON {
        .object(JSONObject([
            ("question", .object(JSONObject([("text", .string(poll.question))]))),
            ("answers", .array(poll.answers.map { answer in
                var media = JSONObject([("text", .string(answer.text))])
                if let emoji = answer.emoji { media["emoji"] = .object(JSONObject([("id", .null), ("name", .string(emoji))])) }
                return .object(JSONObject([("answer_id", .int(answer.id)), ("poll_media", .object(media))]))
            })),
            ("expiry", World.timestamp(poll.expiry)),
            ("allow_multiselect", .bool(poll.allowMultiselect)),
            ("layout_type", .int(poll.layoutType)),
            ("results", .object(JSONObject([
                // Answers nobody voted for are left out, as Discord does.
                ("answer_counts", .array(poll.answers.filter { !$0.voters.isEmpty }.map { answer in
                    .object(JSONObject([("id", .int(answer.id)), ("count", .int(answer.voters.count)),
                                        ("me_voted", .bool(viewer.map(answer.voters.contains) ?? false))]))
                })),
                ("is_finalized", .bool(poll.finalized)),
            ]))),
        ]))
    }

    func renderInteractionMetadata(_ interaction: InteractionRecord, guildID: Snowflake?) -> JSON {
        let owners = JSON.object(JSONObject(guildID.map { [("0", $0.json)] } ?? [("1", interaction.userID.json)]))
        // A modal submit names the command that opened the modal instead of its own command.
        if let command = interaction.openedBy {
            var opened = interaction
            (opened.id, opened.type, opened.openedBy) = (command, 2, nil)
            return .object(JSONObject([
                ("id", interaction.id.json), ("type", .int(interaction.type)), ("user", renderUser(interaction.userID)),
                ("authorizing_integration_owners", owners), ("triggering_interaction_metadata", renderInteractionMetadata(opened, guildID: guildID)),
            ]))
        }
        return .object(JSONObject([
            ("id", interaction.id.json), ("type", .int(interaction.type)), ("name", .string(interaction.name)),
            ("command_type", 1), ("user", renderUser(interaction.userID)), ("authorizing_integration_owners", owners),
        ]))
    }

    /// The deprecated `interaction` object, which Discord still sends beside `interaction_metadata`.
    func renderLegacyInteraction(_ interaction: InteractionRecord, guildID: Snowflake?) -> JSON {
        // A modal submit's legacy object describes the command that opened the modal.
        var legacy = JSONObject([("id", (interaction.openedBy ?? interaction.id).json), ("type", .int(interaction.openedBy == nil ? interaction.type : 2)),
                                 ("name", .string(interaction.name)), ("user", renderUser(interaction.userID))])
        if let guildID, let member = guilds[guildID]?.members[interaction.userID] {
            legacy["member"] = renderMember(member, guildID: guildID, includeUser: false)
        }
        return .object(legacy)
    }

    /// Discord gives each embed an ID; these use snowflake worker 2.
    func renderEmbeds(_ message: Message) -> JSON {
        .array(message.embeds.enumerated().map { index, embed in
            guard case var .object(fields) = embed, fields["id"] == nil else { return embed }
            fields["id"] = Snowflake(message.id.withWorker(2).rawValue + UInt64(index)).json
            return .object(fields)
        })
    }

    /// Discord numbers components in tree order.
    static func numberedComponents(_ components: [JSON]) -> JSON {
        var number = 0
        return .array(components.map { numbered($0, from: &number) })
    }

    private static func numbered(_ component: JSON, from number: inout Int) -> JSON {
        guard case var .object(fields) = component else { return component }
        number += 1
        if fields["id"] == nil { fields["id"] = .int(Int64(number)) }
        if let children = fields["components"]?.arrayValue {
            fields["components"] = .array(children.map { numbered($0, from: &number) })
        }
        return .object(fields)
    }

    /// A message as REST returns it and MESSAGE_CREATE carries it (`member` and
    /// `guild_id` are added for Gateway dispatches by the caller).
    func renderMessage(_ message: Message, viewer: Snowflake?, depth: Int = 0) -> JSON {
        var object = JSONObject()
        object["type"] = .int(message.type)
        object["content"] = .string(message.content)
        object["mentions"] = .array(message.mentions.map(renderUser))
        object["mention_roles"] = .array(message.mentionRoles.map(\.json))
        object["attachments"] = .array(message.attachments.map(renderAttachment))
        object["embeds"] = renderEmbeds(message)
        object["timestamp"] = World.timestamp(message.timestamp)
        object["edited_timestamp"] = World.optionalTimestamp(message.editedAt)
        object["flags"] = .int(message.flags)
        object["components"] = World.numberedComponents(message.components)
        object["id"] = message.id.json
        object["channel_id"] = message.channelID.json
        object["author"] = renderUser(message.authorID)
        object["pinned"] = .bool(message.pinned)
        object["mention_everyone"] = .bool(message.mentionEveryone)
        object["tts"] = .bool(message.tts)
        object["channel_type"] = .int(channels[message.channelID]?.type.rawValue ?? 0)
        if let channel = channels[message.channelID], channel.type.isThread {
            object["position"] = .int(channel.messages.firstIndex { $0.id == message.id } ?? channel.messages.count)
        }
        if let webhookID = message.webhookID { object["webhook_id"] = webhookID.json }
        if let applicationID = message.applicationID { object["application_id"] = applicationID.json }
        if let interaction = message.interaction {
            let guildID = channels[message.channelID]?.guildID
            object["interaction_metadata"] = renderInteractionMetadata(interaction, guildID: guildID)
            object["interaction"] = renderLegacyInteraction(interaction, guildID: guildID)
        }
        if !message.reactions.isEmpty { object["reactions"] = renderReactions(message, viewer: viewer) }
        if let nonce = message.nonce { object["nonce"] = .string(nonce) }
        if let reference = message.reference {
            var ref = JSONObject([("type", .int(reference.type)), ("channel_id", reference.channelID.json)])
            if let messageID = reference.messageID { ref["message_id"] = messageID.json }
            if let guildID = reference.guildID { ref["guild_id"] = guildID.json }
            object["message_reference"] = .object(ref)
            if message.type == 19, depth == 0 {
                let referenced = reference.messageID.flatMap { id in channels[reference.channelID]?.messages.first { $0.id == id } }
                object["referenced_message"] = referenced.map { renderMessage($0, viewer: viewer, depth: 1) } ?? .null
            }
        }
        if !message.messageSnapshots.isEmpty { object["message_snapshots"] = .array(message.messageSnapshots) }
        if let poll = message.poll { object["poll"] = renderPoll(poll, viewer: viewer) }
        object["call"] = message.call
        if !message.stickerIDs.isEmpty {
            let stickers = guilds.values.flatMap(\.stickers) + standardStickers
            object["sticker_items"] = .array(message.stickerIDs.compactMap { id in
                stickers.first { $0.id == id }.map { sticker in
                    .object(JSONObject([("id", sticker.id.json), ("name", .string(sticker.name)), ("format_type", .int(sticker.formatType))]))
                }
            })
        }
        if let threadID = message.threadID, let thread = channels[threadID], depth == 0 {
            object["thread"] = renderThread(thread, viewer: viewer)
        }
        return .object(object)
    }

    /// MESSAGE_CREATE/UPDATE payload: the message plus guild context.
    internal func renderMessageEvent(_ message: Message) -> JSON {
        guard case var .object(object) = renderMessage(message, viewer: nil) else { return .null }
        if let channel = channels[message.channelID] {
            if let guildID = channel.guildID {
                object["guild_id"] = guildID.json
                if let member = guilds[guildID]?.members[message.authorID] {
                    object["member"] = renderMember(member, guildID: guildID, includeUser: false)
                }
            }
        }
        return .object(object)
    }
}
