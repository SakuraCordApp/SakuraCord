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
        readState.isCategoryCollapsed(categoryID: categoryID, guildID: guildID)
    }

    func inheritedCategoryNotificationLevel(
        guildID: GuildID
    ) -> MessageNotificationLevel {
        readState.inheritedNotificationLevel(forCategoryIn: guildID)
    }

    func isCategoryUnread(guildID: GuildID, categoryID: ChannelID) -> Bool {
        !readState.bulkAcknowledgements(
            for: categoryID,
            guildID: guildID
        ).isEmpty
    }
}
