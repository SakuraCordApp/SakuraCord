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
            var override = value.channelOverrides.first { $0.channelID == channelID } ?? ChannelNotificationOverride(channelID: channelID)
            override.flags = selected ? override.flags | GuildChannelSelection.selectedFlag : override.flags & ~GuildChannelSelection.selectedFlag
            value.channelOverrides.removeAll { $0.channelID == channelID }
            value.channelOverrides.append(override)
        }
        return value
    }
}

extension AppModel {
    func presentedGuildChannelSettings(in guildID: GuildID) -> GuildNotificationSettings {
        let confirmed = readState.notificationSettings(guildID: guildID) ?? GuildNotificationSettings(guildID: guildID)
        guard featuresSettings.channelManagement else { return confirmed }
        return onboarding.channelSelections[guildID]?.applying(to: confirmed) ?? confirmed
    }

    func setChannelSelectionEnabled(_ enabled: Bool, guildID: GuildID) {
        guard featuresSettings.channelManagement else { return }
        var pending = onboarding.channelSelections[guildID] ?? .init()
        pending.enabled = enabled
        pending.revision = UUID()
        onboarding.channelSelections[guildID] = pending
        scheduleGuildChannelSelection(in: guildID)
    }

    func setChannelSelected(_ selected: Bool, channelID: ChannelID, guildID: GuildID) {
        guard featuresSettings.channelManagement else { return }
        var pending = onboarding.channelSelections[guildID] ?? .init()
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
                guard model.featuresSettings.channelManagement else {
                    store.channelSelections[guildID] = nil
                    return
                }
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
                    store.entries[guildID]?.error = error.localizedDescription
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
