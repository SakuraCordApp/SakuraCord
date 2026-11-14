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
            MentionPresentation(
                rawToken: mention.rawToken,
                label: DiscordTimestampToken(rawToken: mention.rawToken)?.formatted() ?? mention.rawToken,
                target: .unresolved,
                isTimestamp: true
            )
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
        MessageDocumentCache.shared.document(for: text).segments.reduce(into: [:]) { values, segment in
            if case let .mention(mention) = segment {
                values[mention.rawToken] = presentation(mention)
            }
        }
    }
}
