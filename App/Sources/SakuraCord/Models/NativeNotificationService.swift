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
    /// The message sound and the ringtone, each saved under its kind's keys.
    private(set) var messageSound = NotificationSoundPreference() {
        didSet { persist(messageSound, for: .message) }
    }
    private(set) var callRingtone = NotificationSoundPreference() {
        didSet { persist(callRingtone, for: .call) }
    }

    func sound(for kind: NotificationSoundKind) -> NotificationSoundPreference {
        switch kind {
        case .message: messageSound
        case .call: callRingtone
        }
    }

    private func setSound(_ sound: NotificationSoundPreference, for kind: NotificationSoundKind) {
        switch kind {
        case .message: messageSound = sound
        case .call: callRingtone = sound
        }
    }

    private func persist(_ sound: NotificationSoundPreference, for kind: NotificationSoundKind) {
        defaults.set(sound.soundID, forKey: kind.soundIDKey)
        defaults.set(sound.name, forKey: kind.soundNameKey)
        if let bookmark = sound.bookmark {
            defaults.set(bookmark, forKey: kind.soundBookmarkKey)
        } else {
            defaults.removeObject(forKey: kind.soundBookmarkKey)
        }
    }

    func soundChoice(for kind: NotificationSoundKind) -> NotificationSoundLibrary.Choice {
        sound(for: kind).choice
    }
    func soundName(for kind: NotificationSoundKind) -> String {
        sound(for: kind).name
    }
    func setSoundID(_ soundID: String, for kind: NotificationSoundKind) {
        var sound = sound(for: kind)
        sound.soundID = soundID
        setSound(sound, for: kind)
    }
    func setCustomSound(bookmark: Data, name: String, for kind: NotificationSoundKind) {
        setSound(NotificationSoundPreference(soundID: NotificationSoundLibrary.customID, name: name, bookmark: bookmark), for: kind)
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
        for kind in NotificationSoundKind.allCases {
            var sound = NotificationSoundPreference(
                soundID: defaults.string(forKey: kind.soundIDKey) ?? NotificationSoundLibrary.bundledID,
                name: defaults.string(forKey: kind.soundNameKey) ?? "",
                bookmark: defaults.data(forKey: kind.soundBookmarkKey)
            )
            // Reset and Import only touch the sound IDs, so drop a custom file
            // the ID no longer points at, and treat "custom" without one as default.
            if sound.soundID != NotificationSoundLibrary.customID {
                sound.bookmark = nil
                sound.name = ""
            } else if sound.bookmark == nil {
                sound.soundID = NotificationSoundLibrary.bundledID
                sound.name = ""
            }
            setSound(sound, for: kind)
        }
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
        await add(content, identifier: identifier, sound: sound, kind: "Message", preferences: preferences)
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

    func setDockBadge(_ count: Int, enabled: Bool) {
        guard deliversNotifications else { return }
        NSApplication.shared.dockTile.badgeLabel =
            enabled && count > 0 ? String(count) : nil
    }

    private func add(
        _ content: UNNotificationContent,
        identifier: String,
        sound: UNNotificationSound?,
        kind: StaticString,
        preferences: NotificationPreferences
    ) async {
        guard deliversNotifications, !isSuppressed, preferences.isEnabled,
              let content = content.mutableCopy() as? UNMutableNotificationContent
        else { return }
        content.sound = preferences.playsSound ? sound : nil
        do {
            try await submitRequest(
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
