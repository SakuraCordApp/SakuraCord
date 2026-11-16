import Foundation

/// The signed-in person's own arrangements: a muted noisy channel and thread,
/// a quieter server, and tomorrow's run reminder waiting to send.
extension DemoConverter {
    mutating func addInboxState(me: Snowflake) async throws {
        guard includesGuilds, let band = channels["band-room"], let rota = channels["watering-rota"], let running = channels["running"],
              let porch = await world.channels[band]?.guildID, let garden = await world.channels[rota]?.guildID else { return }
        _ = try await world.patchGuildSettings(me, guilds: JSONObject([
            (porch.description, ["channel_overrides": .object(JSONObject([(band.description, ["muted": true])]))]),
            (garden.description, ["message_notifications": 1, "channel_overrides": .object(JSONObject([(rota.description, ["message_notifications": 0])]))]),
        ]))
        if let recs = channels["recs"],
           let thread = await world.channels.values.filter({ $0.parentID == recs && $0.threadMembers.contains(me) }).map(\.id).min() {
            _ = try await world.setThreadMuted(thread, by: me, muted: true)
        }
        let tomorrowMorning = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: world.epoch.addingTimeInterval(86_400))!
        _ = try await world.scheduleMessage(JSONObject([
            ("channel_id", running.json), ("content", "morning! meeting at the bridge at 7:30, slow pace as always 🐢"),
            ("scheduled_timestamp", World.timestamp(tomorrowMorning)), ("flags", 0), ("attachments", []),
        ]), by: me)
    }
}
