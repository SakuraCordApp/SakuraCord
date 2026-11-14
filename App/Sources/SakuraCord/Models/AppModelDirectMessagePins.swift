import SakuraCordModels

extension AppModel {
    func toggleDirectMessagePin(_ channelID: ChannelID) {
        guard let channel = snapshot?.channels.first(where: {
            $0.id == channelID
                && $0.kind.isDirectMessage
        }), !isNotificationMutationPending(.channel(channelID)) else { return }

        let currentOverride = channelNotificationOverride(for: channel)
            ?? ChannelNotificationOverride(channelID: channelID)
        let isPinned = !currentOverride.isPinned
        let flags = currentOverride.flags(settingPinned: isPinned)
        runNotificationMutation(.channel(channelID), failureMessage: "Discord did not accept the direct message pin.") {
            try await $0.updateChannelPin(guildID: nil, channelID: channelID, flags: flags)
        } apply: { model in
            model.updateLocalChannelNotificationOverride(channel: channel) { $0.flags = $0.flags(settingPinned: isPinned) }
        }
    }
}
