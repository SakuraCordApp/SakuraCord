import Foundation
import SakuraCordModels

extension AppModel {
    func composerAttachments(
        for destination: MessageComposerDestination
    ) -> [StagedAttachment] {
        switch destination {
        case .channel: channelComposerAttachments
        case .thread: threadComposerAttachments
        }
    }

    /// The effective permissions where a composer destination posts, once it
    /// can send there: the selected channel, or the open thread's parent. A
    /// thread being created has no destination yet, so callers decide for it.
    func composerSendPermissions(in destination: MessageComposerDestination) -> UInt64? {
        switch destination {
        case .channel:
            guard let channel = selectedChannel, selectedConversationAccess.canSend,
                  Self.supportsTyping(channel.kind)
            else { return nil }
            return effectiveMessagePermissions(in: channel)
        case .thread:
            guard openThread != nil, openThreadAccess.canSend, let parent = openThreadParentChannel else { return nil }
            return effectiveMessagePermissions(in: parent)
        }
    }

    func isComposerDropEligible(_ destination: MessageComposerDestination) -> Bool {
        guard commandComposer(for: destination).activeCommand == nil else { return false }
        let permissions = if destination == .thread, let threadCreation {
            threadCreation.isSubmitting ? nil : selectedChannel.flatMap { effectiveMessagePermissions(in: $0) }
        } else {
            composerSendPermissions(in: destination)
        }
        return (permissions ?? 0) & DiscordPermissionBits.attachFiles != 0
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
            await sendAttachmentsImmediately(acceptedURLs.map { StagedAttachment(url: $0) }, to: destination)
        case let (.owned(batch), true):
            let acceptedURLs = await preparePromisedAttachmentsForImmediateSend(batch, to: destination)
            guard !acceptedURLs.isEmpty else { return }
            defer { endUsingOwnedPromisedFiles(acceptedURLs) }
            await sendAttachmentsImmediately(acceptedURLs.map { StagedAttachment(url: $0) }, to: destination)
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
        let staged = urls.map { StagedAttachment(url: $0) }
        let stagedIDs = Set(staged.map(\.id))
        let context = attachmentComposerContext(for: destination)
        setComposerAttachments(composerAttachments(for: destination) + staged, for: destination)
        composer.checkingAttachmentIDs.formUnion(stagedIDs)
        defer { composer.checkingAttachmentIDs.subtract(stagedIDs) }
        // A sent message shows at once, so its videos are read while the
        // tiles hold sending back.
        async let videosPrepared: Void = LocalVideo.prepare(urls)
        let acceptedURLs = Set(await checkedAttachmentURLsWithinDiscordLimit(
            urls,
            offeringExternalUploadFor: destination,
            keepsAfterLeaving: true
        ) ?? [])
        await videosPrepared
        let rejectedIDs = Set(staged.filter { !acceptedURLs.contains($0.url) }.map(\.id))
        // Files the user left while they were checked stay with that conversation.
        if attachmentComposerContext(for: destination) != context,
           case let .conversation(conversationID)? = context,
           let kept = removeKeptAttachments(rejectedIDs, in: conversationID)
        {
            pruneOwnedPromisedAttachmentFiles()
            preuploadComposerAttachments(kept.attachments.filter { stagedIDs.contains($0.id) }, in: context)
            return true
        }
        let current = composerAttachments(for: destination)
        if current.contains(where: { rejectedIDs.contains($0.id) }) {
            setComposerAttachments(current.filter { !rejectedIDs.contains($0.id) }, for: destination)
        }
        preuploadComposerAttachments(
            composerAttachments(for: destination).filter { stagedIDs.contains($0.id) },
            in: context
        )
        return true
    }

