import Foundation

public struct ApplicationCommandType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let chatInput = Self(rawValue: 1)
    public static let user = Self(rawValue: 2)
    public static let message = Self(rawValue: 3)
    public static let primaryEntryPoint = Self(rawValue: 4)
}

public struct ApplicationCommandOptionType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let subcommand = Self(rawValue: 1)
    public static let subcommandGroup = Self(rawValue: 2)
    public static let string = Self(rawValue: 3)
    public static let integer = Self(rawValue: 4)
    public static let boolean = Self(rawValue: 5)
    public static let user = Self(rawValue: 6)
    public static let channel = Self(rawValue: 7)
    public static let role = Self(rawValue: 8)
    public static let mentionable = Self(rawValue: 9)
    public static let number = Self(rawValue: 10)
    public static let attachment = Self(rawValue: 11)

    public var isStructural: Bool {
        self == .subcommand || self == .subcommandGroup
    }

    public var supportsAutocomplete: Bool {
        self == .string || self == .integer || self == .number
    }
}

public enum ApplicationCommandChoiceValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case string, integer, number }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .number: self = .number(try container.decode(Double.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .number(value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    public var stableID: String {
        switch self {
        case let .string(value): "s:\(value)"
        case let .integer(value): "i:\(value)"
        case let .number(value): "n:\(value.bitPattern)"
        }
    }
}

public struct ApplicationCommandChoice: Identifiable, Codable, Hashable, Sendable {
    public var id: String { value.stableID }
    public var name: String
    public var localizedName: String?
    public var value: ApplicationCommandChoiceValue

    public init(name: String, localizedName: String? = nil, value: ApplicationCommandChoiceValue) {
        self.name = name
        self.localizedName = localizedName
        self.value = value
    }

    public var displayName: String {
        localizedName ?? name
    }
}

public struct ApplicationCommandOption: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var localizedName: String?
    public var description: String
    public var localizedDescription: String?
    public var type: ApplicationCommandOptionType
    public var isRequired: Bool
    public var choices: [ApplicationCommandChoice]
    public var options: [ApplicationCommandOption]
    public var channelTypes: [Int]
    public var minimumValue: Double?
    public var maximumValue: Double?
    public var minimumLength: Int?
    public var maximumLength: Int?
    public var usesAutocomplete: Bool

    public init(
        id: String? = nil,
        name: String,
        localizedName: String? = nil,
        description: String = "",
        localizedDescription: String? = nil,
        type: ApplicationCommandOptionType,
        isRequired: Bool = false,
        choices: [ApplicationCommandChoice] = [],
        options: [ApplicationCommandOption] = [],
        channelTypes: [Int] = [],
        minimumValue: Double? = nil,
        maximumValue: Double? = nil,
        minimumLength: Int? = nil,
        maximumLength: Int? = nil,
        usesAutocomplete: Bool = false
    ) {
        self.id = id ?? name
        self.name = name
        self.localizedName = localizedName
        self.description = description
        self.localizedDescription = localizedDescription
        self.type = type
        self.isRequired = isRequired
        self.choices = choices
        self.options = options
        self.channelTypes = channelTypes
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.usesAutocomplete = usesAutocomplete
    }

    public var displayName: String {
        localizedName ?? name
    }

    public var displayDescription: String {
        localizedDescription ?? description
    }
}

public struct ApplicationCommandPathComponent: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(type.rawValue):\(name)" }
    public var name: String
    public var localizedName: String?
    public var type: ApplicationCommandOptionType

    public init(name: String, localizedName: String? = nil, type: ApplicationCommandOptionType) {
        self.name = name
        self.localizedName = localizedName
        self.type = type
    }

    public var displayName: String {
        localizedName ?? name
    }
}

public struct ApplicationCommandApplication: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var iconURL: URL?
    public var bot: User?

    public init(
        id: String, name: String, description: String = "", iconURL: URL? = nil, bot: User? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.iconURL = iconURL
        self.bot = bot
    }
}

public struct ApplicationCommandPermission: Codable, Hashable, Sendable {
    public var id: String
    public var type: Int
    public var allows: Bool

    public init(id: String, type: Int, allows: Bool) {
        self.id = id
        self.type = type
        self.allows = allows
    }
}

public struct ApplicationCommand: Identifiable, Codable, Hashable, Sendable {
    /// Stable picker identity. Subcommands of one root command need distinct row identities.
    public var id: String
    public var rootCommandID: String
    public var applicationID: String
    public var guildID: GuildID?
    public var version: String
    public var type: ApplicationCommandType
    public var name: String
    public var localizedName: String?
    public var description: String
    public var localizedDescription: String?
    public var application: ApplicationCommandApplication
    public var options: [ApplicationCommandOption]
    public var subcommandPath: [ApplicationCommandPathComponent]
    public var permissions: [ApplicationCommandPermission]
    public var contexts: [Int]
    public var integrationTypes: [Int]
    public var globalPopularityRank: Int?
    /// Canonical JSON for the root command returned by the index. Execution reuses it rather than
    /// silently dropping future server fields from `application_command`.
    public var rootCommandJSON: Data

