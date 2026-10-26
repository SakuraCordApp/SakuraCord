import Foundation
import Observation
import SakuraCordModels

/// Presentation state for creating and sharing invite links from the server rail.
/// Discord's own modal creates a link as soon as it opens; SakuraCord lists the
/// account's stored links first and creates one only when asked.
@Observable
final class ServerInviteCreationStore {
    enum Page { case list, create }

    struct Presentation: Identifiable, Equatable {
        let guildID: GuildID
        let channelID: ChannelID
        var id: GuildID { guildID }
    }

    var presentation: Presentation? {
        didSet {
            if presentation == nil {
                revision &+= 1
                expirationTask?.cancel()
                expirationTask = nil
            }
        }
    }
    var invites: [CreatedServerInvite] = [] {
        didSet { scheduleExpiration() }
    }
    var page = Page.list
    var settings = ServerInviteSettings()
    var isLoading = false
    var isCreating = false
    var error: String?
    var copiedCode: String?
    @ObservationIgnored var revision: UInt64 = 0
    @ObservationIgnored var copyRevision: UInt64 = 0
    @ObservationIgnored var validatedGuildIDs: Set<GuildID> = []
    @ObservationIgnored var unavailableCodes: Set<String> = []
    @ObservationIgnored private var expirationTask: Task<Void, Never>?

    func reset() {
        resetPresentation()
        validatedGuildIDs = []
        unavailableCodes = []
    }

    func resetPresentation() {
        presentation = nil
        invites = []
        page = .list
        settings = ServerInviteSettings()
        isLoading = false
        isCreating = false
        error = nil
        copiedCode = nil
    }

    func removeInvite(code: String) {
        invites.removeAll { $0.id == code }
        if invites.isEmpty, page == .list { page = .create }
    }

    func pruneExpiredInvites(at date: Date = .now) {
        invites.removeAll { $0.isExpired(at: date) }
        if invites.isEmpty, page == .list { page = .create }
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        expirationTask = nil
        guard presentation != nil, let expiration = invites.compactMap(\.expiresAt).min() else { return }
        expirationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiration.timeIntervalSinceNow))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.pruneExpiredInvites()
        }
    }
}

extension AppModel {
    /// Mirrors Discord's choice: the open channel in that server when it can carry an
    /// invite, otherwise the first channel in sidebar order that can.
    func serverInviteChannel(for guildID: GuildID) -> Channel? {
        guard let basis = conversationPermissionBasis(for: guildID), !basis.guild.isUnavailable,
              !basis.currentUserIsPending else { return nil }
        let required = DiscordPermissionBits.viewChannel | DiscordPermissionBits.createInstantInvite
        func allowsInvite(_ channel: Channel) -> Bool {
            guard let permissions = ConversationPermissionResolver.effectivePermissions(
                guild: basis.guild, channel: channel,
                resolvedBasePermissions: basis.resolvedBasePermissions,
                overwritePrincipals: basis.overwritePrincipals,
                hasCurrentRoleIdentity: basis.hasCurrentRoleIdentity,
            communicationDisabledUntil: basis.currentUserCommunicationDisabledUntil
            ) else { return false }
            return permissions & required == required
        }
        if selectedGuildID == guildID, let channel = selectedChannel, channel.guildID == guildID,
           channel.kind != .unknown, allowsInvite(channel) {
            return channel
        }
        return messagePresentationChannels
            .filter { $0.guildID == guildID && [.text, .announcement, .forum, .voice].contains($0.kind) }
            .sorted {
                ($0.categoryPosition, $0.position, $0.id) < ($1.categoryPosition, $1.position, $1.id)
            }
            .first(where: allowsInvite)
    }

