import AppKit
import SakuraCordModels
import SwiftUI

nonisolated enum MessageReactionMetrics {
    static var pillHeight: CGFloat { InterfaceScale.metric(28) }
    static var emojiSize: CGFloat { InterfaceScale.metric(18) }
    static var avatarSize: CGFloat { InterfaceScale.metric(16) }
    static let maximumAvatarCount = 4
    static var horizontalPadding: CGFloat { InterfaceScale.metric(6) }
    static var avatarStride: CGFloat { avatarSize - InterfaceScale.metric(5) }
    static var horizontalSpacing: CGFloat { InterfaceScale.metric(4) }
    static var verticalSpacing: CGFloat { InterfaceScale.metric(4) }
}

nonisolated struct MessageReactionPreviewPlan: Equatable, Sendable {
    var reactors: [ReactionReactor]
    var placeholderCount: Int

    var avatarCount: Int {
        reactors.count + placeholderCount
    }

    var isEmpty: Bool {
        avatarCount == 0
    }
}

nonisolated struct MessageReactionPreviewLoadKey: Equatable, Hashable, Sendable {
    nonisolated struct Entry: Equatable, Hashable, Sendable {
        let reactionID: String
        let count: Int
    }

    let entries: [Entry]
}

nonisolated struct MessageReactionAutomaticLoadKey: Equatable, Hashable, Sendable {
    let reactionID: String
    let count: Int
    let needsLoad: Bool
}

nonisolated enum MessageReactionTooltipSummary: Equatable, Sendable {
    case countOnly(Int)
    case knownReactors(names: [String], remainingCount: Int)
}

nonisolated enum MessageReactionPresentation {
    static func items(from reactions: [Reaction]) -> [Reaction] {
        var result: [Reaction] = []
        var indicesByID: [String: Int] = [:]

        for reaction in reactions
        where reaction.count > 0
            && !reaction.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let normalized = normalized(reaction)
            if let index = indicesByID[normalized.id] {
                result[index].count = max(result[index].count, normalized.count)
                result[index].didCurrentUserReact =
                    result[index].didCurrentUserReact || normalized.didCurrentUserReact
                result[index].reactors = uniqueReactors(
                    result[index].reactors + normalized.reactors,
                    maximumCount: max(result[index].count, normalized.count)
                )
            } else {
                indicesByID[normalized.id] = result.count
                result.append(normalized)
            }
        }
        return result
    }

    static func previewPlan(for reaction: Reaction) -> MessageReactionPreviewPlan {
        let safeCount = max(0, reaction.count)
        let knownReactors = uniqueReactors(reaction.reactors, maximumCount: safeCount)
        // Reserve every preview slot before reactor metadata or images arrive.
        let avatarCount = min(safeCount, MessageReactionMetrics.maximumAvatarCount)
        let previews = Array(knownReactors.prefix(avatarCount))
        return MessageReactionPreviewPlan(
            reactors: previews,
            placeholderCount: avatarCount - previews.count
        )
    }

    static func previewLoadKey(for reactions: [Reaction]) -> MessageReactionPreviewLoadKey {
        MessageReactionPreviewLoadKey(
            entries: items(from: reactions).map {
                MessageReactionPreviewLoadKey.Entry(reactionID: $0.id, count: $0.count)
            })
    }

    static func needsPreviewLoad(_ reaction: Reaction) -> Bool {
        previewPlan(for: reaction).placeholderCount > 0
    }

    static func previewLoadCandidates(from reactions: [Reaction]) -> [Reaction] {
        items(from: reactions).filter(needsPreviewLoad)
    }

    static func previewLoadKey(forPresented reactions: [Reaction]) -> MessageReactionPreviewLoadKey
    {
        MessageReactionPreviewLoadKey(
            entries: reactions.map {
                MessageReactionPreviewLoadKey.Entry(reactionID: $0.id, count: $0.count)
            })
    }

    static func previewLoadCandidates(fromPresented reactions: [Reaction]) -> [Reaction] {
        reactions.filter(needsPreviewLoad)
    }

    static func tooltipSummary(for reaction: Reaction) -> MessageReactionTooltipSummary {
        let reactors = uniqueReactors(reaction.reactors, maximumCount: reaction.count)
        guard !reactors.isEmpty else { return .countOnly(reaction.count) }
        return .knownReactors(
            names: reactors.map(\.displayName),
            remainingCount: max(0, reaction.count - reactors.count)
        )
    }

    static func emojiLabel(for reaction: Reaction) -> String {
        let reference = reaction.emojiReference
        return reference.id == nil ? reference.name : reference.accessibilityLabel
    }

    @MainActor static func emojiName(for reaction: Reaction) -> String {
        let reference = reaction.emojiReference
        if reference.id != nil {
            return ":\(reference.name):"
        }
        return NativeEmojiCatalogMetadata.shortcode(for: reference.name) ?? reference.name
    }

    static func emojiURL(for reaction: Reaction, customEmojiURLsByID: CustomEmojiImageURLs) -> URL? {
        let reference = reaction.emojiReference
        guard let id = reference.id else { return nil }
        return customEmojiURLsByID[id] ?? reference.imageURL(size: 64)
    }

    static func tooltipDescription(for reaction: Reaction) -> String {
        switch tooltipSummary(for: reaction) {
        case .countOnly(let count):
            return count == 0 ? "No reactions yet" : "\(count) reactions"
        case .knownReactors(let names, let remainingCount):
            let knownNames = names.formatted(.list(type: .and))
            if remainingCount > 0 {
                return "Reacted by \(knownNames), and \(remainingCount) others"
            }
            return "Reacted by \(knownNames)"
        }
    }

    static func accessibilityLabel(for reaction: Reaction) -> String {
        let emoji = emojiLabel(for: reaction)
        switch tooltipSummary(for: reaction) {
        case .countOnly(let count):
            return count == 0 ? "\(emoji), no reactions yet" : "\(emoji), \(count) reactions"
        case .knownReactors(let names, let remainingCount):
            let knownNames = names.formatted(.list(type: .and))
            if remainingCount > 0 {
                return "\(emoji), reacted by \(knownNames) and \(remainingCount) others"
            }
            return "\(emoji), reacted by \(knownNames)"
        }
    }

    private static func normalized(_ reaction: Reaction) -> Reaction {
        var result = reaction
        result.reactors = uniqueReactors(reaction.reactors, maximumCount: reaction.count)
        return result
    }

    private static func uniqueReactors(
        _ reactors: [ReactionReactor], maximumCount: Int
    ) -> [ReactionReactor] {
        guard maximumCount > 0 else { return [] }
        var seen: Set<UserID> = []
        var result: [ReactionReactor] = []
        for reactor in reactors where seen.insert(reactor.id).inserted {
            result.append(reactor)
            if result.count == maximumCount { break }
        }
        return result
    }
}