    public init(
        id: String,
        rootCommandID: String,
        applicationID: String,
        guildID: GuildID? = nil,
        version: String,
        type: ApplicationCommandType = .chatInput,
        name: String,
        localizedName: String? = nil,
        description: String = "",
        localizedDescription: String? = nil,
        application: ApplicationCommandApplication,
        options: [ApplicationCommandOption] = [],
        subcommandPath: [ApplicationCommandPathComponent] = [],
        permissions: [ApplicationCommandPermission] = [],
        contexts: [Int] = [],
        integrationTypes: [Int] = [],
        globalPopularityRank: Int? = nil,
        rootCommandJSON: Data = Data("{}".utf8)
    ) {
        self.id = id
        self.rootCommandID = rootCommandID
        self.applicationID = applicationID
        self.guildID = guildID
        self.version = version
        self.type = type
        self.name = name
        self.localizedName = localizedName
        self.description = description
        self.localizedDescription = localizedDescription
        self.application = application
        self.options = options
        self.subcommandPath = subcommandPath
        self.permissions = permissions
        self.contexts = contexts
        self.integrationTypes = integrationTypes
        self.globalPopularityRank = globalPopularityRank
        self.rootCommandJSON = rootCommandJSON
    }

    public var displayName: String {
        ([localizedName ?? name] + subcommandPath.map(\.displayName)).joined(separator: " ")
    }

    public var executionName: String {
        name
    }

    public var displayDescription: String {
        localizedDescription ?? description
    }
}

public enum ApplicationCommandIndexTarget: Codable, Hashable, Sendable {
    case guild(GuildID)
    case channel(ChannelID)
    case user
    case application(String)

    public var stableID: String {
        switch self {
        case let .guild(id): "guild:\(id)"
        case let .channel(id): "channel:\(id)"
        case .user: "user:@me"
        case let .application(id): "application:\(id)"
        }
    }
}

public struct ApplicationCommandCatalog: Codable, Hashable, Sendable {
    public var target: ApplicationCommandIndexTarget
    public var version: String?
    public var applications: [ApplicationCommandApplication]
    public var commands: [ApplicationCommand]

    public init(
        target: ApplicationCommandIndexTarget,
        version: String? = nil,
        applications: [ApplicationCommandApplication] = [],
        commands: [ApplicationCommand] = []
    ) {
        self.target = target
        self.version = version
        self.applications = applications
        self.commands = commands
    }
}

public enum ApplicationCommandArgument: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case number(Double)
    case user(UserID)
    case channel(ChannelID)
    case role(RoleID)
    case mentionable(String)
    case attachment(URL)
}

public struct ApplicationCommandOptionValue: Identifiable, Codable, Hashable, Sendable {
    public var id: String { optionID }
    public var optionID: String
    public var name: String
    public var type: ApplicationCommandOptionType
    public var argument: ApplicationCommandArgument

    public init(
        optionID: String, name: String, type: ApplicationCommandOptionType,
        argument: ApplicationCommandArgument
    ) {
        self.optionID = optionID
        self.name = name
        self.type = type
        self.argument = argument
    }
}

public struct ApplicationCommandInvocation: Codable, Hashable, Sendable {
    public var command: ApplicationCommand
    public var channelID: ChannelID
    public var guildID: GuildID?
    public var values: [ApplicationCommandOptionValue]
    public var nonce: String

    public init(
        command: ApplicationCommand,
        channelID: ChannelID,
        guildID: GuildID?,
        values: [ApplicationCommandOptionValue],
        nonce: String = ClientNonce.make()
    ) {
        self.command = command
        self.channelID = channelID
        self.guildID = guildID
        self.values = values
        self.nonce = nonce
    }
}

public struct ApplicationCommandAutocompleteRequest: Codable, Hashable, Sendable {
    public var invocation: ApplicationCommandInvocation
    public var focusedOptionID: String
    public var query: String
    public var nonce: String

    public init(
        invocation: ApplicationCommandInvocation,
        focusedOptionID: String,
        query: String,
        nonce: String = ClientNonce.make()
    ) {
        self.invocation = invocation
        self.focusedOptionID = focusedOptionID
        self.query = query
        self.nonce = nonce
    }
}

public struct ApplicationCommandAutocompleteResult: Codable, Hashable, Sendable {
    public var nonce: String
    public var choices: [ApplicationCommandChoice]

    public init(nonce: String, choices: [ApplicationCommandChoice]) {
        self.nonce = nonce
        self.choices = choices
    }
}

public enum ApplicationCommandExecutionState: Equatable, Sendable {
    case queued(nonce: String)
    case created(nonce: String, interactionID: String)
    case succeeded(nonce: String)
    case failed(nonce: String, message: String)
}

public enum ApplicationCommandProgress: Equatable, Sendable {
    case preparing
    case reserving(files: Int)
    case uploading(fileName: String, completed: Int64, total: Int64)
    case submitting(nonce: String)
    case awaitingResponse(nonce: String)
}

public struct MessageInteractionMetadata: Codable, Hashable, Sendable {
    public var id: String?
    public var type: Int
    public var name: String?
    public var localizedName: String?
    public var user: User?
    public var applicationID: String?
    public var originalResponseMessageID: MessageID?

    public init(
        id: String? = nil,
        type: Int = 2,
        name: String? = nil,
        localizedName: String? = nil,
        user: User? = nil,
        applicationID: String? = nil,
        originalResponseMessageID: MessageID? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.localizedName = localizedName
        self.user = user
        self.applicationID = applicationID
        self.originalResponseMessageID = originalResponseMessageID
    }

    public var displayName: String? {
        localizedName ?? name
    }
}
