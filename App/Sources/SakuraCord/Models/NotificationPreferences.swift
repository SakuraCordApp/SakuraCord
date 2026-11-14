import Foundation
import Observation

/// The UserDefaults keys NotificationPreferences and the settings registry share.
nonisolated enum NotificationPreferenceKeys {
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

nonisolated enum NotificationSoundKeys {
    static let messageSoundID = "notifications.messageSound"
    static let messageSoundBookmark = "notifications.messageSoundBookmark"
    static let messageSoundName = "notifications.messageSoundName"
    static let callRingtoneID = "notifications.callRingtone"
    static let callRingtoneBookmark = "notifications.callRingtoneBookmark"
    static let callRingtoneName = "notifications.callRingtoneName"
}

@MainActor
@Observable
final class NotificationPreferences {
    private typealias Key = NotificationPreferenceKeys

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
