import AppKit
import Foundation

nonisolated enum SakuraCordDeepLinkAction: Hashable, Sendable {
    case openSettings(SettingsDeepLinkDestination)
    case sendDiagnostics
    case checkForUpdates
    case applyTheme(SakuraCordSharedTheme)
    case updateToApplyTheme(preview: SakuraCordSharedTheme?)
    case startIssueReport(IssueReportKind?)

    var title: String {
        switch self {
        case .startIssueReport(.bug):
            "Report a Bug"
        case .startIssueReport(.feature):
            "Suggest a Feature"
        case .startIssueReport(nil):
            "Report a Bug or Suggest a Feature"
        case let .openSettings(destination):
            destination.title
        case .sendDiagnostics:
            "Send Diagnostics"
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
        case .openSettings:
            "Open SakuraCord Settings."
        case .sendDiagnostics:
            "Send sanitised local diagnostics to this conversation after confirmation."
        case .checkForUpdates:
            "Ask SakuraCord to check its signed update feed without leaving the conversation."
        case .applyTheme:
            "Apply this shared SakuraCord theme."
        case .updateToApplyTheme:
            "Update SakuraCord to use this newer theme format."
        case .startIssueReport:
            "File it from SakuraCord with your Discord account."
        }
    }

    var buttonTitle: String {
        switch self {
        case .openSettings:
            "Open Settings"
        case .sendDiagnostics:
            "Send Diagnostics…"
        case .checkForUpdates, .updateToApplyTheme:
            "Check for Updates"
        case .applyTheme:
            "Apply Theme"
        case .startIssueReport(.bug):
            "Report a Bug…"
        case .startIssueReport(.feature):
            "Suggest a Feature…"
        case .startIssueReport(nil):
            "Get Started…"
        }
    }

    var systemImage: String {
        switch self {
        case .startIssueReport(.feature):
            "lightbulb.max.fill"
        case .startIssueReport:
            "ladybug.fill"
        case let .openSettings(destination):
            destination.metadata.systemImage
        case .sendDiagnostics:
            "doc.text.magnifyingglass"
        case .checkForUpdates, .updateToApplyTheme:
            "arrow.triangle.2.circlepath"
        case .applyTheme:
            "paintpalette.fill"
        }
    }

    var componentID: String {
        switch self {
        case let .openSettings(destination):
            "sakuracord-settings-\(destination.page.rawValue)-\(destination.controlID?.rawValue ?? "overview")"
        case .sendDiagnostics:
            "sakuracord-send-diagnostics"
        case .checkForUpdates:
            "sakuracord-deeplink-check-for-updates"
        case .applyTheme:
            "sakuracord-deeplink-apply-theme"
        case .updateToApplyTheme:
            "sakuracord-deeplink-update-to-apply-theme"
        case let .startIssueReport(kind):
            "sakuracord-deeplink-report-\(kind?.rawValue ?? "any")"
        }
    }

    var themePreview: SakuraCordSharedTheme? {
        switch self {
        case .openSettings, .sendDiagnostics, .startIssueReport:
            nil
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
        case let .openSettings(destination):
            "Opens \(destination.title) in SakuraCord Settings"
        case .sendDiagnostics:
            "Asks to send sanitised local diagnostics to this conversation"
        case .checkForUpdates:
            "Checks SakuraCord's signed update feed"
        case .applyTheme:
            "Applies the shared SakuraCord theme"
        case .updateToApplyTheme:
            "Checks for an update that supports this theme"
        case .startIssueReport(.feature):
            "Opens SakuraCord's feature suggestion form"
        case .startIssueReport:
            "Opens SakuraCord's bug report form"
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
        if pathComponents == ["report"] {
            // Older Help-menu links also carry prefilled diagnostics; SakuraCord fills its own.
            let type = components.queryItems?.last { $0.name == "type" }?.value
            return .startIssueReport(type.flatMap(IssueReportKind.init(rawValue:)))
        }
        if pathComponents == ["settings", "update"] {
            return .checkForUpdates
        }
        if pathComponents == ["settings", "diagnostics", "send"] {
            guard components.query == nil, components.fragment == nil else { return nil }
            return .sendDiagnostics
        }
        if let destination = SettingsDeepLinkDestination.parse(pathComponents) {
            return .openSettings(destination)
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
    private static var maximumWidth: CGFloat { InterfaceScale.metric(560) }
    private static var preferredButtonWidth: CGFloat { InterfaceScale.metric(196) }
    private static var horizontalInset: CGFloat { InterfaceScale.metric(14) }
    private static var symbolSize: CGFloat { InterfaceScale.metric(32) }
    private static var itemSpacing: CGFloat { InterfaceScale.metric(11) }
    private static var compactRowSpacing: CGFloat { InterfaceScale.metric(10) }
    private static var titleFont: NSFont {
        NSFont.interfaceSystemFont(ofSize: 14, weight: .semibold)
    }

    static func make(
        _ deepLink: SakuraCordDeepLink,
        componentIndex: Int,
        origin: CGPoint,
        maximumWidth: CGFloat,
        integratesWithBubble: Bool = false
    ) -> NativeTimelineRowLayout.SakuraCordDeepLinkRegion {
        let hasPalette = deepLink.action.themePreview != nil
        let inset = integratesWithBubble ? 0 : horizontalInset
        let width = max(1, min(Self.maximumWidth, maximumWidth))
        let titleXOffset = inset + symbolSize + itemSpacing
        let regularHorizontalSpace = max(
            1,
            width - titleXOffset - itemSpacing - inset
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
            ? inset
                + compactHeaderHeight
                + compactRowSpacing
                + NativeTimelineComponentButtonMetrics.height
                + inset
            : integratesWithBubble ? (hasPalette ? 52 : 40) : hasPalette ? 74 : 56
        let frame = CGRect(
            origin: origin,
            size: CGSize(
                width: width,
                height: cardHeight
            )
        )
        let cardFrame = frame
        let leading = cardFrame.minX + inset
        let headerTop = cardFrame.minY + inset
        let symbolBackgroundFrame = CGRect(
            x: leading,
            y: usesCompactLayout
                ? headerTop + (compactHeaderHeight - symbolSize) / 2
                : cardFrame.midY - symbolSize / 2,
            width: symbolSize,
            height: symbolSize
        )
        let symbolFrame = CGRect(
            x: symbolBackgroundFrame.midX - InterfaceScale.metric(11),
            y: symbolBackgroundFrame.midY - InterfaceScale.metric(11),
            width: InterfaceScale.metric(22),
            height: InterfaceScale.metric(22)
        )
        let titleX = symbolBackgroundFrame.maxX + itemSpacing
        let buttonFrame = buttonFrame(
            usesCompactLayout: usesCompactLayout,
            cardFrame: cardFrame,
            headerTop: headerTop,
            compactHeaderHeight: compactHeaderHeight,
            minimumButtonWidth: minimumButtonWidth,
            titleWidth: titleWidth,
            inset: inset
        )
        let titleFrame = CGRect(
            x: titleX,
            y: usesCompactLayout
                ? headerTop + (hasPalette ? 0 : InterfaceScale.metric(6))
                : cardFrame.midY - (hasPalette ? InterfaceScale.metric(18) : InterfaceScale.metric(10)),
            width: max(
                1,
                (usesCompactLayout ? cardFrame.maxX - inset : buttonFrame.minX - itemSpacing)
                    - titleX
            ),
            height: InterfaceScale.metric(20)
        )
        let paletteFrames: [CGRect]
        if let preview = deepLink.action.themePreview {
            let diameter: CGFloat = InterfaceScale.metric(15)
            let step: CGFloat = 10
            paletteFrames = preview.theme.activeColors.indices.map { index in
                CGRect(
                    x: titleX + CGFloat(index) * step,
                    y: usesCompactLayout
                        ? headerTop + InterfaceScale.metric(23)
                        : cardFrame.midY + InterfaceScale.metric(6),
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
        minimumButtonWidth: CGFloat,
        titleWidth: CGFloat,
        inset: CGFloat
    ) -> CGRect {
        let regularHorizontalSpace = max(1, cardFrame.width - inset * 2 - symbolSize - itemSpacing * 2)
        if usesCompactLayout {
            return CGRect(
                x: cardFrame.minX + inset,
                y: headerTop + compactHeaderHeight + compactRowSpacing,
                width: max(1, cardFrame.width - inset * 2),
                height: NativeTimelineComponentButtonMetrics.height
            )
        }
        let width = min(
            preferredButtonWidth,
            max(minimumButtonWidth, regularHorizontalSpace - titleWidth)
        )
        return CGRect(
            x: cardFrame.maxX - inset - width,
            y: cardFrame.midY
                - NativeTimelineComponentButtonMetrics.height / 2,
            width: width,
            height: NativeTimelineComponentButtonMetrics.height
        )
    }
}