    @discardableResult
    func appendCheckedComposerAttachments(_ urls: [URL], to destination: MessageComposerDestination) -> Bool {
        guard isComposerDropEligible(destination), !Task.isCancelled else { return false }
        var attachments = composerAttachments(for: destination)
        if attachmentBatchFits(urls.count, besides: attachments.count) {
            let added = urls.map { StagedAttachment(url: $0) }
            attachments.append(contentsOf: added)
            setComposerAttachments(attachments, for: destination)
            let addedIDs = Set(added.map(\.id))
            if urls.contains(where: LocalVideo.isVideo) {
                // The tiles hold sending back until their videos are read.
                composer.checkingAttachmentIDs.formUnion(addedIDs)
                Task {
                    await LocalVideo.prepare(urls)
                    composer.checkingAttachmentIDs.subtract(addedIDs)
                }
            }
            preuploadComposerAttachments(
                composerAttachments(for: destination).filter { addedIDs.contains($0.id) },
                in: attachmentComposerContext(for: destination)
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
        // A schedule on its way posts these files; they stay until it is answered.
        guard !isSchedulingMessage(in: destination) else { return }
        var attachments = composerAttachments(for: destination)
        discardPreuploads([id])
        attachments.removeAll { $0.id == id }
        setComposerAttachments(attachments, for: destination)
    }

    func updateComposerAttachment(
        _ attachment: StagedAttachment,
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
        guard !isSchedulingMessage(in: destination) else { return }
        discardPreuploads(composerAttachments(for: destination).map(\.id))
        setComposerAttachments([], for: destination)
    }

    /// Like the first-party composer, starts storing checked files as soon as
    /// they are attached, so Send has only the message left to post. A thread
    /// still being created has no channel to store them for yet. With metadata
    /// removal off, files wait for Send: turning it on before then must still
    /// strip them, and a stored file cannot be prepared again.
    func preuploadComposerAttachments(
        _ attachments: [StagedAttachment],
        in context: AttachmentComposerContext?
    ) {
        guard privacySafetySettingsStore.load().removesMediaMetadata,
              case let .conversation(channelID) = context
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
        _ restoredAttachments: [StagedAttachment],
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
        _ attachments: [StagedAttachment],
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
        _ attachments: [StagedAttachment],
        to destination: MessageComposerDestination
    ) async -> Bool {
        guard isComposerDropEligible(destination), !attachments.isEmpty,
              attachmentBatchFits(attachments.count), allowOutgoingQueueSubmission()
        else { return false }
        // A thread still being created has no upload destination yet.
        if destination == .thread, openThread == nil {
            return await addComposerAttachments(attachments.map(\.url), to: .thread)
        }
        // The files go where they were dropped, read while the message waits
        // and holds its place in the outbox.
        let session = accountSession()
        let channelID = selectedChannelID
        let thread = openThread
        guard let reservation = composer.outbox.reserveSubmission() else {
            composer.isSendQueueFullAlertPresented = true
            return false
        }
        // The message shows at once, so its videos are read first.
        await LocalVideo.prepare(attachments.map(\.url))
        composer.outbox.releaseSubmission(reservation)
        guard isCurrentAccountSession(session) else { return false }
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
            guard let thread else { return false }
            return await sendThreadMessage(
                content: "",
                attachments: attachments,
                thread: thread,
                clearsComposer: false
            )
        }
    }

    func setComposerAttachments(
        _ attachments: [StagedAttachment],
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

    /// Takes attachments out of a conversation's kept draft, forgetting a draft
    /// left empty. Returns the remaining draft when one was kept.
    @discardableResult
    func removeKeptAttachments(_ ids: Set<UUID>, in channelID: ChannelID) -> KeptComposerDraft? {
        guard var kept = composer.keptDrafts[channelID] else { return nil }
        kept.attachments.removeAll { ids.contains($0.id) }
        composer.keptDrafts[channelID] = kept.isEmpty ? nil : kept
        return kept
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
}

extension AppModel {
    /// Opens a staged file in the media viewer, which zooms it out of its
    /// tile and back into it.
    func openComposerAttachment(_ id: UUID, in attachments: [StagedAttachment], from anchor: ComposerSendTransitionAnchor) {
        guard let currentUser,
              let presentation = MediaViewerPlan.composerAttachments(
                  attachments,
                  selectedAttachmentID: id,
                  author: currentUser
              )
        else { return }
        // Every staged file zooms back into its own tile, whichever the
        // viewer shows when it closes.
        let sources = attachments.compactMap(anchor.mediaViewerSource)
        mediaViewerSelectedItemID = id.uuidString
        mediaViewerPresentation = presentation.withTimelineMedia(
            previewImages: Dictionary(uniqueKeysWithValues: sources.map { ($0.itemID, $0.image) }),
            transitionSources: Dictionary(uniqueKeysWithValues: sources.map { ($0.itemID, $0) })
        )
    }
}
