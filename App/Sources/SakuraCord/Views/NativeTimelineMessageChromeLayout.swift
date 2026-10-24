import AppKit
import CoreText
import MessageRendering
import SakuraCordModels
import Synchronization

nonisolated enum NativeTimelineReactionFonts {
    private static let cachedCount = Mutex<(pointSize: CGFloat, font: NSFont)?>(nil)

    static var count: NSFont {
        let pointSize = InterfaceScale.fontSize(
            NSFont.preferredFont(forTextStyle: .caption1).pointSize + 3
        )
        return cachedCount.withLock { cached in
            if let cached, cached.pointSize == pointSize { return cached.font }
            let font = AppPerformanceSignposts.measureSync(
                "TimelineReactionCountFontCacheMiss"
            ) {
                NSFont.systemFont(
                    ofSize: pointSize,
                    weight: .medium
                )
            }
            cached = (pointSize, font)
            return font
        }
    }
}

extension NativeTimelineRowLayout {
    static func commandInvocation(
        _ message: Message,
        origin: CGPoint,
        maximumWidth: CGFloat,
        cosmeticPolicy: ProfileCosmeticPolicy
    ) -> CommandInvocationRegion {
        let user = message.interactionMetadata?.user.map(cosmeticPolicy.user)
        let userLabel = user?.displayName ?? "Someone"
        let commandLabel = message.interactionMetadata?.displayName ?? "command"
        let userFont = ProfileNameFontLoader.shared.resolvedFont(for: user, fallback: .interfaceSystemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption2
            ).pointSize,
            weight: .semibold
        ))
        let captionFont = NSFont.interfacePreferredFont(
            forTextStyle: .caption1
        )
        let commandFont = NSFont.interfaceSystemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption1
            ).pointSize,
            weight: .semibold
        )
        let frame = CGRect(
            origin: origin,
            size: CGSize(
                width: maximumWidth,
                height: MessageRowLayoutMetrics.commandInvocationHeight
            )
        )
        let connectorFrame = CGRect(
            x: origin.x,
            y: origin.y,
            width: InterfaceScale.metric(30),
            height: MessageRowLayoutMetrics.commandInvocationHeight
        )
        var horizontalOffset = connectorFrame.maxX + 5
        let identityIconFrame = CGRect(
            x: horizontalOffset,
            y: origin.y + MessageRowLayoutMetrics.commandInvocationContentInset,
            width: InterfaceScale.metric(14),
            height: InterfaceScale.metric(14)
        )
        let avatarFrame = user == nil ? nil : identityIconFrame
        let fallbackAvatarFrame = user == nil ? identityIconFrame : nil
        horizontalOffset += InterfaceScale.metric(14) + 5
        let availableMaxX = frame.maxX - 48
        let userWidth = min(
            NativeTimelineRowLayout.measuredTextWidth(userLabel, font: userFont),
            max(0, availableMaxX - horizontalOffset)
        )
        let userFrame = CGRect(
            x: horizontalOffset,
            y: origin.y + InterfaceScale.metric(3),
            width: userWidth,
            height: InterfaceScale.metric(14)
        )
        horizontalOffset = userFrame.maxX + 5
        let usedWidth = min(
            NativeTimelineRowLayout.measuredTextWidth("used", font: captionFont),
            max(0, availableMaxX - horizontalOffset)
        )
        let usedFrame = CGRect(
            x: horizontalOffset,
            y: origin.y + InterfaceScale.metric(2),
            width: usedWidth,
            height: InterfaceScale.metric(16)
        )
        horizontalOffset = usedFrame.maxX + 5
        let pill = commandPill(
            label: commandLabel,
            font: commandFont,
            origin: CGPoint(x: horizontalOffset, y: origin.y + InterfaceScale.metric(2)),
            maximumWidth: max(0, availableMaxX - horizontalOffset)
        )
        let profileFrame = identityIconFrame.union(userFrame)
        return CommandInvocationRegion(
            frame: frame,
            connectorFrame: connectorFrame,
            avatarFrame: avatarFrame,
            fallbackAvatarFrame: fallbackAvatarFrame,
            profileFrame: profileFrame,
            userFrame: userFrame,
            usedFrame: usedFrame,
            pillFrame: pill.frame,
            commandSymbolFrame: pill.symbol,
            commandFrame: pill.text
        )
    }

    nonisolated private struct CommandPillRegion {
        let frame: CGRect
        let symbol: CGRect
        let text: CGRect
    }

    private static func commandPill(
        label: String,
        font: NSFont,
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> CommandPillRegion {
        let symbolWidth: CGFloat = InterfaceScale.metric(10)
        let horizontalPadding = InterfaceScale.metric(6)
        let symbolGap = InterfaceScale.metric(3)
        let naturalCommandWidth = NativeTimelineRowLayout.measuredTextWidth(
            label,
            font: font
        )
        let pillWidth = min(
            horizontalPadding + symbolWidth + symbolGap + naturalCommandWidth + horizontalPadding,
            maximumWidth
        )
        let pillFrame = CGRect(
            x: origin.x,
            y: origin.y,
            width: pillWidth,
            height: InterfaceScale.metric(16)
        )
        let commandSymbolFrame = CGRect(
            x: pillFrame.minX + horizontalPadding,
            y: pillFrame.minY + InterfaceScale.metric(3),
            width: symbolWidth,
            height: InterfaceScale.metric(10)
        )
        let commandFrame = CGRect(
            x: commandSymbolFrame.maxX + symbolGap,
            y: pillFrame.minY,
            width: max(0, pillFrame.maxX - horizontalPadding - commandSymbolFrame.maxX - symbolGap),
            height: InterfaceScale.metric(16)
        )
        return CommandPillRegion(frame: pillFrame, symbol: commandSymbolFrame, text: commandFrame)
    }

    static func ephemeral(
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> EphemeralRegion {
        let font = NSFont.interfacePreferredFont(forTextStyle: .caption1)
        let frame = CGRect(
            origin: origin,
            size: CGSize(width: maximumWidth, height: InterfaceScale.metric(15))
        )
        var horizontalOffset = origin.x
        let eyeFrame = CGRect(x: horizontalOffset, y: origin.y + 1, width: InterfaceScale.metric(13), height: InterfaceScale.metric(13))
        horizontalOffset = eyeFrame.maxX + 4
        let visibilityWidth = min(
            measuredTextWidth("Only you can see this", font: font),
            max(0, frame.maxX - horizontalOffset)
        )
        let visibilityFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: visibilityWidth,
            height: InterfaceScale.metric(15)
        )
        horizontalOffset = visibilityFrame.maxX + 4
        let bulletWidth = min(
            measuredTextWidth("•", font: font),
            max(0, frame.maxX - horizontalOffset)
        )
        let bulletFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: bulletWidth,
            height: InterfaceScale.metric(15)
        )
        horizontalOffset = bulletFrame.maxX + 4
        let dismissFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: min(
                measuredTextWidth("Dismiss message", font: font),
                max(0, frame.maxX - horizontalOffset)
            ),
            height: InterfaceScale.metric(15)
        )
        return EphemeralRegion(
            frame: frame,
            eyeFrame: eyeFrame,
            visibilityFrame: visibilityFrame,
            bulletFrame: bulletFrame,
            dismissFrame: dismissFrame
        )
    }

    static func reactionSize(_ reaction: Reaction) -> CGSize {
        let plan = MessageReactionPresentation.previewPlan(for: reaction)
        var width = MessageReactionMetrics.horizontalPadding * 2 + MessageReactionMetrics.emojiSize
        if reaction.count > 0 {
            width += MessageReactionMetrics.horizontalPadding + measuredTextWidth(
                String(reaction.count),
                font: NativeTimelineReactionFonts.count
            )
        }
        if !plan.isEmpty {
            width += MessageReactionMetrics.horizontalPadding + reactionPreviewWidth(plan)
        }
        return CGSize(
            width: ceil(width),
            height: MessageReactionMetrics.pillHeight
        )
    }

    private static func reactionPreviewWidth(
        _ plan: MessageReactionPreviewPlan
    ) -> CGFloat {
        plan.avatarCount == 0
            ? 0
            : MessageReactionMetrics.avatarSize
                + CGFloat(plan.avatarCount - 1) * MessageReactionMetrics.avatarStride
    }

    static func reactionRegion(
        _ reaction: Reaction,
        frame: CGRect
    ) -> ReactionRegion {
        var horizontalOffset = frame.minX + MessageReactionMetrics.horizontalPadding
        let emojiFrame = CGRect(
            x: horizontalOffset,
            y: frame.midY - MessageReactionMetrics.emojiSize / 2,
            width: MessageReactionMetrics.emojiSize,
            height: MessageReactionMetrics.emojiSize
        )
        horizontalOffset = emojiFrame.maxX

        var countFrame: CGRect?
        if reaction.count > 0 {
            horizontalOffset += MessageReactionMetrics.horizontalPadding
            let countWidth = measuredTextWidth(
                String(reaction.count),
                font: NativeTimelineReactionFonts.count
            )
            countFrame = CGRect(
                x: horizontalOffset,
                y: frame.minY,
                width: countWidth,
                height: frame.height
            )
            horizontalOffset += countWidth
        }

        let plan = MessageReactionPresentation.previewPlan(for: reaction)
        var avatars: [ReactionRegion.AvatarRegion] = []
        var placeholderAvatarFrames: [CGRect] = []
        if !plan.isEmpty {
            horizontalOffset += MessageReactionMetrics.horizontalPadding
            for index in 0 ..< plan.avatarCount {
                let avatarFrame = CGRect(
                    x: horizontalOffset + CGFloat(index) * MessageReactionMetrics.avatarStride,
                    y: frame.midY - MessageReactionMetrics.avatarSize / 2,
                    width: MessageReactionMetrics.avatarSize,
                    height: MessageReactionMetrics.avatarSize
                )
                if index < plan.reactors.count {
                    avatars.append(.init(frame: avatarFrame, reactor: plan.reactors[index]))
                } else {
                    placeholderAvatarFrames.append(avatarFrame)
                }
            }
        }

        return ReactionRegion(
            frame: frame,
            reaction: reaction,
            emojiFrame: emojiFrame,
            countFrame: countFrame,
            avatarRegions: avatars,
            placeholderAvatarFrames: placeholderAvatarFrames
        )
    }

}
