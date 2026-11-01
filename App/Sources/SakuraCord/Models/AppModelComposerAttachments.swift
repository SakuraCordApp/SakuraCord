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
        guard !urls.isEmpty else { return true }
        // Show the files at once. Their privacy preparation and size check
        // can take a while, so it finishes behind the tiles, and anything it
        // rejects leaves again. Uploading prepares each file afresh; until
        // the check ends, the tiles only hold sending back.
        let staged = urls.map { ForumPostAttachment(url: $0) }
        let stagedIDs = Set(staged.map(\.id))
        setComposerAttachments(composerAttachments(for: destination) + staged, for: destination)
        composer.checkingAttachmentIDs.formUnion(stagedIDs)
        defer { composer.checkingAttachmentIDs.subtract(stagedIDs) }
        // A sent message shows at once, so its videos are read while the
        // tiles hold sending back.
        async let videosPrepared: Void = LocalVideo.prepare(urls)
        let acceptedURLs = Set(await attachmentURLsWithinDiscordLimit(
            urls,
            offeringExternalUploadFor: destination
        ))
        await videosPrepared
        let rejectedIDs = Set(staged.filter { !acceptedURLs.contains($0.url) }.map(\.id))
        let current = composerAttachments(for: destination)
        if current.contains(where: { rejectedIDs.contains($0.id) }) {
            setComposerAttachments(current.filter { !rejectedIDs.contains($0.id) }, for: destination)
        }
        preuploadComposerAttachments(
            composerAttachments(for: destination).filter { stagedIDs.contains($0.id) },
            to: destination
        )
        return true
    }

    @discardableResult
    func appendCheckedComposerAttachments(_ urls: [URL], to destination: MessageComposerDestination) -> Bool {
        guard isComposerDropEligible(destination), !Task.isCancelled else { return false }
        var attachments = composerAttachments(for: destination)
        if attachmentBatchFits(urls.count, besides: attachments.count) {
            let added = urls.map { ForumPostAttachment(url: $0) }
            attachments.append(contentsOf: added)
            Task { await LocalVideo.prepare(urls) }
            setComposerAttachments(attachments, for: destination)
            let addedIDs = Set(added.map(\.id))
            preuploadComposerAttachments(
                composerAttachments(for: destination).filter { addedIDs.contains($0.id) },
                to: destination
            )
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
        discardPreuploads([id])
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

    /// Drops the staged files without sending them.
    func clearComposerAttachments(for destination: MessageComposerDestination) {
        discardPreuploads(composerAttachments(for: destination).map(\.id))
        setComposerAttachments([], for: destination)
    }

    /// Like the first-party composer, starts storing checked files as soon as
    /// they are attached, so Send has only the message left to post. A thread
    /// still being created has no channel to store them for yet. With metadata
    /// removal off, files wait for Send: turning it on before then must still
    /// strip them, and a stored file cannot be prepared again.
    func preuploadComposerAttachments(
        _ attachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) {
        guard privacySafetySettingsStore.load().removesMediaMetadata,
              case let .conversation(channelID) = attachmentComposerContext(for: destination)
        else { return }
        let provider = accountSession().provider
        for attachment in attachments {
            attachmentUploads.beginPreupload(attachment.id)
            Task { [weak self] in
                let stored = await provider.preuploadAttachment(attachment, channelID: channelID) { progress in
                    Task { @MainActor in self?.attachmentUploads.apply(progress) }
                }
                self?.attachmentUploads.endPreupload(attachment.id, stored: stored)
            }
        }
    }

    /// Stops the early uploads of files that will not be sent.
    func discardPreuploads(_ attachmentIDs: [UUID]) {
        let provider = accountSession().provider
        for id in attachmentIDs {
            attachmentUploads.forgetPreupload(id)
            Task { await provider.discardPreuploadedAttachment(id) }
        }
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

    func restoreComposerAttachments(
        _ restoredAttachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) {
        let current = composerAttachments(for: destination)
        var seen = Set(current.map(\.id))
        let restored = restoredAttachments.filter {
            seen.insert($0.id).inserted
        }
        let attachments = restored + current
        setComposerAttachments(Array(attachments.prefix(SendMessageDraft.maximumAttachmentCount)), for: destination)
        discardPreuploads(attachments.dropFirst(SendMessageDraft.maximumAttachmentCount).map(\.id))
    }

    /// Puts back the files of a send that did not take them, unless their
    /// conversation was left meanwhile, which drops their early uploads.
    func returnUnsentComposerAttachments(
        _ attachments: [ForumPostAttachment],
        to destination: MessageComposerDestination,
        from conversationID: ChannelID?
    ) {
        guard attachmentComposerContext(for: destination) == conversationID.map(AttachmentComposerContext.conversation) else {
            discardPreuploads(attachments.map(\.id))
            return
        }
        restoreComposerAttachments(attachments, to: destination)
    }

    @discardableResult
    func sendAttachmentsImmediately(
        _ attachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) async -> Bool {
        guard isComposerDropEligible(destination), !attachments.isEmpty,
              validateAttachmentCount(attachments), allowOutgoingQueueSubmission()
        else { return false }
        // The files go where they were dropped, read while the message waits.
        let channelID = selectedChannelID
        let thread = openThread
        // The message shows at once, so its videos are read first.
        await LocalVideo.prepare(attachments.map(\.url))
        switch destination {
        case .channel:
            guard let channelID else { return false }
            return await sendChannelMessage(
                channelID: channelID,
                content: "",
                replyTo: nil,
                replyPreview: nil,
                attachments: attachments,
                clearsComposer: false
            )
        case .thread:
            guard let thread else {
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
