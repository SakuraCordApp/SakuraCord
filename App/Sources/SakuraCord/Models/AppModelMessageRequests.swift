import DiscordProtocol
import SakuraCordModels

extension AppModel {
    /// Direct messages from non-friends, newest first, as Discord lists them.
    var messageRequestChannels: [Channel] {
        (snapshot?.channels ?? [])
            .filter { $0.guildID == nil && $0.messageRequest != nil }
            .sorted { ($0.lastMessageID?.createdAt ?? $0.id.createdAt) > ($1.lastMessageID?.createdAt ?? $1.id.createdAt) }
    }

    var isMessageRequestsPresented: Bool {
        isFriendsPresented && friends.messageRequestsTab != nil
    }

    func openMessageRequests() {
        openFriends()
        friends.messageRequestsTab = .requests
    }

    func acceptMessageRequest(_ channel: Channel) {
        exitDirectMessage(channel, verb: "accept the request from") { try await $0.acceptMessageRequest(channel.id) }
    }

    func ignoreMessageRequest(_ channel: Channel) {
        exitDirectMessage(channel, verb: "ignore the request from") { try await $0.ignoreMessageRequest(channel.id) }
    }
}
