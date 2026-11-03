import AppKit

/// Applies the theme accent to native controls, selections and focus rings.
@MainActor
final class AppAccentColorController {
    static let shared = AppAccentColorController()

    private var hasStarted = false
    private var bundledAccentColor: NSColor?

    private init() {}

    /// The theme accent always wins over a specific macOS accent. AppKit reads
    /// this undocumented preference once, before NSApplication exists, so it
    /// goes in the process-only argument domain; never write AppleAccentColor
    /// to a persistent app domain or the global domain.
    static func configureSystemAccentOverride() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = -2
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    func start() {
        guard !hasStarted else { return }
        let getter = NSSelectorFromString("_accentColor")
        guard NSApp.responds(to: getter) else { return }
        // Capture the dynamic bundled asset before applying the saved theme.
        bundledAccentColor = NSApp.perform(getter)?.takeUnretainedValue() as? NSColor
        hasStarted = true
        apply()
    }

    /// Applies the committed theme; theme commits call this before their
    /// observers invalidate cached presentation.
    func apply() {
        guard hasStarted else { return }
        let setter = NSSelectorFromString("_setAccentColor:")
        guard NSApp.responds(to: setter) else { return }
        let themeStore = SakuraCordThemeStore.shared
        let color = themeStore.committedTheme == .defaultTheme ? bundledAccentColor : themeStore.accentNSColor()
        NSApp.perform(setter, with: color)
    }
}
