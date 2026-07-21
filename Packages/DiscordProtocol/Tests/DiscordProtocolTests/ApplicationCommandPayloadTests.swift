import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

private func fixtureCommand(
    options: [ApplicationCommandOption], guildID: GuildID? = GuildID("300")!
) -> ApplicationCommand {
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    return ApplicationCommand(
        id: "200:admin/run",
        rootCommandID: "200",
        applicationID: application.id,
        guildID: guildID,
        version: "201",
        name: "admin",
        application: application,
        options: options,
        subcommandPath: [
            ApplicationCommandPathComponent(name: "run", type: .subcommand)
        ],
        rootCommandJSON: Data(
            #"{"id":"200","application_id":"100","name":"admin","future":true}"#.utf8
        )
    )
}

@Test("global command invoked in a guild does not claim guild registration")
func globalCommandInvocationScopeContract() throws {
    let command = fixtureCommand(options: [], guildID: nil)
    let invocation = ApplicationCommandInvocation(
        command: command,
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [],
        nonce: "600"
    )

    let payload = try ApplicationCommandPayloadBuilder.execution(invocation)
    let encoded = try JSONEncoder().encode(JSONValue.object(payload.data))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["guild_id"] == nil)
}

@Test("execution payload nests subcommands and indexes staged attachments")
func executionPayloadContract() throws {
    let options = [
        ApplicationCommandOption(name: "text", type: .string, isRequired: true),
        ApplicationCommandOption(name: "user", type: .user),
        ApplicationCommandOption(name: "channel", type: .channel),
        ApplicationCommandOption(name: "role", type: .role),
        ApplicationCommandOption(name: "mentionable", type: .mentionable),
        ApplicationCommandOption(name: "count", type: .integer, minimumValue: 1, maximumValue: 5),
        ApplicationCommandOption(name: "enabled", type: .boolean),
        ApplicationCommandOption(name: "ratio", type: .number),
        ApplicationCommandOption(name: "file", type: .attachment)
    ].map { option in
        var option = option
        option.id = "200/\(option.name)"
        return option
    }
    let file = URL(fileURLWithPath: "/tmp/sanitized-command.txt")
    let invocation = ApplicationCommandInvocation(
        command: fixtureCommand(options: options),
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [
            .init(optionID: "200/text", name: "text", type: .string, argument: .string("hello")),
            .init(optionID: "200/user", name: "user", type: .user, argument: .user(UserID("500")!)),
            .init(
                optionID: "200/channel", name: "channel", type: .channel,
                argument: .channel(ChannelID("501")!)
            ),
            .init(
                optionID: "200/role", name: "role", type: .role,
                argument: .role(RoleID("502")!)
            ),
            .init(
                optionID: "200/mentionable", name: "mentionable", type: .mentionable,
                argument: .mentionable("503")
            ),
            .init(optionID: "200/count", name: "count", type: .integer, argument: .integer(3)),
            .init(optionID: "200/enabled", name: "enabled", type: .boolean, argument: .boolean(true)),
            .init(optionID: "200/ratio", name: "ratio", type: .number, argument: .number(1.5)),
            .init(optionID: "200/file", name: "file", type: .attachment, argument: .attachment(file))
        ],
        nonce: "600"
    )

    let payload = try ApplicationCommandPayloadBuilder.execution(invocation)
    #expect(payload.attachmentURLs == [file])
    let encoded = try JSONEncoder().encode(JSONValue.object(payload.data))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["id"] as? String == "200")
    #expect(object["name"] as? String == "admin")
    #expect(object["version"] as? String == "201")
    #expect(object["guild_id"] as? String == "300")
    let root = try #require(object["application_command"] as? [String: Any])
    #expect(root["future"] as? Bool == true)
    let outer = try #require(object["options"] as? [[String: Any]])
    #expect(outer.count == 1)
    #expect(outer[0]["name"] as? String == "run")
    let leaves = try #require(outer[0]["options"] as? [[String: Any]])
    #expect(leaves.map { $0["name"] as? String } == [
        "text", "user", "channel", "role", "mentionable", "count", "enabled", "ratio", "file"
    ])
    #expect(leaves[1]["value"] as? String == "500")
    #expect(leaves[2]["value"] as? String == "501")
    #expect(leaves[3]["value"] as? String == "502")
    #expect(leaves[4]["value"] as? String == "503")
    #expect((leaves.last?["value"] as? NSNumber)?.intValue == 0)
}

