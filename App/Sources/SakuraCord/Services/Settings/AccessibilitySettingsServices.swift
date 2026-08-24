import AppKit
import Foundation
import SakuraCordModels

nonisolated enum AccessibilityMotionOverride: String, CaseIterable, Identifiable, Sendable {
    case followMacOS
    case alwaysReduce

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .followMacOS:
            LocalizedStringResource("Follow macOS", bundle: #bundle)
        case .alwaysReduce:
            LocalizedStringResource("Always reduce in SakuraCord", bundle: #bundle)
        }
    }
}

nonisolated enum AccessibilityAnimationCategory: Equatable, Sendable {
    case emoji
    case sticker
    case gif
    case avatar
    case decoration
    case transition
}

nonisolated struct AccessibilitySettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(
        motionOverride: .followMacOS,
        reducesAnimatedContent: false,
        reducesAnimatedEmoji: false,
        reducesAnimatedStickers: false,
        reducesGIFs: false,
        reducesAnimatedAvatars: false,
        reducesDecorations: false,
        reducesTransitions: false,
        increasesContrast: false,
        enlargesMessageActionTargets: false,
        announcesTimestamps: true,
        announcesEditedStatus: true,
        announcesReactionCounts: true,
        announcesAttachmentTypes: true,
        announcesNewMessages: false
    )

    var motionOverride: AccessibilityMotionOverride
    var reducesAnimatedContent: Bool
    var reducesAnimatedEmoji: Bool
    var reducesAnimatedStickers: Bool
    var reducesGIFs: Bool
    var reducesAnimatedAvatars: Bool
    var reducesDecorations: Bool
    var reducesTransitions: Bool
    var increasesContrast: Bool
    var enlargesMessageActionTargets: Bool
    var announcesTimestamps: Bool
    var announcesEditedStatus: Bool
    var announcesReactionCounts: Bool
    var announcesAttachmentTypes: Bool
    var announcesNewMessages: Bool

    func reducesAnimation(
        _ category: AccessibilityAnimationCategory,
        systemReduceMotion: Bool
    ) -> Bool {
        if reducesAllOptionalMotion(systemReduceMotion: systemReduceMotion) {
            return true
        }
        return switch category {
        case .emoji: reducesAnimatedEmoji
        case .sticker: reducesAnimatedStickers
        case .gif: reducesGIFs
        case .avatar: reducesAnimatedAvatars
        case .decoration: reducesDecorations
        case .transition: reducesTransitions
        }
    }

    func reducesAllOptionalMotion(systemReduceMotion: Bool) -> Bool {
        systemReduceMotion || motionOverride == .alwaysReduce
            || reducesAnimatedContent
    }
}

@MainActor
final class AccessibilitySettingsStore {
    static let shared = AccessibilitySettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> AccessibilitySettingsSnapshot {
        var value = AccessibilitySettingsSnapshot.defaults
        value.motionOverride = enumValue(.accessibilityMotionOverride)
            ?? value.motionOverride
        value.reducesAnimatedContent = bool(.accessibilityReduceAnimatedContent)
            ?? value.reducesAnimatedContent
        value.reducesAnimatedEmoji = bool(.accessibilityReduceAnimatedEmoji)
            ?? value.reducesAnimatedEmoji
        value.reducesAnimatedStickers = bool(.accessibilityReduceAnimatedStickers)
            ?? value.reducesAnimatedStickers
        value.reducesGIFs = bool(.accessibilityReduceGIFs) ?? value.reducesGIFs
        value.reducesAnimatedAvatars = bool(.accessibilityReduceAnimatedAvatars)
            ?? value.reducesAnimatedAvatars
        value.reducesDecorations = bool(.accessibilityReduceDecorations)
            ?? value.reducesDecorations
        value.reducesTransitions = bool(.accessibilityReduceTransitions)
            ?? value.reducesTransitions
        value.increasesContrast = bool(.accessibilityIncreaseContrast)
            ?? value.increasesContrast
        value.enlargesMessageActionTargets = bool(.accessibilityLargerTargets)
            ?? value.enlargesMessageActionTargets
        value.announcesTimestamps = bool(.accessibilityAnnounceTimestamp)
            ?? value.announcesTimestamps
        value.announcesEditedStatus = bool(.accessibilityAnnounceEdited)
            ?? value.announcesEditedStatus
        value.announcesReactionCounts = bool(.accessibilityAnnounceReactions)
            ?? value.announcesReactionCounts
        value.announcesAttachmentTypes = bool(.accessibilityAnnounceAttachmentTypes)
            ?? value.announcesAttachmentTypes
        value.announcesNewMessages = bool(.accessibilityAnnounceNewMessages)
            ?? value.announcesNewMessages
        return value
    }

