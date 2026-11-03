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
        var location: EmbeddedActivityLocation
        var instance: EmbeddedActivityInstance?
        var phase: Phase
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
    @ObservationIgnored var launchTimeout: Task<Void, Never>?

    func upsert(_ instance: EmbeddedActivityInstance) {
        instances[instance.compositeInstanceID] = instance.participants.isEmpty ? nil : instance
    }

    func replaceInstances(_ instances: [EmbeddedActivityInstance]) {
        self.instances = Dictionary(
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
        if store.session != nil { await leaveActivity() }
        if channel.guildID != nil, activeVoiceChannel?.id != channel.id {
            await joinVoice(channel)
            guard isCurrentAccountSession(account), activeVoiceChannel?.id == channel.id else { return }
        }
        let location = EmbeddedActivityLocation.of(channel)
        store.session = .init(application: application, channel: channel, location: location, phase: .launching)
        do {
            store.gatewaySessionID = try await account.provider.embeddedActivitySessionID()
            try await account.provider.launchEmbeddedActivity(application.id, channelID: channel.id, guildID: channel.guildID)
        } catch {
            guard isCurrentAccountSession(account), store.session?.location == location else { return }
            store.session?.phase = .failed(error.localizedDescription)
            return
        }
        guard isCurrentAccountSession(account), store.session?.location == location else { return }
        if let instance = store.instances.values.first(where: { isOwnInstance($0, application: application.id, location: location) }) {
            consumeEmbeddedActivity(instance)
        }
        store.launchTimeout?.cancel()
        store.launchTimeout = Task { @MainActor [weak store] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, store?.session?.phase == .launching, store?.session?.location == location else { return }
            store?.session?.phase = .failed("\(application.name) did not start. Try again.")
        }
    }

    func leaveActivity() async {
        let store = embeddedActivities
        let instance = store.session?.instance
        store.endSession()
        guard let instance else { return }
        try? await accountSession().provider.leaveEmbeddedActivity(instance)
    }

    /// Players in the instance an Activity invite points to.
    func activityInvitePlayers(_ reference: ServerInviteReference) -> Int {
        guard let invite = inviteEntry(for: reference)?.invite else { return 0 }
        return activityInstance(for: invite)?.participants.count ?? 0
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
        return embeddedActivities.instances(in: channelID).first { $0.applicationID == activity.applicationID }
    }

    func consumeEmbeddedActivityEvent(_ event: ClientEvent) {
        switch event {
        case .embeddedActivityChanged(let instance):
            embeddedActivities.upsert(instance)
            consumeEmbeddedActivity(instance)
        case .embeddedActivitiesReceived(let instances):
            embeddedActivities.replaceInstances(instances)
            instances.forEach(consumeEmbeddedActivity)
        default:
            return
        }
        // Activity invite cards show who is playing.
        if serverInvites.entries.values.contains(where: { $0.invite?.activity != nil }) { serverInvites.changed() }
    }

    private func consumeEmbeddedActivity(_ instance: EmbeddedActivityInstance) {
        let store = embeddedActivities
        guard let session = store.session,
              session.application.id == instance.applicationID,
              session.location.id == instance.location.id
        else { return }
        guard isOwnInstance(instance, application: session.application.id, location: session.location) else {
            // Discord removed this session from the instance it was in.
            if session.instance?.compositeInstanceID == instance.compositeInstanceID { store.endSession() }
            return
        }
        store.session?.instance = instance
        store.host?.participantsChanged()
        guard session.phase == .launching else { return }
        store.launchTimeout?.cancel()
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            do {
                let ticket = try await account.provider.embeddedActivityProxyTicket(
                    instance.applicationID, channelID: instance.location.channelID
                )
                guard model.embeddedActivities.session?.instance?.compositeInstanceID == instance.compositeInstanceID
                else { return }
                model.embeddedActivities.host = EmbeddedActivityHost(
                    model: model, instance: instance, application: session.application, proxyTicket: ticket
                )
                model.embeddedActivities.session?.phase = .running
            } catch {
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
