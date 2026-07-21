import Foundation

/// Stable, non-secret client metadata shared by REST and Gateway for one
/// provider lifetime. Its shape follows Paicord's current normal-account
/// transport while its version and environment values come from the current
/// Discord host and the real Mac. A server-issued fingerprint can be supplied
/// after the legitimate unauthenticated experiments flow; it is never invented.
public struct DiscordClientMetadata: Sendable {
    private nonisolated static let clientLaunchID = UUID().uuidString.lowercased()
    let locale: String
    let timeZone: String
    let acceptLanguage: String
    let userAgent: String
    let fingerprint: String?
    let properties: [String: JSONValue]

    public init(
        baseline: DiscordProductionBaseline = .july2026,
        locale: String = Locale.preferredLanguages.first ?? "en-US",
        timeZone: String = TimeZone.current.identifier,
        acceptLanguage: String? = nil,
        osVersion: String? = nil,
        fingerprint: String? = nil
    ) {
        self.locale = locale
        self.timeZone = timeZone
        self.acceptLanguage = acceptLanguage ?? locale
        let chromeVersion = "138.0.7204.251"
        let webKitVersion = "537.36"
        let osVersion = osVersion ?? Self.kernelVersion()
        userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/\(webKitVersion) (KHTML, like Gecko) discord/\(baseline.desktopVersion) Chrome/\(chromeVersion) Electron/\(baseline.electronVersion) Safari/\(webKitVersion)"
        self.fingerprint = fingerprint?.isEmpty == false ? fingerprint : nil
        properties = [
            "os": .string("Mac OS X"),
            "browser": .string("Discord Client"),
            "release_channel": .string("stable"),
            "client_version": .string(baseline.desktopVersion),
            "os_version": .string(osVersion),
            "os_arch": .string(Self.architecture),
            "app_arch": .string(Self.architecture),
            "system_locale": .string(locale),
            "has_client_mods": .bool(false),
            "client_launch_id": .string(Self.clientLaunchID),
            "browser_user_agent": .string(userAgent),
            "browser_version": .string(baseline.electronVersion),
            "os_sdk_version": .string(osVersion.split(separator: ".").first.map(String.init) ?? ""),
            "client_build_number": .number(Double(baseline.webBuildNumber)),
            "native_build_number": .number(85861),
            "client_app_state": .string("focused")
        ]
    }

    func superPropertiesHeader() throws -> String {
        try JSONEncoder().encode(JSONValue.object(properties)).base64EncodedString()
    }

    public func apply(to request: inout URLRequest) throws {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        try request.setValue(superPropertiesHeader(), forHTTPHeaderField: "X-Super-Properties")
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

    private nonisolated static func kernelVersion() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.release) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
