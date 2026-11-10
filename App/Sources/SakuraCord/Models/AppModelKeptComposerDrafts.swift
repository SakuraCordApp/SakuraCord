import Foundation
import SakuraCordModels

extension AppModel {
    /// Empties a composer that leaves its conversation. Like Discord, the
    /// conversation keeps its staged files, uploads still running, and its
    /// slash command for when the user returns. A composer without a
    /// conversation, such as a thread being created, drops them.
    /// - Parameter channelID: The conversation's channel, or a thread's parent.
    func leaveComposerConversation(
        _ destination: MessageComposerDestination,
        conversationID: ChannelID?,
        in channelID: ChannelID?
    ) {
        let commandComposer = commandComposer(for: destination)
        let command = commandComposer.draft
        commandComposer.resetForChannelChange()
        let attachments = composerAttachments(for: destination)
        // A conversation deleted or hidden as the user leaves it has nothing
        // to return to.
        let channel = channelID.flatMap(messagePresentationChannel)
        guard let conversationID, let channel, conversationAccess(for: channel) != .hidden,
              !attachments.isEmpty || command != nil
        else {
            clearComposerAttachments(for: destination)
            return
        }
        let kept = KeptComposerDraft(
            guildID: channel.guildID,
            channelID: channelID,
            attachments: attachments,
            command: command
        )
        // Both composers can show one conversation; the last to leave keeps it.
        if let replaced = composer.keptDrafts.updateValue(kept, forKey: conversationID) {
            discardPreuploads(replaced.attachments.map(\.id))
        }
        setComposerAttachments([], for: destination)
    }

    /// Gives a composer entering a conversation what it kept there.
    func restoreComposerConversation(_ destination: MessageComposerDestination, conversationID: ChannelID?) {
        guard let conversationID, let kept = composer.keptDrafts.removeValue(forKey: conversationID) else { return }
        // The command first: setting the attachments prunes owned files no
        // composer holds, which would include the command's.
        if let command = kept.command {
            commandComposer(for: destination).restore(command)
        }
        setComposerAttachments(kept.attachments, for: destination)
    }

    /// Drops a kept draft as clearing its composer would, early uploads included.
    func discardKeptComposerDraft(for conversationID: ChannelID) {
        guard let kept = composer.keptDrafts.removeValue(forKey: conversationID) else { return }
        discardPreuploads(kept.attachments.map(\.id))
        pruneOwnedPromisedAttachmentFiles()
    }

    /// Drops the drafts of servers the user left, of channels, or threads'
    /// parents, that were deleted or hidden from them, and of direct
    /// messages that were closed or left.
    func discardUnreachableKeptComposerDrafts() {
        guard !composer.keptDrafts.isEmpty, let snapshot else { return }
        let guildIDs = Set(snapshot.guilds.map(\.id))
        let channelsByID = Dictionary(snapshot.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (conversationID, kept) in composer.keptDrafts {
            guard let channel = kept.channelID.flatMap({ channelsByID[$0] }) else {
                discardKeptComposerDraft(for: conversationID)
                continue
            }
            let isReachable = (kept.guildID.map(guildIDs.contains) ?? true)
                && conversationAccess(for: channel) != .hidden
            if !isReachable { discardKeptComposerDraft(for: conversationID) }
        }
    }
}
