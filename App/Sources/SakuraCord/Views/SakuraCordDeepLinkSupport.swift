import AppKit
import Foundation

nonisolated enum SakuraCordDeepLinkAction: Hashable, Sendable {
    case checkForUpdates
    case applyTheme(SakuraCordSharedTheme)
    case updateToApplyTheme(preview: SakuraCordSharedTheme?)

    var title: String {
        switch self {
        case .checkForUpdates:
            "Update SakuraCord"
        case .applyTheme:
            "Apply Theme"
        case .updateToApplyTheme:
            "Update SakuraCord to Apply Theme"
        }
    }

    var description: String {
        switch self {
        case .checkForUpdates:
            "Ask SakuraCord to check its signed update feed without leaving the conversation."
        case .applyTheme:
            "Apply this shared SakuraCord theme."
        case .updateToApplyTheme:
            "Update SakuraCord to use this newer theme format."
        }
    }

    var buttonTitle: String {
        switch self {
        case .checkForUpdates, .updateToApplyTheme:
            "Check for Updates"
        case .applyTheme:
            "Apply Theme"
        }
    }

    var systemImage: String {
        switch self {
        case .checkForUpdates, .updateToApplyTheme:
            "arrow.triangle.2.circlepath"
        case .applyTheme:
            "paintpalette.fill"
        }
    }

    var componentID: String {
        switch self {
        case .checkForUpdates:
            "sakuracord-deeplink-check-for-updates"
        case .applyTheme:
            "sakuracord-deeplink-apply-theme"
        case .updateToApplyTheme:
            "sakuracord-deeplink-update-to-apply-theme"
        }
    }

    var themePreview: SakuraCordSharedTheme? {
        switch self {
        case .checkForUpdates:
            nil
        case let .applyTheme(theme):
            theme
        case let .updateToApplyTheme(preview):
            preview
        }
    }

    var accessibilityHelp: String {
        switch self {
        case .checkForUpdates:
            "Checks SakuraCord's signed update feed"
        case .applyTheme:
            "Applies the shared SakuraCord theme"
        case .updateToApplyTheme:
            "Checks for an update that supports this theme"
        }
    }
}

nonisolated struct SakuraCordDeepLink: Equatable, Sendable {
    let url: URL
    let action: SakuraCordDeepLinkAction
}

nonisolated enum SakuraCordDeepLinkPresentation {
    private static let tokenSeparators =
        CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "<>[](){}\"'`")
        )
    private static let trailingPunctuation =
        CharacterSet(charactersIn: ".,;:!?")

    static func first(in content: String) -> SakuraCordDeepLink? {
        for rawCandidate in content.components(separatedBy: tokenSeparators) {
            let candidate = rawCandidate.trimmingCharacters(
                in: trailingPunctuation
            )
            guard let url = URL(string: candidate),
                  let action = action(for: url)
            else { continue }
            return SakuraCordDeepLink(url: url, action: action)
        }
        return nil
    }

    static func action(for url: URL) -> SakuraCordDeepLinkAction? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "sakuracord.app",
              components.user == nil,
              components.password == nil,
              components.port == nil
        else { return nil }

        let pathComponents = components.path.split(separator: "/")
        if pathComponents == ["settings", "update"] {
            return .checkForUpdates
        }
        guard pathComponents.count == 3,
              pathComponents[0] == "settings",
              pathComponents[1] == "themes"
        else { return nil }

        return switch SakuraCordThemeShareCodec.decode(
            String(pathComponents[2])
        ) {
        case let .current(theme):
            .applyTheme(theme)
        case let .requiresNewerClient(preview):
            .updateToApplyTheme(preview: preview)
        case nil:
            nil
        }
    }
}

enum NativeTimelineSakuraCordDeepLinkLayout {
    static func make(
        _ deepLink: SakuraCordDeepLink,
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> NativeTimelineRowLayout.SakuraCordDeepLinkRegion {
        let hasPalette = deepLink.action.themePreview != nil
        let frame = CGRect(
            origin: origin,
            size: CGSize(
                width: min(560, maximumWidth),
                height: hasPalette ? 86 : 68
            )
        )
        let cardFrame = frame.insetBy(dx: 6, dy: 6)
        let leading = cardFrame.minX + 14
        let symbolBackgroundFrame = CGRect(
            x: leading,
            y: cardFrame.midY - 16,
            width: 32,
            height: 32
        )
        let symbolFrame = CGRect(
            x: symbolBackgroundFrame.midX - 11,
            y: symbolBackgroundFrame.midY - 11,
            width: 22,
            height: 22
        )
        let trailing: CGFloat = 14
        let titleX = symbolBackgroundFrame.maxX + 11
        let maximumButtonWidth = max(
            1,
            cardFrame.maxX - titleX - 11 - trailing
        )
        let buttonWidth = min(196, maximumButtonWidth)
        let buttonFrame = CGRect(
            x: cardFrame.maxX - trailing - buttonWidth,
            y: cardFrame.midY - 16,
            width: buttonWidth,
            height: NativeTimelineComponentButtonMetrics.height
        )
        let titleFrame = CGRect(
            x: titleX,
            y: cardFrame.midY - (hasPalette ? 18 : 10),
            width: max(1, buttonFrame.minX - titleX - 11),
            height: 20
        )
        let paletteFrames: [CGRect]
        if let preview = deepLink.action.themePreview {
            let diameter: CGFloat = 15
            let step: CGFloat = 10
            paletteFrames = preview.theme.activeColors.indices.map { index in
                CGRect(
                    x: titleX + CGFloat(index) * step,
                    y: cardFrame.midY + 6,
                    width: diameter,
                    height: diameter
                )
            }
        } else {
            paletteFrames = []
        }
        return .init(
            action: deepLink.action,
            frame: frame,
            cardFrame: cardFrame,
            symbolBackgroundFrame: symbolBackgroundFrame,
            symbolFrame: symbolFrame,
            titleFrame: titleFrame,
            paletteFrames: paletteFrames,
            buttonFrame: buttonFrame
        )
    }
}
