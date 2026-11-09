import Foundation
import SakuraCordModels

struct ApplicationCommandPayload {
    var data: [String: JSONValue]
    var attachmentURLs: [URL]
}

enum ApplicationCommandPayloadBuilder {
    private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    static func execution(_ invocation: ApplicationCommandInvocation) throws
        -> ApplicationCommandPayload
    {
        try build(invocation, autocomplete: nil)
    }

    static func autocomplete(_ request: ApplicationCommandAutocompleteRequest) throws
        -> ApplicationCommandPayload
    {
        try build(
            request.invocation,
            autocomplete: (optionID: request.focusedOptionID, query: request.query)
        )
    }

    private static func build(
        _ invocation: ApplicationCommandInvocation,
        autocomplete: (optionID: String, query: String)?
    ) throws -> ApplicationCommandPayload {
        let command = invocation.command
        if command.type == .user || command.type == .message {
            return try contextMenu(invocation, isAutocomplete: autocomplete != nil)
        }
        guard command.type == .chatInput || command.type == .primaryEntryPoint else {
            throw ChatProviderError.invalidRequest("This kind of application command is not supported.")
        }
        let values = Dictionary(
            invocation.values.map { ($0.optionID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let knownOptionIDs = Set(invocation.command.options.map(\.id))
        if let unexpected = values.keys.first(where: { !knownOptionIDs.contains($0) }) {
            throw ChatProviderError.invalidRequest("The command contains an unknown option: \(unexpected).")
        }
        if let autocomplete, !knownOptionIDs.contains(autocomplete.optionID) {
            throw ChatProviderError.invalidRequest("The focused autocomplete option is unavailable.")
        }

        var attachments: [URL] = []
        var options: [JSONValue] = []
        for option in invocation.command.options {
            let isFocused = autocomplete?.optionID == option.id
            let value = values[option.id]
            if value == nil, !isFocused {
                if autocomplete == nil, option.isRequired {
                    throw ChatProviderError.invalidRequest("\(option.displayName) is required.")
                }
                continue
            }
            if isFocused {
                guard option.usesAutocomplete, option.type.supportsAutocomplete else {
                    throw ChatProviderError.invalidRequest(
                        "\(option.displayName) does not support remote autocomplete."
                    )
                }
                let query = autocomplete?.query ?? ""
                try validateAutocompleteQuery(query, for: option)
                // The focused value is the partial text, sent as a string even
                // for numeric options (an empty integer query is `""`).
                options.append(
                    .object([
                        "type": .number(Double(option.type.rawValue)),
                        "name": .string(option.name),
                        "value": .string(query),
                        "focused": .bool(true)
                    ])
                )
                continue
            }
            guard let value else { continue }
            guard value.type == option.type else {
                throw ChatProviderError.invalidRequest("\(option.displayName) has the wrong value type.")
            }
            let wireValue = try argumentValue(
                value.argument,
                option: option,
                attachmentIndex: attachments.count
            )
            if case let .attachment(url) = value.argument {
                attachments.append(url)
            }
            options.append(
                .object([
                    "type": .number(Double(option.type.rawValue)),
                    "name": .string(option.name),
                    "value": wireValue
                ])
            )
        }

        for path in invocation.command.subcommandPath.reversed() {
            options = [
                .object([
                    "type": .number(Double(path.type.rawValue)),
                    "name": .string(path.name),
                    "options": .array(options)
                ])
            ]
        }

        let data = try envelope(invocation, options: options)
        return ApplicationCommandPayload(data: data, attachmentURLs: attachments)
    }

    private static func contextMenu(
        _ invocation: ApplicationCommandInvocation,
        isAutocomplete: Bool
    ) throws -> ApplicationCommandPayload {
        guard !isAutocomplete else {
            throw ChatProviderError.invalidRequest("Context-menu commands have no autocomplete.")
        }
        guard let targetID = invocation.targetID, UInt64(targetID) != nil else {
            throw ChatProviderError.invalidRequest("Choose a user or message for this command.")
        }
        var data = try envelope(invocation, options: [])
        data["target_id"] = .string(targetID)
        return ApplicationCommandPayload(data: data, attachmentURLs: [])
    }

    private static func envelope(
        _ invocation: ApplicationCommandInvocation,
        options: [JSONValue]
    ) throws -> [String: JSONValue] {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: invocation.command.rootCommandJSON)
        guard case var .object(root) = decoded else {
            throw ChatProviderError.invalidRequest("The selected command has invalid root metadata.")
        }
        // The index omits these for context menu commands; the official client
        // always sends them.
        if root["description"] == nil { root["description"] = .string("") }
        if root["options"] == nil { root["options"] = .array([]) }
        let rootValue = JSONValue.object(root)
        var data: [String: JSONValue] = [
            "version": .string(invocation.command.version),
            "id": .string(invocation.command.rootCommandID),
            "name": .string(invocation.command.executionName),
            "type": .number(Double(invocation.command.type.rawValue)),
            "options": .array(options),
            "application_command": withResolvedLocalizations(rootValue)
        ]
        // The inner guild_id describes where the command itself was registered,
        // not where a global command happens to be invoked. The interaction's
        // outer guild_id carries the invocation context.
        if let guildID = invocation.command.guildID {
            data["guild_id"] = .string(guildID.description)
        }
        return data
    }

    /// The official client sends the definition with the names and descriptions
    /// it displayed, filling `*_localized` wherever the index omitted them.
    private static func withResolvedLocalizations(_ value: JSONValue) -> JSONValue {
        switch value {
        case var .object(object):
            for (key, child) in object {
                object[key] = withResolvedLocalizations(child)
            }
            // Context menu commands have an empty description and Discord sends
            // no localized copy of it.
            for field in ["name", "description"] {
                let localizedKey = "\(field)_localized"
                if case let .string(value)? = object[field], !value.isEmpty,
                   object[localizedKey] == nil || object[localizedKey] == .null
                {
                    object[localizedKey] = object[field]
                }
            }
            return .object(object)
        case let .array(items):
            return .array(items.map(withResolvedLocalizations))
        default:
            return value
        }
    }

    private static func validateAutocompleteQuery(
        _ query: String, for option: ApplicationCommandOption
    ) throws {
        // Autocomplete receives the user's partial value. Discord's minimum length
        // applies to final execution, not to an in-progress query that may need
        // suggestions in order to become valid.
        if let maximumLength = option.maximumLength, query.unicodeScalars.count > maximumLength {
            throw ChatProviderError.invalidRequest(
                "\(option.displayName) allows at most \(maximumLength) characters."
            )
        }
    }

    private static func argumentValue(
        _ argument: ApplicationCommandArgument,
        option: ApplicationCommandOption,
        attachmentIndex: Int
    ) throws -> JSONValue {
        switch (option.type, argument) {
        case (.string, let .string(value)):
            return try stringValue(value, option: option)
        case (.integer, let .integer(value)):
            return try integerValue(value, option: option)
        case (.boolean, let .boolean(value)):
            return .bool(value)
        case (.number, let .number(value)) where value.isFinite:
            return try numberValue(value, option: option)
        case (.user, let .user(value)):
            return .string(value.description)
        case (.channel, let .channel(value)):
            return .string(value.description)
        case (.role, let .role(value)):
            return .string(value.description)
        case (.mentionable, let .mentionable(value)) where UInt64(value) != nil:
            return .string(value)
        case (.attachment, .attachment(_)):
            return .number(Double(attachmentIndex))
        default:
            if ![
                ApplicationCommandOptionType.string, .integer, .boolean, .user, .channel,
                .role, .mentionable, .number, .attachment
            ].contains(option.type) {
                throw ChatProviderError.invalidRequest(
                    "\(option.displayName) uses unsupported option type \(option.type.rawValue)."
                )
            }
            throw ChatProviderError.invalidRequest("\(option.displayName) has an invalid value.")
        }
    }

    private static func stringValue(
        _ value: String,
        option: ApplicationCommandOption
    ) throws -> JSONValue {
        // Discord's server counts Unicode scalars, not graphemes or UTF-16 units.
        if let minimum = option.minimumLength, value.unicodeScalars.count < minimum {
            throw ChatProviderError.invalidRequest(
                "\(option.displayName) needs at least \(minimum) characters."
            )
        }
        if let maximum = option.maximumLength, value.unicodeScalars.count > maximum {
            throw ChatProviderError.invalidRequest(
                "\(option.displayName) allows at most \(maximum) characters."
            )
        }
        if !option.choices.isEmpty,
           !option.choices.contains(where: { $0.value == .string(value) })
        {
            throw ChatProviderError.invalidRequest("Select one of \(option.displayName)'s choices.")
        }
        return .string(value)
    }

    private static func integerValue(
        _ value: Int64,
        option: ApplicationCommandOption
    ) throws -> JSONValue {
        guard value >= -maximumSafeInteger, value <= maximumSafeInteger else {
            throw ChatProviderError.invalidRequest(
                "\(option.displayName) is outside Discord's safe integer range."
            )
        }
        let number = Double(value)
        try validateNumber(number, for: option)
        if !option.choices.isEmpty,
           !option.choices.contains(where: { $0.value == .integer(value) })
        {
            throw ChatProviderError.invalidRequest("Select one of \(option.displayName)'s choices.")
        }
        return .number(number)
    }

    private static func numberValue(
        _ value: Double,
        option: ApplicationCommandOption
    ) throws -> JSONValue {
        try validateNumber(value, for: option)
        if !option.choices.isEmpty,
           !option.choices.contains(where: { $0.value == .number(value) })
        {
            throw ChatProviderError.invalidRequest("Select one of \(option.displayName)'s choices.")
        }
        return .number(value)
    }

    private static func validateNumber(
        _ value: Double, for option: ApplicationCommandOption
    ) throws {
        if let minimum = option.minimumValue, value < minimum {
            throw ChatProviderError.invalidRequest("\(option.displayName) must be at least \(minimum).")
        }
        if let maximum = option.maximumValue, value > maximum {
            throw ChatProviderError.invalidRequest("\(option.displayName) must be at most \(maximum).")
        }
    }
}
