import AppKit
import MessageRendering
import OSLog
import SakuraCordModels
import SwiftUI
import Synchronization

nonisolated enum MentionTarget: Hashable, Sendable {
    case unresolved
    case guildNavigation(guildID: GuildID, destination: GuildNavigationMention)
    case user(UserID)
    case game(String)
    /// A slash command by its root ID and full name, such as `role add`.
    case command(id: String, name: String)
    case role(RoleID)
    case channel(ChannelID)
    case linkedChannel(guildID: GuildID?, channelID: ChannelID)
    case message(guildID: GuildID?, channelID: ChannelID, messageID: MessageID)
}

nonisolated struct MentionPresentation: Hashable, Identifiable, Sendable {
    let rawToken: String
    let label: String
    let target: MentionTarget
    var avatarURL: URL?
    var colorHex: UInt32?
    var systemImage: String?
    var isTimestamp = false

    var id: String { rawToken }
    var isGame: Bool {
        if case .game = target { true } else { false }
    }
    var showsAvatar: Bool {
        if isGame { return avatarURL != nil }
        if case .user = target { return true }
        return false
    }
    var isInteractive: Bool { target != .unresolved }
    /// Discord sets timestamps in the message's own weight, unlike mentions.
    var labelWeight: NSFont.Weight { isTimestamp ? .regular : .semibold }
    /// A game's square icon keeps slightly rounded corners; avatars are round.
    func avatarCornerRadius(size: CGFloat) -> CGFloat { isGame ? 3 : size / 2 }

    /// A link to a channel, thread or forum post the account does not know.
    static let unknownChannelLinkLabel = "unknown-channel"

    /// Broadcast, game, timestamp and command mentions carry everything
    /// they show in the token itself; a game's name and icon load later.
    /// A timestamp mention showing its time as of `date`, or its raw token
    /// when it doesn't parse.
    static func timestamp(_ mention: RenderedMention, at date: Date = .now) -> MentionPresentation {
        MentionPresentation(
            rawToken: mention.rawToken,
            label: DiscordTimestampToken(rawToken: mention.rawToken)?.formatted(relativeTo: date) ?? mention.rawToken,
            target: .unresolved,
            isTimestamp: true
        )
    }

    private static func selfContainedPresentation(for mention: RenderedMention) -> MentionPresentation {
        switch mention.kind {
        case .game:
            MentionPresentation(
                rawToken: mention.rawToken,
                label: "Unknown Game",
                target: .game(mention.id),
                systemImage: "gamecontroller.fill"
            )
        case .timestamp:
            timestamp(mention)
        case .command:
            if let name = mention.commandName {
                MentionPresentation(rawToken: mention.rawToken, label: "/\(name)", target: .command(id: mention.id, name: name))
            } else {
                unresolved(mention, label: mention.rawToken)
            }
        default:
            unresolved(mention, label: mention.rawToken)
        }
    }

    static func fallback(for mention: RenderedMention) -> MentionPresentation {
        switch mention.kind {
        case .guildNavigation:
            let destination = GuildNavigationMention(rawValue: mention.id)
            return unresolved(mention, label: destination?.title ?? mention.rawToken,
                              systemImage: destination == .guide ? "signpost.right.fill" : "list.bullet")
        case .user:
            guard let id = UserID(mention.id) else {
                return unresolved(mention, label: "@unknown-user")
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "@unknown-user",
                target: .user(id)
            )
        case .role:
            guard let id = RoleID(mention.id) else {
                return unresolved(mention, label: "@unknown-role")
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "@unknown-role",
                target: .role(id)
            )
        case .broadcast, .game, .timestamp, .command:
            return selfContainedPresentation(for: mention)
        case .channel:
            guard let id = ChannelID(mention.id) else {
                return unresolved(
                    mention,
                    label: "unknown-channel",
                    systemImage: ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
                )
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "unknown-channel",
                target: .channel(id),
                systemImage: ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
            )
        case .channelLink:
            guard let id = ChannelID(mention.id) else {
                return unresolved(
                    mention,
                    label: unknownChannelLinkLabel,
                    systemImage: ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
                )
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: unknownChannelLinkLabel,
                target: .linkedChannel(
                    guildID: mention.messageGuildID.flatMap(GuildID.init),
                    channelID: id
                ),
                systemImage: ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
            )
        case .message:
            guard let channelID = mention.messageChannelID.flatMap(ChannelID.init),
                  let messageID = MessageID(mention.id)
            else {
                return unresolved(
                    mention,
                    label: "unknown-channel ›",
                    systemImage: "bubble.left.fill"
                )
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "unknown-channel ›",
                target: .message(
                    guildID: mention.messageGuildID.flatMap(GuildID.init),
                    channelID: channelID,
                    messageID: messageID
                ),
                systemImage: "bubble.left.fill"
            )
        }
    }

    private static func unresolved(
        _ mention: RenderedMention,
        label: String,
        systemImage: String? = nil
    ) -> MentionPresentation {
        MentionPresentation(
            rawToken: mention.rawToken,
            label: label,
            target: .unresolved,
            systemImage: systemImage
        )
    }
}

