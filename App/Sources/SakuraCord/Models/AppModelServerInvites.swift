import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

@Observable
final class ServerInvitePresentationStore {
    struct Entry: Equatable {
        var invite: ServerInvite?
        var adaptiveColor: UInt32?
        var error: String?
        var isUnavailable = false
        var isLoading = false
        var updatedAt = Date.distantPast
    }

    static let changed = Notification.Name("SakuraCord.serverInvitesChanged")
    var entries: [ServerInviteReference: Entry] = [:]
    var joining: Set<GuildID> = []
    var leaving: Set<GuildID> = []
    var expanded: Set<ServerInviteReference> = []
    let captcha = ServerInviteCaptchaStore()
    var showsJoinDialog = false
    var leaveConfirmation: Guild?
    var leaveError: String?
    @ObservationIgnored var queue: [ServerInviteReference] = []
    @ObservationIgnored var activeLoads = 0
    @ObservationIgnored var revision: UInt64 = 0

    func changed(_ reference: ServerInviteReference? = nil) {
        revision &+= 1
        NotificationCenter.default.post(name: Self.changed, object: self,
                                        userInfo: reference.map { ["reference": $0] })
    }

    func reset() {
        captcha.cancel()
        entries = [:]
        joining = []
        leaving = []
        expanded = []
        queue = []
        activeLoads = 0
        showsJoinDialog = false
        leaveConfirmation = nil
        leaveError = nil
        changed()
    }
}

extension AppModel {
    func updateServerRailMembership(replacing previous: [GuildID: Guild]) {
        serverRailPresentation.updateAvailableGuildIDs(serverRailGuildsByID.keys)
        for guildID in previous.keys where serverRailGuildsByID[guildID] == nil {
            onboarding.entries[guildID] = nil
            onboarding.members[guildID] = nil
            onboarding.guides[guildID] = nil
            onboarding.channelSelections[guildID] = nil
            if onboarding.presentedGuildID == guildID { onboarding.presentedGuildID = nil }
        }
        if previous.mapValues(\.isUnavailable) != serverRailGuildsByID.mapValues(\.isUnavailable) {
            serverInvites.changed()
        }
    }

