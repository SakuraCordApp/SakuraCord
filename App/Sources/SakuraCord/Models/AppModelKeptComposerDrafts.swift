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
        let kept = channelID.map {
            KeptComposerDraft(channelID: $0, attachments: composerAttachments(for: destination), command: command)
        }
        guard let conversationID, let kept, !kept.isEmpty, canKeepComposerDraft(kept) else {
            clearComposerAttachments(for: destination)
            return
        }
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

    /// Drops the drafts of conversations the user can no longer return to.
    func discardUnreachableKeptComposerDrafts() {
        for (conversationID, kept) in composer.keptDrafts where !canKeepComposerDraft(kept) {
            discardKeptComposerDraft(for: conversationID)
        }
    }

    /// Whether a draft's channel still exists and is open to the user: not
    /// deleted, hidden, or in a server they left. A closed or left direct
    /// message is gone too.
    private func canKeepComposerDraft(_ kept: KeptComposerDraft) -> Bool {
        guard let channel = messagePresentationChannel(kept.channelID) else { return false }
        return (channel.guildID.map { serverRailGuildsByID[$0] != nil } ?? true)
            && conversationAccess(for: channel) != .hidden
    }
}
