import CoreAudio
import Foundation
import MediaPipeline
import MessageRendering
import SakuraCordModels

extension AppModel {
    func voiceMessageComposer(for destination: MessageComposerDestination) -> VoiceMessageComposerState {
        switch destination {
        case .channel: channelVoiceMessageComposer
        case .thread: threadVoiceMessageComposer
        }
    }

    /// Whether the composer may record a voice message: the Features setting
    /// allows it, Discord requires the Send Voice Messages permission in
    /// servers, and voice messages are never part of a thread's first message.
    func canSendVoiceMessages(in destination: MessageComposerDestination) -> Bool {
        guard featuresSettings.voiceMessageRecording else { return false }
        let channel: Channel?
        switch destination {
        case .channel:
            guard selectedConversationAccess.canSend, let kind = selectedChannel?.kind,
                  Self.supportsTyping(kind)
            else { return false }
            channel = selectedChannel
        case .thread:
            guard threadCreation == nil, openThread != nil, openThreadAccess.canSend else { return false }
            channel = openThreadParentChannel
        }
        guard let channel, let permissions = effectiveMessagePermissions(in: channel) else { return false }
        return permissions & DiscordPermissionBits.sendVoiceMessages != 0
    }

    var voiceMessageInputDeviceID: AudioDeviceID? {
        currentVoiceConfiguration().inputDeviceID
    }

    /// Lets voice playback, file downloads, and text previews re-sign expiring
    /// attachment links, and previews lay out their rows again as they change.
    func configureAttachmentMedia() {
        let resolveRemoteURL: @MainActor (URL) async -> URL = { [weak self] url in
            guard let self, DiscordAttachmentLink.needsRefresh(url, now: .now) else { return url }
            let session = accountSession()
            return (try? await session.provider.refreshAttachmentURL(url)) ?? url
        }
        voiceMessagePlayback.resolveRemoteURL = resolveRemoteURL
        attachmentDownloads.resolveRemoteURL = resolveRemoteURL
        attachmentTextPreviews.resolveRemoteURL = resolveRemoteURL
        attachmentTextPreviews.onChange = { [weak self] messageID in
            guard let self else { return }
            if messages.contains(where: { $0.id == messageID }) {
                publishMessageRowsUpdate(changedMessageIDs: [messageID])
            }
            if threadMessages.contains(where: { $0.id == messageID }) {
                publishThreadMessageRowsPresentationUpdate(changedMessageIDs: [messageID])
            }
        }
        voiceMessagePlayback.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    /// Stops playback and discards unsent recordings when the account changes.
    func resetVoiceMessages() {
        voiceMessagePlayback.stopAll()
        channelVoiceMessageComposer.discard(playback: nil)
        threadVoiceMessageComposer.discard(playback: nil)
    }

    /// Sends the composer's finished recording, replying if a reply is active.
    func submitVoiceMessage(from destination: MessageComposerDestination) async -> ComposerSubmissionResult {
        let state = voiceMessageComposer(for: destination)
        guard let submittedRecording = state.phase.recording, canSendVoiceMessages(in: destination) else { return .rejected }
        let channelID: ChannelID
        let replyTo: Message?
        let mentionsRepliedUser: Bool
        switch destination {
        case .channel:
            guard let selected = selectedChannelID else { return .rejected }
            guard allowSlowmodeSubmission(in: selected), allowOutgoingQueueSubmission() else { return .rejected }
            replyTo = replyingTo
            mentionsRepliedUser = replyMentionsAuthor
            guard await prepareChannelMessageSubmission(channelID: selected, account: accountSession()) else {
                return .rejected
            }
            channelID = selected
        case .thread:
            guard let thread = openThread, allowOnboardingSubmission(in: thread.id) else { return .rejected }
            channelID = thread.id
            replyTo = threadReplyingTo
            mentionsRepliedUser = threadReplyMentionsAuthor
        }
        guard state.phase.recording == submittedRecording, canSendVoiceMessages(in: destination),
              allowSlowmodeSubmission(in: channelID), allowOutgoingQueueSubmission(),
              let recording = state.takeRecording(playback: voiceMessagePlayback)
        else { return .rejected }
        let outgoing = SendMessageDraft(
            channelID: channelID,
            content: "",
            replyTo: replyTo?.id,
            mentionsRepliedUser: mentionsRepliedUser,
            attachments: [ForumPostAttachment(url: recording.fileURL, filename: VoiceMessageMetadata.filename)],
            voiceMessage: recording.metadata
        )
        appendOutgoingMessage(optimisticMessage(for: outgoing, replyPreview: replyTo.map(MessageReplyPreview.init)))
        composer.outbox.draftsByNonce[outgoing.nonce] = outgoing
        switch destination {
        case .channel: replyingTo = nil
        case .thread: threadReplyingTo = nil
        }
        return .enqueued(delivery: enqueueOutgoingSend(outgoing, isRetry: false, completesReading: true))
    }

    /// Recordings live in a private temporary directory until delivered or discarded.
    func discardVoiceMessageFile(for outgoing: SendMessageDraft) {
        guard outgoing.voiceMessage != nil, let url = outgoing.attachmentURLs.first else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