/// Resolves mention metadata for a message through the app model.
struct MessageMentionResolver {
    let model: AppModel
    let message: Message?

    init(model: AppModel, message: Message? = nil) {
        self.model = model
        self.message = message
    }

    func label(_ mention: RenderedMention) -> String {
        presentation(mention).label
    }

    /// Every mention in prepared text, keyed by token: resolved through the
    /// model when there is one, else its fallback.
    static func presentations(
        for prepared: RichMessageAttributedText.Prepared, model: AppModel?, message: Message?
    ) -> [String: MentionPresentation] {
        let resolver = model.map { MessageMentionResolver(model: $0, message: message) }
        return prepared.tokens.reduce(into: [:]) { result, token in
            guard case let .mention(mention) = token else { return }
            result[mention.rawToken] = resolver?.presentation(mention) ?? MentionPresentation.fallback(for: mention)
        }
    }

    /// Every mention a draft holds, keyed by token, as an editor shows them.
    func presentations(in text: String) -> [String: MentionPresentation] {
        Self.presentations(in: MessageDocumentCache.shared.document(for: text), presenting: presentation)
    }

    /// Every mention in a document, keyed by token.
    static func presentations(
        in document: MessageDocument,
        presenting: (RenderedMention) -> MentionPresentation
    ) -> [String: MentionPresentation] {
        document.segments.reduce(into: [:]) { values, segment in
            if case let .mention(mention) = segment {
                values[mention.rawToken] = presenting(mention)
            }
        }
    }
}

extension MessageMentionResolver {
    private func member(_ id: UserID) -> Member? {
        sourceGuildID.flatMap { model.membersByGuildID[$0]?[id] }
            ?? (sourceGuildID == model.selectedGuildID ? model.membersByID[id] ?? model.knownMentionMembers[id] : nil)
    }

    func user(_ userID: UserID) -> User? {
        member(userID)?.user
            ?? message?.mentionedUsers.first { $0.id == userID }
            ?? model.messages.first { $0.author.id == userID }?.author
            ?? model.threadMessages.first { $0.author.id == userID }?.author
            ?? (model.currentUser?.id == userID ? model.currentUser : nil)
    }

    func presentation(_ mention: RenderedMention) -> MentionPresentation {
        switch mention.kind {
        case .guildNavigation: guildNavigationPresentation(mention)
        case .user: userPresentation(mention)
        case .role: rolePresentation(mention)
        case .game: gamePresentation(mention)
        case .broadcast, .timestamp, .command: MentionPresentation.fallback(for: mention)
        case .channel: channelPresentation(mention)
        case .channelLink: channelLinkPresentation(mention)
        case .message: messagePresentation(mention)
        }
    }

    /// Media discovery only needs images carried by user and game mentions.
    /// Resolving every mention kind would perform unrelated channel and role
    /// lookups for presentations that cannot contribute a media key.
    func avatarURL(_ mention: RenderedMention) -> URL? {
        if mention.kind == .game {
            return model.gameMentions.gamesByID[mention.id].flatMap(\.artworkURL)
        }
        guard mention.kind == .user,
              let userID = UserID(mention.id)
        else { return nil }
        let member = member(userID)
        return member?.guildAvatarURL ?? user(userID)?.avatarURL
    }

