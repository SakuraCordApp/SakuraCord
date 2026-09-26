import SakuraCordModels

extension AppModel {
    func toggleDirectMessagePin(_ channelID: ChannelID) {
        guard let channel = snapshot?.channels.first(where: {
            $0.id == channelID
                && ($0.kind == .directMessage || $0.kind == .groupDirectMessage)
        }), channelNotificationMutationTasks[channelID] == nil else { return }

        let currentOverride = channelNotificationOverride(for: channel)
            ?? ChannelNotificationOverride(channelID: channelID)
        let isPinned = !currentOverride.isPinnedDirectMessage
        let flags = currentOverride.flags(settingPinnedDirectMessage: isPinned)
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        channelNotificationMutationTasks[channelID] = Task { [weak self] in
            do {
                try await activeProvider.updateDirectMessagePin(
                    channelID: channelID,
                    flags: flags
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.updateLocalChannelNotificationOverride(channel: channel) {
                    $0.flags = $0.flags(settingPinnedDirectMessage: isPinned)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.errorMessage = "Discord did not accept the direct message pin."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration
            else { return }
            self.channelNotificationMutationTasks[channelID] = nil
        }
    }
}
