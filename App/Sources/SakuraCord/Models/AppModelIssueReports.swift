import AppKit
import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// SakuraCord's community server, where every report gets a forum post.
    nonisolated static let sakuraCordGuildID = GuildID(rawValue: 1_528_177_363_563_581_662)
    nonisolated static let sakuraCordInvite = ServerInviteReference("hWNwFXkUTP")!

    /// The report hub's Discord application. SakuraCord only ever authorizes
    /// this application, for `identify`, to this redirect.
    nonisolated static let issueReportAuthorization = OAuth2AuthorizationRequest(
        clientID: "1530180517155176458",
        scopes: ["identify"],
        redirectURI: URL(string: "https://sakuracord.app/report/callback")!,
        state: ""
    )

    /// Decided from this account's server list, which never leaves the Mac.
    var isInSakuraCordServer: Bool {
        serverRailGuildsByID[Self.sakuraCordGuildID] != nil
    }

    var canPresentIssueReport: Bool {
        sessionState == .workspace && currentUser != nil && !accountTransitionIsActive
    }

    func presentIssueReport(_ kind: IssueReportKind?) {
        guard canPresentIssueReport else { return }
        issueReports.present(kind)
    }

    /// The community bot's "Report a bug" and "Suggest a feature" buttons open
    /// the report window here instead of sending the bot an interaction.
    func presentIssueReport(forComponent customID: String, on message: Message) -> Bool {
        guard customID.hasPrefix("r:"),
              let kind = IssueReportKind(rawValue: String(customID.dropFirst(2))),
              componentApplicationID(of: message) == ApplicationID(Self.issueReportAuthorization.clientID)
        else { return false }
        presentIssueReport(kind)
        return true
    }

    func submitIssueReport() {
        let store = issueReports
        guard store.submissionTask == nil, store.missingRequirement(before: .done) == nil else {
            store.error = store.missingRequirement(before: .done)
            return
        }
        let kind = store.kind
        let values = store.submissionValues()
        let draft = store.draft
        runIssueReportSubmission { model, hub, session in
            store.begin(.preparing)
            let files = try await Self.issueReportUploads(for: draft, kind: kind)
            let hubSession = try await model.issueReportHubSession(account: session)
            guard model.isCurrentAccountSession(session) else { throw CancellationError() }
            store.begin(.sending)
            let filed = try await hub.submit(kind: kind, values: values, files: files, session: hubSession)
            return (filed, false)
        }
    }

    /// Adds this person to an existing report, with their description as a note.
    func followExistingIssueReport(_ number: Int) {
        let store = issueReports
        guard store.submissionTask == nil else { return }
        let note = [store.primaryField.map { store.value($0.id) }, store.value("steps")]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        runIssueReportSubmission { model, hub, session in
            let hubSession = try await model.issueReportHubSession(account: session)
            guard model.isCurrentAccountSession(session) else { throw CancellationError() }
            store.begin(.sending)
            return (try await hub.meToo(number: number, note: note, session: hubSession), true)
        }
    }

    private func runIssueReportSubmission(
        _ operation: @escaping @MainActor (
            AppModel, IssueReportHubClient, AppModelAccountSession
        ) async throws -> (IssueReportFiled, Bool)
    ) {
        let store = issueReports
        guard canPresentIssueReport else { return }
        let session = accountSession()
        let generation = store.generation
        store.begin(.preparing)
        store.submissionTask = Task { [weak self] in
            defer {
                if store.generation == generation { store.submissionTask = nil }
            }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard isCurrentAccountSession(session) else { throw CancellationError() }
                let (filed, followed) = try await operation(self, store.client, session)
                guard isCurrentAccountSession(session) else { return }
                store.finish(filed, followedExisting: followed)
            } catch is CancellationError {
                guard store.generation == generation else { return }
                store.fail("")
                store.error = nil
            } catch {
                guard isCurrentAccountSession(session) else { return }
                store.fail(Self.issueReportFailureMessage(error))
            }
        }
    }

    /// Signs in to the report service with this Discord account. Only a
    /// one-time `identify` code leaves the Mac; the account token never does.
    private func issueReportHubSession(
        account session: AppModelAccountSession
    ) async throws -> IssueReportHubSession {
        let store = issueReports
        try Task.checkCancellation()
        guard isCurrentAccountSession(session) else { throw CancellationError() }
        guard let userID = currentUser?.id.description else { throw CancellationError() }
        if let cached = store.hubSession, cached.isFresh, cached.user.id == userID { return cached }
        store.begin(.signingIn)
        let start = try await store.client.beginAuthorization()
        try Task.checkCancellation()
        guard isCurrentAccountSession(session) else { throw CancellationError() }
        var request = Self.issueReportAuthorization
        guard start.applicationId == request.clientID,
              start.redirectUri == request.redirectURI,
              start.scopes == request.scopes
        else { throw IssueReportHubError.server("SakuraCord’s report service asked for an unexpected sign-in.") }
        request.state = start.state
        let grant = try await session.provider.authorizeOAuth2(request)
        guard isCurrentAccountSession(session) else { throw CancellationError() }
        let hubSession = try await store.client.completeAuthorization(code: grant.code, state: start.state)
        try Task.checkCancellation()
        guard isCurrentAccountSession(session) else { throw CancellationError() }
        guard hubSession.user.id == userID else {
            throw IssueReportHubError.server("Discord confirmed a different account. Try again.")
        }
        store.hubSession = hubSession
        return hubSession
    }

    nonisolated private static func issueReportUploads(
        for draft: IssueReportStore.Draft,
        kind: IssueReportKind
    ) async throws -> [IssueReportUpload] {
        let includesAPILog = kind == .bug && draft.includesAPILog
        let panicSave = kind == .bug && draft.includesPanicSave ? IssueReportDiagnostics.latestPanicSave() : nil
        let attachments = draft.attachments.map(\.upload)
        return try await Task.detached(priority: .userInitiated) {
            var uploads = attachments
            if includesAPILog { uploads.append(try IssueReportDiagnostics.apiLogUpload()) }
            if let panicSave { uploads.append(try IssueReportDiagnostics.panicSaveUpload(panicSave)) }
            return uploads
        }.value
    }

    nonisolated private static func issueReportFailureMessage(_ error: any Error) -> String {
        switch error {
        case let error as IssueReportHubError:
            error.localizedDescription
        case let error as OAuth2AuthorizationError:
            error.localizedDescription
        case is URLError:
            "SakuraCord couldn’t reach its report service. Check your connection and try again."
        default:
            "Something went wrong: \(error.localizedDescription)"
        }
    }

    // MARK: After filing

    /// Joins through the same invite flow as any server invite.
    func joinSakuraCordServer() async {
        let store = issueReports
        guard !isInSakuraCordServer, store.joinState != .joining else { return }
        store.joinState = .joining
        let reference = Self.sakuraCordInvite
        let session = accountSession()
        loadServerInvite(reference)
        var attempts = 0
        while serverInvites.entries[reference]?.isLoading != false, attempts < 40 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(250))
            guard isCurrentAccountSession(session), !Task.isCancelled else { return }
        }
        let joined = await activateServerInvite(reference)
        guard isCurrentAccountSession(session) else { return }
        if joined || isInSakuraCordServer {
            store.joinState = .idle
        } else {
            store.joinState = .failed(
                serverInvites.entries[reference]?.error ?? "SakuraCord couldn’t join the server. Try again."
            )
        }
    }

    func openIssueReportForumPost() {
        guard let threadID = issueReports.outcome?.filed.threadId.flatMap(UInt64.init),
              isInSakuraCordServer
        else { return }
        issueReports.dismiss()
        navigate(to: Self.sakuraCordGuildID, linkedChannelID: ChannelID(rawValue: threadID))
    }
}
