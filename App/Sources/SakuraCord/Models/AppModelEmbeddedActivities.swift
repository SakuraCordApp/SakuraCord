import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

/// Running Activities, the shelf, and the one Activity this account hosts.
@Observable
final class EmbeddedActivityStore {
    struct Session: Equatable {
        enum Phase: Equatable {
            case launching
            case running
            case failed(String)
        }

        var application: EmbeddedActivityApplication
        var channel: Channel
        var instance: EmbeddedActivityInstance?
        var phase: Phase
        /// Runs in the call it started in and ends with it; otherwise it is
        /// docked in the channel's chat and outlives calls there.
        var isInCall: Bool
        /// Tells this launch's late results apart from a newer one in the same place.
        let launchID = UUID()

        var location: EmbeddedActivityLocation { .of(channel) }
    }

    /// A question the Activity's host must ask before acting for it.
    struct Prompt: Identifiable {
        enum Kind {
            case authorize(scopes: [String], disclosures: [EmbeddedActivityDisclosure])
            case openLink(URL)
            case confirmAge
            /// Leaving the running Activity, named with its channel, for another.
            case replace(activity: String, channel: String)
        }

        var id = UUID()
        var applicationName: String
        var kind: Kind
        /// The launch it belongs to; ending that launch dismisses it. Nil for
        /// questions asked before a launch, which outlive the Activity running.
        var launchID: UUID?
        var resolve: (Bool) -> Void
    }

    /// Running instances by composite instance ID.
    private(set) var instances: [String: EmbeddedActivityInstance] = [:]
    var shelves: [GuildID?: [EmbeddedActivityApplication]] = [:]
    /// Shelf reads in flight, shared by every caller. Each is an account child
    /// task, so account cleanup cancels and drains it.
    @ObservationIgnored var shelfLoads: [GuildID?: Task<Void, Never>] = [:]
    /// Shelves Activity cards already asked for, so a failed read isn't repeated per card.
    @ObservationIgnored var cardShelfRequests: Set<GuildID?> = []
    var shelfError: String?
    var session: Session?
    var prompt: Prompt?
    @ObservationIgnored var host: EmbeddedActivityHost?
    @ObservationIgnored var gatewaySessionID: String?
    @ObservationIgnored var launch: Task<Void, any Error>?
    @ObservationIgnored var launchTimeout: Task<Void, Never>?
    /// Leaves still on their way to Discord, by composite instance ID.
    @ObservationIgnored var pendingLeaves: [String: Task<Void, Never>] = [:]
    /// Instances this session left, until a roster without it confirms the
    /// leave, and whether that leave failed, which is reported and, like any
    /// mutation, not repeated. They are never hosted again unless the person
    /// joins there again.
    @ObservationIgnored var departingInstances: [String: Bool] = [:]
    /// The proxy ticket fetched before a launch's request, as Discord's client does.
    struct LaunchTicket {
        let launchID: UUID
        let ticket: String
        let fetchedAt = Date.now

        /// Discord's tickets last five minutes; like its client, an older one
        /// is fetched again, such as after a long consent.
        func isUsable(for launchID: UUID) -> Bool {
            launchID == self.launchID && Date.now.timeIntervalSince(fetchedAt) < 4 * 60
        }
    }

    @ObservationIgnored var launchTicket: LaunchTicket?
    /// Recent slash commands from this client by nonce; Discord tags the
    /// participant an Activity command adds with that nonce.
    @ObservationIgnored var commandLaunches: [(nonce: String, application: ApplicationCommandApplication)] = []
    /// Age-gated Activities confirmed this session, as the official client asks once.
    @ObservationIgnored var ageConfirmedApplications: Set<ApplicationID> = []

    func recordCommand(_ nonce: String, application: ApplicationCommandApplication) {
        commandLaunches.append((nonce, application))
        if commandLaunches.count > 16 { commandLaunches.removeFirst() }
    }

    /// The Activity hosted outside a voice channel, docked in its chat.
    var dockedSession: Session? {
        session.flatMap { $0.isInCall ? nil : $0 }
    }

    func upsert(_ instance: EmbeddedActivityInstance) {
        instances[instance.compositeInstanceID] = instance.participants.isEmpty ? nil : instance
    }

