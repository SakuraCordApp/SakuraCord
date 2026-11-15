import Foundation
import MessageRendering
import SakuraCordModels

extension AppModel {
    var messageSpacing: Double { appearanceSettings.messageSpacing }
    var roleColorDisplay: RoleColorDisplay { accessibilitySettings.roleColorDisplay }
    var currentUserID: UserID? { currentUser?.id }
    var supportsComponents: Bool { supportsCapability(.components) }
    var supportsRemoteComponentChoices: Bool { supportsCapability(.remoteComponentChoices) }

    func inviteEntry(for reference: ServerInviteReference) -> ServerInvitePresentationStore.Entry? {
        serverInvites.entries[reference]
    }

    func isInviteExpanded(_ reference: ServerInviteReference) -> Bool {
        serverInvites.expanded.contains(reference)
    }

    func isLeavingInviteGuild(_ guildID: GuildID) -> Bool {
        serverInvites.leaving.contains(guildID)
    }

    func isJoiningInviteGuild(_ guildID: GuildID) -> Bool {
        serverInvites.joining.contains(guildID)
    }

    func presentationGuild(_ guildID: GuildID) -> Guild? {
        serverRailGuildsByID[guildID]
    }

    func forwardedSourceChannel(_ channelID: ChannelID) -> Channel? {
        messagePresentationChannelsByID[channelID]
    }
}
