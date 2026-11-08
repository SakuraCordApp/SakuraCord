import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

/// The current account's applications to apply-to-join servers; see docs/protocol/GUILDS.md, Join applications.
@Observable
final class GuildJoinRequestStore {
    /// The application form and the approval greeting are modals in the official client.
    struct Modal: Identifiable, Equatable {
        enum Kind: Equatable { case form, welcome }
        var guildID: GuildID
        var kind: Kind
        /// Each presentation is new, so a reopened form never receives an earlier load.
        let id = UUID()
    }

    /// Discord's applications, one per server. The provider is authoritative.
    var requests: [GuildID: GuildJoinRequest] = [:]
    /// Name and icon of applied-to servers, which are not in the account's server list.
    var guilds: [GuildID: GuildJoinRequestGuild] = [:]
    /// The open application with the answers entered so far.
    var form: GuildJoinApplicationForm?
    /// Submitted answers, read back from Discord when the applicant views them.
    var answers: [JoinRequestID: [GuildJoinApplicationField]] = [:]
    var modal: Modal?
    /// The application whose status page replaces the workspace, as a server page does.
    var selectedGuildID: GuildID?
    var showsAnswers = false
    var isFolderExpanded = false
    /// Discord points at the folder once an application is submitted instead of leaving the current view.
    var showsSubmittedTip = false
    var isWorking = false
    var error: String?
    /// Approvals whose greeting was closed while Discord records the acknowledgement.
    @ObservationIgnored var acknowledging: Set<JoinRequestID> = []
    /// The invite each application was opened from; Discord's form request carries it.
    @ObservationIgnored var inviteCodes: [GuildID: String] = [:]
    @ObservationIgnored var isLoadingGuilds = false

    func guildName(_ guildID: GuildID) -> String {
        guilds[guildID]?.name ?? "this server"
    }

    func reset() {
        requests = [:]
        guilds = [:]
        form = nil
        answers = [:]
        modal = nil
        selectedGuildID = nil
        showsAnswers = false
        isFolderExpanded = false
        showsSubmittedTip = false
        isWorking = false
        error = nil
        acknowledging = []
        inviteCodes = [:]
        isLoadingGuilds = false
    }
}

extension AppModel {
    /// Unapproved applications to servers the account is not in, oldest first, as Discord's Pending Applications
    /// folder lists them. Unsubmitted ones stay listed so they can be finished or discarded.
    var pendingApplications: [GuildJoinRequest] {
        guildJoinRequests.requests.values
            .filter { ($0.isOpen || $0.status == .started) && serverRailGuildsByID[$0.guildID] == nil }
            .sorted { $0.id < $1.id }
    }

    func applyGuildJoinRequests(_ list: [GuildJoinRequest]) {
        let store = guildJoinRequests
        store.requests = Dictionary(list.map { ($0.guildID, $0) }) { $1 }
        if let guildID = store.selectedGuildID, !pendingApplications.contains(where: { $0.guildID == guildID }) {
            // Approved, withdrawn elsewhere, or reapplied: the page no longer describes an application.
            selectGuildJoinRequest(nil)
        }
        showGuildJoinApprovalIfNeeded()
        loadGuildJoinRequestGuildsIfNeeded()
    }

    /// Greets an unacknowledged approval once no other application modal is open.
    func showGuildJoinApprovalIfNeeded() {
        let store = guildJoinRequests
        guard store.modal == nil,
              let approved = store.requests.values.first(where: {
                  $0.status == .approved && !$0.isAcknowledged && !store.acknowledging.contains($0.id)
              }) else { return }
        store.modal = .init(guildID: approved.guildID, kind: .welcome)
    }

    private func loadGuildJoinRequestGuildsIfNeeded() {
        let store = guildJoinRequests
        guard !store.isLoadingGuilds,
              pendingApplications.contains(where: { store.guilds[$0.guildID] == nil }) else { return }
        store.isLoadingGuilds = true
        startAccountChildTask(account: accountSession()) { model, account in
            let guilds = try? await account.provider.guildJoinRequestGuilds()
            guard model.isCurrentAccountSession(account) else { return }
            store.isLoadingGuilds = false
            for guild in guilds ?? [] { store.guilds[guild.id] = guild }
        }
    }

    func joinRequestGuildName(_ guildID: GuildID) -> String {
        serverRailGuildsByID[guildID]?.name ?? guildJoinRequests.guildName(guildID)
    }

    func joinRequestGuildIconURL(_ guildID: GuildID) -> URL? {
        serverRailGuildsByID[guildID]?.iconURL ?? guildJoinRequests.guilds[guildID]?.iconURL
    }

