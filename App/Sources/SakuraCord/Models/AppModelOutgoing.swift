import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func discardFailedOutgoingMessage(_ message: Message) {
        guard message.outboxState == .failed,
              let nonce = message.nonce,
              outgoingState(
                nonce: nonce,
                channelID: message.channelID
              ) == .failed
        else { return }
        if let outgoing = composer.outbox.draftsByNonce[nonce] {
            discardVoiceMessageFile(for: outgoing)
            discardPreuploads(outgoing.attachments.map(\.id))
        }
        composer.outbox.draftsByNonce[nonce] = nil
        composer.outbox.stickerUploadSourceURLByNonce[nonce] = nil
        attachmentUploads.finish(nonce: nonce)
        removeOutgoingMessage(
            nonce: nonce,
            channelID: message.channelID
        )
        pruneOwnedPromisedAttachmentFiles()
    }

    /// Stops one file of a local send, in flight, waiting or failed. Like
    /// the first-party upload card's cancel, stopping the last file stops
    /// the whole message.
    func cancelAttachmentUpload(_ attachmentID: String, of message: Message) {
        guard let nonce = message.nonce,
              attachmentUploads.canCancel(nonce: nonce, attachmentID: attachmentID),
              let id = UUID(uuidString: attachmentID)
        else { return }
        // A failed send keeps no transfer; its retry starts from the edited draft.
        guard outgoingState(nonce: nonce, channelID: message.channelID) != .failed else {
            discardPreuploads([id])
            return removeOutgoingAttachment(id, nonce: nonce, channelID: message.channelID)
        }
        let session = accountSession()
        Task {
            // Storage can accept the last file before the stop arrives; the message then keeps it.
            // An accepted stop already left the post, so a retry must not bring the file back.
            guard await session.provider.cancelAttachmentUpload(id), isCurrentAccountSession(session) else { return }
            removeOutgoingAttachment(id, nonce: nonce, channelID: message.channelID)
        }
    }

    private func removeOutgoingAttachment(_ id: UUID, nonce: String, channelID: ChannelID) {
        guard var outgoing = composer.outbox.draftsByNonce[nonce] else { return }
        outgoing.attachments.removeAll { $0.id == id }
        if outgoing.attachments.isEmpty {
            composer.outbox.draftsByNonce[nonce] = nil
            // Its slowmode reservation would otherwise block new sends until its turn.
            if composer.outbox.withdrawWaitingDelivery(nonce: nonce) {
                composer.slowmode.end(in: channelID)
            }
            attachmentUploads.finish(nonce: nonce)
            removeOutgoingMessage(nonce: nonce, channelID: channelID)
        } else {
            composer.outbox.draftsByNonce[nonce] = outgoing
            attachmentUploads.remove(attachmentID: id.uuidString, nonce: nonce)
            mutateOutgoingMessage(nonce: nonce, channelID: channelID) {
                $0.attachments.removeAll { $0.id == id.uuidString }
            }
        }
        pruneOwnedPromisedAttachmentFiles()
    }

    func outgoingMediaPresentationPreserving(
        _ incoming: Message
    ) -> Message {
        let existing: Message? = {
            let matches: (Message) -> Bool = { message in
                message.id == incoming.id
                    || (incoming.nonce != nil && message.nonce == incoming.nonce)
            }
            if incoming.channelID == openThread?.id,
               let message = threadMessages.first(where: matches)
            {
                return message
            }
            if incoming.channelID == selectedChannelID,
               let message = messages.first(where: matches)
            {
                return message
            }
            return messageCache[incoming.channelID]?.first(where: matches)
        }()
        guard let existing else { return incoming }

        var resolved = incoming
        resolved.nonce = resolved.nonce ?? existing.nonce
        if !existing.attachments.isEmpty {
            for index in resolved.attachments.indices {
                let attachment = resolved.attachments[index]
                let previous = existing.attachments.first(where: {
                    $0.id == attachment.id
                }) ?? (existing.attachments.indices.contains(index)
                    ? existing.attachments[index]
                    : nil)
                if attachment.mediaKind == .video {
                    resolved.attachments[index].localPreviewURL = previous?.localPreviewURL
                    continue
                }
                guard attachment.mediaKind == .image
                        || attachment.mediaKind == .animatedImage
                else { continue }
                let preservedPreviewURL: URL? = if let proxyURL = previous?.proxyURL {
                    proxyURL
                } else if previous?.url.isFileURL == true {
                    previous?.url
                } else {
                    nil
                }
                if let preservedPreviewURL, !attachment.url.isFileURL {
                    resolved.attachments[index].proxyURL = preservedPreviewURL
                }
            }
        }
        if !existing.stickers.isEmpty {
            for index in resolved.stickers.indices {
                let sticker = resolved.stickers[index]
                let previous = existing.stickers.first(where: {
                    $0.id == sticker.id
                }) ?? (existing.stickers.indices.contains(index)
                    ? existing.stickers[index]
                    : nil)
                if let mediaURL = previous?.mediaURL {
                    resolved.stickers[index].assetURL = mediaURL
                }
            }
        }
        return resolved
    }

    @discardableResult
    func send(attachments: [URL] = []) async -> Bool {
        await sendComposerMessage(
            attachments: attachments.map { ForumPostAttachment(url: $0) }
        )
    }

    @discardableResult
    func sendComposerMessage(attachments: [ForumPostAttachment]) async -> Bool {
        await submitComposerMessage(attachments: attachments).serverConfirmation()
    }

    /// Refuses a new submission while the outbox is full, before it consumes a draft.
    func allowOutgoingQueueSubmission() -> Bool {
        guard composer.outbox.isDeliveryQueueFull else { return true }
        composer.isSendQueueFullAlertPresented = true
        return false
    }

    func submitComposerMessage(
        attachments: [ForumPostAttachment]
    ) async -> ComposerSubmissionResult {
        guard let channelID = selectedChannelID, selectedConversationAccess.canSend else {
            return .rejected
        }
        guard allowSlowmodeSubmission(in: channelID) else { return .rejected }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return .rejected }
        guard validateAttachmentCount(attachments) else { return .rejected }
        guard allowOutgoingQueueSubmission() else { return .rejected }
        let session = accountSession()
        let replyTo = replyingTo?.id
        let mentionsRepliedUser = replyMentionsAuthor
        let replyPreview = replyingTo.map {
            MessageReplyPreview(message: $0)
        }
        guard await prepareChannelMessageSubmission(channelID: channelID, account: session) else { return .rejected }
        guard allowSlowmodeSubmission(in: channelID), allowOutgoingQueueSubmission(),
              let delivery = enqueueChannelMessage(
                  channelID: channelID,
                  content: content,
                  replyTo: replyTo,
                  mentionsRepliedUser: mentionsRepliedUser,
                  replyPreview: replyPreview,
                  attachments: attachments,
                  clearsComposer: true
              )
        else { return .rejected }
        return .enqueued(delivery: delivery)
    }

    func prepareChannelMessageSubmission(channelID: ChannelID, account: AppModelAccountSession) async -> Bool {
        guard isCurrentAccountSession(account), selectedChannelID == channelID else { return false }
        if hasMoreLaterMessages {
            guard await loadNewestMessageWindow(account: account) else { return false }
        }
        return !Task.isCancelled && isCurrentAccountSession(account)
            && selectedChannelID == channelID && !hasMoreLaterMessages
            && selectedConversationAccess.canSend
    }

    @discardableResult
    func sendChannelMessage(
        channelID: ChannelID,
        content: String,
        replyTo: MessageID?,
        mentionsRepliedUser: Bool = true,
        replyPreview: MessageReplyPreview?,
        attachments: [ForumPostAttachment],
        clearsComposer: Bool,
        poll: PollDraft? = nil,
        isTTS: Bool = false,
        nonce: String = ClientNonce.make()
    ) async -> Bool {
        await enqueueChannelMessage(
            channelID: channelID,
            content: content,
            replyTo: replyTo,
            mentionsRepliedUser: mentionsRepliedUser,
            replyPreview: replyPreview,
            attachments: attachments,
            clearsComposer: clearsComposer,
            poll: poll,
            isTTS: isTTS,
            nonce: nonce
        )?.value ?? false
    }

    /// Shows the optimistic message and admits it to the outbox without waiting
    /// for delivery. Returns nil when the message was not admitted.
    func enqueueChannelMessage(
        channelID: ChannelID,
        content: String,
        replyTo: MessageID?,
        mentionsRepliedUser: Bool = true,
        replyPreview: MessageReplyPreview?,
        attachments: [ForumPostAttachment],
        clearsComposer: Bool,
        poll: PollDraft? = nil,
        isTTS: Bool = false,
        nonce: String = ClientNonce.make()
    ) -> Task<Bool, Never>? {
        guard allowSlowmodeSubmission(in: channelID) else { return nil }
        let outgoing = SendMessageDraft(
            channelID: channelID,
            content: content,
            replyTo: replyTo,
            mentionsRepliedUser: mentionsRepliedUser,
            attachments: attachments,
            nonce: nonce,
            poll: poll,
            isTTS: isTTS
        )
        if clearsComposer {
            stopLocalTyping(clearThrottle: true)
        }
        let optimistic = optimisticMessage(
            for: outgoing,
            replyPreview: replyPreview
        )
        appendOutgoingMessage(optimistic)
        composer.outbox.draftsByNonce[outgoing.nonce] = outgoing
        if clearsComposer {
            replyingTo = nil
            updateDraft("")
            translation.resetDraft(.channel)
        }
        return enqueueOutgoingSend(outgoing, isRetry: false, completesReading: true)
    }

    @discardableResult
    func retrySending(_ message: Message) async -> Bool {
        guard message.canRetrySending,
              retainedMessage(channelID: message.channelID, messageID: message.id)?.canRetrySending == true,
              let nonce = message.nonce,
              outgoingState(nonce: nonce, channelID: message.channelID) == .failed,
              let outgoing = composer.outbox.draftsByNonce[nonce]
        else { return false }
        guard allowSlowmodeSubmission(in: message.channelID), allowOutgoingQueueSubmission() else { return false }
        if let sourceURL = composer.outbox.stickerUploadSourceURLByNonce[nonce] {
            updateOutgoingState(.uploading, nonce: nonce, channelID: message.channelID)
            return await performStickerUpload(
                outgoing,
                sourceURL: sourceURL,
                isRetry: true
            )
        }
        updateOutgoingState(.sending, nonce: nonce, channelID: message.channelID)
        return await performOutgoingSend(outgoing, isRetry: true)
    }

    func performOutgoingSend(_ outgoing: SendMessageDraft, isRetry: Bool) async -> Bool {
        await enqueueOutgoingSend(outgoing, isRetry: isRetry).value
    }

    /// Like the first-party message queue, sends leave one at a time in
    /// submission order. Admission is synchronous so the slowmode reservation
    /// and queue position are taken before the submitter can act again.
    /// `prepare` runs once the turn arrives, keeping slow preparation in order.
    func enqueueOutgoingSend(
        _ outgoing: SendMessageDraft,
        isRetry: Bool,
        completesReading: Bool = false,
        prepare: (@MainActor () async -> Bool)? = nil
    ) -> Task<Bool, Never> {
        // The local row is already in the timeline; show it now rather than
        // when Discord confirms it. Retries keep the user's position.
        let advancedLocally = completesReading && !isRetry
            && advanceTimelineForLocalSend(channelID: outgoing.channelID)
        guard allowOnboardingSubmission(in: outgoing.channelID), allowSlowmodeSubmission(in: outgoing.channelID) else {
            updateOutgoingState(.failed, nonce: outgoing.nonce, channelID: outgoing.channelID)
            return Task { false }
        }
        let session = accountSession()
        if composer.outbox.stickerUploadSourceURLByNonce[outgoing.nonce] == nil {
            attachmentUploads.begin(outgoing)
        }
        composer.slowmode.begin(in: outgoing.channelID)
        let turn = composer.outbox.reserveDeliveryTurn(nonce: outgoing.nonce)
        let delivery = Task { @MainActor [weak self] () -> Bool in
            await turn.previous?.value
            guard let self else { return false }
            defer {
                if isCurrentAccountSession(session) {
                    if !composer.outbox.isWithdrawn(nonce: outgoing.nonce) {
                        composer.slowmode.end(in: outgoing.channelID)
                    }
                    composer.outbox.finishDelivery(for: turn)
                }
            }
            let confirmedWhileWaiting = composer.outbox.beginDelivery(for: turn)
            guard isCurrentAccountSession(session), !composer.outbox.isWithdrawn(nonce: outgoing.nonce) else { return false }
            // A late Gateway confirmation can settle a retry while it waits;
            // sticker and poll bodies have no enforced nonce to stop a duplicate.
            if confirmedWhileWaiting
                || outgoingState(nonce: outgoing.nonce, channelID: outgoing.channelID) == .confirmed
            {
                discardVoiceMessageFile(for: outgoing)
                composer.outbox.draftsByNonce[outgoing.nonce] = nil
                composer.outbox.stickerUploadSourceURLByNonce[outgoing.nonce] = nil
                attachmentUploads.finish(nonce: outgoing.nonce)
                return true
            }
            if let prepare, !(await prepare()) { return false }
            let didSend = await deliverOutgoingSend(outgoing, isRetry: isRetry, session: session)
            if didSend, completesReading {
                completeConfirmedSend(channelID: outgoing.channelID, advancedLocally: advancedLocally)
            }
            return didSend
        }
        composer.outbox.setDeliveryTail(Task { _ = await delivery.value }, for: turn)
        return delivery
    }

    private func deliverOutgoingSend(
        _ outgoing: SendMessageDraft,
        isRetry: Bool,
        session: AppModelAccountSession
    ) async -> Bool {
        guard guildTimeoutUntil(in: outgoing.channelID) == nil else {
            updateOutgoingState(.failed, nonce: outgoing.nonce, channelID: outgoing.channelID)
            return false
        }
        let uploadsAttachments = !outgoing.attachmentURLs.isEmpty
        if uploadsAttachments { activeAttachmentUploadCount += 1 }
        defer { if uploadsAttachments { activeAttachmentUploadCount -= 1 } }
        let attachmentURLs = outgoing.attachmentURLs
        beginUsingOwnedPromisedFiles(attachmentURLs)
        let securityScopedURLs = attachmentURLs.filter {
            $0.startAccessingSecurityScopedResource()
        }
        defer {
            for url in securityScopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
            endUsingOwnedPromisedFiles(attachmentURLs)
        }
        Self.messageSendLogger.info(
            """
            Message send started channel=\(outgoing.channelID.description, privacy: .public) \
            nonce=\(outgoing.nonce, privacy: .public) attachments=\(outgoing.attachmentURLs.count) \
            stickers=\(outgoing.stickerIDs.count) retry=\(isRetry)
            """
        )
        do {
            let confirmed = try await session.provider.send(outgoing) { [weak self] progress in
                Task { @MainActor in self?.attachmentUploads.apply(progress, nonce: outgoing.nonce) }
            }
            guard isCurrentAccountSession(session) else { return false }
            attachmentUploads.finish(nonce: outgoing.nonce)
            recordMessageEmojiUsage(outgoing.content)
            confirmSlowmodeMessage(confirmed)
            let reconciled = reconcileVisibleOrCached(confirmed)
            discardVoiceMessageFile(for: outgoing)
            composer.outbox.noteConfirmation(nonce: outgoing.nonce, channelID: outgoing.channelID)
            composer.outbox.draftsByNonce[outgoing.nonce] = nil
            composer.outbox.stickerUploadSourceURLByNonce[outgoing.nonce] = nil
            journalAuthoritativeMessageUpsert(reconciled)
            guard isCurrentAccountSession(session) else { return false }
            Self.messageSendLogger.info(
                """
                Message send succeeded channel=\(outgoing.channelID.description, privacy: .public) \
                nonce=\(outgoing.nonce, privacy: .public) \
                message=\(confirmed.id.description, privacy: .public) retry=\(isRetry)
                """
            )
            return true
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            // A Gateway confirmation is authoritative even if the REST request
            // subsequently times out or fails on the retired transport.
            if outgoingState(nonce: outgoing.nonce, channelID: outgoing.channelID) == .confirmed {
                attachmentUploads.finish(nonce: outgoing.nonce)
                return true
            }
            // The user stopped every file, which already removed the message.
            if error is CancellationError, composer.outbox.draftsByNonce[outgoing.nonce] == nil {
                return false
            }
            attachmentUploads.fail(nonce: outgoing.nonce)
            recoverSlowmode(from: error, in: outgoing.channelID)
            // A timeout ends this attempt without proving whether it was delivered.
            // Keep the draft and nonce for explicit retry or discard; a late
            // Gateway confirmation can still reconcile the failed message.
            let state = OutboxState.failed
            let failure: MessageSendFailure? = if case let ChatProviderError.autoModerationBlocked(explanation) = error {
                .autoModeration(explanation: explanation)
            } else {
                nil
            }
            updateOutgoingState(state, nonce: outgoing.nonce, channelID: outgoing.channelID, failure: failure)
            let nsError = error as NSError
            Self.messageSendLogger.error(
                """
                Message send failed channel=\(outgoing.channelID.description, privacy: .public) \
                nonce=\(outgoing.nonce, privacy: .public) state=\(state.rawValue, privacy: .public) \
                retry=\(isRetry) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code) \
                details=\(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return false
        }
    }

    func optimisticMessage(
        for outgoing: SendMessageDraft,
        replyPreview: MessageReplyPreview?,
        stickers: [MessageSticker] = []
    ) -> Message {
        let id = composer.outbox.nextOptimisticMessageID()
        var message = Message(
            id: id,
            channelID: outgoing.channelID,
            author: snapshot?.currentUser
                ?? User(id: UserID(rawValue: 1), username: "me", displayName: "Me"),
            content: outgoing.content,
            replyTo: outgoing.replyTo,
            replyPreview: replyPreview,
            attachments: outgoing.attachments.enumerated().map {
                var presentation = OptimisticAttachmentPresentation.attachment(
                    for: $0.element.url,
                    index: $0.offset,
                    id: $0.element.id.uuidString
                )
                presentation.filename = $0.element.filename
                presentation.description = $0.element.description
                presentation.isSpoiler = $0.element.isSpoiler
                return presentation
            },
            nonce: outgoing.nonce,
            outboxState: .sending,
            stickers: stickers,
            // Pre-fill the replied-to author when pinging, so the reply @
            // indicator shows before the gateway confirmation arrives.
            mentionedUsers: outgoing.mentionsRepliedUser
                ? replyPreview.map { [$0.author] } ?? []
                : [],
            poll: outgoing.poll?.preview()
        )
        if let voiceMessage = outgoing.voiceMessage, !message.attachments.isEmpty {
            message.flags.insert(.voiceMessage)
            message.attachments[0].mediaType = "audio/ogg"
            message.attachments[0].durationSeconds = voiceMessage.durationSeconds
            message.attachments[0].waveform = voiceMessage.waveform
        }
        return message
    }

    func appendOutgoingMessage(_ message: Message) {
        if let nonce = message.nonce {
            composer.outbox.updateState(message.outboxState, nonce: nonce, channelID: message.channelID)
            timelineSendTransitionStore.noteLocalSend(nonce: nonce)
        }
        if message.channelID == openThread?.id {
            // A send is a later intent than a window request in flight.
            supersedeThreadWindowRequests()
            // Pending sends keep a row in any window so Retry and Discard
            // stay available; they sort after the loaded messages.
            var updated = threadMessages
            Self.insert(message, intoSorted: &updated)
            threadMessages = updated
        } else if message.channelID == selectedChannelID {
            appendSelectedMessage(message)
        } else {
            cache(message)
        }
    }
}

extension Message {
    /// A local send not yet confirmed, including a failed one awaiting retry
    /// or discard, which keeps its place below settled messages.
    nonisolated var isUnconfirmedLocalSend: Bool {
        switch outboxState {
        case .queued, .uploading, .sending, .awaitingReconciliation: true
        case .failed: nonce != nil
        case .confirmed: false
        }
    }
}
