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
                result[index].reactors = (result[index].reactors + normalized.reactors)
                    .uniqueReactors(limit: max(result[index].count, normalized.count))
            } else {
                indicesByID[normalized.id] = result.count
                result.append(normalized)
            }
        }
        return result
    }

    static func previewPlan(for reaction: Reaction) -> MessageReactionPreviewPlan {
        let safeCount = max(0, reaction.count)
        let knownReactors = reaction.reactors.uniqueReactors(limit: safeCount)
        // Reserve every preview slot before reactor metadata or images arrive.
        let avatarCount = min(safeCount, MessageReactionMetrics.maximumAvatarCount)
        let previews = Array(knownReactors.prefix(avatarCount))
        return MessageReactionPreviewPlan(
            reactors: previews,
            placeholderCount: avatarCount - previews.count
        )
    }

    static func needsPreviewLoad(_ reaction: Reaction) -> Bool {
        previewPlan(for: reaction).placeholderCount > 0
    }

    static func previewLoadCandidates(fromPresented reactions: [Reaction]) -> [Reaction] {
        reactions.filter(needsPreviewLoad)
    }

    static func tooltipSummary(for reaction: Reaction) -> MessageReactionTooltipSummary {
        let reactors = reaction.reactors.uniqueReactors(limit: reaction.count)
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
        result.reactors = reaction.reactors.uniqueReactors(limit: reaction.count)
        return result
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
        .accessibilityHidden(true)
    }
}