    /// Replaces the guild instances; the snapshot never lists private ones.
    func replaceInstances(_ instances: [EmbeddedActivityInstance]) {
        self.instances = self.instances.filter { $0.value.location.guildID == nil }.merging(
            instances.filter { !$0.participants.isEmpty }.map { ($0.compositeInstanceID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// Joining again supersedes a leave that failed there.
    func forgetFailedLeaves(of applicationID: ApplicationID, in channelID: ChannelID) {
        for instance in instances(in: channelID)
            where instance.applicationID == applicationID && departingInstances[instance.compositeInstanceID] == true {
            departingInstances[instance.compositeInstanceID] = nil
        }
    }

    func instances(in channelID: ChannelID) -> [EmbeddedActivityInstance] {
        instances.values.filter { $0.location.channelID == channelID }
            .sorted { $0.compositeInstanceID < $1.compositeInstanceID }
    }

    func application(_ id: ApplicationID) -> EmbeddedActivityApplication? {
        shelves.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Asks the person; a cancelled caller, such as one outliving its account,
    /// is declined so nothing waits on a prompt nobody will answer. A question
    /// for a launch (`launchID`) is declined once that launch has ended; nil
    /// asks before a launch.
    func ask(_ kind: Prompt.Kind, applicationName: String, launchID: UUID?) async -> Bool {
        guard !Task.isCancelled, launchID == nil || launchID == session?.launchID else { return false }
        prompt?.resolve(false)
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var isResolved = false
                prompt = Prompt(
                    id: id, applicationName: applicationName, kind: kind, launchID: launchID
                ) { [weak self] granted in
                    guard !isResolved else { return }
                    isResolved = true
                    self?.prompt = nil
                    continuation.resume(returning: granted)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.prompt?.id == id { self?.prompt?.resolve(false) }
            }
        }
    }

    func endSession() {
        launch?.cancel()
        launch = nil
        launchTimeout?.cancel()
        launchTimeout = nil
        launchTicket = nil
        host?.stop()
        host = nil
        if let prompt, prompt.launchID != nil, prompt.launchID == session?.launchID { prompt.resolve(false) }
        session = nil
    }

    func reset() {
        endSession()
        prompt?.resolve(false)
        instances = [:]
        shelves = [:]
        shelfLoads.values.forEach { $0.cancel() }
        shelfLoads = [:]
        cardShelfRequests = []
        shelfError = nil
        gatewaySessionID = nil
        pendingLeaves = [:]
        departingInstances = [:]
        commandLaunches = []
        ageConfirmedApplications = []
    }
}

extension Channel {
    /// Discord's channel type, as Activity consent and the SDK report it.
    var activityChannelType: Int {
        switch kind {
        case .voice: 2
        case .directMessage: 1
        case .groupDirectMessage: 3
        case .announcement: 5
        default: 0
        }
    }
}

extension EmbeddedActivityLocation {
    static func of(_ channel: Channel) -> Self {
        let id = channel.guildID.map { "gc-\($0)-\(channel.id)" } ?? "pc-\(channel.id)"
        return Self(id: id, channelID: channel.id, guildID: channel.guildID)
    }
}

extension AppModel {
    /// Whether the account may start Activities in the channel.
    func canStartActivity(in channel: Channel) -> Bool {
        guard channel.guildID != nil else { return true }
        guard let permissions = effectiveMessagePermissions(in: channel) else { return false }
        return permissions & (DiscordPermissionBits.useEmbeddedActivities | DiscordPermissionBits.administrator) != 0
    }

    func retryActivity() async {
        guard let session = embeddedActivities.session else { return }
        await startActivity(session.application, in: session.channel)
    }

    /// Reads the guild's shelf; a caller arriving mid-read waits for that read.
    func loadActivityShelf(guildID: GuildID?) async {
        let store = embeddedActivities
        let load = store.shelfLoads[guildID] ?? startAccountChildTask(account: accountSession()) { model, account in
            await model.fetchActivityShelf(guildID: guildID, account: account)
        }
        store.shelfLoads[guildID] = load
        await load.value
        if store.shelfLoads[guildID] == load { store.shelfLoads[guildID] = nil }
    }

    /// Activity cards show the shelf's art, as Discord's do.
    func loadActivityCardShelf(guildID: GuildID?) async {
        let store = embeddedActivities
        guard store.shelves[guildID] == nil, store.cardShelfRequests.insert(guildID).inserted else { return }
        await loadActivityShelf(guildID: guildID)
    }

    private func fetchActivityShelf(guildID: GuildID?, account: AppModelAccountSession) async {
        do {
            let shelf = try await account.provider.embeddedActivityShelf(guildID: guildID)
            guard isCurrentAccountSession(account), !Task.isCancelled else { return }
            embeddedActivities.shelves[guildID] = shelf
            embeddedActivities.shelfError = nil
            // Activity cards drawn before the shelf arrived pick up its cover.
            serverInvites.changed()
        } catch {
            guard isCurrentAccountSession(account), !Task.isCancelled else { return }
            embeddedActivities.shelfError = error.localizedDescription
        }
    }

    /// Where the shelf a launch came from was opened, as Discord's launch reports it.
    struct ActivityLauncher {
        /// A call's controls rather than the composer.
        var isFromCall: Bool
        /// The shelf section the Activity was picked from.
        var section: String
    }

    /// Starts the application in the channel, or joins the instance already
    /// running there. A voice channel Activity runs alongside voice; elsewhere
    /// it docks in the channel's chat.
    func startActivity(_ application: EmbeddedActivityApplication, in channel: Channel, launcher: ActivityLauncher? = nil) async {
        let store = embeddedActivities
        let account = accountSession()
        let location = EmbeddedActivityLocation.of(channel)
        if let current = store.session, current.application.id == application.id, current.location == location,
           current.phase == .launching || current.phase == .running {
            return
        }
        guard await confirmLaunch(of: application), isCurrentAccountSession(account) else { return }
        // Discord's client leaves the running Activity before starting another.
        if store.session != nil { leaveActivity() }
        let session = EmbeddedActivityStore.Session(
            application: application, channel: channel, phase: .launching,
            isInCall: channel.kind == .voice || activeVoiceChannel?.id == channel.id
        )
        store.session = session
        if channel.kind == .voice, activeVoiceChannel?.id != channel.id {
            await joinVoice(channel)
            guard isCurrentAccountSession(account), store.session?.launchID == session.launchID else { return }
            guard activeVoiceChannel?.id == channel.id else {
                store.endSession()
                return
            }
        }
        // A rejoin must not race the leave Discord has not yet seen.
        for leave in store.pendingLeaves.values { await leave.value }
        guard isCurrentAccountSession(account), store.session?.launchID == session.launchID else { return }
        store.forgetFailedLeaves(of: application.id, in: channel.id)
        // Like Discord's client, an instance of the Activity already running
        // in the channel is joined rather than started again.
        let joining = store.instances(in: channel.id).contains { $0.applicationID == application.id }
        // Ending the session cancels a launch that has not reached Discord yet.
        let launch = Task {
            // Like Discord's client, the proxy ticket comes before Discord
            // counts this session in, so a failed ticket strands nothing.
            let ticket = try await account.provider.embeddedActivityProxyTicket(application.id, channelID: channel.id)
            store.launchTicket = .init(launchID: session.launchID, ticket: ticket)
            if !joining { try await installForLaunch(application, in: channel, launchID: session.launchID, account: account) }
            // Read after any consent, so ownership names the session the request sends.
            let sessionID = try await account.provider.embeddedActivitySessionID()
            store.gatewaySessionID = sessionID
            try await account.provider.launchEmbeddedActivity(
                application.id, in: channel, sessionID: sessionID, joining: joining,
                fromCall: launcher?.isFromCall ?? session.isInCall, shelfSection: launcher?.section
            )
        }
        store.launch = launch
        do {
            try await launch.value
        } catch {
            // The instance update can arrive before a lost launch response.
            guard isCurrentAccountSession(account), store.session?.launchID == session.launchID,
                  store.session?.instance == nil else { return }
            // The person declined to install the application.
            if error is CancellationError {
                store.endSession()
                return
            }
            store.session?.phase = .failed(error.localizedDescription)
            return
        }
        guard isCurrentAccountSession(account), store.session?.launchID == session.launchID else { return }
        if let instance = store.instances.values.first(where: { isOwnInstance($0, application: application.id, location: location) }) {
            consumeEmbeddedActivity(instance)
        }
        store.launchTimeout?.cancel()
        store.launchTimeout = Task { @MainActor [weak store] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, store?.session?.phase == .launching, store?.session?.launchID == session.launchID
            else { return }
            store?.session?.phase = .failed("\(application.name) did not start. Try again.")
        }
    }

    /// The questions Discord asks before a launch: age-restricted Activities
    /// once a session, and leaving a running Activity for another.
    private func confirmLaunch(of application: EmbeddedActivityApplication) async -> Bool {
        let store = embeddedActivities
        if application.requiresAgeGate, !store.ageConfirmedApplications.contains(application.id) {
            guard await store.ask(.confirmAge, applicationName: application.name, launchID: nil) else { return false }
            store.ageConfirmedApplications.insert(application.id)
        }
        guard let current = store.session, current.phase == .launching || current.phase == .running else { return true }
        return await store.ask(
            .replace(activity: current.application.name, channel: current.channel.name),
            applicationName: application.name, launchID: nil
        )
    }

    /// Like Discord's client, asks the person to install an app-handled
    /// Activity they haven't before its command runs; declining is posted to
    /// Discord and launches nothing.
    private func installForLaunch(
        _ application: EmbeddedActivityApplication, in channel: Channel, launchID: UUID, account: AppModelAccountSession
    ) async throws {
        guard let scopes = try await account.provider.embeddedActivityInstallScopes(application.id, in: channel) else { return }
        let request = EmbeddedActivityAuthorizationRequest(
            applicationID: application.id, scopes: scopes, state: UUID().uuidString,
            location: .of(channel), channelType: channel.activityChannelType
        )
        guard try await embeddedActivityConsent(to: request, launchID: launchID, account: account) else {
            // The launch ends now; Discord answers the refusal with access_denied.
            startAccountChildTask(account: account) { _, account in
                try? await account.provider.installEmbeddedActivity(request, granted: false)
            }
            throw CancellationError()
        }
        try await account.provider.installEmbeddedActivity(request, granted: true)
    }

    /// Discord's consent before an Activity grant: asked unless Discord holds
    /// the grant and the person acknowledged every disclosure, which are
    /// recorded once they agree.
    func embeddedActivityConsent(
        to request: EmbeddedActivityAuthorizationRequest, launchID: UUID, account: AppModelAccountSession
    ) async throws -> Bool {
        let preview = try await account.provider.embeddedActivityAuthorizationPreview(request)
        let disclosures = preview.unacknowledgedDisclosures
        guard !preview.isAuthorized || !disclosures.isEmpty else { return true }
        guard await embeddedActivities.ask(
            .authorize(scopes: request.scopes, disclosures: disclosures), applicationName: preview.applicationName,
            launchID: launchID
        ) else { return false }
        if !disclosures.isEmpty {
            try await account.provider.acknowledgeEmbeddedActivityDisclosures(disclosures, applicationID: request.applicationID)
        }
        return true
    }

    /// Closes the hosted Activity now; Discord is told in the background. A
    /// launch left before its instance arrives is left when it does.
    func leaveActivity() {
        let store = embeddedActivities
        let instance = store.session?.instance
        store.endSession()
        if let instance { leaveEmbeddedActivity(instance) }
    }

    private func leaveEmbeddedActivity(_ instance: EmbeddedActivityInstance) {
        let id = instance.compositeInstanceID
        guard embeddedActivities.pendingLeaves[id] == nil else { return }
        embeddedActivities.departingInstances[id] = false
        embeddedActivities.pendingLeaves[id] = startAccountChildTask(account: accountSession()) { model, account in
            do {
                try await account.provider.leaveEmbeddedActivity(instance)
            } catch {
                guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
                let name = model.embeddedActivities.application(instance.applicationID)?.name ?? "the Activity"
                model.errorMessage = "Couldn’t leave \(name): \(error.localizedDescription)"
                if model.embeddedActivities.departingInstances[id] != nil { model.embeddedActivities.departingInstances[id] = true }
            }
            model.embeddedActivities.pendingLeaves[id] = nil
        }
    }

    /// Players in the instance an Activity invite or launch message points
    /// to, once per account however many of its sessions take part.
    func activityPlayers(reference: ServerInviteReference?, instanceID: String?) -> [UserID] {
        let instance = instanceID.flatMap { embeddedActivities.instances[$0] }
            ?? reference.flatMap { inviteEntry(for: $0)?.invite }.flatMap(activityInstance(for:))
        guard let instance else { return [] }
        var seen = Set<UserID>()
        return instance.participants.map(\.userID).filter { seen.insert($0).inserted }
    }

    func activityPlayerAvatarURL(_ userID: UserID) -> URL? {
        (currentUser?.id == userID ? currentUser : membersByID[userID]?.user)?.avatarURL
    }

    /// The launch message's button: join a running instance, show it joined,
    /// or play again once it ended, as Discord's does.
    func activityInstanceAction(_ instanceID: String) -> (String, Bool) {
        if embeddedActivities.session?.instance?.compositeInstanceID == instanceID { return ("Joined", true) }
        guard let instance = embeddedActivities.instances[instanceID] else { return ("Play", false) }
        return ("Join", knownRootChannel(instance.location.channelID) == nil)
    }

    /// Joins the instance an application's launch message announced, or
    /// starts the Activity again where the message is once it ended. Outside a
    /// voice channel it needs no call, as in an application's own DM.
    func joinActivityInstance(_ instanceID: String, from message: Message) async {
        let instance = embeddedActivities.instances[instanceID]
        guard let channel = knownRootChannel(instance?.location.channelID ?? message.channelID) else { return }
        let applicationID = instance?.applicationID ?? ApplicationID(rawValue: message.author.id.rawValue)
        guard let application = await shelfApplication(applicationID, guildID: channel.guildID, fallback: {
            EmbeddedActivityApplication(id: applicationID, name: message.author.displayName, iconURL: message.author.avatarURL)
        }) else { return }
        await startActivity(application, in: channel)
    }

    func isInActivityInvite(_ invite: ServerInvite) -> Bool {
        guard let instance = activityInstance(for: invite) else { return false }
        return embeddedActivities.session?.instance?.compositeInstanceID == instance.compositeInstanceID
    }

    /// The voice channel an Activity invite opens, when this account can see it.
    func activityInviteChannel(_ invite: ServerInvite) -> Channel? {
        guard invite.activity != nil else { return nil }
        return invite.channelID.flatMap(knownRootChannel)
    }

    func joinActivityInvite(_ invite: ServerInvite) async {
        guard let activity = invite.activity, let channel = activityInviteChannel(invite) else { return }
        guard let application = await shelfApplication(activity.applicationID, guildID: channel.guildID, fallback: {
            EmbeddedActivityApplication(
                id: activity.applicationID, name: activity.name, iconURL: activity.iconURL, coverURL: activity.coverURL
            )
        }) else { return }
        navigate(to: channel.id)
        await startActivity(application, in: channel)
    }

    /// The shelf's details for an Activity a card points to, reading the shelf
    /// first. If the read failed the Activity is treated as age-restricted, so
    /// a card never skips a confirmation the shelf would ask for; one missing
    /// from a loaded shelf has no gate to honour. Nil once the account changed
    /// or the caller was cancelled while reading.
    private func shelfApplication(
        _ id: ApplicationID, guildID: GuildID?, fallback: () -> EmbeddedActivityApplication
    ) async -> EmbeddedActivityApplication? {
        let account = accountSession()
        if embeddedActivities.application(id) == nil { await loadActivityShelf(guildID: guildID) }
        guard isCurrentAccountSession(account), !Task.isCancelled else { return nil }
        if let application = embeddedActivities.application(id) { return application }
        var application = fallback()
        application.requiresAgeGate = embeddedActivities.shelves[guildID] == nil
        return application
    }

    private func activityInstance(for invite: ServerInvite) -> EmbeddedActivityInstance? {
        guard let activity = invite.activity, let channelID = invite.channelID else { return nil }
        return embeddedActivities.instances.values.first {
            $0.location.channelID == channelID && $0.applicationID == activity.applicationID
        }
    }

    func consumeEmbeddedActivityEvent(_ event: ClientEvent) {
        switch event {
        case .embeddedActivityChanged(let instance):
            embeddedActivities.upsert(instance)
            consumeEmbeddedActivity(instance)
        case .embeddedActivitiesReceived(let instances):
            embeddedActivities.replaceInstances(instances)
            let listed = Set(instances.map(\.compositeInstanceID))
            // A guild instance missing from the snapshot has ended; private ones are never listed.
            embeddedActivities.departingInstances = embeddedActivities.departingInstances.filter { id, _ in
                listed.contains(id) || embeddedActivities.instances[id].map { $0.location.guildID == nil } == true
            }
            instances.forEach(consumeEmbeddedActivity)
            // The snapshot lists every guild instance; one that ended while
            // disconnected is simply absent.
            if let hosted = embeddedActivities.session?.instance, hosted.location.guildID != nil,
               !instances.contains(where: { $0.compositeInstanceID == hosted.compositeInstanceID }) {
                embeddedActivities.endSession()
            }
        default:
            return
        }
        // Activity invite and launch cards show who is playing.
        serverInvites.changed()
    }

    private func consumeEmbeddedActivity(_ instance: EmbeddedActivityInstance) {
        let store = embeddedActivities
        // An instance being left is never hosted again, even by a relaunch in
        // the same place that is waiting for that leave.
        if store.departingInstances[instance.compositeInstanceID] != nil {
            if !instance.participants.contains(where: { $0.sessionID == store.gatewaySessionID }) {
                store.departingInstances[instance.compositeInstanceID] = nil
            }
            return
        }
        adoptCommandLaunch(instance)
        guard let session = store.session,
              session.application.id == instance.applicationID,
              session.location.id == instance.location.id
        else {
            // This client is in an instance it no longer hosts, such as a launch
            // that was left before Discord confirmed it.
            if store.session?.instance?.compositeInstanceID != instance.compositeInstanceID,
               instance.participants.contains(where: { $0.sessionID == store.gatewaySessionID }) {
                leaveEmbeddedActivity(instance)
            }
            return
        }
        guard isOwnInstance(instance, application: session.application.id, location: session.location) else {
            // Discord removed this session from the instance it was in.
            if session.instance?.compositeInstanceID == instance.compositeInstanceID { store.endSession() }
            return
        }
        // An instance from a later attempt, such as a retry after a timeout,
        // replaces one this launch adopted from an earlier attempt.
        let replacesInstance = session.instance.map { $0.compositeInstanceID != instance.compositeInstanceID } ?? false
        if replacesInstance, let previous = session.instance {
            store.host?.stop()
            store.host = nil
            leaveEmbeddedActivity(previous)
        }
        store.session?.instance = instance
        store.host?.participantsChanged()
        // The update can arrive before and after the launch request returns;
        // only the first one starts the Activity. It can also arrive after the
        // launch failed or timed out, and Discord counts this client as joined.
        guard session.instance == nil || replacesInstance else { return }
        store.session?.phase = .launching
        store.launchTimeout?.cancel()
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            do {
                let store = model.embeddedActivities
                // A slash command's Activity has no ticket yet; Discord launched it.
                let ticket = if let launchTicket = store.launchTicket, launchTicket.isUsable(for: session.launchID) {
                    launchTicket.ticket
                } else {
                    try await account.provider.embeddedActivityProxyTicket(
                        instance.applicationID, channelID: instance.location.channelID
                    )
                }
                guard store.session?.launchID == session.launchID,
                      store.session?.instance?.compositeInstanceID == instance.compositeInstanceID else { return }
                model.embeddedActivities.host = EmbeddedActivityHost(
                    model: model, instance: instance, application: session.application, launchID: session.launchID,
                    proxyTicket: ticket
                )
                model.embeddedActivities.session?.phase = .running
                // Recents count each Activity opened; a failed save only loses that count.
                try? await account.provider.recordEmbeddedActivityLaunch(instance.applicationID)
            } catch {
                guard model.embeddedActivities.session?.launchID == session.launchID,
                      model.embeddedActivities.session?.instance?.compositeInstanceID == instance.compositeInstanceID
                else { return }
                model.embeddedActivities.session?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Hosts the Activity this client's slash command started, such as
    /// `/wordle` in a text channel or DM. Discord has already moved this
    /// session out of any earlier instance, so that one closes without a leave.
    private func adoptCommandLaunch(_ instance: EmbeddedActivityInstance) {
        let store = embeddedActivities
        guard let participant = instance.participants.first(where: { participant in
            participant.userID == currentUser?.id && store.commandLaunches.contains { $0.nonce == participant.nonce }
        }), let index = store.commandLaunches.firstIndex(where: { $0.nonce == participant.nonce }) else { return }
        let command = store.commandLaunches.remove(at: index).application
        guard let channel = knownRootChannel(instance.location.channelID) else {
            leaveEmbeddedActivity(instance)
            return
        }
        store.endSession()
        store.gatewaySessionID = participant.sessionID
        store.session = EmbeddedActivityStore.Session(
            application: store.application(instance.applicationID) ?? EmbeddedActivityApplication(
                id: instance.applicationID, name: command.name, iconURL: command.displayIconURL
            ),
            channel: channel,
            phase: .launching,
            isInCall: activeVoiceChannel?.id == channel.id
        )
    }

    private func isOwnInstance(
        _ instance: EmbeddedActivityInstance,
        application: ApplicationID,
        location: EmbeddedActivityLocation
    ) -> Bool {
        instance.applicationID == application && instance.location.id == location.id
            && instance.participants.contains { $0.sessionID == embeddedActivities.gatewaySessionID }
    }
}
