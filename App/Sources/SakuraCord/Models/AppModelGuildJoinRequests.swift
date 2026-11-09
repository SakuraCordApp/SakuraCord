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
    /// Each applied-to server's description and counts, from its application form, for the status page's sidebar.
    var previews: [GuildID: GuildJoinApplicationForm] = [:]
    @ObservationIgnored var loadingPreviews: Set<GuildID> = []
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
    /// The application the open form answers, as it was when the form opened or Discord last started one for it.
    /// A form from a server profile has none.
    @ObservationIgnored var formRequest: GuildJoinRequest?
    /// The form's submission while it runs.
    @ObservationIgnored var submission: Submission?

    struct Submission {
        let modalID: UUID
        /// The application the submission answers: the form's, or, for a form from a server profile, the first one
        /// Discord reports while it runs.
        var requestID: JoinRequestID?
    }
    @ObservationIgnored var isLoadingGuilds = false

    func guildName(_ guildID: GuildID) -> String {
        guilds[guildID]?.name ?? "this server"
    }

    /// The form describes the server, so it previews the server and names it.
    func recordPreview(_ form: GuildJoinApplicationForm, for guildID: GuildID) {
        previews[guildID] = form
        if let name = form.guildName { guilds[guildID] = .init(id: guildID, name: name, iconURL: form.iconURL) }
    }

    func reset() {
        requests = [:]
        guilds = [:]
        previews = [:]
        loadingPreviews = []
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
        formRequest = nil
        submission = nil
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

    /// The application whose status page replaces the workspace. An approval's GUILD_CREATE can arrive before its
    /// request update; the page must not keep saying "awaiting review" beside the newly joined server meanwhile.
    var presentedGuildJoinRequestID: GuildID? {
        guildJoinRequests.selectedGuildID.flatMap { serverRailGuildsByID[$0] == nil ? $0 : nil }
    }

    func applyGuildJoinRequests(_ list: [GuildJoinRequest]) {
        let store = guildJoinRequests
        let previous = store.requests
        store.requests = Dictionary(list.map { ($0.guildID, $0) }) { $1 }
        reconcileGuildJoinForm()
        if let guildID = store.selectedGuildID {
            if !pendingApplications.contains(where: { $0.guildID == guildID }) {
                // Approved, withdrawn elsewhere, or reapplied: the page no longer describes an application.
                selectGuildJoinRequest(nil)
            } else if previous[guildID]?.id != store.requests[guildID]?.id {
                // A new application has its own answers, which stay hidden until asked for again.
                store.showsAnswers = false
            }
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
            let isReselection = store.selectedGuildID == guildID
            // The page replaces the workspace like the official route does. Behind it the workspace rests on
            // Friends, so no conversation stays open to be marked read.
            openFriends()
            store.isFolderExpanded = true
            if !isReselection { store.showsAnswers = false }
        }
        store.selectedGuildID = guildID
        store.error = nil
        serverRailPresentation.showsGuildJoinRequest = guildID != nil
    }

    /// An application's status page rests on Friends. It gives way only when a server or conversation replaces
    /// that workspace, so the direct messages list never shows in between.
    func leaveGuildJoinRequestPage() {
        if guildJoinRequests.selectedGuildID != nil { selectGuildJoinRequest(nil) }
    }

    /// Opens the application for a server; an invite code is required when the account has no other access to it.
    /// `guild` is the server as the caller already shows it, so the form's header is right before the form loads.
    func openGuildJoinApplication(_ guildID: GuildID, inviteCode: String? = nil, guild: GuildJoinRequestGuild? = nil) {
        let store = guildJoinRequests
        if let inviteCode { store.inviteCodes[guildID] = inviteCode }
        if let guild, store.guilds[guildID] == nil { store.guilds[guildID] = guild }
        store.form = nil
        store.error = nil
        store.formRequest = store.requests[guildID]
        let modal = GuildJoinRequestStore.Modal(guildID: guildID, kind: .form)
        store.modal = modal
        startAccountChildTask(account: accountSession()) { model, account in
            let result = await Result { try await account.provider.guildJoinApplicationForm(guildID, inviteCode: store.inviteCodes[guildID]) }
            guard model.isCurrentAccountSession(account), store.modal?.id == modal.id else { return }
            switch result {
            case .success(let form):
                store.form = form
                store.recordPreview(form, for: guildID)
            case .failure(let error):
                store.error = error.localizedDescription
            }
        }
    }

    func submitGuildJoinApplication() {
        let store = guildJoinRequests
        guard !store.isWorking, let form = store.form, let modal = store.modal,
              form.fields.allSatisfy(\.isSatisfied) else { return }
        store.submission = .init(modalID: modal.id, requestID: store.requests[form.guildID]?.id)
        runGuildJoinRequestAction { [weak self] provider in
            defer { if store.submission?.modalID == modal.id { store.submission = nil } }
            do {
                try await provider.submitGuildJoinApplication(form.guildID, fields: form.fields)
            } catch where self?.submissionLanded(in: form.guildID) == true {}
        } completion: { [weak self] in
            guard let self, store.modal?.id == modal.id else { return }
            store.form = nil
            store.modal = nil
            showGuildJoinApprovalIfNeeded()
            // Like Discord, an applicant stays where they are; the folder opens with a note on what happens next.
            // A screened member simply continues in the server.
            if serverRailGuildsByID[form.guildID] == nil, store.requests[form.guildID]?.status == .submitted {
                store.isFolderExpanded = true
                store.showsSubmittedTip = true
            }
        }
    }

    /// Whether a submission whose reply failed or was lost is done anyway, because Discord's Gateway updates already
    /// show the result: the screened member is no longer pending, the application was submitted or reviewed, or
    /// another client discarded or replaced it. Keeping the form would offer the same answers again; anything else,
    /// such as an update that has not arrived, keeps the form and its answers with the error.
    private func submissionLanded(in guildID: GuildID) -> Bool {
        if serverRailGuildsByID[guildID] != nil { return hasFinishedScreening(in: guildID) }
        let current = guildJoinRequests.requests[guildID]
        return [.submitted, .rejected, .approved].contains(current?.status)
            || guildJoinRequests.submission?.requestID.map { $0 != current?.id } == true
    }

    /// A member of the server whose screening is done.
    private func hasFinishedScreening(in guildID: GuildID) -> Bool {
        serverRailGuildsByID[guildID] != nil && onboardingMember(in: guildID)?.isPending == false
    }

    /// Once another client submits, replaces or removes the form's application, finishes the member's screening, or a
    /// reviewer acts, submitting would send stale answers, so the form closes. The form's own running submission
    /// decides first; this runs again when it ends.
    func reconcileGuildJoinForm() {
        let store = guildJoinRequests
        guard let modal = store.modal, modal.kind == .form else { return }
        let current = store.requests[modal.guildID]
        if store.submission != nil {
            if store.submission?.requestID == nil { store.submission?.requestID = current?.id }
            return
        }
        if hasFinishedScreening(in: modal.guildID) {
            store.form = nil
            store.modal = nil
            return
        }
        let answered = store.formRequest
        // Discord starting the form's application, or removing an earlier one that is no longer live (as Reapply
        // does), leaves nothing stale.
        if answered?.status != .started, current == nil || current?.status == .started {
            store.formRequest = current
            return
        }
        // Reapply opens the form while the rejected application it replaces can still be listed.
        let isUnchanged = current?.id == answered?.id && current?.status == answered?.status
        if isUnchanged, current?.status == .started || current?.status == .rejected { return }
        store.form = nil
        store.modal = nil
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

    /// Reads the server's description and counts for the status page; the form request carries them.
    func loadGuildJoinRequestPreview(_ guildID: GuildID) async {
        let store = guildJoinRequests
        guard store.previews[guildID] == nil, store.loadingPreviews.insert(guildID).inserted else { return }
        defer { store.loadingPreviews.remove(guildID) }
        let account = accountSession()
        guard let form = try? await account.provider.guildJoinApplicationForm(guildID, inviteCode: store.inviteCodes[guildID]),
              isCurrentAccountSession(account)
        else { return }
        store.recordPreview(form, for: guildID)
    }

    func toggleGuildJoinRequestAnswers(_ guildID: GuildID) {
        let store = guildJoinRequests
        store.showsAnswers.toggle()
        guard store.showsAnswers, let request = store.requests[guildID], store.answers[request.id] == nil else { return }
        runGuildJoinRequestAction {
            do {
                store.answers[request.id] = try await $0.guildJoinRequestAnswers(request.id)
            } catch {
                // Nothing to show; the error explains why and the button can try again.
                store.showsAnswers = false
                throw error
            }
        }
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
            let result = await Result { try await action(account.provider) }
            guard model.isCurrentAccountSession(account) else { return }
            store.isWorking = false
            switch result {
            case .success: completion()
            case .failure(let error): store.error = error.localizedDescription
            }
            model.reconcileGuildJoinForm()
        }
    }
}
