import AppKit
import Foundation
import MessageRendering
import Observation
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
        "message:\(accountID):\(channelID):\(messageID)"
    }

    static func call(accountID: String, channelID: ChannelID) -> String {
        "call:\(accountID):\(channelID)"
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
        return MessageDocument(source: message.content).segments.map { segment in
            switch segment {
            case let .markdown(text):
                String(DiscordMarkdown.attributed(text).characters)
            case let .customEmoji(emoji):
                ":\(emoji.name):"
            case let .mention(mention):
                mentionLabel?(mention) ?? fallbackMentionLabel(mention, message: message)
            }
        }.joined()
    }

    private static func fallbackMentionLabel(_ mention: RenderedMention, message: Message) -> String {
        switch mention.kind {
        case .user:
            "@\(message.mentionedUsers.first { String($0.id.rawValue) == mention.id }?.displayName ?? "unknown-user")"
        case .role: "@unknown-role"
        case .game: "Game"
        case .broadcast: mention.rawToken
        case .timestamp: DiscordTimestampToken(rawToken: mention.rawToken)?.formatted() ?? mention.rawToken
        case .channel, .channelLink: "#unknown-channel"
        case .message: "Message link"
        }
    }

    static func makeIncomingCall(
        callerName: String?,
        conversationName: String?,
        style: NotificationPreviewStyle
    ) -> Self {
        switch style {
        case .full:
            Self(
                title: callerName ?? "Incoming call",
                subtitle: conversationName ?? "",
                body: "Incoming call"
            )
        case .senderOnly:
            Self(title: callerName ?? "Incoming call", subtitle: "", body: "Incoming call")
        case .hidden:
            Self(title: "SakuraCord", subtitle: "", body: "Incoming call")
        }
    }
}

@MainActor
@Observable
final class NotificationPreferences {
    private enum Key {
        static let enabled = "notifications.enabled"
        static let preview = "notifications.preview"
        static let sound = "notifications.sound"
        static let dockBadge = "notifications.dockBadge"
        static let directMessages = "notifications.events.directMessages"
        static let groupDirectMessages = "notifications.events.groupDirectMessages"
        static let mentions = "notifications.events.mentions"
        static let replies = "notifications.events.replies"
        static let incomingCalls = "notifications.events.incomingCalls"
        static let serverActivity = "notifications.events.serverActivity"
        static let suppressCurrentConversation = "notifications.suppressCurrentConversation"
        static let groupByConversation = "notifications.groupByConversation"
        static let clearWhenRead = "notifications.clearWhenRead"
    }

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    var previewStyle: NotificationPreviewStyle {
        didSet { defaults.set(previewStyle.rawValue, forKey: Key.preview) }
    }
    var playsSound: Bool { didSet { defaults.set(playsSound, forKey: Key.sound) } }
    var dockBadgeStyle: NotificationDockBadgeStyle {
        didSet { defaults.set(dockBadgeStyle.rawValue, forKey: Key.dockBadge) }
    }
    var notifiesDirectMessages: Bool {
        didSet { defaults.set(notifiesDirectMessages, forKey: Key.directMessages) }
    }
    var notifiesGroupDirectMessages: Bool {
        didSet { defaults.set(notifiesGroupDirectMessages, forKey: Key.groupDirectMessages) }
    }
    var notifiesMentions: Bool {
        didSet { defaults.set(notifiesMentions, forKey: Key.mentions) }
    }
    var notifiesReplies: Bool {
        didSet { defaults.set(notifiesReplies, forKey: Key.replies) }
    }
    var notifiesIncomingCalls: Bool {
        didSet { defaults.set(notifiesIncomingCalls, forKey: Key.incomingCalls) }
    }
    var notifiesServerActivity: Bool {
        didSet { defaults.set(notifiesServerActivity, forKey: Key.serverActivity) }
    }
    var suppressesCurrentConversation: Bool {
        didSet {
            defaults.set(suppressesCurrentConversation, forKey: Key.suppressCurrentConversation)
        }
    }
    var groupsByConversation: Bool {
        didSet { defaults.set(groupsByConversation, forKey: Key.groupByConversation) }
    }
    var clearsWhenRead: Bool {
        didSet { defaults.set(clearsWhenRead, forKey: Key.clearWhenRead) }
    }
    @ObservationIgnored private let defaults: any PreferenceStoring

