import Foundation

public enum DiscordGuildMemberFlags {
    public static let completedOnboarding: UInt64 = 1 << 1
    public static let startedOnboarding: UInt64 = 1 << 3
}

public enum DiscordGuildSettingsFlags {
    public static let optInChannelsOff: UInt64 = 1 << 13
    public static let optInChannelsOn: UInt64 = 1 << 14
}

public enum DiscordChannelSettingsFlags {
    public static let unreadsOnlyMentions: UInt64 = 1 << 9
    public static let unreadsAllMessages: UInt64 = 1 << 10
    public static let favorited: UInt64 = 1 << 11
    public static let optInEnabled: UInt64 = 1 << 12
    public static let newForumThreadsOff: UInt64 = 1 << 13
    public static let newForumThreadsOn: UInt64 = 1 << 14
}

public struct GuildOnboardingEmoji: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var isAnimated: Bool

    public init(id: String? = nil, name: String? = nil, isAnimated: Bool = false) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case isAnimated = "animated"
    }

    public func imageURL(size: Int = 64) -> URL? {
        guard let id else { return nil }
        var components = URLComponents(
            string: "https://cdn.discordapp.com/emojis/\(id).\(isAnimated ? "gif" : "png")"
        )
        components?.queryItems = [
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "quality", value: "lossless"),
        ]
        return components?.url
    }
}

public struct GuildOnboardingOption: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var channelIDs: [ChannelID]
    public var roleIDs: [RoleID]
    public var emoji: GuildOnboardingEmoji?
    public var title: String
    public var description: String?

    public init(
        id: String,
        channelIDs: [ChannelID] = [],
        roleIDs: [RoleID] = [],
        emoji: GuildOnboardingEmoji? = nil,
        title: String,
        description: String? = nil
    ) {
        self.id = id
        self.channelIDs = channelIDs
        self.roleIDs = roleIDs
        self.emoji = emoji
        self.title = title
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case id, emoji, title, description
        case channelIDs = "channel_ids"
        case roleIDs = "role_ids"
    }
}

public struct GuildOnboardingPrompt: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    /// Discord currently uses 0 for multi-choice and 1 for dropdown prompts.
    /// Keep the raw value so an unknown future prompt type remains decodable.
    public var type: Int
    public var options: [GuildOnboardingOption]
    public var title: String
    public var isSingleSelect: Bool
    public var isRequired: Bool
    public var isInOnboarding: Bool

    public init(
        id: String,
        type: Int = 0,
        options: [GuildOnboardingOption],
        title: String,
        isSingleSelect: Bool = false,
        isRequired: Bool = false,
        isInOnboarding: Bool = true
    ) {
        self.id = id
        self.type = type
        self.options = options
        self.title = title
        self.isSingleSelect = isSingleSelect
        self.isRequired = isRequired
        self.isInOnboarding = isInOnboarding
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, options, title
        case isSingleSelect = "single_select"
        case isRequired = "required"
        case isInOnboarding = "in_onboarding"
    }

    /// Discord compacts questions with more than twelve answers into a list.
    /// The prompt remains the same selection model; this is presentation only.
    public var usesCompactOptionList: Bool { options.count > 12 }
}

public struct GuildOnboardingConnectionRequirement: Codable, Equatable, Sendable {
    public var type: Int
    public var applicationID: String?
    public var providerID: String?
    public var name: String?

    public init(
        type: Int,
        applicationID: String? = nil,
        providerID: String? = nil,
        name: String? = nil
    ) {
        self.type = type
        self.applicationID = applicationID
        self.providerID = providerID
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case type, name
        case applicationID = "application_id"
        case providerID = "provider_id"
    }
}

public struct GuildOnboardingConfiguration: Codable, Equatable, Sendable {
    public var guildID: GuildID?
    public var prompts: [GuildOnboardingPrompt]
    public var defaultChannelIDs: [ChannelID]
    public var selectedOptionIDs: [String]
    public var promptsSeen: [String: Int64]
    public var optionsSeen: [String: Int64]
    public var mode: Int
    public var isEnabled: Bool
    public var isBelowRequirements: Bool?
    public var connections: [GuildOnboardingConnectionRequirement]
    public var additionalConnections: [GuildOnboardingConnectionRequirement]

    public init(
        guildID: GuildID? = nil,
        prompts: [GuildOnboardingPrompt],
        defaultChannelIDs: [ChannelID] = [],
        selectedOptionIDs: [String] = [],
        promptsSeen: [String: Int64] = [:],
        optionsSeen: [String: Int64] = [:],
        mode: Int = 0,
        isEnabled: Bool = true,
        isBelowRequirements: Bool? = nil,
        connections: [GuildOnboardingConnectionRequirement] = [],
        additionalConnections: [GuildOnboardingConnectionRequirement] = []
    ) {
        self.guildID = guildID
        self.prompts = prompts
        self.defaultChannelIDs = defaultChannelIDs
        self.selectedOptionIDs = selectedOptionIDs
        self.promptsSeen = promptsSeen
        self.optionsSeen = optionsSeen
        self.mode = mode
        self.isEnabled = isEnabled
        self.isBelowRequirements = isBelowRequirements
        self.connections = connections
        self.additionalConnections = additionalConnections
    }