    func presentServerInviteCreation(for guild: Guild) {
        let store = serverInvites.creation
        guard !accountTransitionIsActive, let channel = serverInviteChannel(for: guild.id) else { return }
        store.resetPresentation()
        store.presentation = .init(guildID: guild.id, channelID: channel.id)
        store.isLoading = true
        let revision = store.revision
        startAccountChildTask(account: accountSession()) { model, account in
            let stored = await (try? account.database?.createdInvites(guildID: guild.id)) ?? []
            let isCurrent = { model.isCurrentAccountSession(account) && store.revision == revision }
            guard isCurrent() else { return }
            store.invites = stored.filter { !store.unavailableCodes.contains($0.id) && !$0.isExpired() }
            store.isLoading = false
            store.page = store.invites.isEmpty ? .create : .list
            guard store.validatedGuildIDs.insert(guild.id).inserted else { return }
            // One account-scoped pass per server. It can finish after dismissal;
            // reopening reads the same session state instead of starting another pass.
            for invite in store.invites {
                guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
                do {
                    let resolved = try await account.provider.serverInvite(invite.reference)
                    if resolved.expiresAt.map({ $0 <= .now }) == true { throw ServerInviteError.unavailable }
                } catch ServerInviteError.unavailable {
                    guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
                    store.unavailableCodes.insert(invite.id)
                    if store.presentation?.guildID == guild.id { store.removeInvite(code: invite.id) }
                    try? await account.database?.deleteCreatedInvite(code: invite.reference.code)
                } catch {
                    guard model.isCurrentAccountSession(account), !Task.isCancelled, !(error is CancellationError) else { return }
                }
            }
        }
    }

    func createServerInvite() {
        let store = serverInvites.creation
        guard let presentation = store.presentation, !store.isCreating else { return }
        store.isCreating = true
        store.error = nil
        let revision = store.revision
        let settings = store.settings
        startAccountChildTask(account: accountSession()) { model, account in
            let isCurrent = { model.isCurrentAccountSession(account) && store.revision == revision }
            do {
                let invite = try await account.provider.createServerInvite(
                    in: presentation.channelID, guildID: presentation.guildID, settings: settings
                )
                // Discord can return an existing link with identical settings; keep one row per code.
                try? await account.database?.saveCreatedInvite(invite)
                guard isCurrent() else { return }
                store.invites.removeAll { $0.id == invite.id }
                store.invites.insert(invite, at: 0)
                store.page = .list
            } catch {
                guard isCurrent(), !(error is CancellationError) else { return }
                store.error = error.localizedDescription
            }
            if isCurrent() { store.isCreating = false }
        }
    }

    func copyServerInvite(_ invite: CreatedServerInvite) {
        let store = serverInvites.creation
        guard !accountTransitionIsActive else { return }
        ChannelContextMenuValue.copy(invite.reference.url.absoluteString)
        store.error = nil
        store.copiedCode = invite.reference.code
        store.copyRevision &+= 1
        let copyRevision = store.copyRevision
        let revision = store.revision
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                let resolved = try await account.provider.serverInvite(invite.reference)
                if invite.isExpired() || resolved.expiresAt.map({ $0 <= .now }) == true { throw ServerInviteError.unavailable }
            } catch {
                guard model.isCurrentAccountSession(account), !Task.isCancelled, !(error is CancellationError) else { return }
                if (error as? ServerInviteError) == .unavailable {
                    store.unavailableCodes.insert(invite.id)
                    if store.presentation?.guildID == invite.guildID { store.removeInvite(code: invite.id) }
                    try? await account.database?.deleteCreatedInvite(code: invite.id)
                }
                guard model.isCurrentAccountSession(account), store.revision == revision,
                      store.copyRevision == copyRevision else { return }
                store.copiedCode = nil
                store.error = (error as? ServerInviteError) == .unavailable
                    ? "The copied invite has expired or is no longer available."
                    : "Couldn’t check the copied invite. \(error.localizedDescription)"
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if store.revision == revision, store.copyRevision == copyRevision { store.copiedCode = nil }
        }
    }
}
