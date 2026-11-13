import Foundation
import SakuraCordModels

struct GuildChannelSelectionMutation {
    let identity = UUID()
    var revision = UUID()
    var enabled: Bool?
    var channels: [ChannelID: Bool] = [:]
    var isSaving = false

    func applying(to settings: GuildNotificationSettings) -> GuildNotificationSettings {
        var value = settings
        if let enabled {
            value.flags = enabled ? value.flags | GuildChannelSelection.enabledFlag : value.flags & ~GuildChannelSelection.enabledFlag
        }
        for (channelID, selected) in channels {
            value.updateChannelOverride(channelID) {
                $0.flags = selected
                    ? $0.flags | GuildChannelSelection.selectedFlag
                    : $0.flags & ~(GuildChannelSelection.selectedFlag | ChannelNotificationOverride.pinnedFlag)
            }
        }
        return value
    }
}

extension AppModel {
    func isUncustomizedMember(in guildID: GuildID) -> Bool {
        let settings = presentedGuildChannelSettings(in: guildID)
        return settings.flags & GuildChannelSelection.enabledFlag == 0
            && (onboardingMember(in: guildID)?.flags ?? 0) & 2 == 0
            && !settings.channelOverrides.contains { $0.flags & GuildChannelSelection.selectedFlag != 0 }
    }

    func showsAllChannels(in guildID: GuildID) -> Bool {
        !featuresSettings.channelManagement || !hasChannelsAndRoles(in: guildID)
            || presentedGuildChannelSettings(in: guildID).flags & GuildChannelSelection.enabledFlag == 0
    }

    func isChannelSelected(_ channel: Channel) -> Bool {
        guard let guildID = channel.guildID else { return true }
        let settings = presentedGuildChannelSettings(in: guildID)
        return GuildChannelSelection.isSelected(channel.id, settings: settings)
            || channel.categoryID.map { GuildChannelSelection.isSelected($0, settings: settings) } == true
    }

    func presentedGuildChannelSettings(in guildID: GuildID) -> GuildNotificationSettings {
        let confirmed = readState.notificationSettings(guildID: guildID) ?? GuildNotificationSettings(guildID: guildID)
        return onboarding.channelSelections[guildID]?.applying(to: confirmed) ?? confirmed
    }

    func setChannelSelectionEnabled(_ enabled: Bool, guildID: GuildID) {
        guard featuresSettings.channelManagement else { return }
        onboarding.entries[guildID, default: .init()].error = nil
        var pending = onboarding.channelSelections[guildID] ?? .init()
        if enabled, isUncustomizedMember(in: guildID) {
            for channel in browsableChannels(in: guildID) { pending.channels[channel.id] = true }
            for id in onboarding.entries[guildID]?.configuration?.defaultChannelIDs ?? [] { pending.channels[id] = true }
        }
        pending.enabled = enabled
        pending.revision = UUID()
        onboarding.channelSelections[guildID] = pending
        scheduleGuildChannelSelection(in: guildID)
    }

    func setChannelSelected(_ selected: Bool, channelID: ChannelID, guildID: GuildID) {
        guard featuresSettings.channelManagement else { return }
        onboarding.entries[guildID, default: .init()].error = nil
        var pending = onboarding.channelSelections[guildID] ?? .init()
        if isUncustomizedMember(in: guildID) {
            for channel in browsableChannels(in: guildID) { pending.channels[channel.id] = true }
            for id in onboarding.entries[guildID]?.configuration?.defaultChannelIDs ?? [] { pending.channels[id] = true }
        }
        pending.channels[channelID] = selected
        if presentedGuildChannelSettings(in: guildID).flags & GuildChannelSelection.enabledFlag == 0 { pending.enabled = true }
        pending.revision = UUID()
        onboarding.channelSelections[guildID] = pending
        scheduleGuildChannelSelection(in: guildID)
    }

    private func scheduleGuildChannelSelection(in guildID: GuildID) {
        let store = onboarding
        guard let entry = store.channelSelections[guildID], !entry.isSaving else { return }
        store.channelSelections[guildID]?.isSaving = true
        startAccountChildTask(account: accountSession()) { model, account in
            while model.isCurrentAccountSession(account), !Task.isCancelled,
                  let pending = store.channelSelections[guildID], pending.identity == entry.identity {
                do { try await store.customizationDebounce() } catch { return }
                guard model.isCurrentAccountSession(account), !Task.isCancelled,
                      store.channelSelections[guildID]?.identity == entry.identity else { return }
                guard store.channelSelections[guildID]?.revision == pending.revision else { continue }
                do {
                    let baseline = model.readState.notificationSettings(guildID: guildID) ?? GuildNotificationSettings(guildID: guildID)
                    let accepted: GuildNotificationSettings
                    if pending.applying(to: baseline) != baseline {
                        accepted = try await account.provider.updateGuildChannelSelection(in: guildID, enabled: pending.enabled, channels: pending.channels)
                    } else {
                        accepted = baseline
                    }
                    guard model.isCurrentAccountSession(account), !Task.isCancelled,
                          store.channelSelections[guildID]?.identity == entry.identity else { return }
                    model.applyNotificationSettings(accepted)
                } catch {
                    guard model.isCurrentAccountSession(account), store.channelSelections[guildID]?.identity == entry.identity else { return }
                    store.entries[guildID, default: .init()].error = error.localizedDescription
                    if model.guildWorkspacePage != .channelsAndRoles { model.errorMessage = error.localizedDescription }
                }
                guard var latest = store.channelSelections[guildID], latest.identity == entry.identity else { return }
                // Clear only the submitted versions. Newer choices remain visible
                // and are the sole payload of the next request.
                for (id, selected) in pending.channels where latest.channels[id] == selected { latest.channels[id] = nil }
                if latest.enabled == pending.enabled { latest.enabled = nil }
                if latest.channels.isEmpty, latest.enabled == nil {
                    store.channelSelections[guildID] = nil
                    model.reconcileSelectedOnboardingChannel()
                    return
                }
                store.channelSelections[guildID] = latest
            }
        }
    }
}