    init(defaults: any PreferenceStoring = UserDefaults.standard) {
        self.defaults = defaults
        isEnabled = true
        previewStyle = .full
        playsSound = true
        dockBadgeStyle = .mentions
        notifiesDirectMessages = true
        notifiesGroupDirectMessages = true
        notifiesMentions = true
        notifiesReplies = true
        notifiesIncomingCalls = true
        notifiesServerActivity = true
        suppressesCurrentConversation = true
        groupsByConversation = true
        clearsWhenRead = true
        reload()
    }

    func reload() {
        isEnabled = bool(Key.enabled, default: true)
        previewStyle = defaults.string(forKey: Key.preview)
            .flatMap(NotificationPreviewStyle.init(rawValue:)) ?? .full
        playsSound = bool(Key.sound, default: true)
        if let rawValue = defaults.string(forKey: Key.dockBadge),
           let style = NotificationDockBadgeStyle(rawValue: rawValue)
        {
            dockBadgeStyle = style
        } else if let legacyValue = defaults.object(forKey: Key.dockBadge) as? Bool {
            dockBadgeStyle = legacyValue ? .mentions : .off
        } else {
            dockBadgeStyle = .mentions
        }
        notifiesDirectMessages = bool(Key.directMessages, default: true)
        notifiesGroupDirectMessages = bool(Key.groupDirectMessages, default: true)
        notifiesMentions = bool(Key.mentions, default: true)
        notifiesReplies = bool(Key.replies, default: true)
        notifiesIncomingCalls = bool(Key.incomingCalls, default: true)
        notifiesServerActivity = bool(Key.serverActivity, default: true)
        suppressesCurrentConversation = bool(Key.suppressCurrentConversation, default: true)
        groupsByConversation = bool(Key.groupByConversation, default: true)
        clearsWhenRead = bool(Key.clearWhenRead, default: true)
    }

    func allows(
        _ event: NotificationEventContext,
        isCurrentConversation: Bool
    ) -> Bool {
        guard isEnabled || playsSound, isEnabled(event.type) else { return false }
        if event.type == .incomingCall {
            return true
        }
        if suppressesCurrentConversation, isCurrentConversation { return false }
        return true
    }

    private func isEnabled(_ event: NotificationEventType) -> Bool {
        switch event {
        case .directMessage: notifiesDirectMessages
        case .groupDirectMessage: notifiesGroupDirectMessages
        case .mention: notifiesMentions
        case .reply: notifiesReplies
        case .incomingCall: notifiesIncomingCalls
        case .serverActivity: notifiesServerActivity
        }
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
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
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func deliver(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        preferences: NotificationPreferences
    ) async
    func deliverMessage(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        presentation: NotificationContentPresentation,
        preferences: NotificationPreferences
    ) async
    func deliverIncomingCall(
        call: PrivateCall,
        channel: Channel?,
        caller: User?,
        accountID: String,
        preferences: NotificationPreferences
    ) async
    func cancel(accountID: String, channelID: ChannelID) async
    func cancelIncomingCall(accountID: String, channelID: ChannelID) async
    func setDockBadge(_ count: Int, enabled: Bool)
}

extension NativeNotificationService {
    func deliverMessage(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        presentation: NotificationContentPresentation,
        preferences: NotificationPreferences
    ) async {
        await deliver(
            message: message,
            channel: channel,
            guild: guild,
            accountID: accountID,
            preferences: preferences
        )
    }

    func deliverIncomingCall(
        call _: PrivateCall,
        channel _: Channel?,
        caller _: User?,
        accountID _: String,
        preferences _: NotificationPreferences
    ) async {}