@Test("autocomplete marks only the focused option and preserves earlier values")
func autocompletePayloadContract() throws {
    var scope = ApplicationCommandOption(name: "scope", type: .string)
    scope.id = "200/scope"
    var query = ApplicationCommandOption(
        name: "query", type: .string, minimumLength: 1, maximumLength: 20,
        usesAutocomplete: true
    )
    query.id = "200/query"
    var requiredLater = ApplicationCommandOption(
        name: "destination", type: .channel, isRequired: true
    )
    requiredLater.id = "200/destination"
    let invocation = ApplicationCommandInvocation(
        command: fixtureCommand(options: [scope, query, requiredLater]),
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [
            .init(optionID: scope.id, name: scope.name, type: scope.type, argument: .string("all"))
        ],
        nonce: "600"
    )
    let request = ApplicationCommandAutocompleteRequest(
        invocation: invocation, focusedOptionID: query.id, query: "sa", nonce: "601"
    )

    let payload = try ApplicationCommandPayloadBuilder.autocomplete(request)
    let encoded = try JSONEncoder().encode(JSONValue.object(payload.data))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let outer = try #require(object["options"] as? [[String: Any]])
    let leaves = try #require(outer[0]["options"] as? [[String: Any]])
    #expect(leaves.count == 2)
    #expect(leaves[0]["focused"] == nil)
    #expect(leaves[1]["focused"] as? Bool == true)
    #expect(leaves[1]["value"] as? String == "sa")
    #expect(leaves.contains { $0["name"] as? String == "destination" } == false)
}

@Test("invalid and missing command values fail before transmission")
func commandPayloadValidation() throws {
    var required = ApplicationCommandOption(
        name: "count", type: .integer, isRequired: true, minimumValue: 1, maximumValue: 5
    )
    required.id = "200/count"
    let command = fixtureCommand(options: [required])
    let missing = ApplicationCommandInvocation(
        command: command, channelID: ChannelID("400")!, guildID: GuildID("300")!, values: []
    )
    #expect(throws: ChatProviderError.self) {
        try ApplicationCommandPayloadBuilder.execution(missing)
    }

    let tooLarge = ApplicationCommandInvocation(
        command: command,
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [
            .init(optionID: required.id, name: required.name, type: .integer, argument: .integer(9))
        ]
    )
    #expect(throws: ChatProviderError.self) {
        try ApplicationCommandPayloadBuilder.execution(tooLarge)
    }

    let minimumInteger = ApplicationCommandInvocation(
        command: command,
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [
            .init(
                optionID: required.id, name: required.name, type: .integer,
                argument: .integer(.min)
            )
        ]
    )
    #expect(throws: ChatProviderError.self) {
        try ApplicationCommandPayloadBuilder.execution(minimumInteger)
    }
}

@Test("autocomplete accepts a partial value below the final minimum length")
func autocompletePartialValueIgnoresFinalMinimumLength() throws {
    var option = ApplicationCommandOption(
        name: "query", type: .string, isRequired: true,
        minimumLength: 3, maximumLength: 20, usesAutocomplete: true
    )
    option.id = "200/query"
    let invocation = ApplicationCommandInvocation(
        command: fixtureCommand(options: [option]),
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: []
    )

    let payload = try ApplicationCommandPayloadBuilder.autocomplete(
        ApplicationCommandAutocompleteRequest(
            invocation: invocation,
            focusedOptionID: option.id,
            query: "a"
        )
    )
    let encoded = try JSONEncoder().encode(JSONValue.object(payload.data))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let outer = try #require(object["options"] as? [[String: Any]])
    let leaves = try #require(outer[0]["options"] as? [[String: Any]])
    #expect(leaves.first?["value"] as? String == "a")
    #expect(leaves.first?["focused"] as? Bool == true)
}
