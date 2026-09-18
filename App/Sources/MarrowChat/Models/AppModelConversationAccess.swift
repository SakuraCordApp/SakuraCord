import DiscordProtocol
import Foundation
import MarrowChatModels

extension AppModel {
    func conversationAccess(for channel: Channel) -> ConversationAccess {
        guard let guildID = channel.guildID else {
            return .readable(canSend: !channel.isOfficialSystemDirectMessage)
        }
        return Self.resolveConversationAccess(
            for: channel,
            permissionBasis: conversationPermissionBasis(for: guildID)
        )
    }

    func conversationPermissionBasis(
        for guildID: GuildID
    ) -> ConversationPermissionBasis? {
        guard let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else {
            return nil
        }
        let member =
            membersByGuildID[guildID]?[currentUserID]
            ?? (guildID == selectedGuildID ? membersByID[currentUserID] : nil)
        let roles =
            guildRolesByGuildID[guildID]
            ?? (guildID == selectedGuildID ? guildRoles : [])
        let storedRoleIDs = currentUserRoleIDsByGuild[guildID]
        let roleIDs = storedRoleIDs ?? Set(member?.roles.map(\.id) ?? [])
        return ConversationPermissionBasis(
            guild: guild,
            resolvedBasePermissions: guild.currentUserPermissions
                ?? ConversationPermissionResolver.basePermissions(
                    guildID: guildID,
                    roleIDs: roleIDs,
                    roles: roles
                ),
            overwritePrincipals: PermissionOverwritePrincipals(
                guildID: guildID,
                currentUserID: currentUserID,
                roleIDs: roleIDs
            ),
            hasCurrentRoleIdentity: storedRoleIDs != nil || member != nil,
            currentUserIsPending: member?.isPending == true,
            currentUserCommunicationDisabledUntil: member?.communicationDisabledUntil
        )
    }

    func conversationAccess(
        for channel: Channel,
        permissionBasis: ConversationPermissionBasis?
    ) -> ConversationAccess {
        Self.resolveConversationAccess(
            for: channel,
            permissionBasis: permissionBasis
        )
    }

    nonisolated static func resolveConversationAccess(
        for channel: Channel,
        permissionBasis: ConversationPermissionBasis?
    ) -> ConversationAccess {
        guard channel.guildID != nil else {
            return .readable(canSend: !channel.isOfficialSystemDirectMessage)
        }
        guard let permissionBasis else { return .checking }
        let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: permissionBasis.guild,
            channel: channel,
            resolvedBasePermissions: permissionBasis.resolvedBasePermissions,
            overwritePrincipals: permissionBasis.overwritePrincipals,
            hasCurrentRoleIdentity: permissionBasis.hasCurrentRoleIdentity
        )
        let access = if channel.kind == .voice {
            ConversationPermissionResolver.voiceChannelAccess(
                effectivePermissions: permissions
            )
        } else {
            ConversationPermissionResolver.channelAccess(effectivePermissions: permissions)
        }
        return ConversationPermissionResolver.applyingCommunicationTimeout(
            access,
            communicationDisabledUntil: permissionBasis.currentUserCommunicationDisabledUntil
        )
    }

    var openThreadAccess: ConversationAccess {
        guard let thread = openThread, let channel = selectedChannel else { return .checking }
        guard let guildID = channel.guildID else { return .readable(canSend: true) }
        guard let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else {
            return .checking
        }
        let member = membersByID[currentUserID]
        let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: guild,
            channel: channel,
            currentUserID: currentUserID,
            currentMember: member,
            roles: guildRoles,
            currentRoleIDs: currentUserRoleIDsByGuild[guildID]
        )
        let access = ConversationPermissionResolver.threadAccess(
            effectivePermissions: permissions,
            isLocked: thread.isLocked
        )
        return ConversationPermissionResolver.applyingCommunicationTimeout(
            access,
            communicationDisabledUntil: member?.communicationDisabledUntil
        )
    }
}
