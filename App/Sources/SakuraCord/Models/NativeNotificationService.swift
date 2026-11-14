import AppKit
import Foundation
import MessageRendering
import OSLog
import SakuraCordModels
import UserNotifications

nonisolated enum NotificationPreviewStyle: String, CaseIterable, Identifiable {
    case full
    case senderOnly
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Show sender and message"
        case .senderOnly: "Show sender only"
        case .hidden: "Hide notification details"
        }
    }
}

nonisolated enum NotificationDockBadgeStyle: String, CaseIterable, Identifiable {
    case mentions
    case unreadConversations
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mentions: "Unread mentions"
        case .unreadConversations: "Unread conversations"
        case .off: "Off"
        }
    }
}

nonisolated enum NotificationEventType: String, CaseIterable, Identifiable, Sendable {
    case directMessage
    case groupDirectMessage
    case mention
    case reply
    case incomingCall
    case serverActivity

    var id: String { rawValue }
}

nonisolated struct NotificationEventContext: Equatable, Sendable {
    var type: NotificationEventType

    static func message(
        _ message: Message,
        channel: Channel?,
        isMention: Bool,
        currentUserID: UserID
    ) -> Self {
        let type: NotificationEventType
        if channel?.kind == .directMessage {
            type = .directMessage
        } else if channel?.kind == .groupDirectMessage {
            type = .groupDirectMessage
        } else if message.replyPreview?.author.id == currentUserID {
            type = .reply
        } else if isMention {
            type = .mention
        } else {
            type = .serverActivity
        }
        return Self(type: type)
    }

    static let incomingCall = Self(type: .incomingCall)
}

nonisolated enum NativeNotificationIdentity {
    static func message(
        accountID: String,
        channelID: ChannelID,
        messageID: MessageID
    ) -> String {
        messagePrefix(accountID: accountID, channelID: channelID) + "\(messageID)"
    }

    /// The prefix shared by every message notification in a conversation.
    static func messagePrefix(accountID: String, channelID: ChannelID) -> String {
        "message:\(accountID):\(channelID):"
    }

    static func conversation(accountID: String, channelID: ChannelID) -> String {
        "conversation:\(accountID):\(channelID)"
    }
}

nonisolated enum NotificationFocusPolicy {
    static var interruptionLevel: UNNotificationInterruptionLevel { .active }
}

nonisolated struct NotificationContentPresentation: Equatable, Sendable {
    var title: String
    var subtitle: String
    var body: String

    static func make(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        style: NotificationPreviewStyle,
        mentionLabel: ((RenderedMention) -> String)? = nil
    ) -> Self {
        switch style {
        case .full:
            Self(
                title: message.guildMember?.nickname ?? message.author.displayName,
                subtitle: channel?.guildID != nil ? channel.map { "#\($0.name)" } ?? "" : "",
                body: previewText(message: message, mentionLabel: mentionLabel)
            )
        case .senderOnly:
            Self(title: message.author.displayName, subtitle: "", body: "New message")
        case .hidden:
            Self(title: "SakuraCord", subtitle: "", body: "New message")
        }
    }

    private static func previewText(
        message: Message,
        mentionLabel: ((RenderedMention) -> String)?
    ) -> String {
        guard !message.content.isEmpty else {
            return message.attachments.count == 1 ? "Sent an attachment" : "Sent attachments"
        }
        // Parse the whole message, with a placeholder for each inline token,
        // so a spoiler around a mention or emoji is found like any other.
        var source = ""
        var labels: [String] = []
        for segment in MessageDocument(source: message.content).segments {
            switch segment {
            case let .markdown(text):
                source += text
            case let .customEmoji(emoji):
                source.append(inlineTokenPlaceholder)
                labels.append(":\(emoji.name):")
            case let .mention(mention):
                source.append(inlineTokenPlaceholder)
                labels.append(mentionLabel?(mention) ?? fallbackMentionLabel(mention, message: message))
            }
        }
        // Like Discord, each spoiler reads as a placeholder, never its text.
        var output = ""
        var labelIndex = 0
        var currentSpoilerID: Int?
        for run in DiscordMarkdown.plainTextRuns(source) {
            if let spoilerID = run.spoilerID {
                if spoilerID != currentSpoilerID { output += "<spoiler>" }
                currentSpoilerID = spoilerID
                labelIndex += run.text.count { $0 == inlineTokenPlaceholder }
                continue
            }
            currentSpoilerID = nil
            for character in run.text {
                guard character == inlineTokenPlaceholder else {
                    output.append(character)
                    continue
                }
                if labels.indices.contains(labelIndex) { output += labels[labelIndex] }
                labelIndex += 1
            }
        }
        return output
    }

    private static let inlineTokenPlaceholder: Character = "\u{FFFC}"

    private static func fallbackMentionLabel(_ mention: RenderedMention, message: Message) -> String {
        switch mention.kind {
        case .guildNavigation: GuildNavigationMention(rawValue: mention.id)?.title ?? mention.rawToken
        case .user:
            "@\(message.mentionedUsers.first { String($0.id.rawValue) == mention.id }?.displayName ?? "unknown-user")"
        case .role: "@unknown-role"
        case .game, .broadcast, .command, .timestamp: MentionPresentation.fallback(for: mention).label
        case .channel, .channelLink: "#unknown-channel"
        case .message: "Message link"
        }
    }
}

