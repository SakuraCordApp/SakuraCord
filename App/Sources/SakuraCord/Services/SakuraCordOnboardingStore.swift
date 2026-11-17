import Foundation
import SakuraCordModels

enum SakuraCordOnboardingStore {
    private static let completionKey = "dev.sakuracord.onboarding-completed"

    /// Run before startup services write preferences so an existing installation
    /// is grandfathered in, while an unfinished new installation stays pending.
    static func registerInstallation() {
        let defaults = DiscordNetworkRedirect.sessionDefaults
        guard defaults.object(forKey: completionKey) == nil else { return }
        // Each simulator store starts as a new installation.
        if DiscordNetworkRedirect.isActive {
            defaults.set(false, forKey: completionKey)
            return
        }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let existingPreferences = defaults.persistentDomain(forName: bundleID) ?? [:]
        // AppKit can record system preferences even before the app delegate is
        // initialized. Those alone do not establish a previous SakuraCord run.
        let hasExistingInstallation = existingPreferences.keys.contains { key in
            !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple.")
        }
        defaults.set(hasExistingInstallation, forKey: completionKey)
    }

    static var needsThemeSetup: Bool {
        !DiscordNetworkRedirect.sessionDefaults.bool(forKey: completionKey)
    }

    static func complete() {
        DiscordNetworkRedirect.sessionDefaults.set(true, forKey: completionKey)
    }
}
