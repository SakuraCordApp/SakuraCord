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