    func save(_ value: AccessibilitySettingsSnapshot) {
        preferences.set(.string(value.motionOverride.rawValue), for: .accessibilityMotionOverride)
        preferences.set(.bool(value.reducesAnimatedContent), for: .accessibilityReduceAnimatedContent)
        preferences.set(.bool(value.reducesAnimatedEmoji), for: .accessibilityReduceAnimatedEmoji)
        preferences.set(.bool(value.reducesAnimatedStickers), for: .accessibilityReduceAnimatedStickers)
        preferences.set(.bool(value.reducesGIFs), for: .accessibilityReduceGIFs)
        preferences.set(.bool(value.reducesAnimatedAvatars), for: .accessibilityReduceAnimatedAvatars)
        preferences.set(.bool(value.reducesDecorations), for: .accessibilityReduceDecorations)
        preferences.set(.bool(value.reducesTransitions), for: .accessibilityReduceTransitions)
        preferences.set(.bool(value.increasesContrast), for: .accessibilityIncreaseContrast)
        preferences.set(.bool(value.enlargesMessageActionTargets), for: .accessibilityLargerTargets)
        preferences.set(.bool(value.announcesTimestamps), for: .accessibilityAnnounceTimestamp)
        preferences.set(.bool(value.announcesEditedStatus), for: .accessibilityAnnounceEdited)
        preferences.set(.bool(value.announcesReactionCounts), for: .accessibilityAnnounceReactions)
        preferences.set(.bool(value.announcesAttachmentTypes), for: .accessibilityAnnounceAttachmentTypes)
        preferences.set(.bool(value.announcesNewMessages), for: .accessibilityAnnounceNewMessages)
    }

    private func bool(_ id: SettingsControlID) -> Bool? {
        guard case let .bool(value) = preferences.value(for: id) else { return nil }
        return value
    }

    private func enumValue<Value: RawRepresentable>(
        _ id: SettingsControlID
    ) -> Value? where Value.RawValue == String {
        guard case let .string(value) = preferences.value(for: id) else { return nil }
        return Value(rawValue: value)
    }
}

nonisolated enum AccessibilityMessageMetadataPolicy {
    static func summary(
        for message: Message,
        timestamp: String,
        settings: AccessibilitySettingsSnapshot
    ) -> [String] {
        var values: [String] = []
        if settings.announcesTimestamps {
            values.append(timestamp)
        }
        if settings.announcesEditedStatus, message.editedTimestamp != nil {
            values.append("edited")
        }
        if settings.announcesReactionCounts {
            let count = message.reactions.reduce(0) { $0 + max(0, $1.count) }
            if count > 0 {
                values.append(count == 1 ? "1 reaction" : "\(count) reactions")
            }
        }
        if settings.announcesAttachmentTypes, !message.attachments.isEmpty {
            let counts = Dictionary(grouping: message.attachments, by: \.mediaKind)
                .mapValues(\.count)
            for kind in [
                AttachmentMediaKind.image,
                .animatedImage,
                .video,
                .audio,
                .file,
            ] {
                guard let count = counts[kind] else { continue }
                let name: String = switch kind {
                case .image: "image"
                case .animatedImage: "animated image"
                case .video: "video"
                case .audio: "audio"
                case .file: "file"
                }
                values.append(count == 1 ? "1 \(name) attachment" : "\(count) \(name) attachments")
            }
        }
        return values
    }
}

@MainActor
extension AppModel {
    func applyAccessibilitySettings(
        _ value: AccessibilitySettingsSnapshot,
        persists: Bool = true
    ) {
        let previous = accessibilitySettings
        accessibilitySettings = value
        if persists {
            AccessibilitySettingsStore.shared.save(value)
        }
        if previous != value {
            invalidateTimelinePresentation()
        }
        if previous.announcesNewMessages, !value.announcesNewMessages {
            accessibilityMessageAnnouncer.cancel()
        }
    }
}

@MainActor
final class AccessibilityMessageAnnouncer {
    typealias AnnouncementPoster = @MainActor (String) -> Void

    private let isVoiceOverEnabled: @MainActor () -> Bool
    private let post: AnnouncementPoster
    private var pendingCount = 0
    private var task: Task<Void, Never>?

    init(
        isVoiceOverEnabled: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.isVoiceOverEnabled
        },
        post: @escaping AnnouncementPoster = { announcement in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.low.rawValue,
                ]
            )
        }
    ) {
        self.isVoiceOverEnabled = isVoiceOverEnabled
        self.post = post
    }

    func enqueue() {
        guard isVoiceOverEnabled() else { return }
        pendingCount += 1
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingCount = 0
    }

    func flush() {
        task?.cancel()
        task = nil
        guard pendingCount > 0, isVoiceOverEnabled() else {
            pendingCount = 0
            return
        }
        let count = pendingCount
        pendingCount = 0
        post(count == 1 ? "New message" : "\(count) new messages")
    }
}
