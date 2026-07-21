import Foundation
import SakuraCordModels

enum MockApplicationCommands {
    static let applicationID = "900000000000000100"

    static func catalog(
        target: ApplicationCommandIndexTarget,
        guildID: GuildID?,
        currentUser: User
    ) -> ApplicationCommandCatalog {
        let bot = User(
            id: UserID("900000000000000101")!, username: "verified",
            displayName: "Verified", isBot: true
        )
        let application = ApplicationCommandApplication(
            id: applicationID,
            name: "Verified",
            description: "Synthetic offline verification commands",
            bot: bot
        )

        func option(
            _ name: String,
            _ type: ApplicationCommandOptionType,
            description: String,
            required: Bool = false,
            choices: [ApplicationCommandChoice] = [],
            channelTypes: [Int] = [],
            minimumValue: Double? = nil,
            maximumValue: Double? = nil,
            minimumLength: Int? = nil,
            maximumLength: Int? = nil,
            autocomplete: Bool = false,
            prefix: String
        ) -> ApplicationCommandOption {
            ApplicationCommandOption(
                id: "\(prefix)/\(name)", name: name, description: description, type: type,
                isRequired: required, choices: choices, channelTypes: channelTypes,
                minimumValue: minimumValue, maximumValue: maximumValue,
                minimumLength: minimumLength, maximumLength: maximumLength,
                usesAutocomplete: autocomplete
            )
        }

        func command(
            id: String,
            name: String,
            description: String,
            rank: Int,
            options: (String) -> [ApplicationCommandOption],
            path: [ApplicationCommandPathComponent] = []
        ) -> ApplicationCommand {
            let rootJSON = try! JSONSerialization.data(
                withJSONObject: [
                    "id": id,
                    "application_id": applicationID,
                    "version": "\(id)1",
                    "type": 1,
                    "name": name,
                    "description": description,
                    "options": []
                ],
                options: [.sortedKeys]
            )
            let pathKey = path.map(\.name).joined(separator: "/")
            return ApplicationCommand(
                id: pathKey.isEmpty ? id : "\(id):\(pathKey)", rootCommandID: id,
                applicationID: applicationID, guildID: guildID, version: "\(id)1",
                name: name, description: description, application: application,
                options: options(pathKey.isEmpty ? id : "\(id)/\(pathKey)"),
                subcommandPath: path, contexts: guildID == nil ? [1, 2] : [0, 1, 2],
                integrationTypes: [0, 1], globalPopularityRank: rank,
                rootCommandJSON: rootJSON
            )
        }

        let personaChoices = [
            ApplicationCommandChoice(name: "Default", value: .string("default")),
            ApplicationCommandChoice(name: "Friendly", value: .string("friendly")),
            ApplicationCommandChoice(name: "Formal", value: .string("formal"))
        ]
        var commands = [
            command(
                id: "900000000000000200", name: "sayas",
                description: "Send a message as a selected persona", rank: 1
            ) { prefix in
                [
                    option(
                        "user", .user, description: "Who should speak", required: true,
                        prefix: prefix
                    ),
                    option(
                        "text", .string, description: "What to say", required: true,
                        minimumLength: 1, maximumLength: 500, prefix: prefix
                    ),
                    option(
                        "persona", .string, description: "Voice or persona",
                        choices: personaChoices, prefix: prefix
                    ),
                    option(
                        "attachment", .attachment, description: "Optional file", prefix: prefix
                    )
                ]
            },
            command(
                id: "900000000000000201", name: "backgroundcheck",
                description: "Run an offline demo background check", rank: 2
            ) { prefix in
                [option("user", .user, description: "Member to inspect", required: true, prefix: prefix)]
            },
            command(
                id: "900000000000000202", name: "verify",
                description: "Start the synthetic verification flow", rank: 3
            ) { _ in [] },
            command(
                id: "900000000000000203", name: "resetverification",
                description: "Reset synthetic verification state", rank: 4
            ) { prefix in
                [option("user", .user, description: "Member to reset", required: true, prefix: prefix)]
            },
            command(
                id: "900000000000000204", name: "avatar",
                description: "Show a member avatar", rank: 5
            ) { prefix in
                [option("user", .user, description: "Member", required: true, prefix: prefix)]
            },
            command(
                id: "900000000000000205", name: "search",
                description: "Search synthetic verification records", rank: 6
            ) { prefix in
                [
                    option(
                        "query", .string, description: "Record name", required: true,
                        minimumLength: 1, maximumLength: 100, autocomplete: true,
                        prefix: prefix
                    )
                ]
            },
            command(
                id: "900000000000000206", name: "toolbox",
                description: "Exercise every command option type offline", rank: 7,
                options: { prefix in
                    [
                        option("text", .string, description: "Text", required: true, prefix: prefix),
                        option(
                            "integer", .integer, description: "Integer", minimumValue: 1,
                            maximumValue: 10, prefix: prefix
                        ),
                        option("enabled", .boolean, description: "Boolean", prefix: prefix),
                        option("user", .user, description: "User", prefix: prefix),
                        option(
                            "channel", .channel, description: "Text channel", channelTypes: [0, 5],
                            prefix: prefix
                        ),
                        option("role", .role, description: "Role", prefix: prefix),
                        option("mentionable", .mentionable, description: "User or role", prefix: prefix),
                        option(
                            "number", .number, description: "Number", minimumValue: 0,
                            maximumValue: 1, prefix: prefix
                        ),
                        option("file", .attachment, description: "Attachment", prefix: prefix)
                    ]
                },
                path: [ApplicationCommandPathComponent(name: "test", type: .subcommand)]
            )
        ]
        let responseCommandID = "900000000000000207"
        commands.append(contentsOf: [
            ("normal", "Show a normal command response"),
            ("ephemeral", "Show a session-only command response"),
            ("deferred", "Show a loading response that is edited in place"),
            ("followup", "Show an initial response followed by an app message"),
            ("failure", "Show a rejected interaction without retrying")
        ].map { mode, description in
            command(
                id: responseCommandID,
                name: "response",
                description: description,
                rank: 20,
                options: { _ in [] },
                path: [ApplicationCommandPathComponent(name: mode, type: .subcommand)]
            )
        })
        return ApplicationCommandCatalog(
            target: target, version: "offline-1", applications: [application], commands: commands
        )
    }

    static func autocomplete(query: String) -> [ApplicationCommandChoice] {
        let all = ["sakura", "sakuracord", "sample", "sandbox", "safety", "swift"]
        return all.filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }.prefix(8).map { ApplicationCommandChoice(name: $0, value: .string($0)) }
    }
}