nonisolated struct NotificationDeepLink: Codable, Equatable, Sendable {
    var accountID: String
    var guildID: GuildID?
    var channelID: ChannelID
    var messageID: MessageID?

    var userInfo: [String: String] {
        var value = [
            "account_id": accountID,
            "channel_id": String(channelID.rawValue),
        ]
        if let guildID {
            value["guild_id"] = String(guildID.rawValue)
        }
        if let messageID {
            value["message_id"] = String(messageID.rawValue)
        }
        return value
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let accountID = userInfo["account_id"] as? String,
              let channel = userInfo["channel_id"] as? String,
              let channelID = ChannelID(channel)
        else { return nil }
        self.accountID = accountID
        self.guildID = (userInfo["guild_id"] as? String).flatMap(GuildID.init)
        self.channelID = channelID
        self.messageID = (userInfo["message_id"] as? String).flatMap(MessageID.init)
    }

    init(
        accountID: String,
        guildID: GuildID?,
        channelID: ChannelID,
        messageID: MessageID?
    ) {
        self.accountID = accountID
        self.guildID = guildID
        self.channelID = channelID
        self.messageID = messageID
    }
}

@MainActor
protocol NativeNotificationService: Sendable {
    func setSuppressed(_ suppressed: Bool)
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func deliverMessage(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        presentation: NotificationContentPresentation,
        preferences: NotificationPreferences
    ) async
    func cancel(accountID: String, channelID: ChannelID) async
    func setDockBadge(_ count: Int, enabled: Bool)
}

extension NativeNotificationService {
    func setSuppressed(_: Bool) {}
}

@MainActor
final class NoopNativeNotificationService: NativeNotificationService {
    func requestAuthorization() async throws -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func deliverMessage(
        message _: Message,
        channel _: Channel?,
        guild _: Guild?,
        accountID _: String,
        presentation _: NotificationContentPresentation,
        preferences _: NotificationPreferences
    ) async {}
    func cancel(accountID _: String, channelID _: ChannelID) async {}
    func setDockBadge(_: Int, enabled _: Bool) {}
}

