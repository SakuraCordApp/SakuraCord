import Foundation
import SakuraCordModels

extension AppModel {
    func refreshInboxMentionRestrictions() {
        let restricted = Set(inbox.mentions.filter { message in
            inboxRequiresAgeAgreement(
                channelID: message.channelID,
                guildID: message.guildID ?? readState.entries[message.channelID]?.guildID
            )
        }.map(\.id))
        let blocked = Set(inbox.mentions.filter {
            snapshot?.blockedOrIgnoredUserIDs.contains($0.author.id) == true
        }.map(\.id))
        inbox.hiddenMentionIDs = blocked.union(snapshot?.currentUser.allowsAdultContent == true ? [] : restricted)
        inbox.obscuredMentionIDs = snapshot?.currentUser.allowsAdultContent == true ? restricted : []
    }

    func inboxRequiresAgeAgreement(channelID: ChannelID, guildID: GuildID?) -> Bool {
        guard let guildID else { return false }
        let channel = snapshot?.channels.first { $0.id == channelID }
        let parentID = inbox.threads[channelID]?.parentID ?? readState.entries[channelID]?.parentID
        let parent = parentID.flatMap { id in snapshot?.channels.first { $0.id == id } }
        let restricted = snapshot?.guilds.first { $0.id == guildID }?.isAgeRestricted == true
            || (channel ?? parent)?.isAgeRestricted == true
        return restricted && (snapshot?.currentUser.allowsAdultContent != true
            || !inbox.acceptedAgeRestrictedGuildIDs.contains(guildID))
    }

    func requestInboxAgeAgreement(guildID: GuildID, action: @escaping @MainActor () -> Void) {
        inbox.ageRestrictedGuildID = guildID
        inbox.ageRestrictedAction = action
    }

    func cancelInboxAgeAgreement() {
        inbox.ageRestrictedGuildID = nil
        inbox.ageRestrictedAction = nil
    }

    func acceptInboxAgeAgreement() {
        guard snapshot?.currentUser.allowsAdultContent == true, let guildID = inbox.ageRestrictedGuildID else { return }
        inbox.acceptedAgeRestrictedGuildIDs.insert(guildID)
        if !isOfflineTesting {
            PRBuildProfile.defaults.set(inbox.acceptedAgeRestrictedGuildIDs.map(\.description), forKey: "dev.sakuracord.inbox-age-agreements")
        }
        let action = inbox.ageRestrictedAction
        cancelInboxAgeAgreement()
        action?()
    }
}
