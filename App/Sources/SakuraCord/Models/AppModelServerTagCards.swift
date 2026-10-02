import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

/// Server profiles opened from a user's server tag.
@Observable
final class ServerTagCardStore {
    struct Entry {
        enum Content {
            case loaded(GuildProfile)
            case restricted
            case failed(String)
        }

        var content: Content?
        var games: [ProfileGame] = []
        var adaptiveColor: UInt32?
        var actionError: String?
        var isLoading = false
        var updatedAt = Date.distantPast

        var profile: GuildProfile? {
            if case let .loaded(profile) = content { profile } else { nil }
        }
    }

    enum Action: Equatable {
        case goToServer, join
    }

    var entries: [GuildID: Entry] = [:]
    var joining: Set<GuildID> = []

    func reset() {
        entries = [:]
        joining = []
    }
}

extension AppModel {
    func loadServerTagCard(_ guildID: GuildID) {
        let store = serverTagCards
        guard !accountTransitionIsActive else { return }
        if let entry = store.entries[guildID] {
            let isFresh: Bool = if case .failed = entry.content { false } else { Date.now.timeIntervalSince(entry.updatedAt) <= 300 }
            guard !entry.isLoading, !isFresh else { return }
        }
        if store.entries.count >= 64,
           let oldest = store.entries.filter({ !$0.value.isLoading }).min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            store.entries[oldest] = nil
        }
        store.entries[guildID, default: .init()].isLoading = true
        store.entries[guildID]?.actionError = nil
        startAccountChildTask(account: accountSession()) { model, account in
            let content: ServerTagCardStore.Entry.Content
            do {
                content = try await .loaded(account.provider.guildProfile(in: guildID))
            } catch GuildProfileError.restricted {
                content = .restricted
            } catch {
                content = .failed(error.localizedDescription)
            }
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            let previous = model.serverTagCards.entries[guildID]
            model.serverTagCards.entries[guildID] = .init(content: content, games: previous?.games ?? [],
                                                          adaptiveColor: previous?.adaptiveColor, updatedAt: .now)
            guard case let .loaded(profile) = content else { return }
            // Show the profile first; games and the adaptive banner color only enrich it.
            // The first-party card shows the five most active games.
            let gameIDs = Array(profile.rankedGameApplicationIDs.prefix(5))
            async let games = gameIDs.isEmpty ? [] : (try? await account.provider.profileWidgetGames(ids: gameIDs)) ?? []
            async let color = Self.serverTagCardAdaptiveColor(profile)
            let (loadedGames, adaptiveColor) = await (games, color)
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            model.serverTagCards.entries[guildID]?.games = loadedGames
            model.serverTagCards.entries[guildID]?.adaptiveColor = adaptiveColor
        }
    }

    /// The icon's dominant color stands in for a missing brand color, as on invite cards.
    private static func serverTagCardAdaptiveColor(_ profile: GuildProfile) async -> UInt32? {
        guard profile.brandColor == nil, profile.bannerURL == nil, let url = profile.iconURL else { return nil }
        return try? await ProfileAvatarPaletteLoader.shared.colors(url).first
    }

    func serverTagCardAction(for profile: GuildProfile) -> ServerTagCardStore.Action? {
        if serverRailGuildsByID[profile.id] != nil { return .goToServer }
        // Manual-approval applications remain delegated to Discord.
        return profile.isDirectlyJoinable ? .join : nil
    }

    /// Returns `true` when the card's server is now selected.
    func activateServerTagCard(_ guildID: GuildID) async -> Bool {
        let store = serverTagCards
        guard let profile = store.entries[guildID]?.profile, let action = serverTagCardAction(for: profile) else { return false }
        if action == .goToServer {
            guard serverRailGuildsByID[guildID]?.isUnavailable == false else { return false }
            navigateToServerTagGuild(guildID)
            return true
        }
        if profile.features.contains("MEMBER_VERIFICATION_GATE_ENABLED") {
            store.entries[guildID]?.actionError = "This server requires member screening. Join it in Discord, then return to SakuraCord."
            return false
        }
        guard store.joining.insert(guildID).inserted else { return false }
        let session = accountSession()
        store.entries[guildID]?.actionError = nil
        defer {
            if isCurrentAccountSession(session) { store.joining.remove(guildID) }
        }
        do {
            let requiresVerification = try await session.provider.joinDiscoverableGuild(guildID) { [weak self] challenge in
                guard let self else { throw CancellationError() }
                return try await self.solveInviteCaptcha(challenge, account: session)
            }
            guard isCurrentAccountSession(session), !Task.isCancelled else { return false }
            if requiresVerification {
                throw ServerInviteError.unsupported("Discord requires verification to finish joining. Complete it in Discord, then return to SakuraCord.")
            }
            guard let guild = try await awaitJoinedGuild(guildID, account: session) else { return false }
            navigateToServerTagGuild(guildID)
            if guild.features.contains("GUILD_ONBOARDING") { openChannelsAndRoles(in: guildID) }
            return true
        } catch {
            guard isCurrentAccountSession(session), !(error is CancellationError) else { return false }
            store.entries[guildID]?.actionError = error.localizedDescription
            return false
        }
    }

    private func navigateToServerTagGuild(_ guildID: GuildID) {
        dismissContextualProfile()
        dismissExpandedProfile()
        startConversationNavigation { model, account in
            await model.activateGuild(guildID, account: account)
        }
    }
}
