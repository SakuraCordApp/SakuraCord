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

    /// Keep the whole displayed label when formatting splits it into attribute runs.
    static func safetyDisplayedText(in value: NSAttributedString, at index: Int) -> String? {
        guard index >= 0, index < value.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard value.attribute(
            .link, at: index, longestEffectiveRange: &range,
            in: NSRange(location: 0, length: value.length)
        ) != nil else { return nil }
        return value.attributedSubstring(from: range).string
    }

    static func activate(
        _ url: URL,
        model: AppModel?,
        sourceMessage: Message? = nil,
        displayedText: String? = nil,
        presentSystemProfile: ((User) -> Void)? = nil,
        customHandler: (URL) -> Bool = { _ in false },
        confirmExternal: @escaping (ExternalLinkSafetyAssessment) -> Void = {
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
            if let model {
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
            if customHandler(url) { break }
            if let model, DiscordAttachmentLink.matches(url) {
                model.startAccountChildTask(account: model.accountSession()) { model, _ in
                    await model.openAttachmentLink(url) {
                        confirmExternal(ExternalLinkSafetyPolicy.assess($0, displayedText: displayedText))
                    }
                }
            } else {
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
    /// Opens a Discord attachment link, first asking Discord to re-sign it
    /// when it is unsigned or expires within the hour.
    func openAttachmentLink(_ url: URL, open: (URL) -> Void) async {
        guard DiscordAttachmentLink.needsRefresh(url, now: .now) else {
            open(url)
            return
        }
        let session = accountSession()
        do {
            let refreshed = try await session.provider.refreshAttachmentURL(url)
            guard isCurrentAccountSession(session) else { return }
            open(refreshed ?? url)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func systemMessageRecipient(for message: Message) -> User? {
        guard message.type == .friendRequestAccepted,
              let channel = snapshot?.channels.first(where: { $0.id == message.channelID }),
              channel.kind == .directMessage else { return nil }
        return channel.recipients.first { $0.id != snapshot?.currentUser.id }
    }

    func systemMessageUser(
        userID: UserID,
        sourceMessage: Message? = nil
    ) -> User? {
        let guildID = sourceMessage.map { messagePresentationGuildID(for: $0) } ?? selectedGuildID
        if let member = profileMember(userID, in: guildID) {
            return member.user
        }
        let sourceUser = sourceMessage.flatMap { message -> User? in
            if message.author.id == userID { return message.author }
            return message.mentionedUsers.first { $0.id == userID }
                ?? systemMessageRecipient(for: message).flatMap { $0.id == userID ? $0 : nil }
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
