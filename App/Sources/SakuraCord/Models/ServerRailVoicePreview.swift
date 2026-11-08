import Foundation
import Observation
import SakuraCordModels

struct ServerRailVoiceParticipant: Identifiable, Equatable {
    let id: UserID
    /// Nil until the participant's member has been resolved.
    let name: String?
    let avatarURL: URL?
}

/// Who is in voice in one guild, as the server rail's hover card shows it:
/// the first few participants' avatars and a count of the rest.
struct ServerRailVoicePreview: Equatable {
    static let maximumAvatarCount = 5

    let participants: [ServerRailVoiceParticipant]
    let overflowCount: Int
    /// Shown participants outside the open guild's live member store. The
    /// card rereads them from the provider's cache each time it opens; the
    /// app stops refreshing a guild's members once it is left, but the
    /// provider keeps applying member updates for every guild.
    let providerUserIDs: [UserID]
}

/// Users for voice previews outside the open guild, read from the
/// provider's existing member cache.
@Observable
final class ServerRailVoicePreviewStore {
    var usersByGuildID: [GuildID: [UserID: User]] = [:]

    func clear() {
        usersByGuildID = [:]
    }
}

extension AppModel {
    /// Reads account-wide voice states, so only the hovered card observes
    /// voice changes across every guild.
    func serverRailVoicePreview(for guildID: GuildID) -> ServerRailVoicePreview? {
        let currentUser = snapshot?.currentUser
        var userIDs: Set<UserID> = []
        for state in voiceStates.values
            where state.guildID == guildID && state.channelID != nil
        {
            userIDs.insert(state.userID)
        }
        if let currentUser, activeVoiceChannel?.guildID == guildID {
            userIDs.insert(currentUser.id)
        }
        guard !userIDs.isEmpty else { return nil }

        let ordered = userIDs.sorted { lhs, rhs in
            let lhsIsCurrent = lhs == currentUser?.id
            if lhsIsCurrent != (rhs == currentUser?.id) { return lhsIsCurrent }
            return lhs < rhs
        }
        let resolved = serverRailVoicePreviewStore.usersByGuildID[guildID] ?? [:]
        var providerUserIDs: [UserID] = []
        let participants = ordered
            .prefix(ServerRailVoicePreview.maximumAvatarCount)
            .map { userID in
                let liveUser = userID == currentUser?.id ? currentUser
                    : guildID == selectedGuildID ? profileMember(userID, in: guildID)?.user
                    : nil
                if liveUser == nil { providerUserIDs.append(userID) }
                let user = liveUser ?? resolved[userID] ?? profileMember(userID, in: guildID)?.user
                return ServerRailVoiceParticipant(
                    id: userID,
                    name: user?.displayName,
                    avatarURL: user?.avatarURL
                )
            }
        return ServerRailVoicePreview(
            participants: participants,
            overflowCount: ordered.count - participants.count,
            providerUserIDs: providerUserIDs
        )
    }

    /// Fills in shown participants from members the provider already holds.
    /// Hovering never sends a Gateway member request.
    func resolveServerRailVoiceParticipants(
        _ userIDs: [UserID],
        in guildID: GuildID
    ) async {
        guard !userIDs.isEmpty else { return }
        let session = accountSession()
        let members = await session.provider.knownMembers(
            in: guildID,
            userIDs: userIDs
        )
        guard isCurrentAccountSession(session), !members.isEmpty else { return }
        let previous = serverRailVoicePreviewStore.usersByGuildID[guildID] ?? [:]
        var users = previous
        for member in members {
            users[member.id] = member.user
        }
        if users != previous {
            serverRailVoicePreviewStore.usersByGuildID[guildID] = users
        }
    }
}
