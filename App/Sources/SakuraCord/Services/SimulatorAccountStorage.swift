import DiscordProtocol
import Foundation
import SakuraCordModels

/// Where a debug build connected to the Discord simulator keeps its accounts.
/// Simulator tokens, saved accounts and caches live apart from real ones, so a
/// real token is never loaded or sent while the redirect is active.
nonisolated enum SimulatorAccountStorage {
    /// Whether this launch talks to the simulator; always false in release builds.
    static var isActive: Bool {
        #if DEBUG
        DiscordNetworkRedirect.isActive
        #else
        false
        #endif
    }

    /// Nil outside a simulator launch; release builds always use the default location.
    static var databaseDirectory: URL? {
        #if DEBUG
        guard DiscordNetworkRedirect.isActive else { return nil }
        return root.appendingPathComponent("Data", isDirectory: true)
        #else
        return nil
        #endif
    }

    #if DEBUG
    static let root = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("SakuraCord", isDirectory: true)
        .appendingPathComponent("DiscordSimulator", isDirectory: true)

    static let credentialStore = InsecureDebugFileCredentialStore(
        directory: root.appendingPathComponent("Credentials", isDirectory: true)
    )

    /// A simulator token for unattended runs (`SAKURACORD_SIMULATOR_TOKEN`). Each
    /// scenario run issues its own, so it wins over saved simulator accounts.
    static var launchToken: String? {
        guard DiscordNetworkRedirect.isActive else { return nil }
        return ProcessInfo.processInfo.environment["SAKURACORD_SIMULATOR_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static let savedAccountStore: UserDefaultsSavedAccountStore? = DiscordNetworkRedirect.isActive
        ? UserDefaultsSavedAccountStore(defaults: DiscordNetworkRedirect.sessionDefaults)
        : nil
    #endif
}
