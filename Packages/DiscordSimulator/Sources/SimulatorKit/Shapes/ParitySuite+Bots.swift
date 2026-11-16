import Foundation

extension ParityRun {
    /// A command that opens a modal and its submit, then a bot that never answers.
    mutating func modalsAndFailures(_ target: Targets) async throws {
        let world = simulator.world
        let users = await world.users
        guard let bot = try await world.guild(target.guild).members.keys.sorted().first(where: { users[$0]?.bot == true }) else {
            throw WorldError.invalidBody("scenario has no bot in the target guild")
        }
        func command(_ name: String) -> JSON {
            .object(JSONObject([
                ("type", 2), ("application_id", .string(bot.description)), ("guild_id", .string(target.guild.description)),
                ("channel_id", .string(target.channel.description)), ("session_id", "parity"), ("nonce", .string(nonce())),
                ("data", .object(JSONObject([("type", 1), ("name", .string(name)), ("options", [])]))),
            ]))
        }
        await flowStart()
        _ = try await rest("POST", "/api/v9/interactions", body: command("signup"))
        let frames = await gateway?.drain(settle: .milliseconds(400)) ?? []
        for frame in frames where frame.op == 0 { checkFrame(frame) }
        guard let modal = frames.first(where: { $0.name == "INTERACTION_MODAL_CREATE" })?.payload["d"] else {
            throw WorldError.invalidBody("signup opened no modal")
        }
        _ = try await rest("POST", "/api/v9/interactions", body: .object(JSONObject([
            ("type", 5), ("application_id", .string(bot.description)), ("channel_id", .string(target.channel.description)),
            ("guild_id", .string(target.guild.description)), ("session_id", "parity"), ("nonce", .string(nonce())),
            ("data", .object(JSONObject([
                ("id", modal["id"] ?? .null), ("custom_id", modal["custom_id"] ?? .null),
                ("components", [
                    ["type": 18, "component": ["type": 21, "custom_id": "game", "value": "azul"]],
                    ["type": 18, "component": ["type": 22, "custom_id": "snacks", "values": ["cookies", "juice"]]],
                    ["type": 18, "component": ["type": 21, "custom_id": "host", "value": "no"]],
                ]),
            ]))),
        ])))
        await flowEnd(nil)

        await world.setBotResponsive(bot, false)
        await flowStart()
        _ = try await rest("POST", "/api/v9/interactions", body: command("gamenight"))
        // Discord gives up on a silent bot after three seconds.
        for frame in await gateway?.drain(settle: .milliseconds(3_600)) ?? [] where frame.op == 0 { checkFrame(frame) }
        await world.setBotResponsive(bot, true)
    }
}
