import AppKit
import Foundation
import SakuraCordModels

nonisolated enum RoleColorDisplay: String, CaseIterable, Identifiable, Sendable {
    case inNames
    case nextToNames
    case hidden

    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .inNames: LocalizedStringResource("In names", bundle: #bundle)
        case .nextToNames: LocalizedStringResource("Next to names", bundle: #bundle)
        case .hidden: LocalizedStringResource("Don't show role colours", bundle: #bundle)
        }
    }
}

nonisolated struct AccessibilitySettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(
        disablesProfileEffects: false,
        disablesNameplates: false,
        disablesAvatarDecorations: false,
        disablesProfileFrames: false,
        disablesNameStyles: false,
        disablesProfileGradients: false,
        disablesServerTags: false,
        announcesTimestamps: true,
        announcesEditedStatus: true,
        announcesReactionCounts: true,
        announcesAttachmentTypes: true,
        announcesNewMessages: false
    )

    var underlinesLinks = false
    var roleColorDisplay: RoleColorDisplay = .inNames

    var disablesProfileEffects: Bool
    var disablesNameplates: Bool
    var disablesAvatarDecorations: Bool
    var disablesProfileFrames: Bool
    var disablesNameStyles: Bool
    var disablesProfileGradients: Bool
    var disablesServerTags: Bool
    var announcesTimestamps: Bool
    var announcesEditedStatus: Bool
    var announcesReactionCounts: Bool
    var announcesAttachmentTypes: Bool
    var announcesNewMessages: Bool

    var disablesMessageSendingAnimations = false
    var disablesAllAnimations = false
    var disablesSidebarAnimations = false
    var disablesSideChatAnimations = false
    var disablesOverlayAnimations = false
    var disablesOwnCosmetics = false

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
        value.underlinesLinks = bool(.underlineLinks) ?? false
        value.roleColorDisplay = enumValue(.roleColorDisplay) ?? .inNames
        value.disablesProfileEffects = bool(.accessibilityDisableProfileEffects)
            ?? value.disablesProfileEffects
        value.disablesNameplates = bool(.accessibilityDisableNameplates)
            ?? value.disablesNameplates
        value.disablesAvatarDecorations = bool(.accessibilityDisableAvatarDecorations) ?? value.disablesAvatarDecorations
        value.disablesProfileFrames = bool(.accessibilityDisableProfileFrames)
            ?? value.disablesProfileFrames
        value.disablesNameStyles = bool(.accessibilityDisableNameStyles)
            ?? value.disablesNameStyles
        value.disablesProfileGradients = bool(.accessibilityDisableProfileGradients)
            ?? value.disablesProfileGradients
        value.disablesServerTags = bool(.accessibilityDisableServerTags)
            ?? value.disablesServerTags
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
        value.disablesMessageSendingAnimations = bool(.accessibilityDisableSendAnimations) ?? false
        value.disablesAllAnimations = bool(.accessibilityDisableAllAnimations) ?? false
        value.disablesSidebarAnimations = bool(.accessibilityDisableSidebarAnimations) ?? false
        value.disablesSideChatAnimations = bool(.accessibilityDisableSideChatAnimations) ?? false
        value.disablesOverlayAnimations = bool(.accessibilityDisableOverlayAnimations) ?? false
        value.disablesOwnCosmetics = bool(.accessibilityDisableOwnCosmetics) ?? false
        return value
    }

    func save(_ value: AccessibilitySettingsSnapshot) {
        preferences.set(.bool(value.disablesMessageSendingAnimations), for: .accessibilityDisableSendAnimations)
        preferences.set(.bool(value.disablesAllAnimations), for: .accessibilityDisableAllAnimations)
        preferences.set(.bool(value.disablesSidebarAnimations), for: .accessibilityDisableSidebarAnimations)
        preferences.set(.bool(value.disablesSideChatAnimations), for: .accessibilityDisableSideChatAnimations)
        preferences.set(.bool(value.disablesOverlayAnimations), for: .accessibilityDisableOverlayAnimations)
        preferences.set(.bool(value.disablesOwnCosmetics), for: .accessibilityDisableOwnCosmetics)
        preferences.set(.bool(value.underlinesLinks), for: .underlineLinks)
        preferences.set(.string(value.roleColorDisplay.rawValue), for: .roleColorDisplay)
        preferences.set(.bool(value.disablesProfileEffects), for: .accessibilityDisableProfileEffects)
        preferences.set(.bool(value.disablesNameplates), for: .accessibilityDisableNameplates)
        preferences.set(.bool(value.disablesAvatarDecorations), for: .accessibilityDisableAvatarDecorations)
        preferences.set(.bool(value.disablesProfileFrames), for: .accessibilityDisableProfileFrames)
        preferences.set(.bool(value.disablesNameStyles), for: .accessibilityDisableNameStyles)
        preferences.set(.bool(value.disablesProfileGradients), for: .accessibilityDisableProfileGradients)
        preferences.set(.bool(value.disablesServerTags), for: .accessibilityDisableServerTags)
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
    var animatesMessageSending: Bool {
        !accessibilitySettings.disablesMessageSendingAnimations
            && !accessibilitySettings.disablesAllAnimations
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Whether `categories` move rather than snap: macOS Reduce Motion, the
    /// master switch, and each category's own switch all turn them off.
    func animates(_ categories: [AppMotionCategory]) -> Bool {
        AppMotionPolicy.animates(categories, settings: accessibilitySettings)
    }

    func animates(_ category: AppMotionCategory) -> Bool {
        animates([category])
    }

    var cosmeticPolicy: ProfileCosmeticPolicy {
        ProfileCosmeticPolicy(settings: accessibilitySettings, currentUserID: currentUser?.id)
    }

    func applyAccessibilitySettings(
        _ value: AccessibilitySettingsSnapshot,
        persists: Bool = true
    ) {
        let previous = accessibilitySettings
        accessibilitySettings = value
        AppMotionPolicy.settings = value
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
