import Foundation
import SakuraCordModels

extension AppModel {
    /// Whether new reactions can be created on this message.
    func canCreateReactions(on message: Message) -> Bool {
        reactionCreationContext(for: message) != nil
    }

    /// The hover toolbar's quick reactions, or none where reactions cannot be
    /// created on this message.
    func quickReactions(for message: Message) -> [QuickReaction] {
        guard let context = reactionCreationContext(for: message) else { return [] }
        let rankedKeys = discordFrequentlyUsedReactionKeys
        let rankedKeySet = Set(rankedKeys)
        let customEmojis = orderedCustomEmojis.filter { rankedKeySet.contains($0.id) && canResolveFrequentlyUsedEmoji($0) }
        return QuickReactionPolicy.reactions(
            rankedKeys: rankedKeys,
            customEmojisByID: Dictionary(customEmojis.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            existingReactions: message.reactions,
            context: QuickReactionPolicy.Context(
                guildID: context.channel.guildID,
                premiumType: snapshot?.currentUser.premiumType ?? 0,
                canUseExternalEmojis: context.permissions & DiscordPermissionBits.useExternalEmojis != 0,
                roleIDsByGuild: currentUserRoleIDsByGuild,
                skinTone: .preferred
            )
        )
    }

    /// Discord's `disableReactionCreates`: private channels other than the
    /// system DM, or guild channels where the member can chat and has
    /// ADD_REACTIONS. Discord also allows archived threads it can reopen
    /// because it unarchives before reacting; the shared reaction path does
    /// not, so archived threads are excluded.
    private func reactionCreationContext(for message: Message) -> (channel: Channel, permissions: UInt64)? {
        guard message.outboxState == .confirmed, !message.flags.contains(.ephemeral),
              let context = messagePermissionContext(for: message.channelID),
              let permissions = effectiveMessagePermissions(in: context.channel)
        else { return nil }
        let channel = context.channel
        guard let guildID = channel.guildID else {
            return channel.isOfficialSystemDirectMessage ? nil : (channel, permissions)
        }
        guard !requiresOnboarding(in: guildID), onboardingMember(in: guildID)?.isPending != true,
              permissions & DiscordPermissionBits.viewChannel != 0,
              permissions & DiscordPermissionBits.addReactions != 0
        else { return nil }
        if context.isThread, let thread = openThread, thread.id == message.channelID, thread.isArchived {
            return nil
        }
        return (channel, permissions)
    }
}
