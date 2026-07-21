import Foundation
import Testing
@testable import SakuraCordModels

@Test("application command option types preserve future raw values")
func applicationCommandOptionRawValues() throws {
    let future = ApplicationCommandOptionType(rawValue: 42)
    let encoded = try JSONEncoder().encode(future)
    #expect(try JSONDecoder().decode(ApplicationCommandOptionType.self, from: encoded) == future)
    #expect(!future.isStructural)
    #expect(!future.supportsAutocomplete)
}

@Test("command choice values preserve integer and number identity")
func applicationCommandChoiceValues() throws {
    let values: [ApplicationCommandChoiceValue] = [
        .string("one"), .integer(1), .number(1), .number(1.25)
    ]
    let encoded = try JSONEncoder().encode(values)
    let decoded = try JSONDecoder().decode([ApplicationCommandChoiceValue].self, from: encoded)
    #expect(decoded == values)
    #expect(Set(values.map(\.stableID)).count == values.count)
}

@Test("flattened command identity and execution root stay distinct")
func flattenedCommandIdentity() throws {
    let app = ApplicationCommandApplication(id: "100", name: "Utility")
    let command = ApplicationCommand(
        id: "200:admin/verify",
        rootCommandID: "200",
        applicationID: app.id,
        version: "300",
        name: "admin",
        localizedName: "admin",
        application: app,
        subcommandPath: [
            ApplicationCommandPathComponent(
                name: "verify", localizedName: "verify", type: .subcommand
            )
        ],
        rootCommandJSON: Data(#"{"id":"200","name":"admin"}"#.utf8)
    )

    #expect(command.id == "200:admin/verify")
    #expect(command.rootCommandID == "200")
    #expect(command.displayName == "admin verify")
    #expect(command.executionName == "admin")
    #expect(String(decoding: command.rootCommandJSON, as: UTF8.self).contains("\"id\":\"200\""))
}

@Test("command invocation retains typed snowflakes and attachment URLs")
func typedCommandInvocation() throws {
    let app = ApplicationCommandApplication(id: "100", name: "Utility")
    let command = ApplicationCommand(
        id: "200:sayas", rootCommandID: "200", applicationID: app.id,
        version: "300", name: "sayas", application: app
    )
    let fileURL = URL(fileURLWithPath: "/tmp/sanitized-command.txt")
    let invocation = ApplicationCommandInvocation(
        command: command,
        channelID: ChannelID("400")!,
        guildID: GuildID("500")!,
        values: [
            ApplicationCommandOptionValue(
                optionID: "user", name: "user", type: .user,
                argument: .user(UserID("600")!)
            ),
            ApplicationCommandOptionValue(
                optionID: "file", name: "file", type: .attachment,
                argument: .attachment(fileURL)
            )
        ],
        nonce: "700"
    )

    let encoded = try JSONEncoder().encode(invocation)
    #expect(try JSONDecoder().decode(ApplicationCommandInvocation.self, from: encoded) == invocation)
}
