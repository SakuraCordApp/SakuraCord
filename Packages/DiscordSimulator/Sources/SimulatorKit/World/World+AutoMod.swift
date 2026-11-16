import Foundation

/// A keyword AutoMod rule (trigger type 1) that blocks matching messages,
/// optionally also timing the sender out.
public struct AutoModRule: Sendable {
    public var id: Snowflake
    public var guildID: Snowflake
    public var creatorID: Snowflake
    public var name: String
    /// Discord's keyword syntax: `word` matches a whole word, `*word*` anywhere, `word*` a prefix, `*word` a suffix.
    public var keywords: [String]
    public var allowList: [String] = []
    public var exemptRoles: [Snowflake] = []
    public var exemptChannels: [Snowflake] = []
    public var enabled = true
    /// Seconds to time the sender out for (action type 3); nil only blocks.
    public var timeoutSeconds: Int?
}

// AutoMod as a member meets it: a blocked message is refused with code 200000.
// Rules are set up through the control API, since the app doesn't manage them.
extension World {
    static let autoModBlockedMessage = "This can't be posted because it contains content blocked by this server. This may also be viewed by server owners."

    /// Throws Discord's blocked-content error when an enabled rule matches; a timeout action also times the author out.
    func enforceAutoMod(_ content: String, by authorID: Snowflake, in channel: Channel) async throws {
        guard let guildID = channel.guildID, let member = guilds[guildID]?.members[authorID] else { return }
        let ruleChannel = channel.type.isThread ? channel.parentID ?? channel.id : channel.id
        let lowered = content.lowercased()
        let words = lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let matched = servers.autoModRules.values.sorted { $0.id < $1.id }.first { rule in
            rule.guildID == guildID && rule.enabled && !rule.exemptChannels.contains(ruleChannel)
                && rule.exemptRoles.allSatisfy { !member.roles.contains($0) }
                && rule.keywords.contains { keyword in
                    let pattern = keyword.lowercased()
                    let core = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                    guard !core.isEmpty, !rule.allowList.contains(where: { $0.lowercased() == core }) else { return false }
                    switch (pattern.hasPrefix("*"), pattern.hasSuffix("*")) {
                    case (true, true): return lowered.contains(core)
                    case (false, true): return words.contains { $0.hasPrefix(core) }
                    case (true, false): return words.contains { $0.hasSuffix(core) }
                    case (false, false): return words.contains(core) || core.contains(" ") && lowered.contains(core)
                    }
                }
        }
        guard let rule = matched else { return }
        if let seconds = rule.timeoutSeconds {
            guilds[guildID]?.members[authorID]?.communicationDisabledUntil = clock.now.addingTimeInterval(Double(seconds))
            if let updated = guilds[guildID]?.members[authorID] {
                await emit("GUILD_MEMBER_UPDATE", renderMember(updated, guildID: guildID, includeUser: true).merging(["guild_id": guildID.json]),
                           to: .guild(guildID, channel: nil))
            }
        }
        throw WorldError(status: 400, code: 200_000, message: Self.autoModBlockedMessage)
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
        var actions: [JSON] = [.object(JSONObject([("metadata", .object(JSONObject([("custom_message", .null)]))), ("type", 1)]))]
        if let seconds = rule.timeoutSeconds {
            actions.append(.object(JSONObject([("metadata", .object(JSONObject([("duration_seconds", .int(seconds))]))), ("type", 3)])))
        }
        let fields: [(String, JSON)] = [
            ("name", .string(rule.name)), ("trigger_type", 1), ("event_type", 1), ("actions", .array(actions)),
            ("trigger_metadata", .object(JSONObject([("allow_list", .array(rule.allowList.map(JSON.string))),
                                                     ("keyword_filter", .array(rule.keywords.map(JSON.string))), ("regex_patterns", [])]))),
            ("enabled", .bool(rule.enabled)), ("exempt_roles", .array(rule.exemptRoles.map(\.json))),
            ("exempt_channels", .array(rule.exemptChannels.map(\.json))),
        ]
        return fields.map { auditChange($0.0, old: created ? JSON?.none : $0.1, new: created ? $0.1 : JSON?.none) }
    }
}
