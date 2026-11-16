import SakuraCordModels

/// Discord's web links to channels and messages, as its Copy Link actions
/// produce them.
nonisolated enum DiscordLink {
    static func channel(guildID: GuildID?, channelID: ChannelID) -> String {
        "https://discord.com/channels/\(guildID?.description ?? "@me")/\(channelID)"
    }

    static func message(guildID: GuildID?, channelID: ChannelID, messageID: MessageID) -> String {
        "\(channel(guildID: guildID, channelID: channelID))/\(messageID)"
    }
}
