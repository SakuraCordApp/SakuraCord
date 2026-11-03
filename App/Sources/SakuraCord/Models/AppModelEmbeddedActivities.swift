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
        /// Tells this launch's late results apart from a newer one in the same place.
        let launchID = UUID()

        var location: EmbeddedActivityLocation { .of(channel) }
    }

    /// A question the Activity's host must ask before acting for it.
    struct Prompt: Identifiable {
        enum Kind {
            case authorize(scopes: [String])
            case openLink(URL)
        }

        let id = UUID()
        var applicationName: String
        var kind: Kind
        var resolve: (Bool) -> Void
    }

    /// Running instances by composite instance ID.
    private(set) var instances: [String: EmbeddedActivityInstance] = [:]
    var shelves: [GuildID?: [EmbeddedActivityApplication]] = [:]
    var shelfError: String?
    var session: Session?
    var prompt: Prompt?
    @ObservationIgnored var host: EmbeddedActivityHost?
    @ObservationIgnored var gatewaySessionID: String?
    @ObservationIgnored var launch: Task<Void, any Error>?
    @ObservationIgnored var launchTimeout: Task<Void, Never>?
    /// Leaves still on their way to Discord, by composite instance ID.
    @ObservationIgnored var pendingLeaves: [String: Task<Void, Never>] = [:]

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

    func ask(_ kind: Prompt.Kind, applicationName: String) async -> Bool {
        prompt?.resolve(false)
        return await withCheckedContinuation { continuation in
            prompt = Prompt(applicationName: applicationName, kind: kind) { [weak self] granted in
                self?.prompt = nil
                continuation.resume(returning: granted)
            }
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
        shelfError = nil
        gatewaySessionID = nil
        pendingLeaves = [:]
    }
}

extension EmbeddedActivityLocation {
    static func of(_ channel: Channel) -> Self {
        let id = channel.guildID.map { "gc-\($0)-\(channel.id)" } ?? "pc-\(channel.id)"
        return Self(id: id, channelID: channel.id, guildID: channel.guildID)
    }
}

extension AppModel {
    func loadActivityShelf(guildID: GuildID?) async {
        let account = accountSession()
        do {
            let shelf = try await account.provider.embeddedActivityShelf(guildID: guildID)
            guard isCurrentAccountSession(account) else { return }
            embeddedActivities.shelves[guildID] = shelf
            embeddedActivities.shelfError = nil
        } catch {
            guard isCurrentAccountSession(account) else { return }
            embeddedActivities.shelfError = error.localizedDescription
        }
    }

    /// Starts the application in the channel, or joins the instance already
    /// running there. A guild Activity runs alongside voice in that channel.
    func startActivity(_ application: EmbeddedActivityApplication, in channel: Channel) async {
        let store = embeddedActivities
        let account = accountSession()
        if store.session != nil { leaveActivity() }
        let location = EmbeddedActivityLocation.of(channel)
        let session = EmbeddedActivityStore.Session(application: application, channel: channel, phase: .launching)
        store.session = session
        if channel.guildID != nil, activeVoiceChannel?.id != channel.id {
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
            try await account.provider.launchEmbeddedActivity(application.id, channelID: channel.id, guildID: channel.guildID)
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

    /// Players in the instance an Activity invite or launch message points to.
    func activityPlayers(reference: ServerInviteReference?, instanceID: String?) -> Int {
        let instance = instanceID.flatMap { embeddedActivities.instances[$0] }
            ?? reference.flatMap { inviteEntry(for: $0)?.invite }.flatMap(activityInstance(for:))
        return instance?.participants.count ?? 0
    }

    /// The launch message's button: join a running instance, or show it joined or ended.
    func activityInstanceAction(_ instanceID: String) -> (String, Bool) {
        if embeddedActivities.session?.instance?.compositeInstanceID == instanceID { return ("Joined", true) }
        guard let instance = embeddedActivities.instances[instanceID] else { return ("Ended", true) }
        return ("Join", activityChannel(instance) == nil)
    }

    /// Where this client can host the instance: a voice channel, or a DM or
    /// group call. An application's own DM has no call to host it in.
    private func activityChannel(_ instance: EmbeddedActivityInstance) -> Channel? {
        guard let channel = knownRootChannel(instance.location.channelID),
              channel.guildID != nil || channel.recipients.contains(where: { !$0.isBot })
        else { return nil }
        return channel
    }

    /// Joins the instance an application's launch message announced, joining
    /// the call first in a DM or group, where the Activity lives in the call.
    func joinActivityInstance(_ instanceID: String, from message: Message) async {
        guard let instance = embeddedActivities.instances[instanceID], let channel = activityChannel(instance) else { return }
        let application = embeddedActivities.application(instance.applicationID) ?? EmbeddedActivityApplication(
            id: instance.applicationID, name: message.author.displayName, iconURL: message.author.avatarURL
        )
        if channel.guildID == nil, activeVoiceChannel?.id != channel.id {
            let launchID = embeddedActivities.session?.launchID
            await joinPrivateCall(in: channel)
            // An Activity chosen while the call connected wins; leaving voice
            // for the call may have ended the earlier one.
            guard activeVoiceChannel?.id == channel.id,
                  embeddedActivities.session.map({ $0.launchID == launchID }) ?? true
            else { return }
        }
        await startActivity(application, in: channel)
    }

    func isInActivityInvite(_ invite: ServerInvite) -> Bool {
        guard let instance = activityInstance(for: invite) else { return false }
        return embeddedActivities.session?.instance?.compositeInstanceID == instance.compositeInstanceID
    }

    func joinActivityInvite(_ invite: ServerInvite) async {
        guard let activity = invite.activity, let channelID = invite.channelID,
              let channel = knownRootChannel(channelID)
        else { return }
        let application = embeddedActivities.application(activity.applicationID) ?? EmbeddedActivityApplication(
            id: activity.applicationID, name: activity.name, iconURL: activity.iconURL, coverURL: activity.coverURL
        )
        navigate(to: channel.id)
        await startActivity(application, in: channel)
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
        // only the first one starts the Activity.
        guard session.phase == .launching, session.instance == nil else { return }
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

    private func isOwnInstance(
        _ instance: EmbeddedActivityInstance,
        application: ApplicationID,
        location: EmbeddedActivityLocation
    ) -> Bool {
        instance.applicationID == application && instance.location.id == location.id
            && instance.participants.contains { $0.sessionID == embeddedActivities.gatewaySessionID }
    }
}
