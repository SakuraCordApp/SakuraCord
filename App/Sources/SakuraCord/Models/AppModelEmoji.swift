import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// Official EmojiStore resolves role-usable custom emoji before its cap.
    /// Purchasable subscription emoji remain resolvable for locked previews.
    func canResolveFrequentlyUsedEmoji(_ emoji: DiscordEmoji) -> Bool {
        guard !emoji.roleIDs.isEmpty else { return true }
        guard let memberRoles = currentUserRoleIDsByGuild[emoji.guildID] else { return false }
        if !memberRoles.isDisjoint(with: emoji.roleIDs) { return true }
        guard serverRailGuildsByID[emoji.guildID]?.features.contains("ROLE_SUBSCRIPTIONS_ENABLED") == true else { return false }
        let roles = guildRolesByGuildID[emoji.guildID] ?? (emoji.guildID == selectedGuildID ? guildRoles : [])
        return roles.contains { $0.isPurchasableSubscription == true && emoji.roleIDs.contains($0.id) }
    }

    func loadEmojis(for guildID: GuildID) async {
        guard emojisByGuild[guildID] == nil, !loadingEmojiGuildIDs.contains(guildID) else { return }
        let session = accountSession()
        loadingEmojiGuildIDs.insert(guildID)
        defer {
            if isCurrentAccountSession(session) {
                loadingEmojiGuildIDs.remove(guildID)
            }
        }
        do {
            let emojis = try await session.provider.emojis(in: guildID)
            guard isCurrentAccountSession(session) else { return }
            applyEmojis(emojis, to: guildID)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            emojiLoadErrorsByGuild[guildID] = error.localizedDescription
        }
    }

    func applyEmojis(_ emojis: [DiscordEmoji], to guildID: GuildID) {
        emojisByGuild[guildID] = emojis
        for emoji in emojis {
            ComposerEmojiImageStore.shared.register(emoji)
        }
        emojiLoadErrorsByGuild[guildID] = nil
    }

    func applyEmojiUpdate(
        upserted: [DiscordEmoji],
        deletedIDs: [String],
        to guildID: GuildID
    ) {
        guard let existing = emojisByGuild[guildID] else {
            // Discord can send a delta when its official client has a cached base.
            // SakuraCord deliberately leaves this guild unresolved so the existing
            // coalesced REST fallback can obtain a complete catalog.
            return
        }
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for id in deletedIDs {
            byID[id] = nil
        }
        for emoji in upserted {
            byID[emoji.id] = emoji
        }
        applyEmojis(
            byID.values.sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            },
            to: guildID
        )
    }

    func retryEmojis(for guildID: GuildID) async {
        emojisByGuild[guildID] = nil
        emojiLoadErrorsByGuild[guildID] = nil
        await loadEmojis(for: guildID)
    }

    func loadDiscordEmojiSettings() async {
        guard !didAttemptDiscordEmojiSettings || emojiSettingsLoadTask != nil else { return }
        let session = accountSession()
        didAttemptDiscordEmojiSettings = true
        let loading: Task<EmojiUserSettings?, Never>
        if let task = emojiSettingsLoadTask {
            loading = task
        } else {
            loading = Task { try? await session.provider.emojiUserSettings() }
            emojiSettingsLoadTask = loading
        }
        let settings = await loading.value
        guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
        emojiSettingsLoadTask = nil
        if let settings { applyDiscordEmojiSettings(settings) }
        // Destination discovery is local once bootstrap state is available.
        // A failed or timed-out settings enrichment must not leave Forward on
        // an infinite loading state; persisted local deltas still provide the
        // best available frecency signal until the next authenticated session.
        hasLoadedDiscordEmojiSettings = true
        applyPersistedDiscordFrecencyUsageDeltas()
        forwardSearchSourceRevision &+= 1
    }

    func applyDiscordEmojiSettings(_ settings: EmojiUserSettings) {
        if let version = settings.dataVersion, let current = emojiSettingsDataVersion, version < current { return }
        if let version = settings.dataVersion, let deferred = deferredEmojiSettings?.dataVersion, version < deferred { return }
        discordFavoriteEmojiKeys = settings.favoriteKeys
        if emojiFrecencySaveTask != nil {
            deferredEmojiSettings = settings
        } else { updateEmojiFrecency(settings) }
        discordGuildAndChannelUsageScores = settings.guildAndChannelUsageScores
        discordSyncedGuildAndChannelUsageScores = settings.guildAndChannelUsageScores
        discordGuildAndChannelUsage = settings.guildAndChannelUsage
        discordGuildAndChannelUsageOrder = settings.guildAndChannelUsageOrder
    }

    @discardableResult
    func setEmojiFavorite(
        discordKey: String,
        isFavorite: Bool
    ) async -> Bool {
        if emojiFrecency.hasPendingUsage || reactionEmojiFrecency.hasPendingUsage || emojiFrecencySaveTask != nil {
            return await flushEmojiFrecencyIfNeeded(favoriteKey: discordKey, isFavorite: isFavorite)
        }
        let session = accountSession()
        do {
            let settings = try await session.provider.setEmojiFavorite(discordKey, isFavorite: isFavorite)
            guard isCurrentAccountSession(session) else { return false }
            applyDiscordEmojiSettings(settings)
            hasLoadedDiscordEmojiSettings = true
            forwardSearchSourceRevision &+= 1
            return true
        } catch { return false }
    }

    func canComposeEmoji(_ emoji: DiscordEmoji) -> Bool {
        featuresSettings.fakeNitroEmojis
            || DiscordEmojiPermissionPolicy.hasNitro(premiumType: currentUser?.premiumType ?? 0)
            || (!emoji.isAnimated && emoji.guildID == selectedGuildID)
    }

    var composerCustomEmojis: [DiscordEmoji] {
        featuresSettings.fakeNitroEmojis ? orderedCustomEmojis : orderedCustomEmojis.filter(canComposeEmoji)
    }

    func composerText(for emoji: DiscordEmoji) -> String {
        DiscordEmojiPermissionPolicy.composerText(
            for: emoji,
            currentGuildID: selectedGuildID,
            premiumType: snapshot?.currentUser.premiumType ?? 0,
            fakeNitroEnabled: featuresSettings.fakeNitroEmojis
        )
    }

    /// Invalidates asynchronous work and presentation state owned by the
    /// current account. IDs are not sufficient guards here because Discord
    /// guild, channel, and thread IDs remain identical when the same account
    /// reconnects through a replacement provider.
}
