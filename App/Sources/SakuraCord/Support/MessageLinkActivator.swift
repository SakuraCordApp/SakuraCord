import Foundation
import MessageRendering
import SakuraCordModels

@MainActor
enum MessageLinkActivator {
    static func activate(
        _ url: URL,
        model: AppModel?,
        displayedText: String? = nil,
        customHandler: (URL) -> Bool = { _ in false },
        confirmExternal: (ExternalLinkSafetyAssessment) -> Void = {
            ExternalLinkConfirmationPresenter.shared.present($0)
        }
    ) -> Bool {
        if let action = SystemMessageLinkAction(url: url), let model {
            switch action {
            case .profile(let userID):
                model.showSystemMessageProfile(userID: userID)
            case let .message(guildID, channelID, messageID):
                model.navigateToSystemMessageTarget(
                    guildID: guildID,
                    channelID: channelID,
                    messageID: messageID
                )
            case .pins(let channelID):
                model.presentPinnedMessagesFromSystemMessage(channelID: channelID)
            }
            return true
        }
        guard let destination = MessageLinkPolicy.destination(for: url) else {
            return true
        }
        switch destination {
        case let .discordChannel(guildID, channelID):
            if let model, model.chatSettings.opensDiscordLinksInternally {
                model.navigate(to: guildID, linkedChannelID: channelID)
            } else if !customHandler(url) {
                confirmExternal(
                    ExternalLinkSafetyPolicy.assess(
                        url,
                        displayedText: displayedText
                    )
                )
            }
        case .web:
            if !customHandler(url) {
                confirmExternal(
                    ExternalLinkSafetyPolicy.assess(
                        url,
                        displayedText: displayedText
                    )
                )
            }
        }
        return true
    }
}

private enum SystemMessageLinkAction {
    case profile(UserID)
    case message(GuildID?, ChannelID, MessageID)
    case pins(ChannelID)

    init?(url: URL) {
        guard url.scheme == "sakuracord-action" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "profile":
            guard parts.count == 1, let userID = UserID(parts[0]) else { return nil }
            self = .profile(userID)
        case "message":
            guard parts.count == 3,
                  let channelID = ChannelID(parts[1]),
                  let messageID = MessageID(parts[2])
            else { return nil }
            let guildID: GuildID?
            if parts[0] == "@me" {
                guildID = nil
            } else {
                guard let parsedGuildID = GuildID(parts[0]) else { return nil }
                guildID = parsedGuildID
            }
            self = .message(
                guildID,
                channelID,
                messageID
            )
        case "pins":
            guard parts.count == 1, let channelID = ChannelID(parts[0]) else { return nil }
            self = .pins(channelID)
        default:
            return nil
        }
    }
}
