import Foundation
import SakuraCordModels

struct ApplicationCommandIndexDecoder {
    private struct ApplicationBotDTO: Decodable {
        var id: String
        var username: String
        var globalName: String?
        var avatar: String?
        var bot: Bool?

        enum CodingKeys: String, CodingKey {
            case id, username, avatar, bot
            case globalName = "global_name"
        }

        var domain: User? {
            guard let id = UserID(id) else { return nil }
            let avatarURL = avatar.flatMap { hash in
                URL(
                    string:
                    "https://cdn.discordapp.com/avatars/\(id)/\(hash).webp?size=64&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                )
            }
            return User(
                id: id, username: username, displayName: globalName ?? username,
                avatarURL: avatarURL, isBot: bot ?? true
            )
        }
    }

    private struct Envelope: Decodable {
        var applications: [JSONValue]
        var applicationCommands: [JSONValue]
        var version: StringOrInteger

        enum CodingKeys: String, CodingKey {
            case applications
            case applicationCommands = "application_commands"
            case version
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            applications = try values.decodeIfPresent([JSONValue].self, forKey: .applications) ?? []
            applicationCommands =
                try values.decodeIfPresent([JSONValue].self, forKey: .applicationCommands) ?? []
            version = try values.decodeIfPresent(StringOrInteger.self, forKey: .version) ?? .string("")
        }
    }

    private enum StringOrInteger: Decodable {
        case string(String)
        case integer(UInt64)

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) {
                self = .string(string)
            } else {
                self = .integer(try value.decode(UInt64.self))
            }
        }

