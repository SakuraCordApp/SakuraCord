import DiscordProtocol
import SakuraCordModels

extension AppModel {
    /// Discord offers Close DM on 1:1 DMs only; a group DM is left instead.
    func offersCloseDirectMessage(_ channel: Channel) -> Bool {
        channel.guildID == nil && channel.kind == .directMessage
    }

    /// Closes a 1:1 DM without confirmation, as Discord does.
    func closeDirectMessage(_ channel: Channel) {
        exitDirectMessage(channel, verb: "close") { try await $0.closeDirectMessage(channel.id) }
    }
}
