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

    static func all(in content: String) -> [SakuraCordDeepLink] {
        content.components(separatedBy: tokenSeparators).compactMap { rawCandidate in
            let candidate = rawCandidate.trimmingCharacters(
                in: trailingPunctuation
            )
            guard let url = URL(string: candidate),
                  let action = action(for: url)
            else { return nil }
            return SakuraCordDeepLink(url: url, action: action)
        }
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
    private static let maximumWidth: CGFloat = 560
    private static let preferredButtonWidth: CGFloat = 196
    private static let horizontalInset: CGFloat = 14
    private static let symbolSize: CGFloat = 32
    private static let itemSpacing: CGFloat = 11
    private static let compactRowSpacing: CGFloat = 10
    private static let titleFont = NSFont.systemFont(
        ofSize: 14,
        weight: .semibold
    )

    static func make(
        _ deepLink: SakuraCordDeepLink,
        componentIndex: Int,
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> NativeTimelineRowLayout.SakuraCordDeepLinkRegion {
        let hasPalette = deepLink.action.themePreview != nil
        let width = min(Self.maximumWidth, maximumWidth)
        let cardWidth = max(1, width - 12)
        let titleXOffset = horizontalInset + symbolSize + itemSpacing
        let regularHorizontalSpace = max(
            1,
            cardWidth - titleXOffset - itemSpacing - horizontalInset
        )
        let titleWidth = measuredWidth(
            deepLink.action.title,
            font: titleFont
        )
        let minimumButtonWidth = minimumButtonWidth(
            for: deepLink.action.buttonTitle
        )
        let usesCompactLayout = regularHorizontalSpace
            < titleWidth + minimumButtonWidth
        let compactHeaderHeight: CGFloat = hasPalette ? 38 : symbolSize
        let cardHeight: CGFloat = usesCompactLayout
            ? horizontalInset
                + compactHeaderHeight
                + compactRowSpacing
                + NativeTimelineComponentButtonMetrics.height
                + horizontalInset
            : hasPalette ? 74 : 56
        let frame = CGRect(
            origin: origin,
            size: CGSize(
                width: width,
                height: cardHeight + 12
            )
        )
        let cardFrame = frame.insetBy(dx: 6, dy: 6)
        let leading = cardFrame.minX + horizontalInset
        let headerTop = cardFrame.minY + horizontalInset
        let symbolBackgroundFrame = CGRect(
            x: leading,
            y: usesCompactLayout
                ? headerTop + (compactHeaderHeight - symbolSize) / 2
                : cardFrame.midY - symbolSize / 2,
            width: symbolSize,
            height: symbolSize
        )
        let symbolFrame = CGRect(
            x: symbolBackgroundFrame.midX - 11,
            y: symbolBackgroundFrame.midY - 11,
            width: 22,
            height: 22
        )
        let titleX = symbolBackgroundFrame.maxX + itemSpacing
        let buttonFrame = buttonFrame(
            usesCompactLayout: usesCompactLayout,
            cardFrame: cardFrame,
            headerTop: headerTop,
            compactHeaderHeight: compactHeaderHeight,
            regularHorizontalSpace: regularHorizontalSpace,
            minimumButtonWidth: minimumButtonWidth,
            titleWidth: titleWidth
        )
        let titleFrame = CGRect(
            x: titleX,
            y: usesCompactLayout
                ? headerTop + (hasPalette ? 0 : 6)
                : cardFrame.midY - (hasPalette ? 18 : 10),
            width: max(
                1,
                (usesCompactLayout ? cardFrame.maxX - horizontalInset : buttonFrame.minX - itemSpacing)
                    - titleX
            ),
            height: 20
        )
        let paletteFrames: [CGRect]
        if let preview = deepLink.action.themePreview {
            let diameter: CGFloat = 15
            let step: CGFloat = 10
            paletteFrames = preview.theme.activeColors.indices.map { index in
                CGRect(
                    x: titleX + CGFloat(index) * step,
                    y: usesCompactLayout
                        ? headerTop + 23
                        : cardFrame.midY + 6,
                    width: diameter,
                    height: diameter
                )
            }
        } else {
            paletteFrames = []
        }
        return .init(
            action: deepLink.action,
            componentID: "\(deepLink.action.componentID)-\(componentIndex)",
            frame: frame,
            cardFrame: cardFrame,
            symbolBackgroundFrame: symbolBackgroundFrame,
            symbolFrame: symbolFrame,
            titleFrame: titleFrame,
            paletteFrames: paletteFrames,
            buttonFrame: buttonFrame
        )
    }

    private static func measuredWidth(_ value: String, font: NSFont) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func minimumButtonWidth(for title: String) -> CGFloat {
        min(
            preferredButtonWidth,
            measuredWidth(
                title,
                font: NativeTimelineComponentButtonMetrics.font
            ) + 30
        )
    }

    private static func buttonFrame(
        usesCompactLayout: Bool,
        cardFrame: CGRect,
        headerTop: CGFloat,
        compactHeaderHeight: CGFloat,
        regularHorizontalSpace: CGFloat,
        minimumButtonWidth: CGFloat,
        titleWidth: CGFloat
    ) -> CGRect {
        if usesCompactLayout {
            return CGRect(
                x: cardFrame.minX + horizontalInset,
                y: headerTop + compactHeaderHeight + compactRowSpacing,
                width: max(1, cardFrame.width - horizontalInset * 2),
                height: NativeTimelineComponentButtonMetrics.height
            )
        }
        let width = min(
            preferredButtonWidth,
            max(minimumButtonWidth, regularHorizontalSpace - titleWidth)
        )
        return CGRect(
            x: cardFrame.maxX - horizontalInset - width,
            y: cardFrame.midY
                - NativeTimelineComponentButtonMetrics.height / 2,
            width: width,
            height: NativeTimelineComponentButtonMetrics.height
        )
    }
}
