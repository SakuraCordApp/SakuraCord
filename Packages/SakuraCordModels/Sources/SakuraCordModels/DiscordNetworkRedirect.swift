import Foundation

/// Points Discord's hosts at the local Discord simulator in debug builds
/// launched with `--discord-simulator[=PORT]`, or relaunched from a bundle the
/// launch scripts recorded as a simulator launch. Data keeps real URLs; only the
/// connection target changes, right before a request is made. Release builds
/// compile the redirect out and `resolve` returns its input.
public nonisolated enum DiscordNetworkRedirect {
    #if DEBUG
    /// The simulator's base port, or nil for a normal launch.
    public static let simulatorBasePort: UInt16? = basePort(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment,
        recordedPort: Bundle.main.object(forInfoDictionaryKey: recordedPortKey).map { "\($0)" }
    )

    /// Written into the bundle by the launch scripts for a simulator launch, so a
    /// later launch by path alone (LaunchServices, Computer Use) still reaches the
    /// simulator instead of the real account. Other launches remove it.
    static let recordedPortKey = "SakuraCordDiscordSimulatorPort"

    /// `script/run.sh --simulator-sign-in` clears this suite for a fresh start.
    public static let simulatorDefaultsSuite = "dev.sakuracord.SakuraCord.discord-simulator"

    static let defaultBasePort: UInt16 = 47100

    static func basePort(arguments: [String], environment: [String: String], recordedPort: String?) -> UInt16? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--discord-simulator" {
                let next = index + 1 < arguments.count ? UInt16(arguments[index + 1]) : nil
                return next ?? defaultBasePort
            }
            if argument.hasPrefix("--discord-simulator=") {
                return UInt16(argument.dropFirst("--discord-simulator=".count)) ?? defaultBasePort
            }
        }
        if let port = environment["SAKURACORD_DISCORD_SIMULATOR"].flatMap(UInt16.init) { return port }
        // A recorded launch never falls back to the real account, even if unreadable.
        return recordedPort.map { UInt16($0) ?? defaultBasePort }
    }

    /// The simulator listens on one port per Discord host, at these offsets.
    static func portOffset(forHost host: String) -> UInt16? {
        switch host {
        case "discord.com", "discordapp.com", "canary.discord.com", "ptb.discord.com": 0
        case "cdn.discordapp.com": 2
        case "media.discordapp.net": 3
        case "discord-attachments-uploads-prd.storage.googleapis.com": 4
        case _ where host.hasSuffix(".discord.gg"): 1
        case _ where host.hasSuffix(".discord.media"): 5
        case _ where host.hasSuffix(".discordsays.com"): 7
        case _ where host.hasPrefix("images-ext-") && host.hasSuffix(".discordapp.net"): 3
        default: nil
        }
    }

    static func resolve(_ url: URL, basePort: UInt16) -> URL {
        guard let host = url.host()?.lowercased(), let offset = portOffset(forHost: host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = components.scheme == "wss" || components.scheme == "ws" ? "ws" : "http"
        components.host = "127.0.0.1"
        components.port = Int(basePort + offset)
        return components.url ?? url
    }
    #endif

    /// Whether this launch talks to the simulator; always false in release builds.
    public static var isActive: Bool {
        #if DEBUG
        simulatorBasePort != nil
        #else
        false
        #endif
    }

    public static func resolve(_ url: URL?) -> URL? { url.map { resolve($0) } }

    /// Where account and session state is kept (client identity, saved
    /// accounts, onboarding, last conversation), so a simulator session never
    /// reads or overwrites the real one.
    public static var sessionDefaults: UserDefaults {
        #if DEBUG
        if isActive, let simulator = UserDefaults(suiteName: simulatorDefaultsSuite) { return simulator }
        #endif
        return .standard
    }

    /// The URL to connect to for `url`.
    @inline(__always)
    public static func resolve(_ url: URL) -> URL {
        #if DEBUG
        guard let simulatorBasePort else { return url }
        return resolve(url, basePort: simulatorBasePort)
        #else
        return url
        #endif
    }
}
