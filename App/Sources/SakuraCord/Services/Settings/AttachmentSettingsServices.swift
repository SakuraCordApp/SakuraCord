import Foundation
import MediaPipeline

nonisolated enum AttachmentHandlingPolicy: String, CaseIterable, Identifiable, Sendable {
    case ask, always, never
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .always: LocalizedStringResource("Automatically", bundle: #bundle)
        case .ask: LocalizedStringResource("Ask", bundle: #bundle)
        case .never: LocalizedStringResource("Never", bundle: #bundle)
        }
    }

}

nonisolated struct AttachmentSettingsSnapshot: Equatable, Sendable {
    var compactionPolicy: AttachmentHandlingPolicy = .ask
    var externalUploadPolicy: AttachmentHandlingPolicy = .ask
    var externalProvider: ExternalAttachmentHostingService = .litterbox
    var compaction = AttachmentCompactionOptions()
}

@MainActor
final class AttachmentSettingsStore {
    static let shared = AttachmentSettingsStore()
    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> AttachmentSettingsSnapshot {
        var value = AttachmentSettingsSnapshot()
        value.compactionPolicy = preferences.rawValue(.attachmentCompactionPrompt) ?? value.compactionPolicy
        value.externalUploadPolicy = preferences.rawValue(.attachmentExternalUploadPrompt) ?? value.externalUploadPolicy
        value.externalProvider = preferences.rawValue(.attachmentExternalProvider) ?? value.externalProvider
        value.compaction.quality = preferences.rawValue(.attachmentCompactionQuality) ?? value.compaction.quality
        return value
    }

    func save(_ value: AttachmentSettingsSnapshot) {
        preferences.set(.string(value.compactionPolicy.rawValue), for: .attachmentCompactionPrompt)
        preferences.set(.string(value.externalUploadPolicy.rawValue), for: .attachmentExternalUploadPrompt)
        preferences.set(.string(value.externalProvider.rawValue), for: .attachmentExternalProvider)
        preferences.set(.string(value.compaction.quality.rawValue), for: .attachmentCompactionQuality)
    }
}

extension AppModel {
    func applyAttachmentSettings(_ value: AttachmentSettingsSnapshot) {
        attachmentSettings = value
        attachmentSettingsStore.save(value)
    }
}
