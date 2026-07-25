import AppKit
import Foundation
import Observation
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
}

@MainActor
@Observable
final class NotificationPreferences {
    private enum Key {
        static let enabled = "notifications.enabled"
        static let preview = "notifications.preview"
        static let sound = "notifications.sound"
        static let dockBadge = "notifications.dockBadge"
        static let quietHours = "notifications.quietHours"
        static let quietStart = "notifications.quietStart"
        static let quietEnd = "notifications.quietEnd"
    }

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    var previewStyle: NotificationPreviewStyle {
        didSet { defaults.set(previewStyle.rawValue, forKey: Key.preview) }
    }
    var playsSound: Bool { didSet { defaults.set(playsSound, forKey: Key.sound) } }
    var showsDockBadge: Bool { didSet { defaults.set(showsDockBadge, forKey: Key.dockBadge) } }
    var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: Key.quietHours) }
    }
    var quietStartHour: Int { didSet { defaults.set(quietStartHour, forKey: Key.quietStart) } }
    var quietEndHour: Int { didSet { defaults.set(quietEndHour, forKey: Key.quietEnd) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        previewStyle =
            defaults.string(forKey: Key.preview).flatMap(NotificationPreviewStyle.init(rawValue:))
            ?? .full
        playsSound = defaults.object(forKey: Key.sound) as? Bool ?? true
        showsDockBadge = defaults.object(forKey: Key.dockBadge) as? Bool ?? true
        quietHoursEnabled = defaults.bool(forKey: Key.quietHours)
        quietStartHour = defaults.object(forKey: Key.quietStart) as? Int ?? 22
        quietEndHour = defaults.object(forKey: Key.quietEnd) as? Int ?? 8
    }

    func isQuiet(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = calendar.component(.hour, from: date)
        if quietStartHour == quietEndHour { return true }
        if quietStartHour < quietEndHour {
            return hour >= quietStartHour && hour < quietEndHour
        }
        return hour >= quietStartHour || hour < quietEndHour
    }
}

nonisolated struct NotificationDeepLink: Codable, Equatable, Sendable {
    var accountID: String
    var guildID: GuildID?
    var channelID: ChannelID
    var messageID: MessageID

    var userInfo: [String: String] {
        var value = [
            "account_id": accountID,
            "channel_id": String(channelID.rawValue),
            "message_id": String(messageID.rawValue),
        ]
        if let guildID {
            value["guild_id"] = String(guildID.rawValue)
        }
        return value
    }

    init?(
        userInfo: [AnyHashable: Any]
    ) {
        guard let accountID = userInfo["account_id"] as? String,
              let channel = userInfo["channel_id"] as? String,
              let message = userInfo["message_id"] as? String,
              let channelID = ChannelID(channel),
              let messageID = MessageID(message)
        else { return nil }
        self.accountID = accountID
        self.guildID = (userInfo["guild_id"] as? String).flatMap(GuildID.init)
        self.channelID = channelID
        self.messageID = messageID
    }

    init(
        accountID: String,
        guildID: GuildID?,
        channelID: ChannelID,
        messageID: MessageID
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
    func cancel(accountID: String, channelID: ChannelID) async
    func setDockBadge(_ count: Int, enabled: Bool)
}

@MainActor
final class NoopNativeNotificationService: NativeNotificationService {
    func requestAuthorization() async throws -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func deliver(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        preferences: NotificationPreferences
    ) async {}
    func cancel(accountID: String, channelID: ChannelID) async {}
    func setDockBadge(_ count: Int, enabled: Bool) {}
}

@MainActor
final class MacNativeNotificationService: NSObject, NativeNotificationService {
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
        guard preferences.isEnabled, !preferences.isQuiet() else { return }
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
        if preferences.playsSound {
            content.sound = .default
        }
        let link = NotificationDeepLink(
            accountID: accountID,
            guildID: message.guildID ?? channel?.guildID,
            channelID: message.channelID,
            messageID: message.id
        )
        content.userInfo = link.userInfo
        let identifier = Self.identifier(
            accountID: accountID, channelID: message.channelID, messageID: message.id
        )
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
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

    func setDockBadge(_ count: Int, enabled: Bool) {
        NSApplication.shared.dockTile.badgeLabel =
            enabled && count > 0 ? String(count) : nil
    }

    private static func identifier(
        accountID: String,
        channelID: ChannelID,
        messageID: MessageID
    ) -> String {
        "message:\(accountID):\(channelID):\(messageID)"
    }
}
