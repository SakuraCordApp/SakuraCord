import AppKit
import Foundation
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
    var isDirectConversation: Bool

    static func message(
        _ message: Message,
        channel: Channel?,
        isMention: Bool,
        currentUserID: UserID
    ) -> Self {
        let isDirectConversation = channel?.kind == .directMessage
            || channel?.kind == .groupDirectMessage
        let type: NotificationEventType
        if message.replyPreview?.author.id == currentUserID {
            type = .reply
        } else if isMention {
            type = .mention
        } else if channel?.kind == .directMessage {
            type = .directMessage
        } else if channel?.kind == .groupDirectMessage {
            type = .groupDirectMessage
        } else {
            type = .serverActivity
        }
        return Self(type: type, isDirectConversation: isDirectConversation)
    }

    static let incomingCall = Self(type: .incomingCall, isDirectConversation: true)
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
        style: NotificationPreviewStyle
    ) -> Self {
        switch style {
        case .full:
            Self(
                title: message.author.displayName,
                subtitle: channel.map { "#\($0.name)" } ?? guild?.name ?? "",
                body: message.content.isEmpty ? "Sent an attachment" : message.content
            )
        case .senderOnly:
            Self(title: message.author.displayName, subtitle: "", body: "New message")
        case .hidden:
            Self(title: "SakuraCord", subtitle: "", body: "New message")
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
        static let onlyInBackground = "notifications.onlyInBackground"
        static let suppressCurrentConversation = "notifications.suppressCurrentConversation"
        static let groupByConversation = "notifications.groupByConversation"
        static let clearWhenRead = "notifications.clearWhenRead"
        static let callsBypassMessageSuppression = "notifications.callsBypassMessageSuppression"
        static let quietHours = "notifications.quietHours"
        static let quietDays = "notifications.quietDays"
        static let weekdayQuietStart = "notifications.quietStart"
        static let weekdayQuietEnd = "notifications.quietEnd"
        static let weekendQuietStart = "notifications.weekendQuietStart"
        static let weekendQuietEnd = "notifications.weekendQuietEnd"
        static let allowDirectMessagesDuringQuietHours =
            "notifications.allowDirectMessagesDuringQuietHours"
        static let allowCallsDuringQuietHours = "notifications.allowCallsDuringQuietHours"
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
    var notifiesOnlyInBackground: Bool {
        didSet { defaults.set(notifiesOnlyInBackground, forKey: Key.onlyInBackground) }
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
    var callsBypassMessageSuppression: Bool {
        didSet {
            defaults.set(
                callsBypassMessageSuppression,
                forKey: Key.callsBypassMessageSuppression
            )
        }
    }
    var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: Key.quietHours) }
    }
    var quietDays: Set<Int> {
        didSet { defaults.set(quietDays.sorted().map(String.init), forKey: Key.quietDays) }
    }
    var weekdayQuietStartMinutes: Int {
        didSet { defaults.set(weekdayQuietStartMinutes, forKey: Key.weekdayQuietStart) }
    }
    var weekdayQuietEndMinutes: Int {
        didSet { defaults.set(weekdayQuietEndMinutes, forKey: Key.weekdayQuietEnd) }
    }
    var weekendQuietStartMinutes: Int {
        didSet { defaults.set(weekendQuietStartMinutes, forKey: Key.weekendQuietStart) }
    }
    var weekendQuietEndMinutes: Int {
        didSet { defaults.set(weekendQuietEndMinutes, forKey: Key.weekendQuietEnd) }
    }
    var allowsDirectMessagesDuringQuietHours: Bool {
        didSet {
            defaults.set(
                allowsDirectMessagesDuringQuietHours,
                forKey: Key.allowDirectMessagesDuringQuietHours
            )
        }
    }
    var allowsCallsDuringQuietHours: Bool {
        didSet { defaults.set(allowsCallsDuringQuietHours, forKey: Key.allowCallsDuringQuietHours) }
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
        notifiesOnlyInBackground = false
        suppressesCurrentConversation = true
        groupsByConversation = false
        clearsWhenRead = true
        callsBypassMessageSuppression = true
        quietHoursEnabled = false
        quietDays = Set(1 ... 7)
        weekdayQuietStartMinutes = 22 * 60
        weekdayQuietEndMinutes = 8 * 60
        weekendQuietStartMinutes = 22 * 60
        weekendQuietEndMinutes = 8 * 60
        allowsDirectMessagesDuringQuietHours = false
        allowsCallsDuringQuietHours = true
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
        notifiesOnlyInBackground = bool(Key.onlyInBackground, default: false)
        suppressesCurrentConversation = bool(Key.suppressCurrentConversation, default: true)
        groupsByConversation = bool(Key.groupByConversation, default: false)
        clearsWhenRead = bool(Key.clearWhenRead, default: true)
        callsBypassMessageSuppression = bool(Key.callsBypassMessageSuppression, default: true)
        quietHoursEnabled = bool(Key.quietHours, default: false)
        let storedDays = defaults.object(forKey: Key.quietDays) as? [String]
        quietDays = Set(
            (storedDays ?? (1 ... 7).map(String.init))
                .compactMap(Int.init)
                .filter { (1 ... 7).contains($0) }
        )
        weekdayQuietStartMinutes = minutes(Key.weekdayQuietStart, default: 22 * 60)
        weekdayQuietEndMinutes = minutes(Key.weekdayQuietEnd, default: 8 * 60)
        weekendQuietStartMinutes = minutes(Key.weekendQuietStart, default: 22 * 60)
        weekendQuietEndMinutes = minutes(Key.weekendQuietEnd, default: 8 * 60)
        allowsDirectMessagesDuringQuietHours = bool(
            Key.allowDirectMessagesDuringQuietHours,
            default: false
        )
        allowsCallsDuringQuietHours = bool(Key.allowCallsDuringQuietHours, default: true)
    }

    func isQuiet(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let currentDay = calendar.component(.weekday, from: date)
        let currentMinute = minuteOfDay(date, calendar: calendar)
        let currentSchedule = schedule(for: currentDay)
        if quietDays.contains(currentDay), currentSchedule.start == currentSchedule.end {
            return true
        }
        if quietDays.contains(currentDay), currentSchedule.start < currentSchedule.end {
            if currentMinute >= currentSchedule.start,
               currentMinute < currentSchedule.end
            {
                return true
            }
        }
        if quietDays.contains(currentDay), currentMinute >= currentSchedule.start {
            return true
        }
        guard let previousDate = calendar.date(byAdding: .day, value: -1, to: date) else {
            return false
        }
        let previousDay = calendar.component(.weekday, from: previousDate)
        let previousSchedule = schedule(for: previousDay)
        return quietDays.contains(previousDay)
            && previousSchedule.start > previousSchedule.end
            && currentMinute < previousSchedule.end
    }

    func allows(
        _ event: NotificationEventContext,
        isApplicationActive: Bool,
        isCurrentConversation: Bool,
        at date: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard isEnabled, isEnabled(event.type) else { return false }
        if isQuiet(at: date, calendar: calendar) {
            let isQuietHoursException = event.type == .incomingCall
                ? allowsCallsDuringQuietHours
                : event.isDirectConversation && allowsDirectMessagesDuringQuietHours
            guard isQuietHoursException else { return false }
        }
        if event.type == .incomingCall, callsBypassMessageSuppression {
            return true
        }
        if notifiesOnlyInBackground, isApplicationActive { return false }
        if suppressesCurrentConversation, isCurrentConversation { return false }
        return true
    }

    // Preserves the historical hourly API while migrating storage to minute precision.
    var quietStartHour: Int {
        get { weekdayQuietStartMinutes / 60 }
        set {
            weekdayQuietStartMinutes = newValue * 60
            weekendQuietStartMinutes = newValue * 60
        }
    }

    var quietEndHour: Int {
        get { weekdayQuietEndMinutes / 60 }
        set {
            weekdayQuietEndMinutes = newValue * 60
            weekendQuietEndMinutes = newValue * 60
        }
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

    private func minutes(_ key: String, default defaultValue: Int) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int else { return defaultValue }
        let migrated = (0 ... 23).contains(stored) ? stored * 60 : stored
        return min(max(migrated, 0), 23 * 60 + 59)
    }

    private func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func schedule(for weekday: Int) -> (start: Int, end: Int) {
        if weekday == 1 || weekday == 7 {
            (weekendQuietStartMinutes, weekendQuietEndMinutes)
        } else {
            (weekdayQuietStartMinutes, weekdayQuietEndMinutes)
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
        event: NotificationEventContext,
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
        event _: NotificationEventContext,
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
    private var center: UNUserNotificationCenter { .current() }

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
            event: NotificationEventContext(type: .serverActivity, isDirectConversation: false),
            preferences: preferences
        )
    }

    func deliverMessage(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        event _: NotificationEventContext,
        preferences: NotificationPreferences
    ) async {
        let content = UNMutableNotificationContent()
        let presentation = NotificationContentPresentation.make(
            message: message,
            channel: channel,
            guild: guild,
            style: preferences.previewStyle
        )
        content.title = presentation.title
        content.subtitle = presentation.subtitle
        content.body = presentation.body
        content.sound = preferences.playsSound ? .default : nil
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
        let identifier = NativeNotificationIdentity.message(
            accountID: accountID,
            channelID: message.channelID,
            messageID: message.id
        )
        guard !Task.isCancelled else { return }
        await add(content, identifier: identifier, kind: "Message")
    }

    func deliverIncomingCall(
        call: PrivateCall,
        channel: Channel?,
        caller: User?,
        accountID: String,
        preferences: NotificationPreferences
    ) async {
        let content = UNMutableNotificationContent()
        let presentation = NotificationContentPresentation.makeIncomingCall(
            callerName: caller?.displayName,
            conversationName: channel?.kind == .groupDirectMessage ? channel?.name : nil,
            style: preferences.previewStyle
        )
        content.title = presentation.title
        content.subtitle = presentation.subtitle
        content.body = presentation.body
        content.sound = preferences.playsSound ? .default : nil
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
        guard !Task.isCancelled else { return }
        await add(
            content,
            identifier: NativeNotificationIdentity.call(
                accountID: accountID,
                channelID: call.channelID
            ),
            kind: "Call"
        )
    }

    func cancel(accountID: String, channelID: ChannelID) async {
        let prefix = "message:\(accountID):\(channelID):"
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
    }

    func cancelIncomingCall(accountID: String, channelID: ChannelID) async {
        let identifier = NativeNotificationIdentity.call(
            accountID: accountID,
            channelID: channelID
        )
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func setDockBadge(_ count: Int, enabled: Bool) {
        NSApplication.shared.dockTile.badgeLabel =
            enabled && count > 0 ? String(count) : nil
    }

    private func add(
        _ content: UNNotificationContent,
        identifier: String,
        kind: StaticString
    ) async {
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
