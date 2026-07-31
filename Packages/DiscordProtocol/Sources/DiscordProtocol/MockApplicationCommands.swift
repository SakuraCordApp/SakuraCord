import Foundation
import SakuraCordModels

enum MockApplicationCommands {
    static let applicationID = "900000000000000100"

    private struct CommandContext {
        let guildID: GuildID?
        let application: ApplicationCommandApplication
    }

    private struct OptionConstraints {
        var isRequired = false
        var choices: [ApplicationCommandChoice] = []
        var channelTypes: [Int] = []
        var minimumValue: Double?
        var maximumValue: Double?
        var minimumLength: Int?
        var maximumLength: Int?
        var usesAutocomplete = false
    }

    static func catalog(
        target: ApplicationCommandIndexTarget,
        guildID: GuildID?,
        currentUser _: User
    ) -> ApplicationCommandCatalog {
        let bot = User(
            id: UserID("900000000000000101")!,
            username: "verified",
            displayName: "Verified",
            isBot: true
        )
        let application = ApplicationCommandApplication(
            id: applicationID,
            name: "Verified",
            description: "Synthetic offline verification commands",
            bot: bot
        )
        let context = CommandContext(guildID: guildID, application: application)
        let commands = primaryCommands(context) + responseCommands(context)
        return ApplicationCommandCatalog(
            target: target,
            version: "offline-1",
            applications: [application],
            commands: commands
        )
    }

    private static func primaryCommands(_ context: CommandContext) -> [ApplicationCommand] {
        let personaChoices = [
            ApplicationCommandChoice(name: "Default", value: .string("default")),
            ApplicationCommandChoice(name: "Friendly", value: .string("friendly")),
            ApplicationCommandChoice(name: "Formal", value: .string("formal")),
        ]
        return [
            command(
                context, id: "900000000000000200", name: "sayas",
                description: "Send a message as a selected persona", rank: 1
            ) { prefix in
                [
                    option(
                        "user", .user, description: "Who should speak", prefix: prefix,
                        constraints: .init(isRequired: true)
                    ),
                    option(
                        "text", .string, description: "What to say", prefix: prefix,
                        constraints: .init(
                            isRequired: true,
                            minimumLength: 1,
                            maximumLength: 500
                        )
                    ),
                    option(
                        "persona", .string, description: "Voice or persona", prefix: prefix,
                        constraints: .init(choices: personaChoices)
                    ),
                    option("attachment", .attachment, description: "Optional file", prefix: prefix),
                ]
            },
            command(
                context, id: "900000000000000201", name: "backgroundcheck",
                description: "Run an offline demo background check", rank: 2
            ) { prefix in
                [
                    option(
                        "user", .user, description: "Member to inspect", prefix: prefix,
                        constraints: .init(isRequired: true)
                    )
                ]
            },
            command(
                context, id: "900000000000000202", name: "verify",
                description: "Start the synthetic verification flow", rank: 3
            ) { _ in [] },
            command(
                context, id: "900000000000000203", name: "resetverification",
                description: "Reset synthetic verification state", rank: 4
            ) { prefix in
                [
                    option(
                        "user", .user, description: "Member to reset", prefix: prefix,
                        constraints: .init(isRequired: true)
                    )
                ]
            },
            command(
                context, id: "900000000000000204", name: "avatar",
                description: "Show a member avatar", rank: 5
            ) { prefix in
                [
                    option(
                        "user", .user, description: "Member", prefix: prefix,
                        constraints: .init(isRequired: true)
                    )
                ]
            },
            command(
                context, id: "900000000000000205", name: "search",
                description: "Search synthetic verification records", rank: 6
            ) { prefix in
                [
                    option(
                        "query", .string, description: "Record name", prefix: prefix,
                        constraints: .init(
                            isRequired: true,
                            minimumLength: 1,
                            maximumLength: 100,
                            usesAutocomplete: true
                        )
                    )
                ]
            },
            toolboxCommand(context),
        ]
    }

