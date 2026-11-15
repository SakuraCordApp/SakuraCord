import DiscordProtocol
import SakuraCordModels

extension AppModel {
    /// Direct messages from non-friends, newest first, as Discord lists them.
    /// Read only in the Direct Messages home, where the visible channels are
    /// the private ones.
    var messageRequestChannels: [Channel] {
        visibleChannels.filter { $0.messageRequest != nil }
            .sorted { $0.lastActivityDate > $1.lastActivityDate }
    }

    /// Whether the conversation waits in Message Requests, which stays
    /// read-only until it is accepted.
    func awaitsMessageRequestDecision(in channelID: ChannelID) -> Bool {
        messageRequestChannelIDs.contains(channelID)
    }

    /// Whether the user's DM waits in Message Requests, which takes no reply.
    func hasMessageRequest(from userID: UserID) -> Bool {
        snapshot?.channels.contains {
            $0.kind == .directMessage && $0.messageRequest != nil && $0.recipients.contains { $0.id == userID }
        } == true
    }

    var isMessageRequestsPresented: Bool {
        isFriendsPresented && friends.messageRequestsTab != nil
    }

    func openMessageRequests() {
        openFriends()
        friends.messageRequestsTab = .pending
    }

    func acceptMessageRequest(_ channel: Channel) {
        exitDirectMessage(channel, verb: "accept the request from") { try await $0.acceptMessageRequest(channel.id) }
    }

    func ignoreMessageRequest(_ channel: Channel) {
        exitDirectMessage(channel, verb: "ignore the request from") { try await $0.ignoreMessageRequest(channel.id) }
    }
}

nonisolated extension Channel {
    /// The private-channel rule read from this channel value: the system DM,
    /// and a message request until it is accepted, take no replies,
    /// reactions, pins or calls. `awaitsMessageRequestDecision` reads the
    /// live set instead.
    var acceptsPrivateInteraction: Bool {
        !isOfficialSystemDirectMessage && messageRequest == nil
    }
}
