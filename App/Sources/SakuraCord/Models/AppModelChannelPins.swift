import SakuraCordModels

extension AppModel {
    /// Discord saves every pin toggle at once. Waiting for a pause turns rapid
    /// toggling into one save of the final state, or none if it ends unchanged.
    static let channelPinDebounce: Duration = .seconds(1)

    func isChannelPinned(_ channel: Channel) -> Bool {
        guard let guildID = channel.guildID else { return false }
        return optimisticChannelPinnedByID[channel.id]
            ?? readState.notificationOverride(channelID: channel.id, guildID: guildID)?.isPinned
            ?? false
    }

    /// A server's pinned channel IDs in its override order, which Discord uses
    /// to break position ties, with pending edits applied.
    func pinnedChannelIDs(in guildID: GuildID) -> [ChannelID] {
        let overrides = readState.notificationSettings(guildID: guildID)?.channelOverrides ?? []
        let listed = Set(overrides.map(\.channelID))
        return overrides.filter { optimisticChannelPinnedByID[$0.channelID] ?? $0.isPinned }.map(\.channelID)
            + optimisticChannelPinnedByID.filter { $0.value && !listed.contains($0.key) }.keys.sorted()
    }

    func toggleChannelPin(_ channel: Channel) {
        guard let guildID = channel.guildID else { return }
        let isPinned = !isChannelPinned(channel)
        optimisticChannelPinnedByID[channel.id] = isPinned

        if var mutation = channelPinMutationStates[channel.id] {
            mutation.desiredPinned = isPinned
            mutation.editedAt = .now
            channelPinMutationStates[channel.id] = mutation
            return
        }
        channelPinMutationStates[channel.id] = ChannelPinMutationState(
            guildID: guildID,
            confirmedPinned: !isPinned,
            desiredPinned: isPinned,
            editedAt: .now
        )
        let channelID = channel.id
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        channelPinMutationTasks[channelID] = Task { [weak self] in
            while let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration,
                  let mutation = self.channelPinMutationStates[channelID]
            {
                let quietUntil = mutation.editedAt + AppModel.channelPinDebounce
                if quietUntil > .now {
                    do { try await Task.sleep(until: quietUntil) } catch { return }
                    continue
                }
                if mutation.desiredPinned == mutation.confirmedPinned {
                    self.finishChannelPinMutation(channelID: channelID)
                    return
                }

                let sentValue = mutation.desiredPinned
                let override = self.readState.notificationOverride(channelID: channelID, guildID: mutation.guildID)
                    ?? ChannelNotificationOverride(channelID: channelID)
                // Pinning also opts the channel in, as Discord does, so Browse
                // Channels keeps it listed; unpinning leaves that choice alone.
                let flags = sentValue
                    ? override.flags(settingPinned: true) | GuildChannelSelection.selectedFlag
                    : override.flags(settingPinned: false)
                do {
                    try await activeProvider.updateChannelPin(
                        guildID: mutation.guildID,
                        channelID: channelID,
                        flags: flags
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrentAccountSession(session),
                          generation == self.channelNotificationMutationGeneration
                    else { return }
                    self.errorMessage = "Discord did not accept the channel pin."
                    self.finishChannelPinMutation(channelID: channelID)
                    return
                }

                guard self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration,
                      var current = self.channelPinMutationStates[channelID]
                else { return }
                current.confirmedPinned = sentValue
                self.channelPinMutationStates[channelID] = current
                self.updateLocalChannelNotificationOverride(
                    guildID: current.guildID,
                    channelID: channelID
                ) { $0.flags = flags }
            }
        }
    }

    private func finishChannelPinMutation(channelID: ChannelID) {
        channelPinMutationStates[channelID] = nil
        optimisticChannelPinnedByID[channelID] = nil
        channelPinMutationTasks[channelID] = nil
    }

    /// Moves a server's pinned channels into Discord's Pinned Channels section.
    func pinningChannels(_ groups: [ChannelGroup], guildID: GuildID) -> [ChannelGroup] {
        let pinnedIDs = pinnedChannelIDs(in: guildID)
        guard !pinnedIDs.isEmpty else { return groups }
        return ChannelGroup.pinning(pinnedIDs, in: groups, excluding: hiddenChannelIDs)
    }
}
