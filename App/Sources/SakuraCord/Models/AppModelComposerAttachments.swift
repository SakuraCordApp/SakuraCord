import Foundation
import SakuraCordModels

extension AppModel {
    func composerAttachments(
        for destination: MessageComposerDestination
    ) -> [ForumPostAttachment] {
        switch destination {
        case .channel: channelComposerAttachments
        case .thread: threadComposerAttachments
        }
    }

    func isComposerDropEligible(_ destination: MessageComposerDestination) -> Bool {
        let channel = switch destination {
        case .channel: selectedChannel
        case .thread: threadCreation == nil ? openThreadParentChannel : selectedChannel
        }
        guard let channel, let permissions = effectiveMessagePermissions(in: channel),
              permissions & DiscordPermissionBits.attachFiles != 0
        else { return false }
        guard commandComposer(for: destination).activeCommand == nil else { return false }
        switch destination {
        case .channel:
            guard
                  selectedConversationAccess.canSend,
                  let kind = selectedChannel?.kind
            else { return false }
            return Self.supportsTyping(kind)
        case .thread:
            if let threadCreation { return !threadCreation.isSubmitting }
            return openThread != nil && openThreadAccess.canSend
        }
    }

    /// Stages dropped or pasted files, or sends them at once for an instant drop.
    func receiveComposerAttachments(
        _ incoming: ComposerIncomingAttachments,
        to destination: MessageComposerDestination,
        sendingImmediately: Bool
    ) async {
        switch (incoming, sendingImmediately) {
        case let (.external(urls), false):
            await addComposerAttachments(urls, to: destination)
        case let (.owned(batch), false):
            await addPromisedComposerAttachments(batch, to: destination)
        case let (.external(urls), true):
            let urls = uploadableFileURLs(urls)
            guard attachmentBatchFits(urls.count) else { return }
            let acceptedURLs = await attachmentURLsWithinDiscordLimit(urls, offeringExternalUploadFor: destination)
            guard !acceptedURLs.isEmpty else { return }
            let scopedURLs = acceptedURLs.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            await sendAttachmentsImmediately(acceptedURLs.map { ForumPostAttachment(url: $0) }, to: destination)
        case let (.owned(batch), true):
            let acceptedURLs = await preparePromisedAttachmentsForImmediateSend(batch, to: destination)
            guard !acceptedURLs.isEmpty else { return }
            defer { endUsingOwnedPromisedFiles(acceptedURLs) }
            await sendAttachmentsImmediately(acceptedURLs.map { ForumPostAttachment(url: $0) }, to: destination)
        }
    }

    /// Fills the active slash command's attachment option with the first
    /// selected or pasted file. Like Discord, the command takes no other files.
    @discardableResult
    func receiveCommandAttachment(_ incoming: ComposerIncomingAttachments, in destination: MessageComposerDestination = .channel) async -> Bool {
        let commandComposer = commandComposer(for: destination)
        let url: URL? = switch incoming {
        case let .external(urls): uploadableFileURLs(urls).first
        case let .owned(batch): adoptPromisedFileBatch(batch).first
        }
        guard let url else { return false }
        beginUsingOwnedPromisedFiles([url])
        defer { endUsingOwnedPromisedFiles([url]) }
        guard let target = commandComposer.attachmentPasteTarget(),
              !(await attachmentURLsWithinDiscordLimit([url])).isEmpty,
              !Task.isCancelled
        else { return false }
        return commandComposer.finishAttachmentPaste(url, target: target)
    }

    @discardableResult
    func addPromisedComposerAttachments(
        _ batch: ComposerPromisedFileBatch,
        to destination: MessageComposerDestination
    ) async -> Bool {
        let adoptedURLs = adoptPromisedFileBatch(batch)
        beginUsingOwnedPromisedFiles(adoptedURLs)
        defer { endUsingOwnedPromisedFiles(adoptedURLs) }
        let didHandle = await addComposerAttachments(adoptedURLs, to: destination)
        pruneOwnedPromisedAttachmentFiles()
        return didHandle
    }

    func preparePromisedAttachmentsForImmediateSend(
        _ batch: ComposerPromisedFileBatch,
        to destination: MessageComposerDestination
    ) async -> [URL] {
        let adoptedURLs = adoptPromisedFileBatch(batch)
        guard isComposerDropEligible(destination) else {
            pruneOwnedPromisedAttachmentFiles()
            return []
        }
        guard attachmentBatchFits(adoptedURLs.count) else {
            pruneOwnedPromisedAttachmentFiles()
            return []
        }
        beginUsingOwnedPromisedFiles(adoptedURLs)
        let acceptedURLs = await attachmentURLsWithinDiscordLimit(
            adoptedURLs,
            offeringExternalUploadFor: destination
        )
        endUsingOwnedPromisedFiles(adoptedURLs.filter { !acceptedURLs.contains($0) })
        return acceptedURLs
    }

