import DiscordProtocol
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct QuickReactionPolicyTests {
    private let guild = GuildID(rawValue: 1)
    private let otherGuild = GuildID(rawValue: 2)

    private func context(
        guildID: GuildID?, hasNitro: Bool = false, canUseExternalEmojis: Bool = true,
        skinTone: NativeEmojiSkinTone = .standard
    ) -> QuickReactionPolicy.Context {
        .init(
            guildID: guildID, premiumType: hasNitro ? 2 : 0, canUseExternalEmojis: canUseExternalEmojis, skinTone: skinTone
        )
    }

    @Test func emptyHistoryUsesDiscordsSeededReactionRanking() {
        let model = AppModel(launchMode: .offlineTesting)
        model.applyDiscordEmojiSettings(EmojiUserSettings(dataVersion: 1))
        let reactions = QuickReactionPolicy.reactions(
            rankedKeys: model.discordFrequentlyUsedReactionKeys, customEmojisByID: [:],
            existingReactions: [], context: context(guildID: guild)
        )
        #expect(reactions.map(\.token) == ["💯", "👍", "👎"])
        #expect(reactions.map(\.name) == ["100", "thumbsup", "thumbsdown"])
    }

    @Test func toneVariantsFoldToTheFirstBaseAndUseThePreferredTone() {
        let reactions = QuickReactionPolicy.reactions(
            rankedKeys: ["unknown_key", "thumbsup_tone3", "thumbsup", "heart", "joy", "eyes"],
            customEmojisByID: [:], existingReactions: [],
            context: context(guildID: nil, skinTone: .dark)
        )
        #expect(reactions.map(\.token) == ["👍🏿", "❤️", "😂"])
    }

    @Test func unusableCustomEmojiAreSkippedAndShortListsTakeDiscordsFallbacks() {
        let external = DiscordEmoji(id: "11", name: "external", guildID: otherGuild)
        let animated = DiscordEmoji(id: "12", name: "party", isAnimated: true, guildID: guild)
        let unavailable = DiscordEmoji(id: "13", name: "gone", guildID: guild, isAvailable: false)
        let local = DiscordEmoji(id: "14", name: "local", guildID: guild)
        let emojis = Dictionary(uniqueKeysWithValues: [external, animated, unavailable, local].map { ($0.id, $0) })
        let keys = ["11", "12", "13", "14", "laughing"]

        let withoutNitro = QuickReactionPolicy.reactions(
            rankedKeys: keys, customEmojisByID: emojis, existingReactions: [], context: context(guildID: guild)
        )
        // The fallback fills after filtering and does not repeat `laughing`.
        #expect(withoutNitro.map(\.token) == [local.messageToken, "😆", "💯"])

        let withNitro = QuickReactionPolicy.reactions(
            rankedKeys: keys, customEmojisByID: emojis, existingReactions: [],
            context: context(guildID: guild, hasNitro: true, canUseExternalEmojis: false)
        )
        #expect(withNitro.map(\.token) == [animated.messageToken, local.messageToken, "😆"])

        let inDirectMessage = QuickReactionPolicy.reactions(
            rankedKeys: keys, customEmojisByID: emojis, existingReactions: [], context: context(guildID: nil)
        )
        #expect(inDirectMessage.map(\.token) == ["😆", "💯", "💖"])
    }

    @Test func appliedReactionsKeepTheMessageTokenSoTheToggleRemovesThem() {
        let custom = DiscordEmoji(id: "21", name: "local", guildID: guild)
        let existing = [
            Reaction(emoji: "👍", count: 2, didCurrentUserReact: true),
            Reaction(emoji: "<:local:21>", count: 1, didCurrentUserReact: true),
            Reaction(emoji: "❤️", count: 4),
        ]
        let reactions = QuickReactionPolicy.reactions(
            rankedKeys: ["thumbsup", "21", "heart"], customEmojisByID: [custom.id: custom],
            existingReactions: existing, context: context(guildID: guild)
        )
        #expect(reactions.map(\.isApplied) == [true, true, false])
        #expect(reactions.map(\.token) == ["👍", "<:local:21>", "❤️"])
    }
}
