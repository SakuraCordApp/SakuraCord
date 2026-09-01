public enum GuildHighlightNotificationLevel: Int, Codable, Hashable, Sendable {
    case inherit = 0
    case disabled = 1
    case enabled = 2
}

public enum GuildNotificationToggle: Int, CaseIterable, Codable, Hashable, Sendable {
    case suppressEveryone
    case suppressRoles
    case suppressHighlights
    case muteScheduledEvents
    case mobilePush
}

public struct GuildNotificationSettings: Codable, Hashable, Sendable {
    public var guildID: GuildID?
    public var messageNotifications: MessageNotificationLevel
    public var isMuted: Bool
    public var muteConfiguration: DiscordMuteConfiguration?
    public var suppressEveryone: Bool
    public var suppressRoles: Bool
    public var notifyHighlights: GuildHighlightNotificationLevel
    public var muteScheduledEvents: Bool
    public var mobilePush: Bool
    public var flags: UInt64
    public var channelOverrides: [ChannelNotificationOverride]

    public init(
        guildID: GuildID?,
        messageNotifications: MessageNotificationLevel = .onlyMentions,
        isMuted: Bool = false,
        muteConfiguration: DiscordMuteConfiguration? = nil,
        suppressEveryone: Bool = false,
        suppressRoles: Bool = false,
        notifyHighlights: GuildHighlightNotificationLevel = .inherit,
        muteScheduledEvents: Bool = false,
        mobilePush: Bool = true,
        flags: UInt64 = 0,
        channelOverrides: [ChannelNotificationOverride] = []
    ) {
        self.guildID = guildID
        self.messageNotifications = messageNotifications
        self.isMuted = isMuted
        self.muteConfiguration = muteConfiguration
        self.suppressEveryone = suppressEveryone
        self.suppressRoles = suppressRoles
        self.notifyHighlights = notifyHighlights
        self.muteScheduledEvents = muteScheduledEvents
        self.mobilePush = mobilePush
        self.flags = flags
        self.channelOverrides = channelOverrides
    }

    public func isEnabled(_ toggle: GuildNotificationToggle) -> Bool {
        switch toggle {
        case .suppressEveryone: suppressEveryone
        case .suppressRoles: suppressRoles
        case .suppressHighlights: notifyHighlights == .disabled
        case .muteScheduledEvents: muteScheduledEvents
        case .mobilePush: mobilePush
        }
    }

    public mutating func set(_ toggle: GuildNotificationToggle, isEnabled: Bool) {
        switch toggle {
        case .suppressEveryone:
            suppressEveryone = isEnabled
        case .suppressRoles:
            suppressRoles = isEnabled
        case .suppressHighlights:
            notifyHighlights = isEnabled ? .disabled : .inherit
        case .muteScheduledEvents:
            muteScheduledEvents = isEnabled
        case .mobilePush:
            mobilePush = isEnabled
        }
    }

    enum CodingKeys: String, CodingKey {
        case guildID
        case messageNotifications
        case isMuted
        case muteConfiguration
        case suppressEveryone
        case suppressRoles
        case notifyHighlights
        case muteScheduledEvents
        case mobilePush
        case flags
        case channelOverrides
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try container.decodeIfPresent(GuildID.self, forKey: .guildID)
        messageNotifications =
            try container.decodeIfPresent(
                MessageNotificationLevel.self,
                forKey: .messageNotifications
            ) ?? .onlyMentions
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        muteConfiguration = try container.decodeIfPresent(
            DiscordMuteConfiguration.self,
            forKey: .muteConfiguration
        )
        suppressEveryone =
            try container.decodeIfPresent(Bool.self, forKey: .suppressEveryone) ?? false
        suppressRoles =
            try container.decodeIfPresent(Bool.self, forKey: .suppressRoles) ?? false
        notifyHighlights =
            try container.decodeIfPresent(
                GuildHighlightNotificationLevel.self,
                forKey: .notifyHighlights
            ) ?? .inherit
        muteScheduledEvents =
            try container.decodeIfPresent(Bool.self, forKey: .muteScheduledEvents) ?? false
        mobilePush = try container.decodeIfPresent(Bool.self, forKey: .mobilePush) ?? true
        flags = try container.decodeIfPresent(UInt64.self, forKey: .flags) ?? 0
        channelOverrides =
            try container.decodeIfPresent(
                [ChannelNotificationOverride].self,
                forKey: .channelOverrides
            ) ?? []
    }
}