struct MessageReactionStrip<AddReactionControl: View>: View {
    let reactions: [Reaction]
    let customEmojiURLsByID: CustomEmojiImageURLs
    let react: (String) -> Void
    let loadReactors: (Reaction) async -> Void
    let addReactionControl: AddReactionControl

    init(
        reactions: [Reaction],
        customEmojiURLsByID: CustomEmojiImageURLs,
        react: @escaping (String) -> Void,
        loadReactors: @escaping (Reaction) async -> Void,
        @ViewBuilder addReactionControl: () -> AddReactionControl
    ) {
        self.reactions = reactions
        self.customEmojiURLsByID = customEmojiURLsByID
        self.react = react
        self.loadReactors = loadReactors
        self.addReactionControl = addReactionControl()
    }

    var body: some View {
        EmojiWrappingLayout(
            horizontalSpacing: MessageReactionMetrics.horizontalSpacing,
            verticalSpacing: MessageReactionMetrics.verticalSpacing
        ) {
            ForEach(reactions) { reaction in
                MessageReactionPill(
                    reaction: reaction,
                    emojiURL: MessageReactionPresentation.emojiURL(
                        for: reaction,
                        customEmojiURLsByID: customEmojiURLsByID
                    ),
                    react: { react(reaction.emoji) },
                    loadReactors: { await loadReactors(reaction) }
                )
            }
            addReactionControl
        }
        .task(id: MessageReactionPresentation.previewLoadKey(forPresented: reactions)) {
            for reaction in MessageReactionPresentation.previewLoadCandidates(
                fromPresented: reactions
            ) {
                guard !Task.isCancelled else { return }
                await loadReactors(reaction)
            }
        }
    }
}

struct MessageReactionPill: View {
    let reaction: Reaction
    let emojiURL: URL?
    let react: () -> Void
    let loadReactors: () async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var hoverAnchorSnapshot: ReactionHoverAnchorSnapshot?

