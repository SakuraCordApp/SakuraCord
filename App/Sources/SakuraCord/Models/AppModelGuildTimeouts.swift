import Foundation
import SakuraCordModels

extension AppModel {
    func installBootstrapMembership(_ value: BootstrapSnapshot) {
        onboarding.members = value.currentMembersByGuildID
        let bootstrapMembers = onboarding.bootstrapMembers
        onboarding.bootstrapMembers = [:]
        for guild in value.guilds {
            if let member = bootstrapMembers[guild.id]?[value.currentUser.id] {
                receiveOnboardingMember(member, guildID: guild.id)
            }
        }
        reconcileGuildTimeoutExpiries()
    }

    func guildTimeoutUntil(in channelID: ChannelID, guildID: GuildID? = nil, now: Date = .now) -> Date? {
        guard let guildID = guildID ?? messagePermissionContext(for: channelID)?.channel.guildID,
              let until = onboardingMember(in: guildID)?.communicationDisabledUntil,
              until > now,
              serverRailGuildsByID[guildID]?.isOwnedByCurrentUser != true
        else { return nil }
        let permissions = conversationPermissionBasis(for: guildID)?.resolvedBasePermissions
        guard permissions.map({ $0 & DiscordPermissionBits.administrator != 0 }) != true else { return nil }
        return until
    }

    func reconcileGuildTimeoutExpiries() {
        for task in onboarding.timeoutExpiryTasks.values { task.cancel() }
        onboarding.timeoutExpiryTasks = [:]
        for guildID in onboarding.members.keys { scheduleGuildTimeoutExpiry(in: guildID) }
    }

    func scheduleGuildTimeoutExpiry(in guildID: GuildID) {
        onboarding.timeoutExpiryTasks.removeValue(forKey: guildID)?.cancel()
        guard let until = onboarding.members[guildID]?.communicationDisabledUntil, until > .now else { return }
        let account = accountSession()
        onboarding.timeoutExpiryTasks[guildID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow))) } catch { return }
            guard let self, !Task.isCancelled, isCurrentAccountSession(account),
                  onboarding.members[guildID]?.communicationDisabledUntil == until else { return }
            // Re-evaluate wall time after wake; extending/removing a timeout or
            // switching accounts must never let an old timer clear new state.
            if until > .now {
                scheduleGuildTimeoutExpiry(in: guildID)
                return
            }
            onboarding.timeoutExpiryTasks[guildID] = nil
            guard var member = onboarding.members[guildID] else { return }
            member.communicationDisabledUntil = nil
            receiveOnboardingMember(member, guildID: guildID)
        }
    }
}