@MainActor
final class MacNativeNotificationService: NSObject, NativeNotificationService {
    private static let logger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "Notifications"
    )
    private static let notificationSound: UNNotificationSound? = {
        // macOS resolves this basename through AppKit's sound-resource lookup.
        guard Bundle.main.path(forSoundResource: "message1") != nil else {
            logger.error("The bundled notification sound is missing")
            return nil
        }
        return UNNotificationSound(named: UNNotificationSoundName("message1"))
    }()
    private var center: UNUserNotificationCenter { .current() }

    private static func bannerSound(preferences: NotificationPreferences) async -> UNNotificationSound? {
        guard preferences.playsSound else { return nil }
        guard let name = await BannerSoundStore.shared.soundName(for: preferences.soundChoice(for: .message))
        else { return notificationSound }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }

    // Offline demos use real system permissions without publishing fixture alerts.
    private let deliversNotifications: Bool
    private let preparePreviewImage: @MainActor (URL?, Int) async -> Data?
    private let submitRequest: @MainActor (UNNotificationRequest) async throws -> Void
    private var isSuppressed = false
    private var pendingRequests: [String: UUID] = [:]

    init(
        deliversNotifications: Bool = true,
        preparePreviewImage: @escaping @MainActor (URL?, Int) async -> Data? = {
            await NotificationMedia.previewImage(at: $0, maximumDimension: $1)
        },
        submitRequest: @escaping @MainActor (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        }
    ) {
        self.deliversNotifications = deliversNotifications
        self.preparePreviewImage = preparePreviewImage
        self.submitRequest = submitRequest
        super.init()
    }

    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        // Invalidate image preparation even if DND ends before it completes.
        if suppressed { pendingRequests.removeAll() }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func deliverMessage(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        presentation: NotificationContentPresentation,
        preferences: NotificationPreferences
    ) async {
        guard deliversNotifications, !isSuppressed, preferences.isEnabled else { return }
        let identifier = NativeNotificationIdentity.message(
            accountID: accountID, channelID: message.channelID, messageID: message.id
        )
        let token = UUID()
        let style = preferences.previewStyle
        pendingRequests[identifier] = token
        defer { if pendingRequests[identifier] == token { pendingRequests[identifier] = nil } }
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.subtitle = presentation.subtitle
        content.body = presentation.body
        content.interruptionLevel = NotificationFocusPolicy.interruptionLevel
        if preferences.groupsByConversation {
            content.threadIdentifier = NativeNotificationIdentity.conversation(
                accountID: accountID,
                channelID: message.channelID
            )
        }
        content.userInfo = NotificationDeepLink(
            accountID: accountID,
            guildID: message.guildID ?? channel?.guildID,
            channelID: message.channelID,
            messageID: message.id
        ).userInfo
        let attachment = NotificationMedia.imageAttachment(in: message, style: style)
        let imageData = await preparePreviewImage(
            attachment?.proxyURL ?? attachment?.url, 1_280
        )
        guard pendingRequests[identifier] == token, !Task.isCancelled,
              preferences.isEnabled, preferences.previewStyle == style
        else { return }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-\(token.uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        if let imageData {
            do {
                try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
                let url = temporaryDirectory.appendingPathComponent("image.png")
                try imageData.write(to: url)
                content.attachments = [try UNNotificationAttachment(identifier: "image", url: url)]
            } catch {
                Self.logger.debug("Notification image attachment could not be prepared")
            }
        }
        // Prepared before the last check, since a custom sound may need exporting.
        let sound = await Self.bannerSound(preferences: preferences)
        guard pendingRequests[identifier] == token, !Task.isCancelled,
              preferences.isEnabled, preferences.previewStyle == style
        else { return }
        content.sound = preferences.playsSound ? sound : nil
        do {
            try await submitRequest(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        } catch {
            let notificationError = error as NSError
            Self.logger.error(
                "Message notification delivery failed; domain=\(notificationError.domain, privacy: .public), code=\(notificationError.code)"
            )
        }
    }

    func cancel(accountID: String, channelID: ChannelID) async {
        guard deliversNotifications else { return }
        let prefix = NativeNotificationIdentity.messagePrefix(accountID: accountID, channelID: channelID)
        pendingRequests = pendingRequests.filter { !$0.key.hasPrefix(prefix) }
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
    }

    func setDockBadge(_ count: Int, enabled: Bool) {
        guard deliversNotifications else { return }
        NSApplication.shared.dockTile.badgeLabel =
            enabled && count > 0 ? String(count) : nil
    }

}
