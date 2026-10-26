import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// Resolve permissions from the source message, independently of the active composer.
    func diagnosticsDestinationName(in channelID: ChannelID) -> String? {
        guard snapshot != nil, !accountTransitionIsActive else { return nil }
        let thread = (openThread?.id == channelID ? openThread : nil)
            ?? snapshot?.threads.first { $0.id == channelID }
            ?? snapshot?.activeJoinedThreads.first { $0.id == channelID }
            ?? forumPosts.first { $0.thread.id == channelID }?.thread
        let permissionChannelID = thread?.parentID ?? channelID
        guard let channel = snapshot?.channels.first(where: { $0.id == permissionChannelID })
            ?? visibleChannels.first(where: { $0.id == permissionChannelID }),
            thread != nil || Self.supportsTyping(channel.kind) || channel.kind == .voice,
            conversationAccess(for: channel).isReadable
        else { return nil }
        if let guildID = channel.guildID {
            guard let basis = conversationPermissionBasis(for: guildID),
                  let permissions = ConversationPermissionResolver.effectivePermissions(
                      guild: basis.guild,
                      channel: channel,
                      resolvedBasePermissions: basis.resolvedBasePermissions,
                      overwritePrincipals: basis.overwritePrincipals,
                      hasCurrentRoleIdentity: basis.hasCurrentRoleIdentity,
            communicationDisabledUntil: basis.currentUserCommunicationDisabledUntil
                  ),
                  !basis.currentUserIsPending,
                  permissions & DiscordPermissionBits.attachFiles != 0
            else { return nil }
            let access = thread.map {
                ConversationPermissionResolver.threadAccess(
                    effectivePermissions: permissions, isLocked: $0.isLocked
                )
            } ?? conversationAccess(for: channel)
            guard access.canSend else { return nil }
        } else {
            guard conversationAccess(for: channel).canSend else { return nil }
        }
        return thread?.name ?? channel.name
    }

    @discardableResult
    func shareDiagnostics(
        in channelID: ChannelID,
        confirm: (String) async -> Bool,
        export: () throws -> Data = { try DiscordAPIDiagnosticStore.shared.exportData() }
    ) async -> Bool {
        guard !diagnosticsShareInFlight else { return false }
        guard let name = diagnosticsDestinationName(in: channelID) else {
            errorMessage = "You cannot send diagnostic files in this conversation."
            return false
        }
        let session = accountSession()
        diagnosticsShareInFlight = true
        defer { diagnosticsShareInFlight = false }
        guard await confirm(name), !Task.isCancelled,
              isCurrentAccountSession(session)
        else { return false }
        guard diagnosticsDestinationName(in: channelID) != nil,
              allowSlowmodeSubmission(in: channelID)
        else {
            errorMessage = "Diagnostics cannot be sent to this conversation right now."
            return false
        }
        do {
            let data = try export()
            guard Int64(data.count) <= discordAttachmentLimit else {
                errorMessage = "The diagnostics export exceeds your Discord attachment limit."
                return false
            }
            let directory = try ComposerPromisedFileStorage.makeReceivingDirectory()
            let url = directory.appendingPathComponent("SakuraCord-Diagnostics.jsonl")
            var adopted = false
            defer {
                if !adopted { ComposerPromisedFileStorage.removeDirectory(directory) }
            }
            try await DiscordAPILogExporter.write(data, to: url)
            guard !Task.isCancelled, isCurrentAccountSession(session),
                  diagnosticsDestinationName(in: channelID) != nil
            else { return false }
            let urls = adoptPromisedFileBatch(.init(directory: directory, urls: [url]))
            guard urls.count == 1 else { throw CocoaError(.fileReadUnknown) }
            adopted = true
            // The outbox keeps a failed upload's private file for explicit retry,
            // and its existing storage owner removes it after delivery or discard.
            defer { pruneOwnedPromisedAttachmentFiles() }
            return await sendChannelMessage(
                channelID: channelID,
                content: "",
                replyTo: nil,
                replyPreview: nil,
                attachments: [ForumPostAttachment(url: url)],
                clearsComposer: false
            )
        } catch {
            if isCurrentAccountSession(session) {
                errorMessage = "Could not export diagnostics: \(error.localizedDescription)"
            }
            return false
        }
    }
}
