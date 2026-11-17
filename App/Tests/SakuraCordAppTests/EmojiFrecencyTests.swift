import DiscordProtocol
@testable import DiscordProtocolTestSupport
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct EmojiFrecencyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func messageAndReactionRankingMatchDiscord() {
        let time: UInt64 = 1_800_000_000_000
        let history = DiscordFrecencyHistory(entries: [
            .init(key: "turtle", totalUses: 20, recentUses: [time - 20 * 86_400_000, time]),
            .init(key: "snake", totalUses: 3, recentUses: [time, time, time]),
            .init(key: "100", totalUses: 3, recentUses: [time, time, time]),
            .init(key: "empty", totalUses: 100, recentUses: []),
        ])
        let messages = DiscordFrecencyStore(kind: .emoji, now: { now })
        let reactions = DiscordFrecencyStore(kind: .reaction, now: { now })
        messages.overwrite(with: history)
        reactions.overwrite(with: history)
        #expect(messages.frequently == ["turtle", "100", "snake"])
        #expect(messages.score(for: "turtle") == 150)
        #expect(messages.historyForSave().entries.first(where: { $0.key == "turtle" })?.frecency == 1_500)
        // Maximum total uses is measured before entries with no samples are pruned.
        #expect(reactions.frequently == ["100", "snake", "turtle"])
        #expect(reactions.historyForSave().entries.first(where: { $0.key == "turtle" })?.frecency == 160)
        #expect(reactions.historyForSave().entries.first(where: { $0.key == "snake" })?.frecency == 246)
    }

    @Test func emojiIdentityAndSendParsingMatchOfficialCapture() {
        let custom = DiscordEmoji(id: "123456789012345678", name: "sample", guildID: GuildID(rawValue: 1))
        let content = "🐢 🐢 🐍 👋🏽 `🐢` <:sample:123456789012345678>\n```\n🐍\n```"
        #expect(EmojiFrecencyKeys.messageKeys(in: content, customEmojis: [custom]) == [
            "turtle", "turtle", "snake", "wave_tone3", custom.id,
        ])
        #expect(EmojiFrecencyKeys.baseKey("wave_tone3") == "wave")
        #expect(EmojiFrecencyKeys.reactionKey("👋🏽") == "wave_tone3")
        #expect(EmojiFrecencyKeys.reactionKey("sample:123456789012345678") == custom.id)
    }

    @Test func sharedSettingsSaveRetainsFailuresAndOnlyAcknowledgesItsCapturedUses() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        model.applyDiscordEmojiSettings(EmojiUserSettings(dataVersion: 1))
        model.recordMessageEmojiUsage("🐢")
        let session = model.accountSession()
        let failed = try #require(await model.prepareEmojiFrecencyContribution(session: session))
        await failed.complete(nil)
        #expect(model.emojiFrecency.pendingUsages.count == 1)
        let saving = try #require(await model.prepareEmojiFrecencyContribution(session: session))
        #expect(await model.prepareEmojiFrecencyContribution(session: session) == nil)
        let stored = EmojiUserSettings(dataVersion: 2, messageHistory: saving.messages, reactionHistory: saving.reactions)
        model.applyDiscordEmojiSettings(stored)
        model.recordReactionEmojiUsage("🐢")
        await saving.complete(stored)
        #expect(model.emojiFrecencySaveTask == nil)
        #expect(model.emojiFrecency.pendingUsages.count == 1)
        #expect(model.reactionEmojiFrecency.pendingUsages.count == 1)
        #expect(model.emojiFrecency.historyForSave().entries.first { $0.key == "turtle" }?.totalUses == 2)
    }

    @Test func incomingHistoryReplaysPendingUsageAndPickerCapsResolvedCandidates() {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        let timestamp = UInt64(now.timeIntervalSince1970 * 1_000)
        let entries = NativeEmojiPickerIndex.allItems.prefix(45).enumerated().map { index, item in
            DiscordFrecencyEntry(key: item.discordKey, totalUses: 100 - index, recentUses: [timestamp])
        }
        model.applyDiscordEmojiSettings(EmojiUserSettings(dataVersion: 10, messageHistory: .init(entries: entries)))
        model.recordReactionEmojiUsage("🐢")
        let updated = EmojiUserSettings(dataVersion: 11, messageHistory: .init(entries: [
            .init(key: "turtle", totalUses: 9, recentUses: [timestamp]),
            .init(key: "wave_tone3", totalUses: 5, recentUses: [timestamp]),
            .init(key: "wave", totalUses: 4, recentUses: [timestamp]),
        ] + entries))
        model.applyDiscordEmojiSettings(updated)
        #expect(model.emojiFrecency.historyForSave().entries.first(where: { $0.key == "turtle" })?.totalUses == 10)
        #expect(model.reactionEmojiFrecency.pendingUsages.count == 1)
        model.applyDiscordEmojiSettings(EmojiUserSettings(dataVersion: 9))
        #expect(model.emojiSettingsDataVersion == 11)
        let document = EmojiPickerDocumentStore()
        document.synchronize(with: model, useCase: .message)
        let cells = document.selectableCells.filter { $0.rowID.hasPrefix("emojis:frequent:") }
        #expect(cells.count == 42)
        model.discordFrequentlyUsedEmojiKeys = ["wave_tone3", "wave"] + Array(entries.prefix(42).map(\.key))
        document.synchronize(with: model, useCase: .message)
        let folded = document.selectableCells.filter { $0.rowID.hasPrefix("emojis:frequent:") }
        #expect(folded.count == 41)
        #expect(folded.first?.item.discordKey == "wave")
        // Known but unavailable custom emoji consume a slot before filtering.
        let unavailable = DiscordEmoji(id: "123456789012345678", name: "unavailable", guildID: GuildID(rawValue: 1), isAvailable: false)
        model.orderedCustomEmojis = [unavailable]
        model.discordFrequentlyUsedEmojiKeys = [unavailable.id] + entries.map(\.key)
        document.synchronize(with: model, useCase: .message)
        let available = document.selectableCells.filter { $0.rowID.hasPrefix("emojis:frequent:") }
        #expect(available.count == 41)
        #expect(available.map(\.item.discordKey) == Array(entries.prefix(41).map(\.key)))
        // Role-ineligible emoji are unresolved before the cap, unlike boost
        // availability. Purchasable subscription roles allow locked previews.
        var restricted = unavailable
        let roleID = RoleID(rawValue: 7)
        restricted.roleIDs = [roleID]
        model.orderedCustomEmojis = [restricted]
        document.synchronize(with: model, useCase: .message)
        #expect(document.selectableCells.filter { $0.rowID.hasPrefix("emojis:frequent:") }.count == 42)
        model.currentUserRoleIDsByGuild[restricted.guildID] = [roleID]
        document.synchronize(with: model, useCase: .message)
        #expect(document.selectableCells.filter { $0.rowID.hasPrefix("emojis:frequent:") }.count == 41)
        model.currentUserRoleIDsByGuild[restricted.guildID] = []
        model.serverRailGuildsByID[restricted.guildID] = Guild(id: restricted.guildID, name: "Subscriptions", features: [GuildFeature.roleSubscriptionsEnabled])
        model.guildRolesByGuildID[restricted.guildID] = [GuildRole(id: roleID, name: "Subscriber", isPurchasableSubscription: true)]
        #expect(model.canResolveFrequentlyUsedEmoji(restricted))
        model.serverRailGuildsByID[restricted.guildID]?.features = []
        #expect(!model.canResolveFrequentlyUsedEmoji(restricted))
        // Live reaction comparison: search aliases must not substitute snail
        // for bug or love_letter for heart (or mark those substitutes favorite).
        model.discordFrequentlyUsedReactionKeys = ["bug", "heart"]
        model.discordFavoriteEmojiKeys = ["bug", "heart"]
        document.synchronize(with: model, useCase: .reaction(guildID: nil))
        let identities = document.selectableCells.filter { $0.rowID.hasPrefix("emojis:frequent:") }
        #expect(identities.map(\.item.discordKey) == ["bug", "heart"])
        for item in NativeEmojiPickerIndex.allItems where ["snail", "love_letter"].contains(item.discordKey) {
            #expect(!document.isFavorite(item))
        }
        // An account switch must clear both projections and unsaved in-memory usage.
        model.configureEmojiFrecency(scope: "other-account")
        #expect(!model.emojiFrecency.hasPendingUsage && !model.reactionEmojiFrecency.hasPendingUsage)
        #expect(model.discordFrequentlyUsedEmojiKeys.isEmpty)
        model.recordReactionEmojiUsage("🐢")
        model.resetAccountPresentationState()
        #expect(model.discordFrequentlyUsedEmojiKeys == ["turtle"])
        #expect(model.discordFrequentlyUsedReactionKeys == ["turtle"])
    }
}
