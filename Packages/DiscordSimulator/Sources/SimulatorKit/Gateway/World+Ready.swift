import Foundation

/// READY and READY_SUPPLEMENTAL in the deduplicated, client-state-v2 form the
/// official desktop client receives for its Identify capabilities.
public extension World {
    func renderReady(for userID: Snowflake, sessionID: String, resumeURL: String) -> JSON {
        let guilds = guilds(of: userID)
        let openChannels = (openPrivateChannels[userID] ?? []).compactMap { channels[$0] }
        let ownRelationships = (relationships[userID] ?? [:]).values.sorted { $0.since < $1.since }
        var referencedUsers: [Snowflake] = []
        for id in openChannels.flatMap(\.recipients) + ownRelationships.map(\.userID) where id != userID && !referencedUsers.contains(id) {
            referencedUsers.append(id)
        }

        let privateChannels = openChannels.map { readyPrivateChannel($0, viewer: userID) }

        let relationshipList: [JSON] = ownRelationships.map { relationship in
            .object(JSONObject([
                ("user_id", relationship.userID.json), ("type", .int(relationship.type.rawValue)),
                ("since", World.timestamp(relationship.since)), ("nickname", .optional(relationship.nickname)),
                ("is_spam_request", false), ("user_ignored", .bool(relationship.ignored)), ("id", relationship.userID.json),
            ]))
        }

        let readStateEntries: [JSON] = (readStates[userID] ?? [:]).sorted { $0.key < $1.key }.map { channelID, state in
            var entry = JSONObject([("id", channelID.json), ("mention_count", .int(state.mentionCount)), ("flags", 0)])
            // Channel read states carry the last read message as `last_message_id`; only typed ones use `last_acked_id`.
            if let acked = state.lastAckedID { entry["last_message_id"] = acked.json }
            if let pin = state.lastPinTimestamp { entry["last_pin_timestamp"] = World.timestamp(pin) }
            if let viewed = state.lastViewed { entry["last_viewed"] = .int(viewed) }
            return .object(entry)
        }

        let renderedGuilds = guilds.map { readyGuild($0, viewer: userID) }

        let mergedMembers: [JSON] = guilds.map { guild in
            guard let member = guild.members[userID] else { return [] }
            return .array([renderMember(member, guildID: guild.id, includeUser: false)])
        }

        let user = users[userID]
        return .object(JSONObject([
            ("v", 9),
            ("user", renderSelf(userID)),
            ("users", .array(referencedUsers.map(renderUser))),
            ("guilds", .array(renderedGuilds)),
            ("merged_members", .array(mergedMembers)),
            ("private_channels", .array(privateChannels)),
            ("relationships", .array(relationshipList)),
            ("read_state", .object(JSONObject([("version", 1), ("partial", false), ("entries", .array(readStateEntries + eventReadStates(userID)))]))),
            ("user_guild_settings", .object(JSONObject([("version", 1), ("partial", false), ("entries", .array(renderGuildSettingsEntries(userID)))]))),
            ("user_settings_proto", .string(settingsProto[userID]?[1]?.base64EncodedString() ?? "")),
            ("session_id", .string(sessionID)),
            ("session_type", "normal"),
            ("resume_gateway_url", .string(resumeURL)),
            ("sessions", .array([.object(JSONObject([
                ("status", .string((presences[userID]?.status ?? .online).rawValue)), ("session_id", .string(sessionID)),
                ("client_info", .object(JSONObject([("version", 0), ("os", "macos"), ("client", "desktop")]))),
                ("activities", []), ("hidden_activities", []), ("processed_at_timestamp", .int(Int64(clock.now.timeIntervalSince1970 * 1000))),
            ]))])),
            ("connected_accounts", []),
            ("guild_join_requests", .array(readyJoinRequests(userID))),
            ("guild_experiments", []),
            ("experiments", []),
            ("apex_experiments", .object(JSONObject([("assignments", .object(JSONObject()))]))),
            ("geo_ordered_rtc_regions", .array(["rotterdam", "frankfurt", "milan", "madrid", "stockholm"])),
            ("country_code", "NL"),
            ("notification_settings", .object(JSONObject([("flags", 0)]))),
            ("tutorial", .null),
            ("consents", .object(JSONObject([("personalization", .object(JSONObject([("consented", false)])))]))),
            ("auth", .object(JSONObject([("authenticator_types", [])]))),
            ("friend_suggestion_count", 0),
            ("analytics_token", .string(nextHash())),
            ("auth_session_id_hash", .string(nextHash())),
            ("static_client_session_id", .string(sessionID)),
            ("api_code_version", 1),
            ("explicit_content_scan_version", 2),
            ("broadcaster_user_ids", []),
            ("linked_users", []),
            ("game_relationships", []),
            ("pending_payments", .null),
            ("ad_personalization_toggles_disabled", false),
            ("swp_message_promotion_default_opted_out", false),
            ("swp_message_promotion_locked", false),
            ("subdivision_code", "NH"),
            ("regional_feature_config", .object(JSONObject([
                ("age_gated_features", 0), ("app_store_consent_revoked_android", false), ("app_store_consent_revoked_ios", false),
                ("media_takedown_regulation", .null), ("should_collect_app_store_signal", false), ("teen_by_default_settings", 0),
            ]))),
            ("_trace", .array([.string("[\"gateway-sim\",{\"micros\":0}]")])),
            ("qos_token", .string(nextHash())),
        ]))
    }

