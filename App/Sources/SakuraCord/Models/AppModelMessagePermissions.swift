import DiscordProtocol
import SakuraCordModels

extension AppModel {
    /// The author may edit a message while they can still post where it is,
    /// except a poll or voice message, which Discord does not edit.
    func canEditMessage(_ message: Message) -> Bool {
        message.author.id == currentUser?.id
            && message.hasEditableContent
            && guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil
            && MessageReplyPresentationPolicy.allowsReplyAction(for: message)
    }

    func canDeleteMessage(_ message: Message) -> Bool {
        guard message.outboxState == .confirmed, !message.flags.contains(.ephemeral) else { return false }
        if !message.type.hasGeneratedContent,
           message.author.id == currentUser?.id
        {
            return true
        }
        guard let context = messagePermissionContext(for: message.channelID),
              context.channel.guildID != nil,
              let permissions = effectiveMessagePermissions(in: context.channel)
        else { return false }
        return permissions & DiscordPermissionBits.viewChannel != 0
            && permissions & DiscordPermissionBits.readMessageHistory != 0
            && permissions & DiscordPermissionBits.manageMessages != 0
    }

    func messagePermissionContext(
        for channelID: ChannelID
    ) -> (channel: Channel, isThread: Bool)? {
        if let channel = messagePresentationChannel(channelID) {
            return (channel, false)
        }
        if openThread?.id == channelID, let parent = openThreadParentChannel {
            return (parent, true)
        }
        let parentID = threads.first(where: { $0.id == channelID })?.parentID
            ?? activeJoinedThreads.first(where: { $0.id == channelID })?.parentID
            ?? messageSearch.page?.channels.first(where: { $0.id == channelID })?.categoryID
        guard let parentID, let parent = messagePresentationChannel(parentID) else { return nil }
        return (parent, true)
    }
}
