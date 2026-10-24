import Foundation
import Observation
import SakuraCordModels

/// Blocked and ignored content share one presentation; only copy and symbols differ.
nonisolated enum UserContentSuppression: String {
    case ignored, blocked

    var systemImage: String {
        switch self {
        case .ignored: "eye.slash"
        case .blocked: "nosign"
        }
    }

    func countLabel(_ count: Int) -> String {
        count == 1 ? "1 \(rawValue) message" : "\(count) \(rawValue) messages"
    }

    var replyPlaceholder: String {
        switch self {
        case .ignored: "Ignored message"
        case .blocked: "Blocked message"
        }
    }
}

/// Reveals are local presentation state, never relationship mutations.
@Observable
final class IgnoredUsersState {
    private(set) var ignoredUserIDs: Set<UserID> = []
    private(set) var blockedUserIDs: Set<UserID> = []
    var revealedMessageIDs: Set<MessageID> = []
    /// Concealed rows that stay in the timeline until their closing motion ends.
    var collapsingMessageIDs: Set<MessageID> = []
    var revealedProfileRequests: Set<UUID> = []
    var groupWarning: Channel?
    var dismissedGroupWarningIDs: Set<ChannelID> = []
    var voiceWarning: Channel?
    @ObservationIgnored var voiceConfirmation: CheckedContinuation<Bool, Never>?

    func replaceRelationships(_ relationships: [Relationship]) {
        ignoredUserIDs = relationships.ignoredUserIDs
        blockedUserIDs = Set(relationships.lazy.filter { $0.type == .blocked }.map(\.id))
    }

    func reset() {
        ignoredUserIDs = []
        blockedUserIDs = []
        revealedMessageIDs = []
        collapsingMessageIDs = []
        revealedProfileRequests = []
        groupWarning = nil
        dismissedGroupWarningIDs = []
        resolveVoiceWarning(false)
    }

    func resolveVoiceWarning(_ proceed: Bool) {
        let continuation = voiceConfirmation
        voiceConfirmation = nil
        voiceWarning = nil
        continuation?.resume(returning: proceed)
    }
}

extension AppModel {
    func reconcileIgnoredGroupWarning() {
        guard let channel = selectedChannel, channel.kind == .groupDirectMessage,
              !channel.blockedUserWarningDismissed,
              !ignoredUsers.dismissedGroupWarningIDs.contains(channel.id),
              channel.recipients.contains(where: { isUserIgnored($0.id) }) else {
            ignoredUsers.groupWarning = nil
            return
        }
        ignoredUsers.groupWarning = channel
    }

    func dismissIgnoredGroupWarning(_ channel: Channel) {
        ignoredUsers.groupWarning = nil
        ignoredUsers.dismissedGroupWarningIDs.insert(channel.id)
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            do {
                try await account.provider.dismissIgnoredGroupWarning(in: channel.id)
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                model.ignoredUsers.dismissedGroupWarningIDs.remove(channel.id)
                model.friends.actionError = error.localizedDescription
            }
        }
    }

    func isUserIgnored(_ userID: UserID) -> Bool {
        ignoredUsers.ignoredUserIDs.contains(userID)
    }

    /// Blocking takes precedence over ignoring.
    func userSuppressionReason(_ userID: UserID) -> UserContentSuppression? {
        if ignoredUsers.blockedUserIDs.contains(userID) { return .blocked }
        return isUserIgnored(userID) ? .ignored : nil
    }

    func messageSuppressionReason(_ message: Message) -> UserContentSuppression? {
        let ids = [message.author.id] + (message.interactionMetadata?.user.map { [$0.id] } ?? [])
            + (message.type == .threadStarter ? message.replyPreview.map { [$0.author.id] } ?? [] : [])
        let reasons = ids.compactMap(userSuppressionReason)
        return reasons.contains(.blocked) ? .blocked : reasons.first
    }

    func isMessageSuppressed(_ message: Message) -> Bool {
        messageSuppressionReason(message) != nil
    }

    func isIncomingCallSuppressed(_ call: PrivateCall) -> Bool {
        let rings = call.ongoingRings.filter { $0.recipientID == currentUser?.id }
        return !rings.isEmpty && rings.allSatisfy { isUserIgnored($0.senderID) || ignoredUsers.blockedUserIDs.contains($0.senderID) }
    }

    /// Reveals or conceals a run. An animated conceal keeps the rows in the
    /// timeline until `finishCollapsingSuppressedMessages` ends the motion.
    func toggleSuppressedMessages(_ messageIDs: [MessageID], holdsCollapsingRows: Bool = false) {
        if messageIDs.allSatisfy(ignoredUsers.revealedMessageIDs.contains) {
            ignoredUsers.revealedMessageIDs.subtract(messageIDs)
            if holdsCollapsingRows { ignoredUsers.collapsingMessageIDs.formUnion(messageIDs) }
        } else {
            ignoredUsers.revealedMessageIDs.formUnion(messageIDs)
            ignoredUsers.collapsingMessageIDs.subtract(messageIDs)
        }
    }

    func finishCollapsingSuppressedMessages(_ messageIDs: [MessageID]) {
        guard messageIDs.contains(where: ignoredUsers.collapsingMessageIDs.contains) else { return }
        ignoredUsers.collapsingMessageIDs.subtract(messageIDs)
    }

    /// The reason a profile is withheld until the viewer asks to see it.
    func profileSuppression(_ presentation: ProfilePresentationState) -> UserContentSuppression? {
        guard !presentation.isCurrentUser,
              !ignoredUsers.revealedProfileRequests.contains(presentation.id) else { return nil }
        return userSuppressionReason(presentation.member.id)
    }

    func reconcileIgnoredVoiceParticipants(previous: [UserID: VoiceParticipantState] = [:]) {
        guard let channel = activeVoiceChannel, channel.guildID != nil, voiceSessionState == .connected,
              ignoredUsers.voiceWarning == nil,
              voiceStates.values.contains(where: {
                  $0.channelID == channel.id && isUserIgnored($0.userID)
                      && previous[$0.userID]?.channelID != channel.id
              }) else { return }
        ignoredUsers.voiceWarning = channel
    }

    func confirmIgnoredVoiceParticipants(in channel: Channel) async -> Bool {
        // Official direct calls remain joinable without this guild voice warning.
        guard channel.guildID != nil else { return true }
        let participants = voiceStates.values.filter { $0.channelID == channel.id }.map(\.userID)
        guard participants.contains(where: isUserIgnored) else { return true }
        // A second join cannot replace a pending confirmation's continuation.
        guard ignoredUsers.voiceConfirmation == nil else { return false }
        return await withCheckedContinuation { continuation in
            ignoredUsers.voiceConfirmation = continuation
            ignoredUsers.voiceWarning = channel
        }
    }
}
