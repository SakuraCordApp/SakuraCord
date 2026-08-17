import Foundation
import Observation
import SakuraCordModels

struct VoiceSidebarParticipant: Identifiable, Equatable {
    let id: UserID
    let name: String
    let avatarURL: URL?
    let isCurrentUser: Bool
    let isMuted: Bool
    let isDeafened: Bool
    let isStreaming: Bool
    let isVideoEnabled: Bool
}

@Observable
final class VoiceSidebarChannelEntry: Identifiable {
    let id: ChannelID
    var participants: [VoiceSidebarParticipant] = []

    init(id: ChannelID) {
        self.id = id
    }

    @discardableResult
    func update(_ participants: [VoiceSidebarParticipant]) -> Bool {
        guard self.participants != participants else { return false }
        self.participants = participants
        return true
    }
}

/// Maintains stable per-channel presentation leaves for the native channel
/// outline. Member hydration and voice-state events can update one voice
/// channel without invalidating or rediffing the complete channel list.
@Observable
final class VoiceSidebarPresentationStore {
    @ObservationIgnored private var entriesByChannelID:
        [ChannelID: VoiceSidebarChannelEntry] = [:]
    @ObservationIgnored private var populatedChannelIDs: Set<ChannelID> = []

    func entry(for channelID: ChannelID) -> VoiceSidebarChannelEntry {
        if let entry = entriesByChannelID[channelID] {
            return entry
        }
        let entry = VoiceSidebarChannelEntry(id: channelID)
        entriesByChannelID[channelID] = entry
        return entry
    }

    func update(
        voiceStates: [UserID: VoiceParticipantState],
        membersByID: [UserID: Member],
        currentUser: User?,
        activeVoiceChannel: Channel?,
        isVoiceMuted: Bool,
        isVoiceDeafened: Bool,
        isCameraEnabled: Bool
    ) {
        AppPerformanceSignposts.measureSync(
            "VoiceSidebarPresentationReconciliation"
        ) {
            let currentUserID = currentUser?.id
            var statesByChannel:
                [ChannelID: [UserID: VoiceParticipantState]] = [:]
            statesByChannel.reserveCapacity(populatedChannelIDs.count)

            for state in voiceStates.values {
                guard let channelID = state.channelID else { continue }
                statesByChannel[channelID, default: [:]][state.userID] = state
            }

            if let activeVoiceChannel,
               let currentUserID,
               statesByChannel[activeVoiceChannel.id]?[currentUserID] == nil
            {
                statesByChannel[activeVoiceChannel.id, default: [:]][currentUserID] =
                    VoiceParticipantState(
                        userID: currentUserID,
                        channelID: activeVoiceChannel.id,
                        guildID: activeVoiceChannel.guildID,
                        sessionID: "local",
                        isSelfMuted: isVoiceMuted,
                        isSelfDeafened: isVoiceDeafened,
                        isVideoEnabled: isCameraEnabled
                    )
            }

            let nextPopulatedChannelIDs = Set(statesByChannel.keys)
            for channelID in populatedChannelIDs.subtracting(
                nextPopulatedChannelIDs
            ) {
                publish([], to: entry(for: channelID))
            }

            for (channelID, statesByUser) in statesByChannel {
                let participants = statesByUser.map { userID, state in
                    let user = userID == currentUserID
                        ? currentUser
                        : membersByID[userID]?.user
                    return VoiceSidebarParticipant(
                        id: userID,
                        name: user?.displayName ?? "User \(userID.rawValue)",
                        avatarURL: user?.avatarURL,
                        isCurrentUser: userID == currentUserID,
                        isMuted: state.isMuted || state.isSelfMuted,
                        isDeafened: state.isDeafened || state.isSelfDeafened,
                        isStreaming: state.isStreaming,
                        isVideoEnabled: state.isVideoEnabled
                    )
                }.sorted {
                    if $0.isCurrentUser != $1.isCurrentUser {
                        return $0.isCurrentUser
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name)
                        == .orderedAscending
                }
                publish(participants, to: entry(for: channelID))
            }

            populatedChannelIDs = nextPopulatedChannelIDs
        }
    }

    private func publish(
        _ participants: [VoiceSidebarParticipant],
        to entry: VoiceSidebarChannelEntry
    ) {
        guard entry.participants != participants else { return }
        AppPerformanceSignposts.measureSync("VoiceSidebarChannelPublication") {
            _ = entry.update(participants)
        }
    }
}

extension AppModel {
    func refreshVoiceSidebarPresentation(
        using indexedMembers: [UserID: Member]? = nil
    ) {
        voiceSidebarPresentation.update(
            voiceStates: voiceStates,
            membersByID: indexedMembers ?? membersByID,
            currentUser: snapshot?.currentUser,
            activeVoiceChannel: activeVoiceChannel,
            isVoiceMuted: isVoiceMuted,
            isVoiceDeafened: isVoiceDeafened,
            isCameraEnabled: isCameraEnabled
        )
    }
}