    @discardableResult
    func addComposerAttachments(
        _ urls: [URL],
        to destination: MessageComposerDestination
    ) async -> Bool {
        guard isComposerDropEligible(destination), !urls.isEmpty else { return false }
        let urls = uploadableFileURLs(urls)
        guard attachmentBatchFits(urls.count, besides: composerAttachments(for: destination).count) else {
            return true
        }
        let acceptedURLs = await attachmentURLsWithinDiscordLimit(
            urls,
            offeringExternalUploadFor: destination
        )
        return appendCheckedComposerAttachments(acceptedURLs, to: destination)
    }

    @discardableResult
    func appendCheckedComposerAttachments(_ urls: [URL], to destination: MessageComposerDestination) -> Bool {
        guard isComposerDropEligible(destination), !Task.isCancelled else { return false }
        var attachments = composerAttachments(for: destination)
        if attachmentBatchFits(urls.count, besides: attachments.count) {
            attachments.append(contentsOf: urls.map { ForumPostAttachment(url: $0) })
            setComposerAttachments(attachments, for: destination)
        } else {
            pruneOwnedPromisedAttachmentFiles()
        }
        // An eligible destination handled the files even when limits rejected
        // them; each limit reports its own error.
        return true
    }

    func removeComposerAttachment(
        _ id: UUID,
        from destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        attachments.removeAll { $0.id == id }
        setComposerAttachments(attachments, for: destination)
    }

    func updateComposerAttachment(
        _ attachment: ForumPostAttachment,
        in destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else {
            return
        }
        attachments[index] = attachment
        setComposerAttachments(attachments, for: destination)
    }

    func toggleComposerAttachmentSpoiler(
        _ id: UUID,
        in destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].isSpoiler.toggle()
        setComposerAttachments(attachments, for: destination)
    }

    func clearComposerAttachments(for destination: MessageComposerDestination) {
        setComposerAttachments([], for: destination)
    }

    @discardableResult
    func consumeEscapeForComposerAttachments(
        in destination: MessageComposerDestination
    ) -> Bool {
        guard destination != .thread || threadCreation?.isSubmitting != true else { return false }
        guard !composerAttachments(for: destination).isEmpty else { return false }
        clearComposerAttachments(for: destination)
        return true
    }

    @discardableResult
    func consumeEscapeForSupplementaryConversation() -> Bool {
        if hasThreadPane {
            closeThread()
            return true
        }
        if closeGuildSupplementaryConversation() { return true }
        guard isVoiceChatOpen else { return false }
        closeVoiceChat()
        return true
    }

    func restoreComposerAttachments(
        _ restoredAttachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) {
        let current = composerAttachments(for: destination)
        var seen = Set(current.map(\.id))
        let restored = restoredAttachments.filter {
            seen.insert($0.id).inserted
        }
        setComposerAttachments(
            Array((restored + current).prefix(SendMessageDraft.maximumAttachmentCount)),
            for: destination
        )
    }

    @discardableResult
    func sendAttachmentsImmediately(
        _ attachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) async -> Bool {
        guard isComposerDropEligible(destination), !attachments.isEmpty,
              validateAttachmentCount(attachments), allowOutgoingQueueSubmission()
        else { return false }
        switch destination {
        case .channel:
            guard let channelID = selectedChannelID else { return false }
            return await sendChannelMessage(
                channelID: channelID,
                content: "",
                replyTo: nil,
                replyPreview: nil,
                attachments: attachments,
                clearsComposer: false
            )
        case .thread:
            guard let thread = openThread else {
                // A thread still being created has no upload destination yet.
                return await addComposerAttachments(attachments.map(\.url), to: .thread)
            }
            return await sendThreadMessage(
                content: "",
                attachments: attachments,
                thread: thread,
                clearsComposer: false
            )
        }
    }

    func setComposerAttachments(
        _ attachments: [ForumPostAttachment],
        for destination: MessageComposerDestination
    ) {
        let attachments = attachments.map {
            $0.applyingFilenamePrivacy(privacySafetySettings.anonymisesFileNames)
        }
        switch destination {
        case .channel:
            channelComposerAttachments = attachments
        case .thread:
            threadComposerAttachments = attachments
        }
        pruneOwnedPromisedAttachmentFiles()
    }

    /// Like Discord, rejects the whole batch rather than keeping the files that fit.
    func attachmentBatchFits(_ count: Int, besides existingCount: Int = 0) -> Bool {
        guard existingCount + count <= SendMessageDraft.maximumAttachmentCount else {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
            return false
        }
        return true
    }

    func validateAttachmentCount(_ attachments: [ForumPostAttachment]) -> Bool {
        guard attachments.count <= SendMessageDraft.maximumAttachmentCount else {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
            return false
        }
        return true
    }
}
