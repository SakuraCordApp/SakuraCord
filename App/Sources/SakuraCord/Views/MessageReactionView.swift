import AppKit
import SakuraCordModels
import SwiftUI

nonisolated enum MessageReactionMetrics {
    static let pillHeight: CGFloat = 28
    static let emojiSize: CGFloat = 18
    static let nativeEmojiVisualScale: CGFloat = 0.78
    static let avatarSize: CGFloat = 16
    static let maximumAvatarCount = 5
    static let avatarCountBeforeOverflow = 4
    static let horizontalSpacing: CGFloat = 4
    static let verticalSpacing: CGFloat = 4
}

nonisolated struct MessageReactionPreviewPlan: Equatable, Sendable {
    var reactors: [ReactionReactor]
    var overflowCount: Int

    var isEmpty: Bool {
        reactors.isEmpty && overflowCount == 0
    }
}

nonisolated struct MessageReactionPreviewLoadKey: Equatable, Hashable, Sendable {
    nonisolated struct Entry: Equatable, Hashable, Sendable {
        let reactionID: String
        let count: Int
    }

    let entries: [Entry]
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
        guard !knownReactors.isEmpty else {
            return MessageReactionPreviewPlan(reactors: [], overflowCount: 0)
        }
        if safeCount <= MessageReactionMetrics.maximumAvatarCount {
            return MessageReactionPreviewPlan(
                reactors: Array(knownReactors.prefix(MessageReactionMetrics.maximumAvatarCount)),
                overflowCount: 0
            )
        }
        let previews = Array(
            knownReactors.prefix(MessageReactionMetrics.avatarCountBeforeOverflow)
        )
        return MessageReactionPreviewPlan(
            reactors: previews,
            overflowCount: max(0, safeCount - previews.count)
        )
    }

    static func previewLoadKey(for reactions: [Reaction]) -> MessageReactionPreviewLoadKey {
        MessageReactionPreviewLoadKey(
            entries: items(from: reactions).map {
                MessageReactionPreviewLoadKey.Entry(reactionID: $0.id, count: $0.count)
            })
    }

    static func previewLoadCandidates(from reactions: [Reaction]) -> [Reaction] {
        items(from: reactions).filter { $0.reactors.isEmpty }
    }

    static func previewLoadKey(forPresented reactions: [Reaction]) -> MessageReactionPreviewLoadKey
    {
        MessageReactionPreviewLoadKey(
            entries: reactions.map {
                MessageReactionPreviewLoadKey.Entry(reactionID: $0.id, count: $0.count)
            })
    }

    static func previewLoadCandidates(fromPresented reactions: [Reaction]) -> [Reaction] {
        reactions.filter { $0.reactors.isEmpty }
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

    static func emojiURL(for reaction: Reaction, customEmojiURLsByID: [String: URL]) -> URL? {
        let reference = reaction.emojiReference
        guard let id = reference.id else { return nil }
        return customEmojiURLsByID[id] ?? reference.imageURL(size: 64)
    }

    static func tooltipDescription(for reaction: Reaction) -> String {
        switch tooltipSummary(for: reaction) {
        case .countOnly(let count):
            return "\(count) reactions"
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
            return "\(emoji), \(count) reactions"
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
    let customEmojiURLsByID: [String: URL]
    let react: (String) -> Void
    let loadReactors: (Reaction) async -> Void
    let addReactionControl: AddReactionControl

    init(
        reactions: [Reaction],
        customEmojiURLsByID: [String: URL],
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
    @State private var isHovered = false
    @State private var hoverAnchorSnapshot: ReactionHoverAnchorSnapshot?

    var body: some View {
        Button(action: react) {
            HStack(spacing: 4) {
                MessageReactionEmoji(
                    reaction: reaction,
                    url: emojiURL,
                    size: MessageReactionMetrics.emojiSize
                )
                Text(reaction.count, format: .number)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(reaction.didCurrentUserReact ? Color.accentColor : .primary)
                let previewPlan = MessageReactionPresentation.previewPlan(for: reaction)
                if !previewPlan.isEmpty {
                    MessageReactionAvatarStack(plan: previewPlan)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: MessageReactionMetrics.pillHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: reaction.didCurrentUserReact ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
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
            return Color.accentColor.opacity(isHovered ? 0.22 : 0.16)
        }
        return Color.primary.opacity(isHovered ? 0.14 : 0.09)
    }

    private var borderColor: Color {
        if reaction.didCurrentUserReact { return Color.accentColor.opacity(0.95) }
        return isHovered ? Color.primary.opacity(0.28) : .clear
    }
}

private struct MessageReactionEmoji: View {
    let reaction: Reaction
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if reaction.emojiReference.id != nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: "face.smiling")
                        .font(.system(size: size * 0.58, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let url {
                        AnimatedRemoteImage(
                            url: url,
                            fallbackSystemImage: "face.smiling",
                            fallbackInset: 3
                        )
                    }
                }
                .frame(width: size, height: size)
            } else {
                Text(reaction.emoji)
                    .font(.system(size: size))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .scaleEffect(MessageReactionMetrics.nativeEmojiVisualScale)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct MessageReactionAvatarStack: View {
    let plan: MessageReactionPreviewPlan

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: -5) {
                ForEach(plan.reactors) { reactor in
                    AvatarView(
                        name: reactor.displayName,
                        url: reactor.avatarURL,
                        size: MessageReactionMetrics.avatarSize
                    )
                    .overlay {
                        Circle().strokeBorder(Color.primary.opacity(0.24), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
                }
            }
            if plan.overflowCount > 0 {
                Text("+\(plan.overflowCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: MessageReactionMetrics.avatarSize)
                    .accessibilityLabel("\(plan.overflowCount) more reactors")
            }
        }
    }
}

struct MessageReactionTooltip: View {
    let reaction: Reaction
    let emojiURL: URL?

    var body: some View {
        HStack(spacing: 9) {
            MessageReactionEmoji(reaction: reaction, url: emojiURL, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(MessageReactionPresentation.emojiName(for: reaction))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(MessageReactionPresentation.tooltipDescription(for: reaction))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 260, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityHidden(true)
    }
}
