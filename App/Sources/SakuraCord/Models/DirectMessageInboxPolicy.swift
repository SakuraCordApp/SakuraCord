import Foundation
import SakuraCordModels

nonisolated enum DirectMessageInboxPolicy {
    static func conversations(
        in channels: [Channel],
        pinnedChannelIDs: Set<ChannelID> = []
    ) -> [Channel] {
        let conversations = channels.filter(\.isListedDirectMessage)
        let pinned = conversations.filter { pinnedChannelIDs.contains($0.id) }
            .sorted { $0.lastActivityDate > $1.lastActivityDate }
        return pinned + conversations.filter { !pinnedChannelIDs.contains($0.id) }
    }

    static func recipientMember(
        for channel: Channel,
        membersByID: [UserID: Member]
    ) -> Member? {
        guard channel.kind == .directMessage,
              let recipient = channel.recipients.first
        else { return nil }
        return membersByID[recipient.id]
    }

    static func secondaryText(for channel: Channel, member: Member? = nil) -> String? {
        if channel.kind == .groupDirectMessage {
            return "\(channel.recipients.count + 1) members"
        }
        guard channel.kind == .directMessage else { return nil }
        guard let rawStatus = member?.customStatus else { return nil }
        let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty
        else { return nil }
        return status
    }

    static func callStatus(for call: PrivateCall?) -> String? {
        guard call?.ongoingRings.isEmpty == false else { return nil }
        return "Ringing"
    }
}
