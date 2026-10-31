import AppKit

@MainActor
final class AppAccentColorController {
    static let shared = AppAccentColorController()

    private var hasStarted = false
    private var bundledAccentColor: NSColor?
    private var appearanceObservation: NSKeyValueObservation?
    private var systemColorsObservation: NSObjectProtocol?
    private var overridesSystemAccent = false

    private init() {}

    static func configureSystemAccentOverride() {
        guard case .bool(true) = SettingsPreferenceStore.shared.value(for: .overrideMacOSAccent) else { return }
        // AppKit caches this undocumented preference at initialization. Use the
        // process-only argument domain before creating NSApplication; never write
        // AppleAccentColor to a persistent app domain or the global domain.
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = -2
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    func start() {
        guard !hasStarted else { return }
        let getter = NSSelectorFromString("_accentColor")
        guard NSApp.responds(to: getter) else { return }
        // Capture the dynamic bundled asset, before applying the saved theme.
        // The effective accent may already include the user's system override.
        bundledAccentColor = NSApp.perform(getter)?.takeUnretainedValue() as? NSColor
        hasStarted = true
        if case let .bool(enabled) = SettingsPreferenceStore.shared.value(for: .overrideMacOSAccent) {
            overridesSystemAccent = enabled
        }
        refreshSystemAccent()
        apply(SakuraCordThemeStore.shared.committedTheme, background: SakuraCordThemeStore.shared.committedBackgroundTheme)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshSystemAccent() }
        }
        systemColorsObservation = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSystemAccent() }
        }
    }

    private func refreshSystemAccent() {
        // Read the global domain directly: our optional process-local override
        // deliberately masks AppleAccentColor in the standard search list.
        let selection = (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleAccentColor"] as? NSNumber)?.intValue
        let color = overridesSystemAccent ? nil : Self.systemAccentColor(for: selection)
        SakuraCordThemeStore.shared.setSystemAccentColor(color)
    }

    static func systemAccentColor(for selection: Int?) -> SakuraCordThemeColor? {
        let name: String
        switch selection {
        case -1: name = "controlAccentNoColor"
        case 0: name = "controlAccentRedColor"
        case 1: name = "controlAccentOrangeColor"
        case 2: name = "controlAccentYellowColor"
        case 3: name = "controlAccentGreenColor"
        case 4: name = "controlAccentBlueColor"
        case 5: name = "controlAccentPurpleColor"
        case 6: name = "controlAccentPinkColor"
        default: return nil // Unset and Multicolour leave Theme Designer editable.
        }
        let selector = NSSelectorFromString(name)
        guard NSColor.responds(to: selector),
              let color = NSColor.perform(selector)?.takeUnretainedValue() as? NSColor else { return nil }
        // Canonical light-appearance hues keep the background stable as macOS
        // changes appearance, while its native accent retains dynamic variants.
        var result: SakuraCordThemeColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            rgb.getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
            result = SakuraCordThemeColor(hue: hue, saturation: saturation)
        }
        return result
    }

    func apply(_ theme: SakuraCordGradientTheme, background: SakuraCordGradientTheme) {
        guard hasStarted else { return }
        let setter = NSSelectorFromString("_setAccentColor:")
        guard NSApp.responds(to: setter) else { return }
        // AppKit's private application-wide override updates native controls,
        // selections and focus rings together, on the main actor. Apply before
        // theme commit observers invalidate their cached presentation.
        let color = theme == .defaultTheme ? bundledAccentColor : accentColor(for: theme, background: background)
        NSApp.perform(setter, with: color)
    }

    private func accentColor(for theme: SakuraCordGradientTheme, background: SakuraCordGradientTheme) -> NSColor {
        let accent = theme.activeColors.first ?? SakuraCordGradientTheme.defaultTheme.colors[0]
        // Preserve Theme Designer's existing readable light/dark accent recipe.
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let source = SakuraCordThemeRGB(
                hue: accent.hue,
                saturation: accent.saturation,
                brightness: 0.82
            )
            return NSColor(background.readableForeground(source, for: isDark ? .dark : .light))
        }
    }
}
