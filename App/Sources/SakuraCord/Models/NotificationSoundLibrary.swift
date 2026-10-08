import Foundation

/// Which notification sound a stored choice controls.
nonisolated enum NotificationSoundKind: Sendable {
    case message
    case call

    var defaultEffect: AppSoundEffect {
        switch self {
        case .message: .message
        case .call: .callRinging
        }
    }
}

nonisolated enum NotificationSoundKeys {
    static let messageSoundID = "notifications.messageSound"
    static let messageSoundBookmark = "notifications.messageSoundBookmark"
    static let messageSoundName = "notifications.messageSoundName"
    static let callRingtoneID = "notifications.callRingtone"
    static let callRingtoneBookmark = "notifications.callRingtoneBookmark"
    static let callRingtoneName = "notifications.callRingtoneName"
}

nonisolated enum NotificationSoundLibrary {
    static let bundledID = "bundled"
    static let customID = "custom"
    static let chooseFileID = "choose-file"
    private static let systemPrefix = "system:"
    private static let systemSoundsDirectory = "/System/Library/Sounds"

    static func systemID(for name: String) -> String { "\(systemPrefix)\(name)" }

    /// The stored choice for one sound, read from NotificationPreferences.
    struct Choice: Equatable, Sendable {
        var soundID: String
        var bookmark: Data?
    }

    /// A resolved sound file. `isSecurityScoped` means the caller must start
    /// and later stop access to `url`; `isStaleBookmark` means the bookmark
    /// should be re-created and saved.
    struct Resolution: Sendable {
        var url: URL
        var isSecurityScoped: Bool
        var isStaleBookmark: Bool
    }

    /// Listed once: /System/Library/Sounds does not change while the app runs.
    static let systemAlertSounds: [String] =
        ((try? FileManager.default.contentsOfDirectory(atPath: systemSoundsDirectory)) ?? [])
            .filter { $0.hasSuffix(".aiff") || $0.hasSuffix(".aif") || $0.hasSuffix(".wav") }
            .sorted()

    static let systemAlertSoundNames: [String] =
        systemAlertSounds.map { ($0 as NSString).deletingPathExtension }

    static func displayName(soundID: String, customName: String) -> String {
        if soundID == bundledID {
            return "Default"
        }
        if soundID.hasPrefix(systemPrefix) {
            return String(soundID.dropFirst(systemPrefix.count))
        }
        if soundID == customID {
            return customName.isEmpty ? "Custom file" : customName
        }
        return "Default"
    }

    static func defaultURL(kind: NotificationSoundKind) -> URL {
        kind.defaultEffect.resourceURL
            ?? URL(fileURLWithPath: systemSoundsDirectory).appendingPathComponent("Glass.aiff")
    }

    /// Resolves the chosen file without touching it. A custom file's
    /// existence can only be checked after security-scoped access starts,
    /// so the caller falls back to `defaultURL` when opening it fails.
    static func resolve(_ choice: Choice, kind: NotificationSoundKind) -> Resolution {
        if choice.soundID.hasPrefix(systemPrefix) {
            let name = String(choice.soundID.dropFirst(systemPrefix.count))
            if let match = systemAlertSounds.first(where: { ($0 as NSString).deletingPathExtension == name }) {
                return Resolution(
                    url: URL(fileURLWithPath: systemSoundsDirectory).appendingPathComponent(match),
                    isSecurityScoped: false,
                    isStaleBookmark: false
                )
            }
        } else if choice.soundID == customID, let bookmark = choice.bookmark, !bookmark.isEmpty {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return Resolution(url: url, isSecurityScoped: true, isStaleBookmark: isStale)
            }
        }
        return Resolution(url: defaultURL(kind: kind), isSecurityScoped: false, isStaleBookmark: false)
    }
}
