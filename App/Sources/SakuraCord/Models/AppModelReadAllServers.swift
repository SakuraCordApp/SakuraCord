import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    var hasUnreadServers: Bool {
        guard !accountTransitionIsActive, currentUser != nil else { return false }
        return readState.hasUnreadServerConversations(in: Set(serverRailGuildsByID.values.filter { !$0.isUnavailable }.map(\.id)))
    }

    func markAllServersRead() {
        guard featuresSettings.readAllButton, !runsChatPerformanceBenchmark,
              !isMarkingAllServersRead, !accountTransitionIsActive,
              let snapshot
        else { return }
        let targets = readState.allServerAcknowledgements(in: Set(snapshot.guilds.filter { !$0.isUnavailable }.map(\.id)))
        guard !targets.isEmpty else { return }

        for target in targets {
            preserveUnreadDividerIfNeeded(channelID: target.channelID)
            discardPendingAcknowledgement(for: target.channelID)
            readState.unblockAutomaticAcknowledgement(channelID: target.channelID)
            readState.acknowledge(channelID: target.channelID, messageID: target.messageID)
        }
        isMarkingAllServersRead = true
        refreshUnreadPresentation()
        let generation = acknowledgementGeneration
        let session = accountSession()
        allServersReadTask = Task { [weak self] in
            // Account teardown may cancel this task before it reaches the provider.
            guard !Task.isCancelled, self?.isCurrentAccountSession(session) == true,
                  self?.acknowledgementGeneration == generation else { return }
            // As in Discord, a failed batch is dropped silently.
            try? await session.provider.acknowledgeBulk(targets)
            guard let self, isCurrentAccountSession(session), generation == acknowledgementGeneration else { return }
            for target in targets where readState[target.channelID]?.isUnread == false {
                cancelNativeNotifications(channelID: target.channelID)
            }
            isMarkingAllServersRead = false
            allServersReadTask = nil
        }
    }
}
