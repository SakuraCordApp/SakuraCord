import Foundation

nonisolated enum TranslationProvider: String, CaseIterable, Identifiable, Sendable {
    case off
    case deepL = "deepl"
    case libreTranslate = "libretranslate"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .deepL: "DeepL"
        case .libreTranslate: "LibreTranslate"
        }
    }

    var requiresAPIKey: Bool { self == .deepL }
}

/// Target languages offered for translation. Raw values are stable BCP 47
/// identifiers that are safe to persist and export; each provider receives
/// its own spelling of the same language.
nonisolated enum TranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    case arabic = "ar"
    case bulgarian = "bg"
    case czech = "cs"
    case danish = "da"
    case german = "de"
    case greek = "el"
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case spanish = "es"
    case estonian = "et"
    case finnish = "fi"
    case french = "fr"
    case hebrew = "he"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case lithuanian = "lt"
    case latvian = "lv"
    case norwegianBokmal = "nb"
    case dutch = "nl"
    case polish = "pl"
    case portugueseBrazil = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case romanian = "ro"
    case russian = "ru"
    case slovak = "sk"
    case slovenian = "sl"
    case swedish = "sv"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case vietnamese = "vi"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    var id: String { rawValue }

    var deepLCode: String { rawValue.uppercased() }

    var libreTranslateCode: String {
        switch self {
        case .englishUS, .englishUK: "en"
        case .portuguesePortugal: "pt"
        default: rawValue
        }
    }

    func displayName(locale: Locale = .autoupdatingCurrent) -> String {
        locale.localizedString(forIdentifier: rawValue) ?? rawValue
    }

    static var sortedCases: [Self] {
        allCases.sorted {
            $0.displayName().localizedStandardCompare($1.displayName()) == .orderedAscending
        }
    }

    /// Resolves a stored preference. An empty value follows the system language.
    static func resolved(
        _ storedValue: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Self {
        if let language = Self(rawValue: storedValue) { return language }
        return preferredLanguages.lazy.compactMap(Self.matching).first ?? .englishUS
    }

    static func matching(_ identifier: String) -> Self? {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier.lowercased() else { return nil }
        let region = language.region?.identifier.uppercased()
        switch code {
        case "en":
            return ["GB", "IE", "AU", "NZ", "ZA", "IN"].contains(region ?? "") ? .englishUK : .englishUS
        case "pt":
            return region == "PT" ? .portuguesePortugal : .portugueseBrazil
        case "zh":
            let script = language.script?.identifier
            return script == "Hant" || ["TW", "HK", "MO"].contains(region ?? "")
                ? .chineseTraditional : .chineseSimplified
        case "no", "nn":
            return .norwegianBokmal
        case "iw":
            return .hebrew
        default:
            return Self(rawValue: code)
        }
    }

    /// A localized name for a provider-reported source language such as `EN` or `pt`.
    static func sourceDisplayName(_ code: String?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty,
              code.lowercased() != "auto"
        else { return nil }
        return locale.localizedString(forIdentifier: code.lowercased())
            ?? locale.localizedString(forLanguageCode: code.lowercased())
    }
}

nonisolated struct TranslationRequest: Equatable, Sendable {
    var provider: TranslationProvider
    var text: String
    var targetLanguage: TranslationLanguage
    var serverURL: String
    var apiKey: String?
}

nonisolated struct TranslationResult: Equatable, Sendable {
    var text: String
    var detectedSourceLanguage: String?
}

nonisolated enum TranslationError: LocalizedError, Equatable {
    case notConfigured
    case missingAPIKey(TranslationProvider)
    case invalidServerURL
    case insecureServerURL
    case emptyText
    case slashCommand
    case protectedTokenChanged
    case requestFailed(TranslationProvider, String)
    case httpStatus(TranslationProvider, Int, String?)
    case invalidResponse(TranslationProvider)
    case emptyResponse(TranslationProvider)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Choose a translation provider in Settings › Features."
        case .missingAPIKey(let provider):
            "Add your \(provider.displayName) API key in Settings › Features."
        case .invalidServerURL:
            "Enter a valid LibreTranslate server address in Settings › Features."
        case .insecureServerURL:
            "Use an https:// address for a LibreTranslate server outside your local network."
        case .emptyText:
            "There is no text to translate."
        case .slashCommand:
            "Slash commands can’t be translated."
        case .protectedTokenChanged:
            "The translation changed a mention, emoji, link, or code. Your draft was kept."
        case let .requestFailed(provider, message):
            "\(provider.displayName) couldn’t be reached: \(message)"
        case let .httpStatus(provider, status, message):
            Self.statusDescription(provider: provider, status: status, message: message)
        case .invalidResponse(let provider):
            "\(provider.displayName) returned an invalid response."
        case .emptyResponse(let provider):
            "\(provider.displayName) returned no translation."
        }
    }

    private static func statusDescription(
        provider: TranslationProvider,
        status: Int,
        message: String?
    ) -> String {
        switch (provider, status) {
        case (.deepL, 403):
            return "DeepL rejected the API key."
        case (.deepL, 456):
            return "Your DeepL translation quota is used up."
        case (_, 429):
            return "\(provider.displayName) is receiving too many requests. Try again shortly."
        default:
            if let message, !message.isEmpty {
                return "\(provider.displayName) rejected the request: \(message)"
            }
            return "\(provider.displayName) rejected the request (HTTP \(status))."
        }
    }
}
