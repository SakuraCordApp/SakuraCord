import Foundation
import MessageRendering
import SakuraCordModels

@MainActor
enum MessageLinkActivator {
    static func accessibilityHelp(for url: URL, label: String) -> String {
        guard let action = SystemMessageLinkAction(url: url) else {
            return "Open link"
        }
        return switch action {
        case .profile:
            "View \(label)'s profile"
        case .message:
            "Jump to message"
        case .pins:
            "See all pinned messages"
        }
    }

    static func activate(
        _ url: URL,
        model: AppModel?,
        sourceMessage: Message? = nil,
        displayedText: String? = nil,
        presentSystemProfile: ((User) -> Void)? = nil,
        customHandler: (URL) -> Bool = { _ in false },
        confirmExternal: (ExternalLinkSafetyAssessment) -> Void = {
            ExternalLinkConfirmationPresenter.shared.present($0)
        }
    ) -> Bool {
        if let action = SystemMessageLinkAction(url: url), let model {
            switch action {
            case .profile(let userID):
                if let presentSystemProfile,
                   let user = model.systemMessageUser(
                       userID: userID,
                       sourceMessage: sourceMessage
                   )
                {
                    presentSystemProfile(user)
                } else {
                    model.showSystemMessageProfile(
                        userID: userID,
                        sourceMessage: sourceMessage
                    )
                }
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

extension AppModel {
    func systemMessageUser(
        userID: UserID,
        sourceMessage: Message? = nil
    ) -> User? {
        if let member = membersByID[userID] {
            return member.user
        }
        let sourceUser = sourceMessage.flatMap { message -> User? in
            if message.author.id == userID { return message.author }
            return message.mentionedUsers.first { $0.id == userID }
        }
        return sourceUser
            ?? (messages + threadMessages).lazy.compactMap { message -> User? in
                if message.author.id == userID { return message.author }
                return message.mentionedUsers.first { $0.id == userID }
            }.first
            ?? pinnedMessages.items.lazy.compactMap { item -> User? in
                if item.message.author.id == userID { return item.message.author }
                return item.message.mentionedUsers.first { $0.id == userID }
            }.first
            ?? messageSearch.page?.results.lazy.compactMap { result -> User? in
                result.messages.lazy.compactMap { message -> User? in
                    if message.author.id == userID { return message.author }
                    return message.mentionedUsers.first { $0.id == userID }
                }.first
            }.first
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
