import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Test("command index decoder joins applications and flattens subcommand paths")
func commandIndexDecodingAndFlattening() throws {
    let data = Data(
        #"""
        {
          "version": "900",
          "applications": [
            {
              "id": "100",
              "name": "Verified",
              "description": "Verification tools",
              "icon": "abc",
              "bot": {"id":"101","username":"verified","global_name":"Verified","bot":true}
            }
          ],
          "application_commands": [
            {
              "id": "200",
              "application_id": "100",
              "guild_id": "300",
              "version": "201",
              "type": 1,
              "name": "admin",
              "description": "Admin tools",
              "global_popularity_rank": 7,
              "integration_types": [0],
              "contexts": [0],
              "options": [
                {
                  "type": 2,
                  "name": "verification",
                  "description": "Verification commands",
                  "options": [
                    {
                      "type": 1,
                      "name": "check",
                      "description": "Check a member",
                      "options": [
                        {"type":6,"name":"user","description":"Member","required":true},
                        {
                          "type":4,
                          "name":"level",
                          "description":"Level",
                          "choices":[{"name":"One","value":1}],
                          "min_value":1,
                          "max_value":5,
                          "autocomplete":false
                        },
                        {"type":42,"name":"future","description":"Future value"}
                      ]
                    }
                  ]
                }
              ],
              "future_root_field": {"retained": true}
            }
          ]
        }
        """#.utf8
    )

    let catalog = try ApplicationCommandIndexDecoder.decode(data, target: .guild(GuildID("300")!))
    #expect(catalog.version == "900")
    #expect(catalog.applications.count == 1)
    #expect(catalog.commands.count == 1)
    let command = try #require(catalog.commands.first)
    #expect(command.id == "200:verification/check")
    #expect(command.rootCommandID == "200")
    #expect(command.displayName == "admin verification check")
    #expect(command.displayDescription == "Check a member")
    #expect(command.subcommandPath.map(\.type) == [.subcommandGroup, .subcommand])
    #expect(command.options.map(\.name) == ["user", "level", "future"])
    #expect(command.options[0].isRequired)
    #expect(command.options[1].minimumValue == 1)
    #expect(command.options[1].maximumValue == 5)
    #expect(command.options[1].choices.first?.value == .integer(1))
    #expect(command.options[2].type.rawValue == 42)
    #expect(String(data: command.rootCommandJSON, encoding: .utf8)?.contains("future_root_field") == true)
}

@Test("command index decoder localizes display fields while preserving execution names")
func commandIndexLocalization() throws {
    let data = Data(
        #"""
        {
          "version": 9,
          "applications": [{"id":"100","name":"Utility"}],
          "application_commands": [
            {
              "id":"200",
              "application_id":"100",
              "version":201,
              "type":1,
              "name":"salut",
              "name_default":"hello",
              "description":"Dire bonjour",
              "description_default":"Say hello",
              "options":[
                {
                  "type":3,
                  "name":"texte",
                  "name_default":"text",
                  "description":"Votre texte",
                  "description_default":"Your text",
                  "required":true,
                  "min_length":1,
                  "max_length":20
                }
              ]
            }
          ]
        }
        """#.utf8
    )

    let catalog = try ApplicationCommandIndexDecoder.decode(data, target: .user)
    let command = try #require(catalog.commands.first)
    #expect(command.name == "hello")
    #expect(command.localizedName == "salut")
    #expect(command.displayName == "salut")
    #expect(command.description == "Say hello")
    #expect(command.displayDescription == "Dire bonjour")
    #expect(command.options.first?.name == "text")
    #expect(command.options.first?.localizedName == "texte")
    #expect(command.options.first?.minimumLength == 1)
    #expect(command.options.first?.maximumLength == 20)
}

@Test("malformed command entries do not discard a usable index")
func commandIndexLossyEntries() throws {
    let data = Data(
        #"""
        {
          "applications": [{"id":"100","name":"Utility"}, {"bad":true}],
          "application_commands": [
            {"id":"broken"},
            {"id":"200","application_id":"100","version":"1","name":"ping","description":"Ping"}
          ]
        }
        """#.utf8
    )

    let catalog = try ApplicationCommandIndexDecoder.decode(data, target: .user)
    #expect(catalog.applications.map(\.id) == ["100"])
    #expect(catalog.commands.map(\.name) == ["ping"])
}
