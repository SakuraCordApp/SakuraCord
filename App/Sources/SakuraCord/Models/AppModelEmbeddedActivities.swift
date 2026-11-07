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
            case authorize(scopes: [String])
            case openLink(URL)
            case confirmAge
        }

        let id = UUID()
        var applicationName: String
        var kind: Kind
        var resolve: (Bool) -> Void
    }

    /// Running instances by composite instance ID.
    private(set) var instances: [String: EmbeddedActivityInstance] = [:]
    var shelves: [GuildID?: [EmbeddedActivityApplication]] = [:]
    /// Shelf loads in flight, so a second caller waits for the first.
    @ObservationIgnored var shelfLoads: [GuildID?: Task<Void, Never>] = [:]
    var shelfError: String?
    var session: Session?
    var prompt: Prompt?
    @ObservationIgnored var host: EmbeddedActivityHost?
    @ObservationIgnored var gatewaySessionID: String?
    @ObservationIgnored var launch: Task<Void, any Error>?
    @ObservationIgnored var launchTimeout: Task<Void, Never>?
    /// Leaves still on their way to Discord, by composite instance ID.
    @ObservationIgnored var pendingLeaves: [String: Task<Void, Never>] = [:]
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

    func instances(in channelID: ChannelID) -> [EmbeddedActivityInstance] {
        instances.values.filter { $0.location.channelID == channelID }
            .sorted { $0.compositeInstanceID < $1.compositeInstanceID }
    }

    func application(_ id: ApplicationID) -> EmbeddedActivityApplication? {
        shelves.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Asks the person; a cancelled caller, such as one outliving its account,
    /// is declined so nothing waits on a prompt nobody will answer.
    func ask(_ kind: Prompt.Kind, applicationName: String) async -> Bool {
        prompt?.resolve(false)
        guard !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var isResolved = false
                prompt = Prompt(applicationName: applicationName, kind: kind) { [weak self] granted in
                    guard !isResolved else { return }
                    isResolved = true
                    self?.prompt = nil
                    continuation.resume(returning: granted)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.prompt?.resolve(false) }
        }
    }

    func endSession() {
        launch?.cancel()
        launch = nil
        launchTimeout?.cancel()
        launchTimeout = nil
        host?.stop()
        host = nil
        prompt?.resolve(false)
        session = nil
    }

    func reset() {
        endSession()
        instances = [:]
        shelves = [:]
        shelfLoads = [:]
        shelfError = nil
        gatewaySessionID = nil
        pendingLeaves = [:]
        commandLaunches = []
        ageConfirmedApplications = []
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
        return permissions & ((1 << 39) | DiscordPermissionBits.administrator) != 0
    }

    func retryActivity() async {
        guard let session = embeddedActivities.session else { return }
        await startActivity(session.application, in: session.channel)
    }

    func loadActivityShelf(guildID: GuildID?) async {
        let store = embeddedActivities
        if let load = store.shelfLoads[guildID] { return await load.value }
        let load = Task { await fetchActivityShelf(guildID: guildID) }
        store.shelfLoads[guildID] = load
        await load.value
        if store.shelfLoads[guildID] == load { store.shelfLoads[guildID] = nil }
    }

    private func fetchActivityShelf(guildID: GuildID?) async {
        let account = accountSession()
        do {
            let shelf = try await account.provider.embeddedActivityShelf(guildID: guildID)
            guard isCurrentAccountSession(account) else { return }
            embeddedActivities.shelves[guildID] = shelf
            embeddedActivities.shelfError = nil
            // Activity cards drawn before the shelf arrived pick up its cover.
            serverInvites.changed()
        } catch {
            guard isCurrentAccountSession(account) else { return }
            embeddedActivities.shelfError = error.localizedDescription
        }
    }

    /// Starts the application in the channel, or joins the instance already
    /// running there. A voice channel Activity runs alongside voice; elsewhere
    /// it docks in the channel's chat.
    func startActivity(_ application: EmbeddedActivityApplication, in channel: Channel) async {
        let store = embeddedActivities
        let account = accountSession()
        let location = EmbeddedActivityLocation.of(channel)
        if let current = store.session, current.application.id == application.id, current.location == location,
           current.phase == .launching || current.phase == .running {
            return
        }
        if application.requiresAgeGate, !store.ageConfirmedApplications.contains(application.id) {
            guard await store.ask(.confirmAge, applicationName: application.name),
                  isCurrentAccountSession(account) else { return }
            store.ageConfirmedApplications.insert(application.id)
        }
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
        // Ending the session cancels a launch that has not reached Discord yet.
        let launch = Task {
            store.gatewaySessionID = try await account.provider.embeddedActivitySessionID()
            try await account.provider.launchEmbeddedActivity(application.id, in: channel)
        }
        store.launch = launch
        do {
            try await launch.value
        } catch {
            // The instance update can arrive before a lost launch response.
            guard isCurrentAccountSession(account), store.session?.launchID == session.launchID,
                  store.session?.instance == nil else { return }
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
        embeddedActivities.pendingLeaves[id] = startAccountChildTask(account: accountSession()) { model, account in
            try? await account.provider.leaveEmbeddedActivity(instance)
            model.embeddedActivities.pendingLeaves[id] = nil
        }
    }

    /// Players in the instance an Activity invite or launch message points
    /// to, once per account however many of its sessions take part.
    func activityPlayers(reference: ServerInviteReference?, instanceID: String?) -> [UserID] {
        let instance = instanceID.flatMap { embeddedActivities.instances[$0] }
            ?? reference.flatMap { inviteEntry(for: $0)?.invite }.flatMap(activityInstance(for:))
        var seen = Set<UserID>()
        return (instance?.participants ?? []).map(\.userID).filter { seen.insert($0).inserted }
    }

    func activityPlayerAvatarURL(_ userID: UserID) -> URL? {
        (currentUser?.id == userID ? currentUser : membersByID[userID]?.user)?.avatarURL
    }

    /// The launch message's button: join a running instance, or show it joined or ended.
    func activityInstanceAction(_ instanceID: String) -> (String, Bool) {
        if embeddedActivities.session?.instance?.compositeInstanceID == instanceID { return ("Joined", true) }
        guard let instance = embeddedActivities.instances[instanceID] else { return ("Ended", true) }
        return ("Join", activityChannel(instance) == nil)
    }

    /// Where this client can host the instance. Threads are not hosted yet.
    private func activityChannel(_ instance: EmbeddedActivityInstance) -> Channel? {
        knownRootChannel(instance.location.channelID)
    }

    /// Joins the instance an application's launch message announced. Outside
    /// a voice channel it needs no call, as in an application's own DM.
    func joinActivityInstance(_ instanceID: String, from message: Message) async {
        guard let instance = embeddedActivities.instances[instanceID], let channel = activityChannel(instance) else { return }
        guard let application = await shelfApplication(instance.applicationID, guildID: channel.guildID, fallback: {
            EmbeddedActivityApplication(id: instance.applicationID, name: message.author.displayName, iconURL: message.author.avatarURL)
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

    /// The shelf's details for an Activity a card points to, loading the shelf
    /// first. Without them the Activity is treated as age-restricted, so a
    /// card never skips the confirmation the shelf would ask for.
    /// Nil once the account changed or the caller was cancelled while loading.
    private func shelfApplication(
        _ id: ApplicationID, guildID: GuildID?, fallback: () -> EmbeddedActivityApplication
    ) async -> EmbeddedActivityApplication? {
        let account = accountSession()
        if embeddedActivities.application(id) == nil { await loadActivityShelf(guildID: guildID) }
        guard isCurrentAccountSession(account), !Task.isCancelled else { return nil }
        if let application = embeddedActivities.application(id) { return application }
        var application = fallback()
        application.requiresAgeGate = true
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
        store.session?.instance = instance
        store.host?.participantsChanged()
        // The update can arrive before and after the launch request returns;
        // only the first one starts the Activity. It can also arrive after the
        // launch failed or timed out, and Discord counts this client as joined.
        guard session.instance == nil else { return }
        store.session?.phase = .launching
        store.launchTimeout?.cancel()
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            do {
                let ticket = try await account.provider.embeddedActivityProxyTicket(
                    instance.applicationID, channelID: instance.location.channelID
                )
                guard model.embeddedActivities.session?.launchID == session.launchID else { return }
                model.embeddedActivities.host = EmbeddedActivityHost(
                    model: model, instance: instance, application: session.application, proxyTicket: ticket
                )
                model.embeddedActivities.session?.phase = .running
            } catch {
                guard model.embeddedActivities.session?.launchID == session.launchID else { return }
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
        guard let channel = activityChannel(instance) else {
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