    var body: some View {
        Button(action: react) {
            HStack(spacing: MessageReactionMetrics.horizontalPadding) {
                MessageReactionEmoji(
                    reaction: reaction,
                    url: emojiURL,
                    size: MessageReactionMetrics.emojiSize
                )
                if reaction.count > 0 {
                    Text(String(reaction.count))
                        .font(Font(NativeTimelineReactionFonts.count))
                        .foregroundStyle(
                            reaction.didCurrentUserReact ? SakuraCordAccentColor.color : .primary
                        )
                        .contentTransition(.numericText(value: Double(reaction.count)))
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.24),
                            value: reaction.count
                        )
                }
                let previewPlan = MessageReactionPresentation.previewPlan(for: reaction)
                if !previewPlan.isEmpty {
                    MessageReactionAvatarStack(plan: previewPlan)
                }
            }
            .padding(.horizontal, MessageReactionMetrics.horizontalPadding)
            .frame(height: MessageReactionMetrics.pillHeight)
            .background(
                ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay {
                ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
                    .padding(0.5)
            }
            .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
        }
        .buttonStyle(.plain)
        .task(
            id: MessageReactionAutomaticLoadKey(
                reactionID: reaction.id,
                count: reaction.count,
                needsLoad: MessageReactionPresentation.needsPreviewLoad(reaction)
            )
        ) {
            guard MessageReactionPresentation.needsPreviewLoad(reaction) else { return }
            await loadReactors()
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                let beganHovering = !isHovered
                isHovered = true
                hoverAnchorSnapshot = ReactionHoverAnchorSnapshot(
                    mouseLocationInScreen: NSEvent.mouseLocation,
                    mouseLocationInPill: location
                )
                if beganHovering {
                    Task { await loadReactors() }
                }
            case .ended:
                isHovered = false
                hoverAnchorSnapshot = nil
            }
        }
        .reactionHoverDetail(
            isPresented: $isHovered,
            anchorSnapshot: hoverAnchorSnapshot
        ) {
            MessageReactionTooltip(reaction: reaction, emojiURL: emojiURL)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MessageReactionPresentation.accessibilityLabel(for: reaction))
        .accessibilityValue(reaction.didCurrentUserReact ? "You reacted" : "You have not reacted")
        .accessibilityHint(
            reaction.didCurrentUserReact ? "Remove your reaction" : "Add the same reaction"
        )
    }

    private var backgroundColor: Color {
        if reaction.didCurrentUserReact {
            return SakuraCordAccentColor.color.opacity(isHovered ? 0.22 : 0.16)
        }
        return Color.primary.opacity(isHovered ? 0.14 : 0.09)
    }

    private var borderColor: Color {
        if reaction.didCurrentUserReact {
            return SakuraCordAccentColor.color.opacity(0.95)
        }
        return isHovered ? Color.primary.opacity(0.28) : .clear
    }
}

struct MessageReactionEmoji: View {
    let reaction: Reaction
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if reaction.emojiReference.id != nil {
                Group {
                    if let url {
                        AnimatedRemoteImage(
                            url: url,
                            fallbackSystemImage: SakuraCordSystemSymbol.emojiFaceGrinning,
                            fallbackInset: 3,
                        )
                    } else {
                        ZStack {
                            ConcentricRectangle(cornerRadius: InterfaceScale.metric(5), style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                            SakuraCordSystemSymbol.emojiFaceGrinningImage
                                .font(.system(size: size * 0.58, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: size, height: size)
            } else {
                // Match timeline reactions: center the visible glyph, not its text line box.
                Image(nsImage: ComponentUnicodeEmojiRenderer.image(for: reaction.emoji))
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: size,
                        height: size
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct MessageReactionAvatarStack: View {
    let plan: MessageReactionPreviewPlan

    var body: some View {
        HStack(spacing: MessageReactionMetrics.avatarStride - MessageReactionMetrics.avatarSize) {
            ForEach(0 ..< plan.avatarCount, id: \.self) { index in
                let reactor = index < plan.reactors.count ? plan.reactors[index] : nil
                Group {
                    if let reactor {
                        AvatarView(
                            name: reactor.displayName,
                            url: reactor.avatarURL,
                            size: MessageReactionMetrics.avatarSize
                        )
                        .background {
                            Circle().fill(Color(nsColor: .quaternaryLabelColor))
                        }
                    } else {
                        Circle()
                            .fill(Color(nsColor: .quaternaryLabelColor))
                            .frame(
                                width: MessageReactionMetrics.avatarSize,
                                height: MessageReactionMetrics.avatarSize
                            )
                    }
                }
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.24), lineWidth: 1)
                }
                .accessibilityHidden(true)
            }
        }
    }
}

struct MessageReactionTooltip: View {
    let reaction: Reaction
    let emojiURL: URL?

    var body: some View {
        HStack(spacing: InterfaceScale.metric(9)) {
            MessageReactionEmoji(reaction: reaction, url: emojiURL, size: InterfaceScale.metric(30))
            VStack(alignment: .leading, spacing: 1) {
                Text(MessageReactionPresentation.emojiName(for: reaction))
                    .font(.interface(.caption).weight(.semibold))
                    .lineLimit(1)
                Text(MessageReactionPresentation.tooltipDescription(for: reaction))
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: InterfaceScale.metric(260), alignment: .leading)
        .padding(.horizontal, InterfaceScale.metric(12))
        .padding(.vertical, InterfaceScale.metric(10))
        // The tooltip floats over messages and the composer; a backing keeps
        // its text legible while the popover glass still picks up the tint.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.78))
        .accessibilityHidden(true)
    }
}
