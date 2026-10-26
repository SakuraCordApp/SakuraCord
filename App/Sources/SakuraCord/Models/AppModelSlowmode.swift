import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func slowmodeConfiguration(in channelID: ChannelID) -> (interval: Int, immune: Bool) {
        let thread = threads.first { $0.id == channelID }
            ?? activeJoinedThreads.first { $0.id == channelID }
            ?? (openThread?.id == channelID ? openThread : nil)
        let permissionChannelID = thread?.parentID ?? channelID
        guard let channel = (selectedChannel?.id == permissionChannelID ? selectedChannel : nil)
                ?? visibleChannels.first(where: { $0.id == permissionChannelID })
                ?? messagePresentationChannelsByID[permissionChannelID],
              let guildID = channel.guildID
        else { return (0, false) }
        let interval = max(0, thread?.rateLimitPerUser ?? channel.rateLimitPerUser)
        if currentUser?.isBot == true { return (interval, true) }
        guard let basis = conversationPermissionBasis(for: guildID) else { return (interval, false) }
        let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: basis.guild,
            channel: channel,
            resolvedBasePermissions: basis.resolvedBasePermissions,
            overwritePrincipals: basis.overwritePrincipals,
            hasCurrentRoleIdentity: basis.hasCurrentRoleIdentity,
            communicationDisabledUntil: basis.currentUserCommunicationDisabledUntil
        )
        return (interval, permissions.map { $0 & DiscordPermissionBits.bypassSlowmode != 0 } ?? false)
    }

    func slowmodeRemaining(in channelID: ChannelID, now: Date = .now) -> Int {
        let configuration = slowmodeConfiguration(in: channelID)
        return composer.slowmode.remaining(
            in: channelID, interval: configuration.interval, immune: configuration.immune, now: now
        )
    }

    /// Called before consuming drafts and again at the shared delivery boundary.
    func allowSlowmodeSubmission(in channelID: ChannelID) -> Bool {
        guard guildTimeoutUntil(in: channelID) == nil else { return false }
        if slowmodeRemaining(in: channelID) > 0 {
            composer.slowmode.reject(in: channelID)
            return false
        }
        let configuration = slowmodeConfiguration(in: channelID)
        return configuration.interval == 0 || configuration.immune
            || composer.slowmode.pendingChannels[channelID, default: 0] == 0
    }

    func confirmSlowmodeMessage(_ message: Message, at date: Date = .now) {
        guard message.author.id == snapshot?.currentUser.id else { return }
        let configuration = slowmodeConfiguration(in: message.channelID)
        composer.slowmode.confirm(
            message, interval: configuration.immune ? 0 : configuration.interval, at: date
        )
    }

    func seedSlowmodeHistory(_ messages: [Message]) {
        guard let currentUserID = snapshot?.currentUser.id,
              let latest = messages.last(where: { $0.author.id == currentUserID && $0.outboxState == .confirmed }),
              latest.timestamp > Date.now.addingTimeInterval(-21600)
        else { return }
        confirmSlowmodeMessage(latest, at: latest.timestamp)
    }

    func recoverSlowmode(from error: any Error, in channelID: ChannelID) {
        guard case let ChatProviderError.slowmode(retryAfter) = error else { return }
        composer.slowmode.recover(channelID: channelID, retryAfter: retryAfter)
        composer.slowmode.reject(in: channelID)
    }
}
