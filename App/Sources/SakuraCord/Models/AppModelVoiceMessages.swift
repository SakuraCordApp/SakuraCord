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
    /// servers, and voice messages are never part of a thread's first message
    /// or scheduled, so none posts at once under the composer's schedule.
    func canSendVoiceMessages(in destination: MessageComposerDestination) -> Bool {
        guard featuresSettings.voiceMessageRecording, scheduledSendDate(in: destination) == nil else { return false }
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
        let replyTo = replyingTo(in: destination)
        let mentionsRepliedUser = replyMentionsAuthor(in: destination)
        switch destination {
        case .channel:
            guard let selected = selectedChannelID else { return .rejected }
            guard allowSlowmodeSubmission(in: selected), allowOutgoingQueueSubmission() else { return .rejected }
            guard await prepareChannelMessageSubmission(channelID: selected, account: accountSession()) else {
                return .rejected
            }
            channelID = selected
        case .thread:
            guard let thread = openThread, allowOnboardingSubmission(in: thread.id) else { return .rejected }
            channelID = thread.id
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
        admitToOutbox(optimisticMessage(for: outgoing, replyPreview: replyTo.map(MessageReplyPreview.init)), draft: outgoing)
        setReplyingTo(nil, in: destination)
        return .enqueued(delivery: enqueueOutgoingSend(outgoing, isRetry: false, completesReading: true))
    }

    /// Recordings live in a private temporary directory until delivered or discarded.
    func discardVoiceMessageFile(for outgoing: SendMessageDraft) {
        guard outgoing.voiceMessage != nil, let url = outgoing.attachmentURLs.first else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
