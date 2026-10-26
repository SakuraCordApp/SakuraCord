import Foundation
import SakuraCordModels

extension AppModel {
    func refreshInboxMentionRestrictions() {
        let restricted = Set(inbox.mentions.filter { message in
            inboxRequiresAgeAgreement(
                channelID: message.channelID,
                guildID: message.guildID ?? readState[message.channelID]?.guildID
            )
        }.map(\.id))
        let blocked = Set(inbox.mentions.filter {
            isMessageSuppressed($0)
        }.map(\.id))
        inbox.hiddenMentionIDs = blocked.union(currentUser?.allowsAdultContent == true ? [] : restricted)
        inbox.obscuredMentionIDs = currentUser?.allowsAdultContent == true ? restricted : []
    }

    func inboxRequiresAgeAgreement(channelID: ChannelID, guildID: GuildID?) -> Bool {
        guard let guildID else { return false }
        let channel = messagePresentationChannelsByID[channelID]
        let parentID = inbox.threads[channelID]?.parentID ?? readState[channelID]?.parentID
        let parent = parentID.flatMap { id in messagePresentationChannelsByID[id] }
        let restricted = serverRailGuildsByID[guildID]?.isAgeRestricted == true
            || (channel ?? parent)?.isAgeRestricted == true
        return restricted && (currentUser?.allowsAdultContent != true
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
        guard currentUser?.allowsAdultContent == true, let guildID = inbox.ageRestrictedGuildID else { return }
        inbox.acceptedAgeRestrictedGuildIDs.insert(guildID)
        if !isOfflineTesting {
            PRBuildProfile.defaults.set(inbox.acceptedAgeRestrictedGuildIDs.map(\.description), forKey: "dev.sakuracord.inbox-age-agreements")
        }
        let action = inbox.ageRestrictedAction
        cancelInboxAgeAgreement()
        action?()
    }
}