    func loadServerInvite(_ reference: ServerInviteReference, refresh: Bool = false) {
        let store = serverInvites
        guard !accountTransitionIsActive, store.queue.count < 64 else { return }
        if let entry = store.entries[reference] {
            guard !entry.isLoading,
                  refresh || Date.now.timeIntervalSince(entry.updatedAt) > 300 else { return }
        }
        if store.entries.count >= 256,
           let oldest = store.entries.filter({ !$0.value.isLoading })
            .min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            store.entries[oldest] = nil
            store.expanded.remove(oldest)
        }
        var entry = store.entries[reference] ?? .init()
        entry.isLoading = true
        entry.error = nil
        store.entries[reference] = entry
        store.queue.append(reference)
        startServerInviteLoads()
    }

    private func startServerInviteLoads() {
        let store = serverInvites
        while store.activeLoads < 4, !store.queue.isEmpty {
            let reference = store.queue.removeFirst()
            store.activeLoads += 1
            let session = accountSession()
            startAccountChildTask(account: session) { model, account in
                var entry = ServerInvitePresentationStore.Entry()
                do {
                    let invite = try await account.provider.serverInvite(reference)
                    entry.invite = invite
                    if invite.brandColor == nil, let url = invite.iconURL {
                        entry.adaptiveColor = try? await ProfileAvatarPaletteLoader.shared.colors(url).first
                    }
                } catch {
                    entry.error = error.localizedDescription
                    entry.isUnavailable = (error as? ServerInviteError) == .unavailable
                }
                guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
                entry.updatedAt = .now
                store.entries[reference] = entry
                store.activeLoads -= 1
                store.changed(reference)
                model.startServerInviteLoads()
            }
        }
    }

    func activateServerInvite(_ reference: ServerInviteReference, messageID: MessageID? = nil) async -> Bool {
        let store = serverInvites
        guard let invite = store.entries[reference]?.invite else {
            loadServerInvite(reference, refresh: true)
            return false
        }
        if let guild = serverRailGuildsByID[invite.guildID] {
            guard !guild.isUnavailable else { return false }
            store.showsJoinDialog = false
            navigateToInvite(invite)
            return true
        }
        if let reason = invite.unsupportedJoinReason {
            store.entries[reference]?.error = reason
            store.changed(reference)
            return false
        }
        guard store.joining.insert(invite.guildID).inserted else { return false }
        let session = accountSession()
        store.entries[reference]?.error = nil
        store.changed(reference)
        defer {
            if isCurrentAccountSession(session) {
                store.joining.remove(invite.guildID)
                store.changed()
            }
        }
        do {
            let accepted = try await session.provider.acceptServerInvite(reference, messageID: messageID) { [weak self] challenge in
                guard let self else { throw CancellationError() }
                return try await self.solveInviteCaptcha(challenge, account: session)
            }
            guard isCurrentAccountSession(session), !Task.isCancelled else { return false }
            store.entries[reference]?.invite = accepted.invite
            if accepted.requiresVerification {
                throw ServerInviteError.unsupported("Discord requires verification to finish joining. Complete it in Discord, then return to SakuraCord.")
            }
            return try await finishJoiningInvite(accepted.invite, account: session)
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            if error is CancellationError { return false }
            store.entries[reference]?.error = error.localizedDescription
            if (error as? ServerInviteError) == .unavailable { store.entries[reference]?.isUnavailable = true }
            return false
        }
    }

    private func finishJoiningInvite(_ invite: ServerInvite, account session: AppModelAccountSession) async throws -> Bool {
        // Gateway may arrive before or after REST. Wait only for local reconciliation; never repeat the write.
        for _ in 0 ..< 80 {
            guard isCurrentAccountSession(session), !Task.isCancelled else { return false }
            // A joined server can legitimately have no channels visible to this member.
            if let guild = serverRailGuildsByID[invite.guildID], !guild.isUnavailable {
                if conversationPermissionBasis(for: guild.id)?.currentUserIsPending == true {
                    throw ServerInviteError.unsupported("This server requires member verification. Finish verification in Discord.")
                }
                // The onboarding workspace replaces the rail's presentation
                // host. Close its shared state before that host is recreated.
                serverInvites.showsJoinDialog = false
                navigateToInvite(invite)
                if guild.features.contains("GUILD_ONBOARDING") { openChannelsAndRoles(in: guild.id) }
                loadServerInvite(invite.reference, refresh: true)
                return true
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ServerInviteError.failed("Discord accepted the invite, but server details have not arrived yet. Reconnect and check your server list before trying again.")
    }

    private func solveInviteCaptcha(_ challenge: DiscordCaptchaChallenge, account: AppModelAccountSession) async throws -> String {
        guard isCurrentAccountSession(account) else { throw CancellationError() }
        return try await serverInvites.captcha.solution(for: challenge)
    }

    private func navigateToInvite(_ invite: ServerInvite) {
        startConversationNavigation { model, account in
            await model.activateGuild(invite.guildID, account: account)
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            if let channelID = invite.channelID,
               let channel = model.snapshot?.channels.first(where: { $0.id == channelID && $0.guildID == invite.guildID }),
               model.conversationAccess(for: channel).isReadable, channel.kind != .voice {
                model.selectedChannelID = channelID
            }
        }
    }

    func leaveServer(_ guild: Guild) async -> Bool {
        let store = serverInvites
        guard guild.isOwnedByCurrentUser == false, !guild.isUnavailable,
              store.leaving.insert(guild.id).inserted else { return false }
        let session = accountSession()
        store.changed()
        defer {
            if isCurrentAccountSession(session) { store.leaving.remove(guild.id); store.changed() }
        }
        do {
            try await session.provider.leaveGuild(guild.id)
            for _ in 0 ..< 80 {
                guard isCurrentAccountSession(session), !Task.isCancelled else { return false }
                if serverRailGuildsByID[guild.id] == nil {
                    onboarding.persist(nil, guildID: guild.id, database: session.database)
                    return true
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw ServerInviteError.failed("Discord accepted the leave request, but membership has not updated yet. Reconnect before trying again.")
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            store.leaveError = error.localizedDescription
            return false
        }
    }
}