    private enum CodingKeys: String, CodingKey {
        case prompts, mode, connections
        case guildID = "guild_id"
        case defaultChannelIDs = "default_channel_ids"
        case selectedOptionIDs = "responses"
        case promptsSeen = "onboarding_prompts_seen"
        case optionsSeen = "onboarding_responses_seen"
        case isEnabled = "enabled"
        case isBelowRequirements = "below_requirements"
        case additionalConnections = "additional_connections"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try values.decodeIfPresent(GuildID.self, forKey: .guildID)
        prompts = try values.decodeIfPresent([GuildOnboardingPrompt].self, forKey: .prompts) ?? []
        defaultChannelIDs =
            try values.decodeIfPresent([ChannelID].self, forKey: .defaultChannelIDs) ?? []
        selectedOptionIDs =
            try values.decodeIfPresent([String].self, forKey: .selectedOptionIDs) ?? []
        promptsSeen = try values.decodeIfPresent([String: Int64].self, forKey: .promptsSeen) ?? [:]
        optionsSeen = try values.decodeIfPresent([String: Int64].self, forKey: .optionsSeen) ?? [:]
        mode = try values.decodeIfPresent(Int.self, forKey: .mode) ?? 0
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        isBelowRequirements = try values.decodeIfPresent(Bool.self, forKey: .isBelowRequirements)
        connections =
            try values.decodeIfPresent(
                [GuildOnboardingConnectionRequirement].self, forKey: .connections
            ) ?? []
        additionalConnections =
            try values.decodeIfPresent(
                [GuildOnboardingConnectionRequirement].self,
                forKey: .additionalConnections
            ) ?? []
    }
}

public struct GuildOnboardingResponseSubmission: Equatable, Sendable {
    public var selectedOptionIDs: [String]
    public var promptsSeen: [String: Int64]
    public var optionsSeen: [String: Int64]

    public init(
        selectedOptionIDs: [String],
        promptsSeen: [String: Int64],
        optionsSeen: [String: Int64]
    ) {
        self.selectedOptionIDs = selectedOptionIDs
        self.promptsSeen = promptsSeen
        self.optionsSeen = optionsSeen
    }

    public static func completeSnapshot(
        configuration: GuildOnboardingConfiguration,
        selectedOptionIDs: some Sequence<String>,
        timestampMilliseconds: Int64
    ) -> Self {
        let selections = Set(selectedOptionIDs)
        return Self(
            selectedOptionIDs: configuration.prompts.flatMap(\.options).map(\.id).filter {
                selections.contains($0)
            },
            promptsSeen: Dictionary(
                uniqueKeysWithValues: configuration.prompts.map {
                    ($0.id, timestampMilliseconds)
                }
            ),
            optionsSeen: Dictionary(
                uniqueKeysWithValues: configuration.prompts.flatMap(\.options).map {
                    ($0.id, timestampMilliseconds)
                }
            )
        )
    }
}

public extension GuildOnboardingConfiguration {
    func reconcilingUserResponse(
        _ response: GuildOnboardingConfiguration,
        submission: GuildOnboardingResponseSubmission,
        guildID: GuildID
    ) -> Self {
        var reconciled = response.prompts.isEmpty && !prompts.isEmpty ? self : response
        reconciled.guildID = guildID
        reconciled.selectedOptionIDs = submission.selectedOptionIDs
        reconciled.promptsSeen = submission.promptsSeen
        reconciled.optionsSeen = submission.optionsSeen
        return reconciled
    }

    func projectedRoleIDs(currentRoleIDs: Set<RoleID>) -> Set<RoleID> {
        let managedRoleIDs = Set(prompts.flatMap(\.options).flatMap(\.roleIDs))
        let selectedOptions = Set(selectedOptionIDs)
        let selectedRoleIDs = Set(
            prompts.flatMap(\.options)
                .filter { selectedOptions.contains($0.id) }
                .flatMap(\.roleIDs)
        )
        return currentRoleIDs.subtracting(managedRoleIDs).union(selectedRoleIDs)
    }
}

public extension GuildNotificationSettings {
    var usesOptInChannelList: Bool {
        flags & DiscordGuildSettingsFlags.optInChannelsOn != 0
            && flags & DiscordGuildSettingsFlags.optInChannelsOff == 0
    }
}

public extension ChannelNotificationOverride {
    var isOptedIn: Bool {
        flags & DiscordChannelSettingsFlags.optInEnabled != 0
    }
}
