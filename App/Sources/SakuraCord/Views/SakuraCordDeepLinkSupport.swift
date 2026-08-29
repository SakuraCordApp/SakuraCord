import AppKit
import Foundation

nonisolated enum SakuraCordDeepLinkAction: Hashable, Sendable {
    case checkForUpdates

    var title: String {
        switch self {
        case .checkForUpdates:
            "Check for SakuraCord Updates"
        }
    }

    var description: String {
        switch self {
        case .checkForUpdates:
            "Ask SakuraCord to check its signed update feed without leaving the conversation."
        }
    }

    var buttonTitle: String {
        switch self {
        case .checkForUpdates:
            "Check for SakuraCord Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .checkForUpdates:
            "arrow.triangle.2.circlepath"
        }
    }

    var componentID: String {
        switch self {
        case .checkForUpdates:
            "sakuracord-deeplink-check-for-updates"
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

        return switch components.path {
        case "/settings/update", "/settings/update/":
            .checkForUpdates
        default:
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
        let frame = CGRect(
            origin: origin,
            size: CGSize(
                width: min(560, maximumWidth),
                height: 68
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
            y: cardFrame.midY - 10,
            width: max(1, buttonFrame.minX - titleX - 11),
            height: 20
        )
        return .init(
            action: deepLink.action,
            frame: frame,
            cardFrame: cardFrame,
            symbolBackgroundFrame: symbolBackgroundFrame,
            symbolFrame: symbolFrame,
            titleFrame: titleFrame,
            buttonFrame: buttonFrame
        )
    }
}