    private func gamePresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let game = model.gameMentions.gamesByID[mention.id] else {
            model.requestGameMentionDetails(id: mention.id)
            return MentionPresentation.fallback(for: mention)
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: game.name,
            target: .game(game.id),
            avatarURL: game.artworkURL,
            systemImage: game.artworkURL == nil ? "gamecontroller.fill" : nil
        )
    }

    private func userPresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let userID = UserID(mention.id) else {
            return MentionPresentation.fallback(for: mention)
        }
        let member = member(userID)
        let value = user(userID)
        let topColor = member.flatMap {
            MessageAuthorPresentation.topRoleColor(in: $0.roles)
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: "@\((sourceGuildID == nil ? model.friendNickname(for: userID) : nil) ?? member?.user.displayName ?? value?.displayName ?? "unknown-user")",
            target: .user(userID),
            avatarURL: member?.guildAvatarURL ?? value?.avatarURL,
            colorHex: topColor
        )
    }

    func role(_ roleID: RoleID) -> GuildRole? {
        let roles = sourceGuildID.flatMap { model.guildRolesByGuildID[$0] }
            ?? (sourceGuildID == model.selectedGuildID ? model.guildRoles : [])
        return roles.first { $0.id == roleID }
    }

    private func rolePresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let roleID = RoleID(mention.id) else {
            return MentionPresentation.fallback(for: mention)
        }
        let role = role(roleID)
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: "@\(role?.name ?? "unknown-role")",
            target: .role(roleID),
            colorHex: role?.colorHex
        )
    }

    private func guildNavigationPresentation(_ mention: RenderedMention) -> MentionPresentation {
        var presentation = MentionPresentation.fallback(for: mention)
        if let destination = GuildNavigationMention(rawValue: mention.id),
           let guildID = sourceGuildID,
           model.hasGuildNavigationDestination(destination, in: guildID) {
            presentation = MentionPresentation(
                rawToken: mention.rawToken, label: destination.title,
                target: .guildNavigation(guildID: guildID, destination: destination),
                systemImage: presentation.systemImage
            )
        }
        return presentation
    }

    private func channelPresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let channelID = ChannelID(mention.id) else {
            return MentionPresentation.fallback(for: mention)
        }
        let channel = channel(channelID)
        if channel == nil, let thread = model.messagePresentationThread(channelID) {
            return threadPresentation(thread, mention: mention)
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: channel.map { qualifiedLabel($0.name, guildID: $0.guildID) } ?? "unknown-channel",
            target: .channel(channelID),
            systemImage: ChannelIconPresentation.systemImage(
                for: channel?.kind ?? .unknown,
                isHidden: false
            )
        )
    }

    private func channelLinkPresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let channelID = ChannelID(mention.id) else {
            return MentionPresentation.fallback(for: mention)
        }
        let guildID = mention.messageGuildID.flatMap(GuildID.init)
        if let channel = channel(channelID) {
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: qualifiedLabel(channel.name, guildID: channel.guildID),
                target: .channel(channelID),
                systemImage: ChannelIconPresentation.systemImage(
                    for: channel.kind,
                    isHidden: false
                )
            )
        }
        if let thread = model.messagePresentationThread(channelID) {
            return threadPresentation(thread, mention: mention, linkGuildID: guildID)
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: MentionPresentation.unknownChannelLinkLabel,
            target: .linkedChannel(guildID: guildID, channelID: channelID),
            systemImage: ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
        )
    }

    /// A conversation's name, after its server's when the mention points
    /// into another server.
    private func qualifiedLabel(_ name: String, guildID: GuildID?) -> String {
        guard crossesGuild(targetGuildID: guildID),
              let guildName = guildID.flatMap({ model.serverRailGuildsByID[$0]?.name })
        else { return name }
        return "\(guildName) / \(name)"
    }

    /// A known thread or forum post, which opens like a thread link.
    private func threadPresentation(
        _ thread: MessageThreadSummary,
        mention: RenderedMention,
        linkGuildID: GuildID? = nil
    ) -> MentionPresentation {
        let guildID = thread.guildID ?? linkGuildID
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: qualifiedLabel(thread.name, guildID: guildID),
            target: .linkedChannel(guildID: guildID, channelID: thread.id),
            systemImage: ChannelIconPresentation.systemImage(forThreadInForum: model.isForumPost(thread))
        )
    }

    private func messagePresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let rawChannelID = mention.messageChannelID,
              let channelID = ChannelID(rawChannelID),
              let messageID = MessageID(mention.id)
        else {
            return MentionPresentation.fallback(for: mention)
        }
        let guildID = mention.messageGuildID.flatMap(GuildID.init)
        // A message in a thread or forum post is labeled with that thread.
        let name = channel(channelID)?.name ?? model.messagePresentationThread(channelID)?.name
        let channelLabel = "\(name.map { qualifiedLabel($0, guildID: guildID) } ?? MentionPresentation.unknownChannelLinkLabel) ›"
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: channelLabel,
            target: .message(
                guildID: guildID,
                channelID: channelID,
                messageID: messageID
            ),
            systemImage: "bubble.left.fill"
        )
    }

    private func channel(_ channelID: ChannelID) -> Channel? {
        model.messagePresentationChannel(channelID)
    }

    private var sourceGuildID: GuildID? {
        if let guildID = message?.guildID { return guildID }
        // REST thread messages, such as a forum card's starter, omit their guild.
        if let channelID = message?.channelID {
            return channel(channelID)?.guildID ?? model.messagePresentationThread(channelID)?.guildID
        }
        return model.selectedGuildID
    }

    private func crossesGuild(targetGuildID: GuildID?) -> Bool {
        guard let targetGuildID, let sourceGuildID else { return false }
        return targetGuildID != sourceGuildID
    }
}