        var value: String {
            switch self {
            case let .string(value): value
            case let .integer(value): String(value)
            }
        }
    }

    private struct ApplicationDTO: Decodable {
        var id: String
        var name: String
        var description: String?
        var icon: String?
        var bot: ApplicationBotDTO?

        var domain: ApplicationCommandApplication {
            let iconURL = icon.flatMap { hash in
                URL(string: "https://cdn.discordapp.com/app-icons/\(id)/\(hash).webp?size=64")
            }
            return ApplicationCommandApplication(
                id: id, name: name, description: description ?? "", iconURL: iconURL,
                bot: bot?.domain
            )
        }
    }

    private struct PermissionDTO: Decodable {
        var id: String
        var type: Int
        var permission: Bool

        var domain: ApplicationCommandPermission {
            ApplicationCommandPermission(id: id, type: type, allows: permission)
        }
    }

    private struct ChoiceDTO: Decodable {
        var name: String
        var defaultName: String?
        var localizedName: String?
        var value: JSONValue

        enum CodingKeys: String, CodingKey {
            case name, value
            case defaultName = "name_default"
            case localizedName = "name_localized"
        }

        func domain(optionType: ApplicationCommandOptionType) -> ApplicationCommandChoice? {
            let parsed: ApplicationCommandChoiceValue
            switch (optionType, value) {
            case (.integer, let .number(value)) where value.isFinite
                && value.rounded(.towardZero) == value
                && value >= Double(Int64.min) && value <= Double(Int64.max):
                parsed = .integer(Int64(value))
            case (.number, let .number(value)) where value.isFinite:
                parsed = .number(value)
            case (.string, let .string(value)):
                parsed = .string(value)
            case (_, let .string(value)):
                parsed = .string(value)
            case (_, let .number(value)) where value.isFinite && value.rounded(.towardZero) == value:
                parsed = .integer(Int64(value))
            case (_, let .number(value)) where value.isFinite:
                parsed = .number(value)
            default:
                return nil
            }
            let sourceName = defaultName ?? name
            let displayName = localizedName ?? (sourceName == name ? nil : name)
            return ApplicationCommandChoice(
                name: sourceName, localizedName: displayName, value: parsed
            )
        }
    }

    private struct OptionDTO: Decodable {
        var type: Int
        var name: String
        var defaultName: String?
        var localizedName: String?
        var description: String?
        var defaultDescription: String?
        var localizedDescription: String?
        var required: Bool?
        var choices: [ChoiceDTO]?
        var options: [OptionDTO]?
        var channelTypes: [Int]?
        var minimumValue: Double?
        var maximumValue: Double?
        var minimumLength: Int?
        var maximumLength: Int?
        var autocomplete: Bool?

        enum CodingKeys: String, CodingKey {
            case type, name, description, required, choices, options, autocomplete
            case defaultName = "name_default"
            case localizedName = "name_localized"
            case defaultDescription = "description_default"
            case localizedDescription = "description_localized"
            case channelTypes = "channel_types"
            case minimumValue = "min_value"
            case maximumValue = "max_value"
            case minimumLength = "min_length"
            case maximumLength = "max_length"
        }

        func domain(idPrefix: String) -> ApplicationCommandOption {
            let optionType = ApplicationCommandOptionType(rawValue: type)
            let sourceName = defaultName ?? name
            let sourceDescription = defaultDescription ?? description ?? ""
            return ApplicationCommandOption(
                id: "\(idPrefix)/\(sourceName)",
                name: sourceName,
                localizedName: localizedName ?? (sourceName == name ? nil : name),
                description: sourceDescription,
                localizedDescription: localizedDescription
                    ?? (sourceDescription == description ? nil : description),
                type: optionType,
                isRequired: required ?? false,
                choices: (choices ?? []).compactMap { $0.domain(optionType: optionType) },
                options: (options ?? []).map { $0.domain(idPrefix: "\(idPrefix)/\(sourceName)") },
                channelTypes: channelTypes ?? [],
                minimumValue: minimumValue,
                maximumValue: maximumValue,
                minimumLength: minimumLength,
                maximumLength: maximumLength,
                usesAutocomplete: autocomplete ?? false
            )
        }
    }

    private struct CommandDTO: Decodable {
        var id: String
        var applicationID: String
        var guildID: String?
        var version: StringOrInteger
        var type: Int?
        var name: String
        var defaultName: String?
        var localizedName: String?
        var description: String?
        var defaultDescription: String?
        var localizedDescription: String?
        var options: [OptionDTO]?
        var permissions: [PermissionDTO]?
        var contexts: [Int]?
        var integrationTypes: [Int]?
        var globalPopularityRank: Int?

        enum CodingKeys: String, CodingKey {
            case id, version, type, name, description, options, permissions, contexts
            case applicationID = "application_id"
            case guildID = "guild_id"
            case defaultName = "name_default"
            case localizedName = "name_localized"
            case defaultDescription = "description_default"
            case localizedDescription = "description_localized"
            case integrationTypes = "integration_types"
            case globalPopularityRank = "global_popularity_rank"
        }

        func flattened(
            application: ApplicationCommandApplication,
            rawJSON: Data
        ) -> [ApplicationCommand] {
            let rootName = defaultName ?? name
            let rootLocalizedName = localizedName ?? (rootName == name ? nil : name)
            let rootDescription = defaultDescription ?? description ?? ""
            let rootLocalizedDescription = localizedDescription
                ?? (rootDescription == description ? nil : description)
            let rootOptions = (options ?? []).map { $0.domain(idPrefix: id) }
            let structural = rootOptions.filter { $0.type.isStructural }

            func command(
                path: [ApplicationCommandPathComponent],
                leafOptions: [ApplicationCommandOption],
                leafDescription: String?,
                leafLocalizedDescription: String?
            ) -> ApplicationCommand {
                let pathKey = path.map(\.name).joined(separator: "/")
                return ApplicationCommand(
                    id: pathKey.isEmpty ? id : "\(id):\(pathKey)",
                    rootCommandID: id,
                    applicationID: applicationID,
                    guildID: guildID.flatMap(GuildID.init),
                    version: version.value,
                    type: ApplicationCommandType(rawValue: type ?? 1),
                    name: rootName,
                    localizedName: rootLocalizedName,
                    description: leafDescription ?? rootDescription,
                    localizedDescription: leafLocalizedDescription ?? rootLocalizedDescription,
                    application: application,
                    options: leafOptions,
                    subcommandPath: path,
                    permissions: (permissions ?? []).map(\.domain),
                    contexts: contexts ?? [],
                    integrationTypes: integrationTypes ?? [],
                    globalPopularityRank: globalPopularityRank,
                    rootCommandJSON: rawJSON
                )
            }

            guard !structural.isEmpty else {
                return [
                    command(
                        path: [], leafOptions: rootOptions,
                        leafDescription: nil, leafLocalizedDescription: nil
                    )
                ]
            }

            var flattened: [ApplicationCommand] = []
            for option in structural {
                if option.type == .subcommand {
                    flattened.append(
                        command(
                            path: [
                                ApplicationCommandPathComponent(
                                    name: option.name, localizedName: option.localizedName,
                                    type: option.type
                                )
                            ],
                            leafOptions: option.options,
                            leafDescription: option.description,
                            leafLocalizedDescription: option.localizedDescription
                        )
                    )
                } else if option.type == .subcommandGroup {
                    for child in option.options where child.type == .subcommand {
                        flattened.append(
                            command(
                                path: [
                                    ApplicationCommandPathComponent(
                                        name: option.name, localizedName: option.localizedName,
                                        type: option.type
                                    ),
                                    ApplicationCommandPathComponent(
                                        name: child.name, localizedName: child.localizedName,
                                        type: child.type
                                    )
                                ],
                                leafOptions: child.options,
                                leafDescription: child.description,
                                leafLocalizedDescription: child.localizedDescription
                            )
                        )
                    }
                }
            }
            return flattened
        }
    }

    static func decode(_ data: Data, target: ApplicationCommandIndexTarget) throws
        -> ApplicationCommandCatalog
    {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var applications: [String: ApplicationCommandApplication] = [:]
        for value in envelope.applications {
            guard let payload = try? JSONEncoder().encode(value),
                  let application = try? JSONDecoder().decode(ApplicationDTO.self, from: payload)
            else { continue }
            applications[application.id] = application.domain
        }

        var commands: [ApplicationCommand] = []
        for value in envelope.applicationCommands {
            guard let payload = try? JSONEncoder().encode(value),
                  let command = try? JSONDecoder().decode(CommandDTO.self, from: payload),
                  let application = applications[command.applicationID]
            else { continue }
            commands.append(contentsOf: command.flattened(application: application, rawJSON: payload))
        }
        return ApplicationCommandCatalog(
            target: target,
            version: envelope.version.value.isEmpty ? nil : envelope.version.value,
            applications: applications.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            commands: commands
        )
    }
}
