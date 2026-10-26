import AVFAudio
import Foundation
import OSLog

/// Which notification sound a stored choice controls.
nonisolated enum NotificationSoundKind: CaseIterable, Sendable {
    case message
    case call

    var defaultEffect: AppSoundEffect {
        switch self {
        case .message: .message
        case .call: .callRinging
        }
    }

    /// How much of a chosen file plays in the app. A message sound matches
    /// the banner limit; a ringtone loops a longer stretch.
    var playbackLimitSeconds: Double {
        switch self {
        case .message: NotificationSoundLibrary.bannerLimitSeconds
        case .call: 300
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
        } else if choice.soundID == customID, let bookmark = choice.bookmark {
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

    /// A player that can actually play `url`. Some files open but never play,
    /// such as Ogg Opus, so preparing is part of the check.
    @MainActor
    static func makePlayer(at url: URL) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(contentsOf: url), player.prepareToPlay() else { return nil }
        return player
    }

    /// Identifies one version of a sound file. Read uncached, unlike URL resource values.
    struct FileStamp: Equatable {
        var modified: Date?
        var size: Int?

        init?(_ url: URL?) {
            guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            else { return nil }
            modified = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.intValue
        }
    }
}

/// Notification Center plays `UNNotificationSound(named:)` files from the
/// app's `Library/Sounds`, so the message sound is exported there as a CAF.
/// Calls ring only in the app and have no banner copy. The sandbox links
/// that folder to `~/Library/Sounds`, which the entitlements make writable.
actor BannerSoundStore {
    static let shared = BannerSoundStore()

    private struct Export {
        var choice: NotificationSoundLibrary.Choice
        var sourceStamp: NotificationSoundLibrary.FileStamp?
        var name: String
    }

    private static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "Notifications")
    private static let directory = URL.libraryDirectory.appending(path: "Sounds", directoryHint: .isDirectory)
    private static let prefix = "SakuraCord-message"
    private var export: Export?

    /// The exported copy of `choice`, exported again when the choice or its
    /// file changed. Nil means the banner keeps the bundled sound.
    func soundName(for choice: NotificationSoundLibrary.Choice) -> String? {
        guard choice.soundID != NotificationSoundLibrary.bundledID else {
            replaceExport(with: nil)
            return nil
        }
        let resolution = NotificationSoundLibrary.resolve(choice, kind: .message)
        // An unresolved bookmark keeps Default for now and is retried next time.
        guard choice.soundID != NotificationSoundLibrary.customID || resolution.isSecurityScoped else {
            replaceExport(with: nil)
            return nil
        }
        let isScoped = resolution.isSecurityScoped && resolution.url.startAccessingSecurityScopedResource()
        defer { if isScoped { resolution.url.stopAccessingSecurityScopedResource() } }
        let stamp = NotificationSoundLibrary.FileStamp(resolution.url)
        if let export, export.choice == choice, export.sourceStamp == stamp,
           FileManager.default.fileExists(atPath: Self.directory.appending(path: export.name).path)
        {
            return export.name
        }
        // Notification Center caches a sound by name, so each export gets a new one.
        let name = "\(Self.prefix)-\(UUID().uuidString.prefix(8)).caf"
        let temporary = FileManager.default.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try NotificationSoundLibrary.convertToLinearPCM(
                from: resolution.url,
                to: temporary,
                limitSeconds: NotificationSoundLibrary.bannerLimitSeconds
            )
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: Self.directory.appending(path: name))
        } catch {
            replaceExport(with: nil)
            let nsError = error as NSError
            Self.logger.error("Message banner sound export failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code)")
            return nil
        }
        replaceExport(with: Export(choice: choice, sourceStamp: stamp, name: name))
        return name
    }

    /// Records `export` and removes every other copy, including ones left by
    /// an earlier launch.
    private func replaceExport(with newExport: Export?) {
        export = newExport
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        for name in names where name.hasPrefix(Self.prefix) && name.hasSuffix(".caf") && name != newExport?.name {
            try? FileManager.default.removeItem(at: Self.directory.appending(path: name))
        }
    }
}

nonisolated extension NotificationSoundLibrary {
    /// Notification Center ignores sounds of 30 seconds or longer, so a
    /// banner plays only the start of a longer file.
    static let bannerLimitSeconds = 29.0
    private static let conversionChunkFrames: AVAudioFrameCount = 32_768

    static func convertToLinearPCM(from source: URL, to destination: URL, limitSeconds: Double) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: conversionChunkFrames) else { return }
        let limit = min(input.length, AVAudioFramePosition(format.sampleRate * limitSeconds))
        while input.framePosition < limit {
            let remaining = AVAudioFrameCount(limit - input.framePosition)
            try input.read(into: buffer, frameCount: min(conversionChunkFrames, remaining))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}