    /// Shows an application's status in place of the workspace, or clears it.
    func selectGuildJoinRequest(_ guildID: GuildID?) {
        let store = guildJoinRequests
        if let guildID {
            // The page replaces the workspace like the official route does. Behind it the workspace rests on
            // Friends, so no conversation stays open to be marked read.
            openFriends()
            store.isFolderExpanded = true
            if store.selectedGuildID != guildID { store.showsAnswers = false }
        }
        store.selectedGuildID = guildID
        store.error = nil
        serverRailPresentation.showsGuildJoinRequest = guildID != nil
    }

    /// Opens the application for a server; an invite code is required when the account has no other access to it.
    func openGuildJoinApplication(_ guildID: GuildID, inviteCode: String? = nil) {
        let store = guildJoinRequests
        if let inviteCode { store.inviteCodes[guildID] = inviteCode }
        store.form = nil
        store.error = nil
        let modal = GuildJoinRequestStore.Modal(guildID: guildID, kind: .form)
        store.modal = modal
        startAccountChildTask(account: accountSession()) { model, account in
            let result = await Result { try await account.provider.guildJoinApplicationForm(guildID, inviteCode: store.inviteCodes[guildID]) }
            guard model.isCurrentAccountSession(account), store.modal?.id == modal.id else { return }
            switch result {
            case .success(let form):
                store.form = form
                if let name = form.guildName { store.guilds[guildID] = .init(id: guildID, name: name, iconURL: form.iconURL) }
            case .failure(let error):
                store.error = error.localizedDescription
            }
        }
    }

    func submitGuildJoinApplication() {
        let store = guildJoinRequests
        guard let form = store.form, let modal = store.modal, form.fields.allSatisfy(\.isSatisfied) else { return }
        runGuildJoinRequestAction { try await $0.submitGuildJoinApplication(form.guildID, fields: form.fields) } completion: { [weak self] in
            guard let self, store.modal?.id == modal.id else { return }
            store.form = nil
            store.modal = nil
            showGuildJoinApprovalIfNeeded()
            // Like Discord, an applicant stays where they are; the folder opens with a note on what happens next.
            // A screened member simply continues in the server.
            if serverRailGuildsByID[form.guildID] == nil {
                store.isFolderExpanded = true
                store.showsSubmittedTip = true
            }
        }
    }

    func withdrawGuildJoinRequest(_ guildID: GuildID) {
        runGuildJoinRequestAction { try await $0.withdrawGuildJoinRequest(guildID) }
    }

    /// Starts a new application after a rejection, then opens its form.
    func reapplyToGuild(_ guildID: GuildID) {
        runGuildJoinRequestAction { try await $0.reapplyToGuild(guildID) } completion: { [weak self] in
            self?.openGuildJoinApplication(guildID)
        }
    }

    func toggleGuildJoinRequestAnswers(_ guildID: GuildID) {
        let store = guildJoinRequests
        store.showsAnswers.toggle()
        guard store.showsAnswers, let request = store.requests[guildID], store.answers[request.id] == nil else { return }
        runGuildJoinRequestAction { store.answers[request.id] = try await $0.guildJoinRequestAnswers(request.id) }
    }

    /// Closes the approval greeting, records it with Discord as the official client does, and opens the server.
    func finishGuildJoinApproval(_ guildID: GuildID) {
        let store = guildJoinRequests
        store.modal = nil
        if let request = store.requests[guildID], request.status == .approved, !request.isAcknowledged {
            store.acknowledging.insert(request.id)
            startAccountChildTask(account: accountSession()) { _, account in
                try? await account.provider.acknowledgeGuildJoinRequest(request)
            }
        }
        // The approval can reach the applicant before the guild's GUILD_CREATE.
        startAccountChildTask(account: accountSession()) { model, account in
            guard let guild = try? await model.awaitJoinedGuild(guildID, account: account) else { return }
            model.startConversationNavigation { model, account in
                await model.activateGuild(guildID, account: account)
            }
            if guild.features.contains("GUILD_ONBOARDING") { model.openChannelsAndRoles(in: guildID) }
        }
    }

    private func runGuildJoinRequestAction(
        _ action: @escaping (any ChatProvider) async throws -> Void,
        completion: @escaping () -> Void = {}
    ) {
        let store = guildJoinRequests
        guard !store.isWorking else { return }
        store.isWorking = true
        store.error = nil
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                try await action(account.provider)
                guard model.isCurrentAccountSession(account) else { return }
                store.isWorking = false
                completion()
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                store.isWorking = false
                store.error = error.localizedDescription
            }
        }
    }
}
