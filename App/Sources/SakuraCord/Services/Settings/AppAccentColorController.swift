import AppKit
import QuartzCore

/// Installs the theme colour as the app's real system accent. AppKit and
/// SwiftUI then derive every accent colour from it (control fills, selections,
/// focus rings, system effects, inactive states) exactly as for a macOS accent.
@MainActor
@Observable
final class AppAccentColorController {
    static let shared = AppAccentColorController()

    /// The colour installed as the system accent, which
    /// `NSColor.controlAccentColor` resolves to once `start()` has run.
    private(set) var accent: NSColor
    /// The label colour for text drawn on `accent`, worked out once per install.
    private(set) var labelOnAccent: NSColor
    @ObservationIgnored private var installed: SakuraCordThemeRGB?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var frameLink: CADisplayLink?

    private init() {
        let accent = NSColor(SakuraCordThemeStore.shared.activeTheme.accentRGB)
        self.accent = accent
        labelOnAccent = SakuraCordAccentColor.labelNSColor(on: accent)
    }

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
        hasStarted = true
        apply()
    }

    /// Installs the active theme's accent now. Theme commits call this before
    /// their observers invalidate cached presentation; live edits in between
    /// are coalesced to one install per display frame.
    func apply() {
        guard hasStarted else { return }
        frameLink?.invalidate()
        frameLink = nil
        let themeStore = SakuraCordThemeStore.shared
        let rgb = withObservationTracking {
            themeStore.activeTheme.accentRGB
        } onChange: {
            Task { @MainActor in AppAccentColorController.shared.scheduleApply() }
        }
        guard rgb != installed else { return }
        let setter = NSSelectorFromString("_setAccentColor:")
        guard NSApp.responds(to: setter) else { return }
        let color = NSColor(rgb)
        NSApp.perform(setter, with: color)
        installed = rgb
        accent = color
        labelOnAccent = SakuraCordAccentColor.labelNSColor(on: color)
    }

    private func scheduleApply() {
        guard frameLink == nil,
              let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        else { return }
        let link = screen.displayLink(target: FrameTarget.shared, selector: #selector(FrameTarget.fire))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    private final class FrameTarget: NSObject {
        static let shared = FrameTarget()

        @objc func fire(_ link: CADisplayLink) {
            MainActor.assumeIsolated { AppAccentColorController.shared.apply() }
        }
    }
}
