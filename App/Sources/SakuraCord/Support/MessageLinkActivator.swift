import AppKit
import MessageRendering

@MainActor
enum MessageLinkActivator {
    static func activate(
        _ url: URL,
        model: AppModel?,
        customHandler: (URL) -> Bool = { _ in false }
    ) -> Bool {
        guard let destination = MessageLinkPolicy.destination(for: url) else {
            return true
        }
        switch destination {
        case let .discordChannel(guildID, channelID):
            if let model, model.chatSettings.opensDiscordLinksInternally {
                model.navigate(to: guildID, linkedChannelID: channelID)
            } else if !customHandler(url) {
                NSWorkspace.shared.open(url)
            }
        case .web:
            if !customHandler(url) {
                NSWorkspace.shared.open(url)
            }
        }
        return true
    }
}
