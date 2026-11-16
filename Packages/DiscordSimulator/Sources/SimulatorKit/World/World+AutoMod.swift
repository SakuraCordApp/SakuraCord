import Foundation

/// A keyword AutoMod rule (trigger type 1): it blocks matching messages and/or
/// posts an alert to a moderators' channel, and may time the sender out.
public struct AutoModRule: Sendable {
    public var id: Snowflake
    public var guildID: Snowflake
    public var creatorID: Snowflake
    public var name: String
    /// Discord's keyword syntax: `word` matches a whole word, `*word*` anywhere, `word*` a prefix, `*word` a suffix.
    public var keywords: [String]
    public var allowList: [String] = []
    /// Action type 1.
    public var blocks = true
    /// Action type 2: where the alert goes. That channel is exempt from the rule.
    public var alertChannelID: Snowflake?
    /// Action type 3: seconds to time the sender out for.
    public var timeoutSeconds: Int?

    /// The keyword a message trips, if any.
    func trippedKeyword(_ content: String) -> String? {
        let lowered = content.lowercased()
        let words = lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return keywords.first { keyword in
            let pattern = keyword.lowercased()
            let core = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard !core.isEmpty, !allowList.contains(where: { $0.lowercased() == core }) else { return false }
            switch (pattern.hasPrefix("*"), pattern.hasSuffix("*")) {
            case (true, true): return lowered.contains(core)
            case (false, true): return words.contains { $0.hasPrefix(core) }
            case (true, false): return words.contains { $0.hasSuffix(core) }
            case (false, false): return words.contains(core) || core.contains(" ") && lowered.contains(core)
            }
        }
    }
}

// AutoMod as a member meets it: a blocked message is refused with code 200000, an
// alert-only rule lets it through and posts an AutoMod alert. Rules are set up
// through the control API, since the app doesn't manage them.
extension World {
    /// Throws Discord's blocked-content error when a blocking rule matches (after any timeout);
    /// returns the alert-only rule and keyword the message trips, to report once it's posted.
    func enforceAutoMod(_ content: String, by authorID: Snowflake, in channel: Channel) async throws -> (rule: AutoModRule, keyword: String)? {
        guard let guildID = channel.guildID, guilds[guildID]?.members[authorID] != nil else { return nil }
        let tripped = servers.autoModRules.values.sorted { $0.id < $1.id }.compactMap { rule -> (rule: AutoModRule, keyword: String)? in
            guard rule.guildID == guildID, rule.alertChannelID != channel.id, let keyword = rule.trippedKeyword(content) else { return nil }
            return (rule, keyword)
        }
        for (rule, _) in tripped {
            guard let seconds = rule.timeoutSeconds else { continue }
            guilds[guildID]?.members[authorID]?.communicationDisabledUntil = clock.now.addingTimeInterval(Double(seconds))
            if let updated = guilds[guildID]?.members[authorID] { await emitMemberUpdate(updated, in: guildID) }
        }
        if tripped.contains(where: \.rule.blocks) {
            throw WorldError(status: 400, code: 200_000,
                             message: "This can't be posted because it contains content blocked by this server. This may also be viewed by server owners.")
        }
        return tripped.first { $0.rule.alertChannelID != nil }
    }

    /// The AutoMod alert (message type 24) in the rule's alert channel, authored by the flagged member.
    func postAutoModAlert(_ rule: AutoModRule, keyword: String, for message: Message) async throws {
        guard let alertChannel = rule.alertChannelID else { return }
        let fields: [(String, String)] = [
            ("rule_name", rule.name), ("channel_id", message.channelID.description), ("decision_id", nextHash()), ("keyword", keyword),
            ("keyword_matched_content", keyword), ("flagged_message_id", message.id.description), ("decision_outcome", "flagged"),
        ]
        var alert = MessageDraft()
        alert.type = 24
        alert.embeds = [.object(JSONObject([
            ("type", "auto_moderation_message"), ("description", .string(message.content)),
            ("fields", .array(fields.map { .object(JSONObject([("inline", false), ("name", .string($0.0)), ("value", .string($0.1))])) })),
        ]))]
        try await sendMessage(alert, as: message.authorID, in: alertChannel, checkPermissions: false)
    }

    func saveAutoModRule(_ rule: AutoModRule) async {
        servers.autoModRules[rule.id] = rule
        await emitAuditLog(rule.guildID, action: 140, target: rule.id, by: rule.creatorID, changes: autoModChanges(rule, created: true))
    }

    func deleteAutoModRule(_ id: Snowflake, by userID: Snowflake) async throws {
        guard let rule = servers.autoModRules.removeValue(forKey: id) else { throw WorldError.notFound }
        await emitAuditLog(rule.guildID, action: 142, target: id, by: userID, changes: autoModChanges(rule, created: false))
    }

    private func autoModChanges(_ rule: AutoModRule, created: Bool) -> [JSON] {
        var actions: [JSON] = rule.blocks ? [.object(JSONObject([("metadata", .object(JSONObject([("custom_message", .null)]))), ("type", 1)]))] : []
        if let channel = rule.alertChannelID {
            actions.append(.object(JSONObject([("metadata", .object(JSONObject([("channel_id", channel.json)]))), ("type", 2)])))
        }
        if let seconds = rule.timeoutSeconds {
            actions.append(.object(JSONObject([("metadata", .object(JSONObject([("duration_seconds", .int(seconds))]))), ("type", 3)])))
        }
        let fields: [(String, JSON)] = [
            ("name", .string(rule.name)), ("trigger_type", 1), ("event_type", 1), ("actions", .array(actions)),
            ("trigger_metadata", .object(JSONObject([("allow_list", .array(rule.allowList.map(JSON.string))),
                                                     ("keyword_filter", .array(rule.keywords.map(JSON.string))), ("regex_patterns", [])]))),
            ("enabled", true), ("exempt_roles", []), ("exempt_channels", .array(rule.alertChannelID.map { [$0.json] } ?? [])),
        ]
        return fields.map { auditChange($0.0, old: created ? JSON?.none : $0.1, new: created ? $0.1 : JSON?.none) }
    }
}
