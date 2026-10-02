import Foundation
import SakuraCordModels

nonisolated struct NativeTimelineMentionHover: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let characterIndex: Int
    let rawToken: String
}

nonisolated struct NativeTimelineTextLinkHover: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let characterIndex: Int
}

nonisolated struct NativeTimelineTextSpoilerHover: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let rangeLocation: Int
}

struct NativeTimelineMentionHitRegion {
    let characterIndex: Int
    let presentation: MentionPresentation
    let frame: CGRect
}

enum NativeTimelineMentionAppearance {
    static func backgroundAlpha(isHovered: Bool) -> CGFloat {
        isHovered ? 0.34 : 0.18
    }
}

nonisolated struct NativeTimelineComponentButtonTarget: Hashable {
    let messageID: MessageID
    let componentID: String
}

nonisolated struct NativeTimelineComponentSelectTarget: Hashable {
    let messageID: MessageID
    let componentID: String
}

nonisolated enum NativeTimelineComponentButtonVisualState {
    static let pressAnimationDuration: TimeInterval = 0.09

    static func scale(pressProgress: CGFloat) -> CGFloat {
        1 - 0.015 * min(max(pressProgress, 0), 1)
    }

    static func brightness(
        isHovered: Bool,
        pressProgress: CGFloat
    ) -> CGFloat {
        let pressProgress = min(max(pressProgress, 0), 1)
        let hoverBrightness: CGFloat = isHovered ? 0.035 : 0
        return hoverBrightness * (1 - pressProgress)
            - 0.07 * pressProgress
    }

    static func borderAlpha(
        isHovered: Bool,
        isEnabled: Bool
    ) -> CGFloat {
        isHovered && isEnabled ? 0.14 : 0.07
    }

    static func easeOut(_ progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return 1 - pow(1 - progress, 3)
    }
}

nonisolated enum TimelineButtonActivationPolicy {
    static func activates(
        pressed: NativeTimelineComponentButtonTarget?,
        released: NativeTimelineComponentButtonTarget?
    ) -> Bool {
        NativeTimelinePointerActivationPolicy.activates(
            pressed: pressed,
            released: released
        )
    }
}

nonisolated enum NativeTimelinePointerActivationTarget: Hashable {
    case loader
    case message(MessageID)
    case componentReveal(MessageID, String)
    case componentImage(MessageID, String)
    case componentMedia(MessageID, String)
    case componentFile(MessageID, String)
    case componentSelect(MessageID, String)
    case textMention(
        MessageID,
        NativeTimelineTextRegion,
        characterIndex: Int,
        rawToken: String
    )
    case textURL(
        MessageID,
        NativeTimelineTextRegion,
        characterIndex: Int,
        url: URL
    )
    case textSpoiler(
        MessageID,
        NativeTimelineTextRegion,
        rangeLocation: Int
    )
    case ephemeralDismiss(MessageID)
    case translationAction(MessageID)
    case authorProfile(MessageID)
    case invocationProfile(MessageID)
    case reply(MessageID, MessageID)
    case forwardedSource(MessageID, ChannelID, GuildID?, MessageID?)
    case linkedImage(MessageID, URL)
    case attachment(MessageID, String)
    case embedMedia(MessageID, String)
    case thread(MessageID, ChannelID)

    var supportsTextSelection: Bool {
        switch self {
        case .message, .textMention, .textURL:
            true
        default:
            false
        }
    }
}

nonisolated enum NativeTimelinePointerActivationPolicy {
    static func activates<T: Equatable>(
        pressed: T?,
        released: T?
    ) -> Bool {
        pressed != nil && pressed == released
    }
}

nonisolated enum NativeTimelineResultActivationPolicy {
    static func frame(
        for context: NativeTimelineMessageInteractionContext,
        searchCardFrame: CGRect?,
        highlightFrame: CGRect?
    ) -> CGRect? {
        switch context {
        case .searchResult:
            searchCardFrame
        case .pinnedResult, .inboxResult, .inboxMention:
            highlightFrame
        case .conversation:
            nil
        }
    }
}

nonisolated enum NativeTimelineAuthorProfileGeometry {
    static func hitFrames(
        avatarFrame: CGRect?,
        authorFrame: CGRect?
    ) -> [CGRect] {
        [avatarFrame, authorFrame].compactMap { $0 }
    }

    static func hitFrame(
        at point: CGPoint,
        avatarFrame: CGRect?,
        authorFrame: CGRect?
    ) -> CGRect? {
        hitFrames(
            avatarFrame: avatarFrame,
            authorFrame: authorFrame
        ).first(where: { $0.contains(point) })
    }
}

nonisolated enum NativeTimelineAvatarPresentation {
    static let decorationScale: CGFloat = 1.16

    static func decorationFrame(around avatarFrame: CGRect) -> CGRect {
        let width = avatarFrame.width * decorationScale
        let height = avatarFrame.height * decorationScale
        return CGRect(
            x: avatarFrame.midX - width / 2,
            y: avatarFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func replyAvatarFrame(in replyContentFrame: CGRect) -> CGRect {
        CGRect(
            x: replyContentFrame.minX,
            y: replyContentFrame.minY + 3,
            width: 14,
            height: 14
        )
    }

    static func shouldDecodeAnimation(for url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "gif", "apng":
            return true
        default:
            return URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.contains {
                $0.name == "animated"
                    && $0.value?.lowercased() == "true"
            } == true
        }
    }
}

nonisolated enum NativeTimelineScrollingRenderPolicy {
    static func usesDirectPainter(
        isScrolling: Bool,
        hasCachedBitmap: Bool,
        estimatedBitmapCost: Int,
        cacheCostLimit: Int
    ) -> Bool {
        isScrolling
            && !hasCachedBitmap
            && estimatedBitmapCost > cacheCostLimit / 2
    }
}

nonisolated enum NativeTimelineShortContentRedrawPolicy {
    static func redrawsSynchronously(
        conversationChanged: Bool,
        appendedAtTail: Bool
    ) -> Bool {
        appendedAtTail && !conversationChanged
    }
}

nonisolated struct NativeTimelineTextSelection: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let range: NSRange
}
