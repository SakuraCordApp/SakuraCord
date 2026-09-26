import Foundation
import NaturalLanguage
import Observation
import Translation

nonisolated struct AppleTranslationLanguages: TranslationLanguageProviding {
    nonisolated func supportedLanguages() async -> [TranslationLanguage] {
        await LanguageAvailability(preferredStrategy: .highFidelity).supportedLanguages.map {
            TranslationLanguage(id: $0.maximalIdentifier)
        }
    }

    nonisolated func status(for text: String, target: TranslationLanguage) async throws -> TranslationPairStatus {
        let sample = TranslationTokenProtector(text).slots.map(\.text).joined(separator: " ")
        let value = try await LanguageAvailability(preferredStrategy: .highFidelity)
            .status(for: sample, to: Locale.Language(identifier: target.id))
        switch value {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported:
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
               confidence >= 0.8,
               TranslationLanguages.match(language.rawValue, supported: [target]) != nil {
                return .sameLanguage
            }
            return .unsupported
        @unknown default: return .unsupported
        }
    }
}

@MainActor
@Observable
final class TranslationLanguages {
    private(set) var supported: [TranslationLanguage] = []
    @ObservationIgnored let provider: any TranslationLanguageProviding

    init(provider: any TranslationLanguageProviding = AppleTranslationLanguages()) {
        self.provider = provider
    }

    func refresh() async {
        supported = await provider.supportedLanguages().sorted {
            $0.displayName().localizedStandardCompare($1.displayName()) == .orderedAscending
        }
    }

    func resolve(_ saved: String, preferred: [String] = Locale.preferredLanguages) async throws -> TranslationLanguage {
        if supported.isEmpty { await refresh() }
        let choices = saved.isEmpty ? preferred : [saved]
        for choice in choices {
            if let result = Self.match(choice, supported: supported) { return result }
        }
        throw LocalTranslationError.unsupportedTarget
    }

    /// Maximal identifiers preserve script differences (notably Hans/Hant).
    /// Region fallback is permitted only within the same language AND script.
    nonisolated static func match(_ identifier: String, supported: [TranslationLanguage]) -> TranslationLanguage? {
        let requested = Locale.Language(identifier: identifier)
        if let exact = supported.first(where: { Locale.Language(identifier: $0.id).maximalIdentifier == requested.maximalIdentifier }) {
            return exact
        }
        return supported.first {
            let candidate = Locale.Language(identifier: $0.id)
            return candidate.languageCode == requested.languageCode && candidate.script == requested.script
        }
    }

    nonisolated static func validPreference(_ raw: String) -> Bool {
        raw.isEmpty || raw.range(of: #"^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3}$"#, options: .regularExpression) != nil
    }
}
