import Foundation

/// Live Discord configuration and confirmed answers. This value is never persisted.
public struct GuildOnboarding: Decodable, Equatable, Sendable {
    public var guildID: GuildID
    public var prompts: [GuildOnboardingPrompt]
    public var defaultChannelIDs: [ChannelID]
    public var enabled: Bool
    public var responses: [String]
    public var promptsSeen: [String: Double]
    public var responsesSeen: [String: Double]

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id", defaultChannelIDs = "default_channel_ids"
        case prompts, enabled, responses
        case promptsSeen = "onboarding_prompts_seen", responsesSeen = "onboarding_responses_seen"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try values.decode(GuildID.self, forKey: .guildID)
        prompts = try values.decode([GuildOnboardingPrompt].self, forKey: .prompts)
        defaultChannelIDs = try values.decode([ChannelID].self, forKey: .defaultChannelIDs)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        responses = try values.decodeIfPresent([String].self, forKey: .responses) ?? []
        promptsSeen = try values.decodeIfPresent([String: Double].self, forKey: .promptsSeen) ?? [:]
        responsesSeen = try values.decodeIfPresent([String: Double].self, forKey: .responsesSeen) ?? [:]
    }

    public func hasNewOptions(_ prompt: GuildOnboardingPrompt) -> Bool {
        promptsSeen[prompt.id] == nil || prompt.options.contains { responsesSeen[$0.id] == nil }
    }

    public var customizationQuestions: [GuildOnboardingPrompt] {
        prompts.filter { !$0.inOnboarding } + prompts.filter(\.inOnboarding)
    }

    public func questions(initial: Bool) -> [GuildOnboardingPrompt] {
        prompts.filter { !initial || $0.inOnboarding }
    }

    public func validResponses(_ selected: Set<String>, initial: Bool) -> Set<String> {
        selected.intersection(questions(initial: initial).flatMap { $0.options.map(\.id) })
    }

    public func validationError(_ selected: Set<String>, initial: Bool) -> String? {
        guard enabled || !initial else { return "Onboarding is no longer enabled. Refresh to check your membership." }
        for prompt in questions(initial: initial) {
            let count = prompt.options.filter { selected.contains($0.id) }.count
            if prompt.required, count == 0 { return "Choose an answer for “\(prompt.title)”." }
            if prompt.singleSelect, count > 1 { return "Choose only one answer for “\(prompt.title)”." }
            if ![0, 1].contains(prompt.type) { return "Discord added an unsupported question type. Refresh or complete onboarding in Discord." }
        }
        return nil
    }
}

public struct GuildOnboardingPrompt: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var options: [GuildOnboardingOption]
    public var singleSelect: Bool
    public var required: Bool
    public var inOnboarding: Bool
    public var type: Int

    enum CodingKeys: String, CodingKey {
        case id, title, options, required, type
        case singleSelect = "single_select", inOnboarding = "in_onboarding"
    }
}

public struct GuildOnboardingOption: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var description: String?
    public var roleIDs: [RoleID]
    public var channelIDs: [ChannelID]
    public var emoji: Emoji?

    public struct Emoji: Decodable, Equatable, Sendable {
        public var id: String?
        public var name: String?
        public var animated: Bool?
        public var url: URL? {
            id.flatMap { URL(string: "https://cdn.discordapp.com/emojis/\($0).\(animated == true ? "gif" : "webp")?size=48") }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, emoji
        case roleIDs = "role_ids", channelIDs = "channel_ids"
    }
}

/// Only unfinished, user-authored choices and their editing context go to the account database.
public struct GuildOnboardingDraft: Codable, Equatable, Sendable {
    public var responses: Set<String>
    public var baselineResponses: Set<String>
    public var promptID: String?
    public var joinedAt: Date?
    public var initial: Bool

    public init(responses: Set<String>, baselineResponses: Set<String>, promptID: String?, joinedAt: Date?, initial: Bool) {
        self.responses = responses
        self.baselineResponses = baselineResponses
        self.promptID = promptID
        self.joinedAt = joinedAt
        self.initial = initial
    }
}

public enum GuildChannelSelection {
    public static let enabledFlag: UInt64 = 1 << 14
    public static let selectedFlag: UInt64 = 1 << 12

    public static func isSelected(_ channelID: ChannelID, settings: GuildNotificationSettings) -> Bool {
        settings.channelOverrides.first { $0.channelID == channelID }.map { $0.flags & selectedFlag != 0 } ?? false
    }
}