    private func readyPrivateChannel(_ channel: Channel, viewer userID: Snowflake) -> JSON {
        var object = JSONObject([
            ("type", .int(channel.type.rawValue)), ("id", channel.id.json), ("flags", .int(channel.flags)),
            ("last_message_id", channel.lastMessageID?.json ?? .null),
            ("recipient_ids", .array(channel.recipients.filter { $0 != userID }.map(\.json))),
            ("recipient_flags", 0), ("is_spam", false), ("is_message_request", false),
            ("is_message_request_timestamp", .null), ("blocked_user_warning_dismissed", false), ("safety_warnings", []),
        ])
        if let pinned = channel.lastPinTimestamp { object["last_pin_timestamp"] = World.timestamp(pinned) }
        if channel.type == .groupDM {
            object["name"] = .optional(channel.name)
            object["icon"] = .optional(channel.icon)
            object["owner_id"] = channel.ownerID?.json ?? .null
        }
        return .object(object)
    }

    func readyGuild(_ guild: Guild, viewer userID: Snowflake) -> JSON {
        let visible = visibleChannels(in: guild, for: userID)
        return .object(JSONObject([
            ("version", .int(Int64(clock.now.timeIntervalSince1970 * 1000))),
            ("threads", .array(activeThreads(in: guild, for: userID).map { renderThread($0, viewer: userID) })),
            ("stickers", .array(guild.stickers.map { renderSticker($0, guildID: guild.id) })),
            ("stage_instances", []),
            ("roles", .array(guild.roles.map(renderRole))),
            ("properties", renderGuildProperties(guild)),
            ("premium_subscription_count", .int(guild.premiumSubscriptionCount)),
            ("member_count", .int(guild.memberCount)),
            ("lazy", true),
            ("large", .bool(guild.memberCount > 250)),
            ("joined_at", World.timestamp(guild.members[userID]?.joinedAt ?? guild.id.date)),
            ("id", guild.id.json),
            ("guild_scheduled_events", .array(scheduledEvents(in: guild.id).map(renderScheduledEvent))),
            ("emojis", .array(guild.emojis.map(renderEmoji))),
            ("data_mode", "full"),
            ("channels", .array(visible.map { renderChannel($0, viewer: userID) })),
            ("application_command_counts", .object(JSONObject())),
            ("channel_settings", .object(JSONObject())),
            ("experiments", .object(JSONObject([("assignments", []), ("evaluation_id", "")]))),
        ]))
    }

    func renderReadySupplemental(for userID: Snowflake) -> JSON {
        let guilds = guilds(of: userID)
        let friends = (relationships[userID] ?? [:]).values.filter { $0.type == .friend }.map(\.userID).sorted()
        func presence(_ id: Snowflake) -> JSON {
            let presence = presences[id] ?? Presence()
            let status = presence.status == .invisible ? PresenceStatus.offline : presence.status
            return .object(JSONObject([
                ("user_id", id.json), ("status", .string(status.rawValue)),
                ("client_status", .object(JSONObject(status == .offline ? [] : [("desktop", .string(status.rawValue))]))),
                ("activities", .array(presence.activities.map(presenceActivity))), ("hidden_activities", []),
                ("processed_at_timestamp", .int(Int64(clock.now.timeIntervalSince1970 * 1000))),
                ("restricted_application", .null),
            ]))
        }
        let onlineFriends = friends.filter { (presences[$0]?.status ?? .offline) != .offline }
        return .object(JSONObject([
            ("merged_presences", .object(JSONObject([
                ("guilds", .array(guilds.map { guild in
                    .array(guild.memberOrder.filter { $0 != userID && (presences[$0]?.status ?? .offline) != .offline }.prefix(100).map(presence))
                })),
                ("friends", .array(onlineFriends.map(presence))),
            ]))),
            ("merged_members", .array(guilds.map { guild in
                .array(guild.memberOrder.filter { $0 != userID }.prefix(100).compactMap { id in
                    // Members without gaming leaderboard data omit the field here.
                    guild.members[id].map { renderMember($0, guildID: guild.id, includeUser: false).removing("member_gaming_leaderboard_data") }
                })
            })),
            ("lazy_private_channels", []),
            ("guilds", .array(guilds.map { guild in
                .object(JSONObject([("voice_states", renderGuildVoiceStates(guild.id)), ("id", guild.id.json), ("embedded_activities", []), ("activity_instances", [])]))
            })),
            ("game_invites", []),
            ("user_activities", []),
            ("disclose", .array(["pomelo"])),
        ]))
    }
}
