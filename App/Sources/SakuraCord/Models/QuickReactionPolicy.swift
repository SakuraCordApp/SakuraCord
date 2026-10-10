import Foundation
import SakuraCordModels

/// One emoji in the message hover toolbar's quick-reaction section.
nonisolated struct QuickReaction: Identifiable, Sendable {
    /// Tone-folded Unicode key or custom emoji ID.
    let id: String
    /// The reaction token for the shared toggle. An applied reaction keeps the
    /// message's own token so the toggle removes that exact reaction.
    let token: String
    /// Discord's tooltip name: the Unicode unique name or custom emoji name.
    let name: String
    let isApplied: Bool
}

/// Discord's message hover bar quick reactions: the reaction frecency list,
/// resolved and tone-folded, minus custom emoji that cannot be a new reaction
/// in this channel. Fewer than three usable entries are topped up with a fixed
/// fallback set before taking the first three.
enum QuickReactionPolicy {
    static let limit = 3

    struct Context {
        /// The message channel's guild; nil in DMs and group DMs.
        var guildID: GuildID?
        var premiumType: Int
        var canUseExternalEmojis: Bool
        var roleIDsByGuild: [GuildID: Set<RoleID>] = [:]
        var skinTone: NativeEmojiSkinTone = .standard
    }

    private enum Candidate {
        case native(key: String, value: String)
        case custom(DiscordEmoji)

        var foldedKey: String {
            switch self {
            case let .native(key, _): key
            case let .custom(emoji): emoji.id
            }
        }
    }

    private static let fallback = ["100", "laughing", "sparkling_heart"].compactMap {
        resolve($0, customEmojisByID: [:])
    }

    /// - Parameters:
    ///   - rankedKeys: Reaction frecency keys, highest first.
    ///   - customEmojisByID: Custom emoji the account can resolve.
    static func reactions(
        rankedKeys: [String],
        customEmojisByID: [String: DiscordEmoji],
        existingReactions: [Reaction],
        context: Context
    ) -> [QuickReaction] {
        let resolved = rankedKeys.lazy
            .compactMap { resolve($0, customEmojisByID: customEmojisByID) }
            .prefix(EmojiFrecencyKeys.frequentlyUsedCandidateLimit)
        let usable = folded(Array(resolved)).filter { isUsable($0, context: context) }
        return folded(usable + fallback).prefix(limit).map {
            quickReaction(for: $0, existingReactions: existingReactions, skinTone: context.skinTone)
        }
    }

    private static func resolve(_ key: String, customEmojisByID: [String: DiscordEmoji]) -> Candidate? {
        if let emoji = customEmojisByID[key] { return .custom(emoji) }
        let base = EmojiFrecencyKeys.baseKey(key)
        guard let value = EmojiFrecencyKeys.value(for: base) else { return nil }
        return .native(key: base, value: value)
    }

    /// Keeps each base emoji or custom ID at its first position.
    private static func folded(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.foldedKey).inserted }
    }

    /// SakuraCord's reaction rule, so a shown emoji passes the toggle guard,
    /// plus Discord's channel filters: Use External Emojis in servers,
    /// availability and role restrictions.
    private static func isUsable(_ candidate: Candidate, context: Context) -> Bool {
        guard case let .custom(emoji) = candidate else { return true }
        let isExternal = context.guildID != nil && emoji.guildID != context.guildID
        guard emoji.isAvailable, !isExternal || context.canUseExternalEmojis,
              DiscordEmojiPermissionPolicy.canShow(
                  emoji, for: .reaction(guildID: context.guildID), premiumType: context.premiumType
              )
        else { return false }
        guard !emoji.roleIDs.isEmpty else { return true }
        return context.roleIDsByGuild[emoji.guildID].map { !$0.isDisjoint(with: emoji.roleIDs) } ?? false
    }

    private static func quickReaction(
        for candidate: Candidate,
        existingReactions: [Reaction],
        skinTone: NativeEmojiSkinTone
    ) -> QuickReaction {
        let token: String
        let name: String
        switch candidate {
        case let .native(key, value):
            token = NativeEmojiPickerIndex.emoji(forValue: value)?.value(for: skinTone) ?? value
            name = key
        case let .custom(emoji):
            token = emoji.messageToken
            name = emoji.name
        }
        let applied = EmojiFrecencyKeys.reactionKey(token).flatMap { key in
            existingReactions.first { $0.didCurrentUserReact && EmojiFrecencyKeys.reactionKey($0.emoji) == key }
        }
        return QuickReaction(
            id: candidate.foldedKey,
            token: applied?.emoji ?? token,
            name: name,
            isApplied: applied != nil
        )
    }
}
