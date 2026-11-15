import AppKit
import SakuraCordModels

nonisolated enum SystemMessagePresentation {
    enum Action: Equatable, Sendable {
        case profile(UserID)
        case message(guildID: GuildID?, channelID: ChannelID, messageID: MessageID)
        case pins(ChannelID)
        case editGroup(ChannelID)

        var url: URL {
            switch self {
            case .profile(let userID):
                URL(string: "sakuracord-action://profile/\(userID)")!
            case let .message(guildID, channelID, messageID):
                URL(string: "sakuracord-action://message/\(guildID?.description ?? "@me")/\(channelID)/\(messageID)")!
            case .pins(let channelID):
                URL(string: "sakuracord-action://pins/\(channelID)")!
            case .editGroup(let channelID):
                URL(string: "sakuracord-action://edit-group/\(channelID)")!
            }
        }

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
                self = .message(guildID: guildID, channelID: channelID, messageID: messageID)
            case "pins":
                guard parts.count == 1, let channelID = ChannelID(parts[0]) else { return nil }
                self = .pins(channelID)
            case "edit-group":
                guard parts.count == 1, let channelID = ChannelID(parts[0]) else { return nil }
                self = .editGroup(channelID)
            default:
                return nil
            }
        }
    }

    struct TextRun: Equatable, Sendable {
        let text: String
        let isEmphasized: Bool
        let action: Action?
        /// Drawn in link color, like Discord's trailing Edit Group action.
        var isLink = false

        static func emphasized(_ text: String, action: Action? = nil) -> Self {
            Self(text: text, isEmphasized: true, action: action)
        }

        static func secondary(_ text: String) -> Self {
            Self(text: text, isEmphasized: false, action: nil)
        }

        static func link(_ text: String, action: Action) -> Self {
            Self(text: text, isEmphasized: false, action: action, isLink: true)
        }
    }

    /// What a system message says after its author's name, for one-line
    /// previews such as a thread card's latest message.
    static func previewText(for message: Message) -> String {
        if message.type == .channelPinnedMessage { return "pinned a message to this channel." }
        var runs = textRuns(for: message)
        if runs.first?.action == .profile(message.author.id) { runs.removeFirst() }
        return runs.filter { !$0.isLink }.map(\.text).joined()
            .trimmingCharacters(in: .whitespaces)
    }

    static func label(
        for message: Message,
        currentUserID: UserID? = nil,
        recipient: User? = nil
    ) -> String {
        textRuns(for: message, currentUserID: currentUserID, recipient: recipient)
            .map(\.text)
            .joined()
    }

    static func attributedLabel(
        for message: Message,
        currentUserID: UserID? = nil,
        recipient: User? = nil,
        baseFontSize: CGFloat,
        actorColor: NSColor? = nil
    ) -> NSAttributedString {
        let value = NSMutableAttributedString()
        for run in textRuns(for: message, currentUserID: currentUserID, recipient: recipient) {
            var attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(
                            ofSize: baseFontSize,
                            weight: run.isEmphasized ? .semibold : .regular
                        ),
                        .foregroundColor: run.action == .profile(message.author.id)
                            ? actorColor ?? NSColor.labelColor
                            : run.isLink
                                ? NSColor.linkColor
                                : run.isEmphasized
                                ? NSColor.labelColor
                                : NSColor.secondaryLabelColor,
            ]
            if let action = run.action {
                attributes[.link] = action.url
            }
            value.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return value
    }

    private static func pollResultTextRuns(_ message: Message) -> [TextRun] {
        let question = message.pollResultSummary?.question ?? "Poll"
        let title = question.count > 50 ? String(question.prefix(47)) + "…" : question
        let action = message.messageReference?.messageID.map {
            Action.message(guildID: message.guildID, channelID: message.messageReference?.channelID ?? message.channelID, messageID: $0)
        }
        return [actorRun(message), .secondary("’s poll "), .emphasized(title, action: action), .secondary(" has closed.")]
    }

    static func textRuns(
        for message: Message,
        currentUserID: UserID? = nil,
        recipient: User? = nil
    ) -> [TextRun] {
        let author = message.author.displayName
        return switch message.type {
        case .recipientAdd, .recipientRemove, .channelNameChange, .channelIconChange,
             .channelPinnedMessage, .userJoin:
            conversationTextRuns(for: message, author: author)
        case .friendRequestAccepted:
            friendRequestTextRuns(for: message, currentUserID: currentUserID, recipient: recipient)
        case .pollResult:
            pollResultTextRuns(message)
        case .guildJoinRequestApproved:
            // The applicant is not named in the payload; the official row names the GDM's applicant.
            [.secondary("The application to "), .emphasized(message.content), .secondary(" was approved! Welcome!")]
        case .call:
            callTextRuns(for: message, author: author, currentUserID: currentUserID)
        case .guildBoost, .guildBoostTier1, .guildBoostTier2, .guildBoostTier3:
            boostTextRuns(for: message, author: author)
        case .channelFollowAdd, .threadCreated, .guildInviteReminder, .stageStart,
             .stageEnd, .stageSpeaker, .stageTopic:
            eventTextRuns(for: message, author: author)
        default:
            [
                .secondary(
                    message.content.isEmpty
                        ? "Discord system message"
                        : message.content
                )
            ]
        }
    }

    private static func friendRequestTextRuns(
        for message: Message,
        currentUserID: UserID?,
        recipient: User?
    ) -> [TextRun] {
        let acceptedByCurrentUser = message.author.id == currentUserID
        var runs: [TextRun]
        if acceptedByCurrentUser, let recipient {
            runs = [
                .secondary("You accepted "),
                .emphasized(recipient.displayName, action: .profile(recipient.id)),
                .secondary("’s friend request."),
            ]
        } else if acceptedByCurrentUser {
            runs = [.secondary("You accepted a friend request.")]
        } else {
            runs = [actorRun(message), .secondary(currentUserID == nil
                ? " accepted a friend request." : " accepted your friend request.")]
        }
        if !message.content.isEmpty {
            runs.append(.secondary(acceptedByCurrentUser ? " They said: "
                : currentUserID == nil ? " Note: " : " You said: "))
            runs.append(.emphasized(message.content))
        }
        return runs
    }

    private static func conversationTextRuns(
        for message: Message,
        author: String
    ) -> [TextRun] {
        switch message.type {
        case .recipientAdd:
            let recipientUser = message.mentionedUsers.first
            let recipient = recipientUser?.displayName ?? "someone"
            return [
                actorRun(message),
                .secondary(" added "),
                .emphasized(recipient, action: recipientUser.map { .profile($0.id) }),
                .secondary(" to the group."),
            ]
        case .recipientRemove:
            let recipientUser = message.mentionedUsers.first
            // Discord records a member leaving as removing themselves.
            if recipientUser?.id == message.author.id {
                return [actorRun(message), .secondary(" left the group.")]
            }
            let recipient = recipientUser?.displayName ?? "someone"
            return [
                actorRun(message),
                .secondary(" removed "),
                .emphasized(recipient, action: recipientUser.map { .profile($0.id) }),
                .secondary(" from the group."),
            ]
        case .channelNameChange where message.guildID != nil:
            // A renamed thread or forum post, worded as the first-party client does.
            return [
                actorRun(message),
                .secondary(" changed the channel name: "),
                .emphasized(message.content),
            ]
        case .channelNameChange:
            let editGroup = TextRun.link("Edit Group", action: .editGroup(message.channelID))
            if message.content.isEmpty {
                return [
                    actorRun(message),
                    .secondary(" changed the group name. "),
                    editGroup,
                ]
            }
            return [
                actorRun(message),
                .secondary(" changed the group name to "),
                .emphasized(message.content),
                .secondary(". "),
                editGroup,
            ]
        case .channelIconChange:
            return [
                actorRun(message),
                .secondary(" changed the group icon. "),
                .link("Edit Group", action: .editGroup(message.channelID)),
            ]
        case .channelPinnedMessage:
            let target = message.messageReference?.messageID.map {
                Action.message(
                    guildID: message.messageReference?.guildID ?? message.guildID,
                    channelID: message.messageReference?.channelID ?? message.channelID,
                    messageID: $0
                )
            }
            return [
                actorRun(message),
                .secondary(" pinned "),
                .emphasized("a message", action: target),
                .secondary(" to this channel. "),
                .emphasized("See all pinned messages", action: .pins(message.channelID)),
                .secondary("."),
            ]
        case .userJoin:
            return [
                .secondary("Yay you made it, "),
                actorRun(message),
                .secondary("!"),
            ]
        default:
            return []
        }
    }

    private static func callTextRuns(
        for message: Message,
        author: String,
        currentUserID: UserID?
    ) -> [TextRun] {
        guard let endedAt = message.call?.endedAt else {
            return [
                actorRun(message),
                .secondary(" started a call."),
            ]
        }
        let duration = callDuration(from: message.timestamp, to: endedAt)
        if isMissedCall(message, currentUserID: currentUserID) {
            return [
                .secondary("You missed a call from "),
                actorRun(message),
                .secondary(" that lasted \(duration)."),
            ]
        }
        return [
            actorRun(message),
            .secondary(" started a call that lasted \(duration)."),
        ]
    }

    private static func boostTextRuns(
        for message: Message,
        author: String
    ) -> [TextRun] {
        switch message.type {
        case .guildBoost:
            return [actorRun(message), .secondary(" boosted the server!")]
        case .guildBoostTier1:
            return [
                actorRun(message),
                .secondary(" boosted the server to "),
                .emphasized("Level 1"),
                .secondary("!"),
            ]
        case .guildBoostTier2:
            return [
                actorRun(message),
                .secondary(" boosted the server to "),
                .emphasized("Level 2"),
                .secondary("!"),
            ]
        case .guildBoostTier3:
            return [
                actorRun(message),
                .secondary(" boosted the server to "),
                .emphasized("Level 3"),
                .secondary("!"),
            ]
        default:
            return []
        }
    }

    private static func eventTextRuns(
        for message: Message,
        author: String
    ) -> [TextRun] {
        switch message.type {
        case .channelFollowAdd:
            return [
                actorRun(message),
                .secondary(" added a followed channel."),
            ]
        case .threadCreated:
            return [
                actorRun(message),
                .secondary(" started a thread: "),
                .emphasized(message.thread?.name ?? (message.content.isEmpty ? "Thread" : message.content)),
            ]
        case .guildInviteReminder:
            return [
                .secondary(
                    "Wondering who to invite? Start by inviting anyone who can help this server grow."
                )
            ]
        case .stageStart:
            return [actorRun(message), .secondary(" started a Stage.")]
        case .stageEnd:
            return [actorRun(message), .secondary(" ended the Stage.")]
        case .stageSpeaker:
            return [actorRun(message), .secondary(" is now a speaker.")]
        case .stageTopic:
            if message.content.isEmpty {
                return [.secondary("The Stage topic changed.")]
            }
            return [
                .secondary("Stage topic: "),
                .emphasized(message.content),
            ]
        default:
            return []
        }
    }

    private static func actorRun(_ message: Message) -> TextRun {
        .emphasized(
            message.author.displayName,
            action: .profile(message.author.id)
        )
    }

    static func systemImage(
        for message: Message,
        currentUserID: UserID? = nil
    ) -> String {
        switch message.type {
        case .friendRequestAccepted: "person.fill.checkmark"
        case .pollResult: "chart.bar.xaxis"
        case .recipientAdd: "arrow.right"
        case .recipientRemove: "arrow.left"
        case .channelNameChange: "pencil"
        case .channelIconChange: "photo.fill"
        case .userJoin, .guildJoinRequestApproved: "arrow.right"
        case .guildBoost, .guildBoostTier1, .guildBoostTier2, .guildBoostTier3:
            "sparkles"
        case .channelPinnedMessage: "pin.fill"
        case .threadCreated: SakuraCordSystemSymbol.thread
        case .call:
            isMissedCall(message, currentUserID: currentUserID)
                ? "phone.down.fill" : "phone.fill"
        default: "info.circle.fill"
        }
    }

    static func usesSuccessColor(
        for message: Message,
        currentUserID: UserID? = nil
    ) -> Bool {
        message.type == .friendRequestAccepted
            || message.type == .recipientAdd
            || message.type == .userJoin
            || message.type == .guildJoinRequestApproved
            || (message.type == .call
                && !isMissedCall(message, currentUserID: currentUserID))
    }

    static func isMissedCall(
        _ message: Message,
        currentUserID: UserID?
    ) -> Bool {
        guard message.type == .call,
              let currentUserID,
              let call = message.call,
              call.endedAt != nil,
              !call.participantIDs.isEmpty
        else { return false }
        return !call.participantIDs.contains(currentUserID)
    }

    private static func callDuration(from start: Date, to end: Date) -> String {
        let totalSeconds = max(0, Int(end.timeIntervalSince(start)))
        if totalSeconds < 60 {
            return "a few seconds"
        }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return totalMinutes == 1 ? "1 minute" : "\(totalMinutes) minutes"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        guard minutes > 0 else { return hourText }
        return "\(hourText) \(minutes == 1 ? "1 minute" : "\(minutes) minutes")"
    }
}
