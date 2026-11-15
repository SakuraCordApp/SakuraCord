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
    var compactionPolicy: AttachmentHandlingPolicy
    var externalUploadPolicy: AttachmentHandlingPolicy
    var externalProvider: ExternalAttachmentHostingService
    var compaction: AttachmentCompactionOptions

    init(reading value: (SettingsControlID) -> SettingsPreferenceValue) {
        compactionPolicy = value(.attachmentCompactionPrompt).rawValue()
        externalUploadPolicy = value(.attachmentExternalUploadPrompt).rawValue()
        externalProvider = value(.attachmentExternalProvider).rawValue()
        compaction = AttachmentCompactionOptions(quality: value(.attachmentCompactionQuality).rawValue())
    }
}

@MainActor
final class AttachmentSettingsStore {
    static let shared = AttachmentSettingsStore()
    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> AttachmentSettingsSnapshot {
        AttachmentSettingsSnapshot { preferences.value(for: $0) }
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
