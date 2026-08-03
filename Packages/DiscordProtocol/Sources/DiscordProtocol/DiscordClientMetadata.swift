import Foundation

/// Stable, non-secret client metadata shared by REST and Gateway for one
/// provider lifetime. Its shape follows Paicord's current normal-account
/// transport while its version and environment values come from the current
/// Discord host and the real Mac. A server-issued fingerprint can be supplied
/// after the legitimate unauthenticated experiments flow; it is never invented.
public struct DiscordClientMetadata: Sendable {
    private nonisolated static let clientLaunchID = UUID().uuidString.lowercased()
    private nonisolated static let launchSignature = Self.makeLaunchSignature()
    private nonisolated static let clientHeartbeatSessionID = UUID().uuidString.lowercased()
    let locale: String
    let timeZone: String
    let acceptLanguage: String
    let userAgent: String
    let fingerprint: String?
    private let baseProperties: [String: JSONValue]

    var properties: [String: JSONValue] {
        properties(clientAppState: "focused")
    }

    public init(
        baseline: DiscordProductionBaseline = .august2026,
        locale: String = Locale.preferredLanguages.first ?? "en-US",
        systemLocale: String? = nil,
        timeZone: String = TimeZone.current.identifier,
        acceptLanguage: String? = nil,
        osVersion: String? = nil,
        fingerprint: String? = nil
    ) {
        self.locale = locale
        self.timeZone = timeZone
        self.acceptLanguage = acceptLanguage ?? Self.acceptLanguageHeader()
        let chromeVersion = "138.0.7204.251"
        let webKitVersion = "537.36"
        let osVersion = osVersion ?? Self.operatingSystemVersion()
        userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/\(webKitVersion) "
            + "(KHTML, like Gecko) discord/\(baseline.desktopVersion) Chrome/\(chromeVersion) "
            + "Electron/\(baseline.electronVersion) Safari/\(webKitVersion)"
        self.fingerprint = fingerprint?.isEmpty == false ? fingerprint : nil
        baseProperties = [
            "os": .string("Mac OS X"),
            "browser": .string("Discord Client"),
            "release_channel": .string("stable"),
            "client_version": .string(baseline.desktopVersion),
            "os_version": .string(osVersion),
            "os_arch": .string(Self.architecture),
            "app_arch": .string(Self.architecture),
            "system_locale": .string(systemLocale ?? Self.systemLocale),
            "has_client_mods": .bool(false),
            "client_launch_id": .string(Self.clientLaunchID),
            "launch_signature": .string(Self.launchSignature),
            "client_heartbeat_session_id": .string(Self.clientHeartbeatSessionID),
            "browser_user_agent": .string(userAgent),
            "browser_version": .string(baseline.electronVersion),
            "os_sdk_version": .string(osVersion.split(separator: ".").first.map(String.init) ?? ""),
            "client_build_number": .number(Double(baseline.webBuildNumber)),
            "client_event_source": .null,
        ]
    }

    func properties(clientAppState: String) -> [String: JSONValue] {
        var value = baseProperties
        value["client_app_state"] = .string(clientAppState)
        return value
    }

    func superPropertiesHeader(clientAppState: String = "focused") throws -> String {
        try JSONEncoder().encode(
            JSONValue.object(properties(clientAppState: clientAppState))
        ).base64EncodedString()
    }

    public func apply(
        to request: inout URLRequest,
        clientAppState: String = "focused"
    ) throws {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        try request.setValue(
            superPropertiesHeader(clientAppState: clientAppState),
            forHTTPHeaderField: "X-Super-Properties"
        )
        request.setValue(locale, forHTTPHeaderField: "X-Discord-Locale")
        request.setValue(timeZone, forHTTPHeaderField: "X-Discord-Timezone")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("bugReporterEnabled", forHTTPHeaderField: "X-Debug-Options")
        request.setValue("u=1, i", forHTTPHeaderField: "Priority")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("?0", forHTTPHeaderField: "Sec-CH-UA-Mobile")
        request.setValue("\"macOS\"", forHTTPHeaderField: "Sec-CH-UA-Platform")
        request.setValue(
            "\"Not)A;Brand\";v=\"8\", \"Chromium\";v=\"138\"",
            forHTTPHeaderField: "Sec-CH-UA"
        )
        request.setValue("https://discord.com/channels/@me", forHTTPHeaderField: "Referer")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        if let fingerprint {
            request.setValue(fingerprint, forHTTPHeaderField: "X-Fingerprint")
        }
    }

    /// Header set used by Paicord's remote-auth v2 WebSocket. Keeping this
    /// separate avoids sending REST-only client metadata during QR sign-in.
    public func applyRemoteAuthWebSocketHeaders(to request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
    }

    static let messageContextHeader = Data(#"{"location":"chat_input"}"#.utf8).base64EncodedString()

    private nonisolated static var architecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x64"
        #else
            "unknown"
        #endif
    }

    private nonisolated static var systemLocale: String {
        let locale = Locale.current
        guard let language = locale.language.languageCode?.identifier else {
            return locale.identifier.replacingOccurrences(of: "_", with: "-")
        }
        return locale.region.map { "\(language)-\($0.identifier)" } ?? language
    }

    private nonisolated static func acceptLanguageHeader() -> String {
        var seen = Set<String>()
        let languages = Locale.preferredLanguages.filter { seen.insert($0).inserted }.prefix(10)
        return languages.enumerated().map { index, language in
            guard index > 0 else { return language }
            return "\(language);q=\(String(format: "%.1f", 1 - Double(index) / 10))"
        }.joined(separator: ",")
    }

    private nonisolated static func operatingSystemVersion() -> String {
        let value = ProcessInfo.processInfo.operatingSystemVersion
        return "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
    }

    /// Discord's desktop launch signature is a client-generated UUID with a
    /// fixed bit pattern. It is not a captured or server-issued identifier.
    private nonisolated static func makeLaunchSignature() -> String {
        let requiredBits: [UInt8] = [
            0x00, 0x80, 0x10, 0x10, 0x08, 0x10, 0x08, 0x00,
            0x20, 0x81, 0x00, 0x40, 0x01, 0x00, 0x08, 0x00,
        ]
        var randomBytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        for index in randomBytes.indices {
            randomBytes[index] |= requiredBits[index]
        }
        let value = UUID(uuid: (
            randomBytes[0], randomBytes[1], randomBytes[2], randomBytes[3],
            randomBytes[4], randomBytes[5], randomBytes[6], randomBytes[7],
            randomBytes[8], randomBytes[9], randomBytes[10], randomBytes[11],
            randomBytes[12], randomBytes[13], randomBytes[14], randomBytes[15]
        ))
        return value.uuidString.lowercased()
    }
}
