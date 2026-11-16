import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// Adds a private channel the provider opened to the snapshot, unless
    /// the snapshot already lists it.
    func mergeOpenedPrivateChannel(_ channel: Channel) {
        guard snapshot?.channels.contains(where: { $0.id == channel.id }) == false else { return }
        snapshot?.channels.append(channel)
        destinationSearchSourceRevision &+= 1
    }

    /// Opens the existing conversation, or creates it through the provider.
    func openDirectMessage(with user: User) {
        if let channel = snapshot?.channels.first(where: {
            $0.kind == .directMessage && $0.recipients.first?.id == user.id
        }) {
            navigate(to: channel.id)
            return
        }
        startConversationNavigation(presentsFavorites: false) { model, session in
            do {
                let channel = try await session.provider.ensurePrivateChannel(for: user.id)
                guard !Task.isCancelled, model.isCurrentAccountSession(session) else { return }
                model.mergeOpenedPrivateChannel(channel)
                if model.selectedGuildID != nil { await model.activateGuild(nil, account: session) }
                guard !Task.isCancelled, model.isCurrentAccountSession(session) else { return }
                model.recordConversationDestinationVisit(channel.id)
                model.closeThread()
                model.selectedChannelID = channel.id
            } catch {
                guard !Task.isCancelled, model.isCurrentAccountSession(session), !(error is CancellationError) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
