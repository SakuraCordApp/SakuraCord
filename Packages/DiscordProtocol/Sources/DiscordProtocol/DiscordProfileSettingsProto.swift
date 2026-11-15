import Foundation

extension DiscordRESTProvider {
    /// Applies type-1 settings and returns whether StatusSettings were
    /// applied. A full proto without them clears them; a partial one does not.
    @discardableResult
    func applyProfileSettingsProto(_ encoded: String?, isPartial: Bool) -> Bool {
        guard let encoded, let data = Data(base64Encoded: encoded) else { return false }
        let version = DiscordSettingsProto.dataVersion(in: data)
        if let version { DiscordSettingsProto.advance(&settingsDataVersion, to: version) }
        let status = DiscordSettingsProto.statusSettings(in: data) ?? (isPartial ? nil : Data())
        let isStale = DiscordSettingsProto.isStale(version, comparedWith: profileStatusSettingsDataVersion)
        if let status, !isStale {
            adoptStatusSettings(status)
            if let version { profileStatusSettingsDataVersion = version }
        }
        let developerMode = DiscordSettingsProto.profileDeveloperMode(from: data)
        let developerIsStale = DiscordSettingsProto.isStale(version, comparedWith: profileDeveloperSettingsDataVersion)
        if !developerIsStale, developerMode != nil || !isPartial {
            profileDeveloperMode = developerMode ?? false
            if let version { profileDeveloperSettingsDataVersion = version }
        }
        return status != nil && !isStale
    }
}

/// Discord rejected a type-1 settings write as invalid data (400 / 50105).
struct UserSettingsRejection: Error {}

extension DiscordRESTProvider {
    // Official stable622805 module594061 `persistChanges`.
    /// PATCHes type-1 settings. A 429 is retried once when requested and
    /// Discord asks for at most 30 seconds; 400 / 50105 throws
    /// `UserSettingsRejection`, after which the caller reloads.
    func patchUserSettings(_ body: [String: JSONValue], retriesRateLimit: Bool, statusSave: StatusSettingsSaveContext? = nil) async throws -> UserSettingsProtoDTO {
        let path = "/users/@me/settings-proto/1"
        var retries = retriesRateLimit ? 1 : 0
        while true {
            let (data, response) = try await perform(path, method: "PATCH", body: body, statusSave: statusSave)
            if response.statusCode == 429, retries > 0,
               Self.retryAfter(from: data, response: response, addsSafetyMargin: false) <= 30 {
                retries -= 1
                continue
            }
            if response.statusCode == 400, Self.discordErrorCode(from: data) == 50105 {
                gatewayLogger.fault("Discord rejected a settings write as invalid data (50105); reloading settings.")
                throw UserSettingsRejection()
            }
            let settings: UserSettingsProtoDTO = try decodedResponse(data, response, method: "PATCH", path: path)
            if let root = Data(base64Encoded: settings.settings), let version = DiscordSettingsProto.dataVersion(in: root) {
                DiscordSettingsProto.advance(&settingsDataVersion, to: version)
            }
            return settings
        }
    }

    // Official stable622805 module594061 `loadIfNecessary(true)`.
    /// Reloads type-1 settings after a rejected write, so the server wins.
    @discardableResult
    func reloadUserSettings() async -> Bool {
        let generation = profileEditingGeneration
        do {
            let response: UserSettingsProtoDTO = try await request("/users/@me/settings-proto/1")
            guard generation == profileEditingGeneration,
                  Data(base64Encoded: response.settings) != nil else { return false }
            await applyUserSettingsProto(response.settings, isPartial: false)
            return true
        } catch {
            gatewayLogger.error("Settings reload failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

extension DiscordSettingsProto {
    static func profileDeveloperMode(from data: Data) -> Bool? {
        // Official stable607562 module873298: settings.appearance (13),
        // AppearanceSettings.developer_mode (2). Preserve field absence in patches.
        var reader = ProtoReader(data: data)
        var result: Bool?
        while let field = reader.readRawField() {
            guard field.field == 13, let payload = field.payload else { continue }
            var appearance = ProtoReader(data: payload)
            while let setting = appearance.readRawField() {
                if setting.field == 2, let value = setting.varint { result = value != 0 }
            }
        }
        return result
    }
}