    func cancelIncomingCall(accountID _: String, channelID _: ChannelID) async {}
}

@MainActor
final class NoopNativeNotificationService: NativeNotificationService {
    func requestAuthorization() async throws -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func deliver(
        message _: Message,
        channel _: Channel?,
        guild _: Guild?,
        accountID _: String,
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

    // Offline demos use real system permissions without publishing fixture alerts.
    private let deliversNotifications: Bool
    private var pendingRequests: [String: UUID] = [:]

    init(deliversNotifications: Bool = true) {
        self.deliversNotifications = deliversNotifications
        super.init()
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func deliver(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        preferences: NotificationPreferences
    ) async {
        await deliverMessage(
            message: message,
            channel: channel,
            guild: guild,
            accountID: accountID,
            presentation: NotificationContentPresentation.make(
                message: message, channel: channel, guild: guild, style: preferences.previewStyle
            ),
            preferences: preferences
        )
    }

    func deliverMessage(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        presentation: NotificationContentPresentation,
        preferences: NotificationPreferences
    ) async {
        guard deliversNotifications, preferences.isEnabled else { return }
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
        let imageData = await NotificationMedia.previewImage(
            at: attachment?.proxyURL ?? attachment?.url, maximumDimension: 1_280
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
        guard pendingRequests[identifier] == token, !Task.isCancelled,
              preferences.isEnabled, preferences.previewStyle == style
        else { return }
        await add(content, identifier: identifier, kind: "Message", preferences: preferences)
    }

    func deliverIncomingCall(
        call: PrivateCall,
        channel: Channel?,
        caller: User?,
        accountID: String,
        preferences: NotificationPreferences
    ) async {
        guard deliversNotifications, preferences.isEnabled else { return }
        let identifier = NativeNotificationIdentity.call(accountID: accountID, channelID: call.channelID)
        let token = UUID()
        let style = preferences.previewStyle
        pendingRequests[identifier] = token
        defer { if pendingRequests[identifier] == token { pendingRequests[identifier] = nil } }
        let content = UNMutableNotificationContent()
        let presentation = NotificationContentPresentation.makeIncomingCall(
            callerName: caller?.displayName,
            conversationName: nil,
            style: preferences.previewStyle
        )
        content.title = presentation.title
        content.subtitle = presentation.subtitle
        content.body = presentation.body
        // Standard active notifications remain governed by the user's Focus configuration.
        content.interruptionLevel = NotificationFocusPolicy.interruptionLevel
        if preferences.groupsByConversation {
            content.threadIdentifier = NativeNotificationIdentity.conversation(
                accountID: accountID,
                channelID: call.channelID
            )
        }
        content.userInfo = NotificationDeepLink(
            accountID: accountID,
            guildID: nil,
            channelID: call.channelID,
            messageID: call.messageID
        ).userInfo
        guard pendingRequests[identifier] == token, !Task.isCancelled,
              preferences.isEnabled, preferences.previewStyle == style
        else { return }
        await add(content, identifier: identifier, kind: "Call", preferences: preferences)
    }

    func cancel(accountID: String, channelID: ChannelID) async {
        guard deliversNotifications else { return }
        let prefix = "message:\(accountID):\(channelID):"
        pendingRequests = pendingRequests.filter { !$0.key.hasPrefix(prefix) }
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
    }

    func cancelIncomingCall(accountID: String, channelID: ChannelID) async {
        guard deliversNotifications else { return }
        let identifier = NativeNotificationIdentity.call(
            accountID: accountID,
            channelID: channelID
        )
        pendingRequests[identifier] = nil
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func setDockBadge(_ count: Int, enabled: Bool) {
        guard deliversNotifications else { return }
        NSApplication.shared.dockTile.badgeLabel =
            enabled && count > 0 ? String(count) : nil
    }

    private func add(
        _ content: UNNotificationContent,
        identifier: String,
        kind: StaticString,
        preferences: NotificationPreferences
    ) async {
        guard deliversNotifications, preferences.isEnabled,
              let content = content.mutableCopy() as? UNMutableNotificationContent
        else { return }
        content.sound = preferences.playsSound ? Self.notificationSound : nil
        do {
            try await center.add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        } catch {
            let notificationError = error as NSError
            Self.logger.error(
                "\(kind) notification delivery failed; domain=\(notificationError.domain, privacy: .public), code=\(notificationError.code)"
            )
        }
    }

}
