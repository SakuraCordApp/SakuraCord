import SakuraCordModels

extension AppModel {
    func categoryNotificationOverride(
        guildID: GuildID,
        categoryID: ChannelID
    ) -> ChannelNotificationOverride? {
        readState.notificationOverride(channelID: categoryID, guildID: guildID)
    }

    func isCategoryMuted(guildID: GuildID, categoryID: ChannelID) -> Bool {
        readState.isCategoryMuted(categoryID: categoryID, guildID: guildID)
    }

    func isCategoryCollapsed(guildID: GuildID, categoryID: ChannelID) -> Bool {
        if let optimisticValue = optimisticCategoryCollapsedByID[categoryID] {
            return optimisticValue
        }
        return readState.isCategoryCollapsed(categoryID: categoryID, guildID: guildID)
    }

    func inheritedCategoryNotificationLevel(
        guildID: GuildID
    ) -> MessageNotificationLevel {
        readState.inheritedNotificationLevel(forCategoryIn: guildID)
    }

    func isCategoryUnread(guildID: GuildID, categoryID: ChannelID) -> Bool {
        unreadCategoryIDs(guildID: guildID).contains(categoryID)
    }

    func unreadCategoryIDs(guildID: GuildID) -> Set<ChannelID> {
        readState.unreadCategoryIDs(in: guildID)
    }
}
