import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func applicationCommandFrecency() async throws -> DiscordFrecencyHistory {
        let data = try await frecencySettingsProto()
        return DiscordSettingsProto.frecencyHistory(from: data, field: DiscordSettingsProto.applicationCommandFrecencyField) ?? DiscordFrecencyHistory()
    }

    /// One PATCH carrying field 7 and any other pending usage, matching Discord's flush of
    /// command uses. The Gateway then echoes the stored proto to every session.
    func saveApplicationCommandFrecency(_ history: DiscordFrecencyHistory) async throws
        -> DiscordFrecencyHistory
    {
        let patch = DiscordSettingsProto.frecencyPatch(
            history,
            field: DiscordSettingsProto.applicationCommandFrecencyField,
            limit: DiscordSettingsProto.maximumApplicationCommandFrecencyEntries
        )
        let stored = try await persistFrecencySettingsPatch(patch)
        return DiscordSettingsProto.frecencyHistory(from: stored, field: DiscordSettingsProto.applicationCommandFrecencyField) ?? history
    }
}
