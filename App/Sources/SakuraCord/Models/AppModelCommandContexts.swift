import SakuraCordModels

extension AppModel {
    var commandComposers: [ApplicationCommandComposerModel] { [commandComposer, threadCommandComposer] }

    func commandComposer(for destination: MessageComposerDestination) -> ApplicationCommandComposerModel {
        destination == .thread ? threadCommandComposer : commandComposer
    }

    /// Threads inherit their parent's command availability, but interactions
    /// always target the thread itself. A creation draft has no destination yet.
    func commandContext(for destination: MessageComposerDestination) -> (channelID: ChannelID, channel: Channel)? {
        switch destination {
        case .channel:
            guard let channel = selectedChannel, channel.kind != .forum, channel.kind != .unknown else { return nil }
            return (channel.id, channel)
        case .thread:
            guard threadCreation == nil, let thread = openThread, let parent = openThreadParentChannel else { return nil }
            return (thread.id, parent)
        }
    }

    func commandDestination(in channelID: ChannelID) -> MessageComposerDestination {
        openThread?.id == channelID ? .thread : .channel
    }

    func invalidateApplicationCommandIndex(_ target: ApplicationCommandIndexTarget) {
        for destination in [MessageComposerDestination.channel, .thread]
            where commandComposer(for: destination).invalidated(target)
        {
            loadApplicationCommands(in: destination)
        }
        // Every place Recents were read for, including a read still in flight.
        for guildID in embeddedActivities.installedLoads.keys
            where target == .user || guildID.map(ApplicationCommandIndexTarget.guild) == target
        {
            loadInstalledActivities(guildID: guildID)
        }
    }

    func updateCommandFrecency(_ history: DiscordFrecencyHistory) {
        commandComposer.applyRemoteFrecency(history)
        threadCommandComposer.refreshFrecency()
    }
}
