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
            acknowledgementTasks[target.channelID]?.cancel()
            acknowledgementTasks[target.channelID] = nil
            debouncedAcknowledgementTargets[target.channelID] = nil
            queuedAcknowledgements[target.channelID] = nil
            acknowledgementQueueOrder.removeAll { $0 == target.channelID }
            readState.unblockAutomaticAcknowledgement(channelID: target.channelID)
            readState.markAcknowledgementPending(channelID: target.channelID, messageID: target.messageID)
        }
        isMarkingAllServersRead = true
        refreshUnreadPresentation()
        reconcileInboxReadState()
        let generation = acknowledgementGeneration
        let session = accountSession()
        allServersReadTask = Task { [weak self] in
            // Account teardown may cancel this task before it reaches the provider.
            guard !Task.isCancelled, self?.isCurrentAccountSession(session) == true,
                  self?.acknowledgementGeneration == generation else { return }
            do {
                try await session.provider.acknowledgeBulk(targets)
                guard let self, isCurrentAccountSession(session), generation == acknowledgementGeneration else { return }
                for target in targets {
                    readState.completeAcknowledgement(channelID: target.channelID, messageID: target.messageID, token: nil)
                }
            } catch let partial as PartialBulkReadAcknowledgementError {
                guard let self, isCurrentAccountSession(session), generation == acknowledgementGeneration else { return }
                resolvePartialBulkAcknowledgement(partial, targets: targets)
                errorMessage = "Some conversations could not be marked as read.\n\n\(partial.failureDescription)"
            } catch {
                guard let self, isCurrentAccountSession(session), generation == acknowledgementGeneration else { return }
                for target in targets {
                    readState.failAcknowledgement(channelID: target.channelID, messageID: target.messageID)
                }
                errorMessage = "Conversations could not be marked as read.\n\n\(error.localizedDescription)"
            }
            guard let self, isCurrentAccountSession(session), generation == acknowledgementGeneration else { return }
            for target in targets where readState[target.channelID]?.isUnread == false {
                cancelNativeNotifications(channelID: target.channelID)
            }
            isMarkingAllServersRead = false
            allServersReadTask = nil
            refreshUnreadPresentation()
            reconcileInboxReadState()
        }
    }
}
