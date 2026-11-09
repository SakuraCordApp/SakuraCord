import Foundation

enum SakuraCordOnboardingStore {
    private static let completionKey = "dev.sakuracord.onboarding-completed"

    /// Run before startup services write preferences so an existing installation
    /// is grandfathered in, while an unfinished new installation stays pending.
    static func registerInstallation() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: completionKey) == nil,
              let bundleID = Bundle.main.bundleIdentifier
        else { return }
        let existingPreferences = defaults.persistentDomain(forName: bundleID) ?? [:]
        // AppKit can record system preferences even before the app delegate is
        // initialized. Those alone do not establish a previous SakuraCord run.
        let hasExistingInstallation = existingPreferences.keys.contains { key in
            !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple.")
        }
        defaults.set(hasExistingInstallation, forKey: completionKey)
    }

    static var needsThemeSetup: Bool {
        !UserDefaults.standard.bool(forKey: completionKey)
    }

    static func complete() {
        UserDefaults.standard.set(true, forKey: completionKey)
    }
}
