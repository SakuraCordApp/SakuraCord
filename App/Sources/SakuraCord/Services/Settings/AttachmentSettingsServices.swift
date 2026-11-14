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
        if let raw = preferences.string(.attachmentCompactionPrompt),
           let saved = AttachmentHandlingPolicy(rawValue: raw) { value.compactionPolicy = saved }
        if let raw = preferences.string(.attachmentExternalUploadPrompt),
           let saved = AttachmentHandlingPolicy(rawValue: raw) { value.externalUploadPolicy = saved }
        if let raw = preferences.string(.attachmentExternalProvider),
           let saved = ExternalAttachmentHostingService(rawValue: raw) { value.externalProvider = saved }
        if let raw = preferences.string(.attachmentCompactionQuality),
           let saved = AttachmentCompactionOptions.Quality(rawValue: raw) { value.compaction.quality = saved }
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
