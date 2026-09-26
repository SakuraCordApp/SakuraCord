import Foundation

nonisolated struct TranslationLanguage: Hashable, Identifiable, Sendable {
    let id: String

    func displayName(locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: id) ?? id
    }

    static func sourceDisplayName(_ identifier: String?) -> String? {
        identifier.map { TranslationLanguage(id: $0).displayName() }
    }
}

nonisolated struct TranslationRequest: Equatable, Sendable {
    let text: String
    /// Empty means the first supported language in the user's preferred languages.
    let targetLanguage: String
}

nonisolated struct TranslationResult: Equatable, Sendable {
    let text: String
    let detectedSourceLanguage: String?
}

nonisolated enum LocalTranslationError: Error, LocalizedError, Equatable {
    case disabled, emptyText, slashCommand, unsupportedTarget, unsupportedPair
    case ambiguousSource, sameLanguage, downloadRequired, downloadFailed, failed
    case protectedTokenChanged, hostUnavailable, queueFull

    var errorDescription: String? {
        switch self {
        case .disabled: String(localized: "Enable on-device translation in Settings > Features first.")
        case .emptyText: String(localized: "There is no text to translate.")
        case .slashCommand: String(localized: "Finish or cancel the application command before translating a draft.")
        case .unsupportedTarget: String(localized: "This target language is unavailable. Choose a supported language in Settings > Features.")
        case .unsupportedPair: String(localized: "Apple Translation does not support this language pair.")
        case .ambiguousSource: String(localized: "The source language could not be identified. Retry and choose a source language if macOS asks.")
        case .sameLanguage: String(localized: "The text is already in the target language.")
        case .downloadRequired: String(localized: "The language models are not installed. Retry in the main window to approve their download.")
        case .downloadFailed: String(localized: "The language download failed. Check your connection and retry.")
        case .failed: String(localized: "Apple Translation could not translate this text. You can retry.")
        case .protectedTokenChanged: String(localized: "Translation changed protected formatting. Your text has been kept intact.")
        case .hostUnavailable: String(localized: "Open the main SakuraCord window and retry translation.")
        case .queueFull: String(localized: "Other translations are still running. Try again when they finish.")
        }
    }
}

@MainActor
protocol TextTranslating {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

nonisolated enum TranslationPairStatus: Equatable, Sendable {
    case installed, supported, unsupported, sameLanguage
}

@MainActor
protocol TranslationLanguageProviding {
    func supportedLanguages() async -> [TranslationLanguage]
    func status(for text: String, target: TranslationLanguage) async throws -> TranslationPairStatus
}
