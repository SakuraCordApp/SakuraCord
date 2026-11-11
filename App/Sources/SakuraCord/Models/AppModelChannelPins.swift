import SakuraCordModels

extension AppModel {
    /// Discord saves every pin toggle at once. Waiting for a pause turns rapid
    /// toggling into one save of the final state, or none if it ends unchanged.
    static let channelPinDebounce: Duration = .seconds(1)

    func isChannelPinned(_ channel: Channel) -> Bool {
        optimisticChannelPinnedByID[channel.id] ?? channelNotificationOverride(for: channel)?.isPinned ?? false
    }

    /// A server's pinned channel IDs in its override order, which Discord uses
    /// to break position ties, with pending edits applied.
    func pinnedChannelIDs(in guildID: GuildID) -> [ChannelID] {
        // Pending Browse Channels edits can unpin, so read the presented settings.
        let overrides = presentedGuildChannelSettings(in: guildID).channelOverrides
        let optimistic = optimisticChannelPinnedByID
        guard !optimistic.isEmpty else { return overrides.filter(\.isPinned).map(\.channelID) }
        let pinned = overrides.filter { optimistic[$0.channelID] ?? $0.isPinned }.map(\.channelID)
        let added = optimistic.filter { id, isPinned in
            isPinned && !overrides.contains { $0.channelID == id }
        }
        return pinned + added.keys.sorted()
    }

    /// The server's channel groups with its Pinned Channels section in front.
    func pinnedChannelGroups(_ groups: [ChannelGroup], guildID: GuildID) -> [ChannelGroup] {
        ChannelGroup.pinning(pinnedChannelIDs(in: guildID), in: groups, guildID: guildID, excluding: hiddenChannelIDs)
    }

    func toggleChannelPin(_ channel: Channel) {
        guard let guildID = channel.guildID else { return }
        let channelID = channel.id
        let isPinned = !isChannelPinned(channel)
        optimisticChannelPinnedByID[channelID] = isPinned

        if var mutation = channelPinMutationStates[channelID] {
            mutation.desiredPinned = isPinned
            mutation.editedAt = .now
            channelPinMutationStates[channelID] = mutation
            return
        }
        channelPinMutationStates[channelID] = ChannelPinMutationState(
            guildID: guildID,
            confirmedPinned: !isPinned,
            desiredPinned: isPinned,
            editedAt: .now
        )
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
                // Build on pending Browse Channels edits too, so this save
                // never reverts an opt-in or opt-out made meanwhile.
                let override = self.presentedGuildChannelSettings(in: mutation.guildID).channelOverrides
                    .first { $0.channelID == channelID } ?? ChannelNotificationOverride(channelID: channelID)
                // Pinning also opts the channel in, as Discord does, so Browse
                // Channels keeps it listed; unpinning leaves that choice alone.
                let flags = sentValue
                    ? override.flags(settingPinned: true) | GuildChannelSelection.selectedFlag
                    : override.flags(settingPinned: false)
                let revision = self.guildNotificationSettingsRevisions[mutation.guildID]
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
                // A settings update received meanwhile is newer than this write.
                guard self.guildNotificationSettingsRevisions[current.guildID] == revision else { continue }
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
}