    private static func toolboxCommand(_ context: CommandContext) -> ApplicationCommand {
        command(
            context,
            id: "900000000000000206",
            name: "toolbox",
            description: "Exercise every command option type offline",
            rank: 7,
            path: [ApplicationCommandPathComponent(name: "test", type: .subcommand)]
        ) { prefix in
            [
                option(
                    "text", .string, description: "Text", prefix: prefix,
                    constraints: .init(isRequired: true)
                ),
                option(
                    "integer", .integer, description: "Integer", prefix: prefix,
                    constraints: .init(minimumValue: 1, maximumValue: 10)
                ),
                option("enabled", .boolean, description: "Boolean", prefix: prefix),
                option("user", .user, description: "User", prefix: prefix),
                option(
                    "channel", .channel, description: "Text channel", prefix: prefix,
                    constraints: .init(channelTypes: [0, 5])
                ),
                option("role", .role, description: "Role", prefix: prefix),
                option("mentionable", .mentionable, description: "User or role", prefix: prefix),
                option(
                    "number", .number, description: "Number", prefix: prefix,
                    constraints: .init(minimumValue: 0, maximumValue: 1)
                ),
                option("file", .attachment, description: "Attachment", prefix: prefix),
            ]
        }
    }

    private static func responseCommands(_ context: CommandContext) -> [ApplicationCommand] {
        let responseCommandID = "900000000000000207"
        return [
            ("normal", "Show a normal command response"),
            ("ephemeral", "Show a session-only command response"),
            ("deferred", "Show a loading response that is edited in place"),
            ("followup", "Show an initial response followed by an app message"),
            ("failure", "Show a rejected interaction without retrying"),
        ].map { mode, description in
            command(
                context,
                id: responseCommandID,
                name: "response",
                description: description,
                rank: 20,
                path: [ApplicationCommandPathComponent(name: mode, type: .subcommand)]
            ) { _ in [] }
        }
    }

    private static func option(
        _ name: String,
        _ type: ApplicationCommandOptionType,
        description: String,
        prefix: String,
        constraints: OptionConstraints = .init()
    ) -> ApplicationCommandOption {
        ApplicationCommandOption(
            id: "\(prefix)/\(name)",
            name: name,
            description: description,
            type: type,
            isRequired: constraints.isRequired,
            choices: constraints.choices,
            channelTypes: constraints.channelTypes,
            minimumValue: constraints.minimumValue,
            maximumValue: constraints.maximumValue,
            minimumLength: constraints.minimumLength,
            maximumLength: constraints.maximumLength,
            usesAutocomplete: constraints.usesAutocomplete
        )
    }

    private static func command(
        _ context: CommandContext,
        id: String,
        name: String,
        description: String,
        rank: Int,
        path: [ApplicationCommandPathComponent] = [],
        options: (String) -> [ApplicationCommandOption]
    ) -> ApplicationCommand {
        let rootJSON: Data
        do {
            rootJSON = try JSONSerialization.data(
                withJSONObject: [
                    "id": id,
                    "application_id": applicationID,
                    "version": "\(id)1",
                    "type": 1,
                    "name": name,
                    "description": description,
                    "options": [],
                ],
                options: [.sortedKeys]
            )
        } catch {
            preconditionFailure("Invalid checked-in mock command: \(error)")
        }
        let pathKey = path.map(\.name).joined(separator: "/")
        return ApplicationCommand(
            id: pathKey.isEmpty ? id : "\(id):\(pathKey)",
            rootCommandID: id,
            applicationID: applicationID,
            guildID: context.guildID,
            version: "\(id)1",
            name: name,
            description: description,
            application: context.application,
            options: options(pathKey.isEmpty ? id : "\(id)/\(pathKey)"),
            subcommandPath: path,
            contexts: context.guildID == nil ? [1, 2] : [0, 1, 2],
            integrationTypes: [0, 1],
            globalPopularityRank: rank,
            rootCommandJSON: rootJSON
        )
    }

    static func autocomplete(query: String) -> [ApplicationCommandChoice] {
        let all = ["sakura", "sakuracord", "sample", "sandbox", "safety", "swift"]
        return all.filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }.prefix(8).map { ApplicationCommandChoice(name: $0, value: .string($0)) }
    }
}
