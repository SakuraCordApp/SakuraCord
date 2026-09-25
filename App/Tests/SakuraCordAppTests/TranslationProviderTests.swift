@testable import SakuraCord
import Foundation
import Testing

private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Test(arguments: [
    ("free-key:fx", "https://api-free.deepl.com/v2/translate"),
    ("pro-key", "https://api.deepl.com/v2/translate"),
])
func `DeepL requests follow the documented contract`(apiKey: String, endpoint: String) throws {
    let request = try HTTPTextTranslator.urlRequest(for: TranslationRequest(
        provider: .deepL, text: "hallo", targetLanguage: .englishUK, serverURL: "", apiKey: apiKey
    ))

    #expect(request.url?.absoluteString == endpoint)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key \(apiKey)")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    let body = try jsonBody(request)
    #expect(body["text"] as? [String] == ["hallo"])
    #expect(body["target_lang"] as? String == "EN-GB")
    #expect(body.count == 2)
}

@Test func `DeepL requires an API key`() {
    #expect(throws: TranslationError.missingAPIKey(.deepL)) {
        try HTTPTextTranslator.urlRequest(for: TranslationRequest(
            provider: .deepL, text: "hallo", targetLanguage: .german, serverURL: "", apiKey: "  "
        ))
    }
}

@Test(arguments: [
    ("", "http://127.0.0.1:5000/translate"),
    ("https://translate.example.com", "https://translate.example.com/translate"),
    ("translate.example.com/", "https://translate.example.com/translate"),
    ("https://example.com/libre/translate?x=1", "https://example.com/libre/translate"),
    ("http://localhost:5000", "http://localhost:5000/translate"),
    ("http://nas.local:5000", "http://nas.local:5000/translate"),
    ("http://192.168.1.20:5000", "http://192.168.1.20:5000/translate"),
])
func `LibreTranslate server addresses resolve to the translate endpoint`(server: String, endpoint: String) throws {
    #expect(try TranslationServerAddress.libreTranslateEndpoint(server).absoluteString == endpoint)
    #expect(TranslationServerAddress.acceptsStoredServer(server))
}

@Test func `LibreTranslate rejects public plain HTTP and credentials in the address`() {
    #expect(throws: TranslationError.insecureServerURL) {
        try TranslationServerAddress.libreTranslateEndpoint("http://translate.example.com")
    }
    #expect(throws: TranslationError.invalidServerURL) {
        try TranslationServerAddress.libreTranslateEndpoint("https://user:secret@translate.example.com")
    }
    #expect(throws: TranslationError.invalidServerURL) {
        try TranslationServerAddress.libreTranslateEndpoint("ftp://translate.example.com")
    }
    #expect(!TranslationServerAddress.acceptsStoredServer("http://8.8.8.8"))
}

@Test(arguments: [nil, "secret"])
func `LibreTranslate requests send the API key only when set`(apiKey: String?) throws {
    let request = try HTTPTextTranslator.urlRequest(for: TranslationRequest(
        provider: .libreTranslate, text: "hallo", targetLanguage: .portuguesePortugal,
        serverURL: "https://translate.example.com", apiKey: apiKey
    ))

    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try jsonBody(request)
    #expect(body["q"] as? String == "hallo")
    #expect(body["source"] as? String == "auto")
    #expect(body["target"] as? String == "pt")
    #expect(body["format"] as? String == "text")
    #expect(body["api_key"] as? String == apiKey)
}

@Test func `provider responses and errors are parsed`() throws {
    let deepL = try HTTPTextTranslator.parse(
        data: Data(#"{"translations":[{"detected_source_language":"NL","text":"hello"}]}"#.utf8),
        statusCode: 200, provider: .deepL
    )
    #expect(deepL == TranslationResult(text: "hello", detectedSourceLanguage: "NL"))

    let libre = try HTTPTextTranslator.parse(
        data: Data(#"{"translatedText":"hola","detectedLanguage":{"confidence":90,"language":"en"}}"#.utf8),
        statusCode: 200, provider: .libreTranslate
    )
    #expect(libre == TranslationResult(text: "hola", detectedSourceLanguage: "en"))

    #expect(throws: TranslationError.httpStatus(.deepL, 456, nil)) {
        try HTTPTextTranslator.parse(data: Data(), statusCode: 456, provider: .deepL)
    }
    #expect(throws: TranslationError.httpStatus(.libreTranslate, 400, "zz is not supported")) {
        try HTTPTextTranslator.parse(
            data: Data(#"{"error":"zz is not supported"}"#.utf8), statusCode: 400, provider: .libreTranslate
        )
    }
    #expect(throws: TranslationError.emptyResponse(.libreTranslate)) {
        try HTTPTextTranslator.parse(data: Data(#"{"translatedText":" "}"#.utf8), statusCode: 200, provider: .libreTranslate)
    }
    #expect(throws: TranslationError.invalidResponse(.deepL)) {
        try HTTPTextTranslator.parse(data: Data("not json".utf8), statusCode: 200, provider: .deepL)
    }
}

@Test(arguments: [
    "hey <@123> kijk naar <:sakura:456> en <a:dance:789>",
    "zie https://example.com/a?b=c en <https://discord.com/channels/1/2/3>",
    "code `let x = 1` en\n```swift\nprint(\"hoi\")\n```",
    "@everyone om <t:1700000000:R> via </translate:42> in <#77> voor <@&88>",
    "[sakura](https://cdn.discordapp.com/emojis/456.webp?size=48) staat klaar",
])
func `protected Discord syntax survives translation verbatim`(text: String) throws {
    let protector = TranslationTokenProtector(text)
    #expect(!protector.tokens.isEmpty)
    for token in protector.tokens {
        #expect(!protector.providerText.contains(token))
    }
    // Simulate a provider that rewrites every word but keeps the placeholders.
    let translated = protector.providerText.uppercased()
    let restored = try protector.restore(translated, mode: .strict)
    for token in protector.tokens {
        #expect(restored.contains(token))
    }
}

@Test func `strict restoration rejects dropped or duplicated placeholders`() throws {
    let protector = TranslationTokenProtector("hoi <@1> en <@2>")
    let placeholders = protector.providerText.components(separatedBy: " ").filter { $0.hasPrefix("\u{E000}") }
    #expect(placeholders.count == 2)

    let dropped = protector.providerText.replacingOccurrences(of: placeholders[1], with: "")
    #expect(throws: TranslationError.protectedTokenChanged) {
        try protector.restore(dropped, mode: .strict)
    }
    #expect(try protector.restore(dropped, mode: .lenient) == "hoi <@1> en ")

    let duplicated = protector.providerText + " " + placeholders[0]
    #expect(throws: TranslationError.protectedTokenChanged) {
        try protector.restore(duplicated, mode: .strict)
    }

    let spacedFullWidth = "hi \u{E000} \u{FF10} \u{E001} and \u{E000}1\u{E001}"
    #expect(try protector.restore(spacedFullWidth, mode: .strict) == "hi <@1> and <@2>")
}

@Test func `drafts without words are not translatable`() {
    #expect(!TranslationTokenProtector("<@1> <:a:2> https://example.com").hasTranslatableText)
    #expect(TranslationTokenProtector("hoi <@1>").hasTranslatableText)
}

@Test(arguments: [
    ("nl-NL", TranslationLanguage.dutch),
    ("en-GB", .englishUK),
    ("en", .englishUS),
    ("pt-PT", .portuguesePortugal),
    ("pt", .portugueseBrazil),
    ("zh-Hant-TW", .chineseTraditional),
    ("zh-Hans-CN", .chineseSimplified),
    ("nb-NO", .norwegianBokmal),
])
func `system languages map to provider languages`(identifier: String, expected: TranslationLanguage) {
    #expect(TranslationLanguage.matching(identifier) == expected)
    #expect(TranslationLanguage.resolved("", preferredLanguages: [identifier]) == expected)
}

@Test func `stored languages resolve and fall back to English`() {
    #expect(TranslationLanguage.resolved("de", preferredLanguages: ["nl-NL"]) == .german)
    #expect(TranslationLanguage.resolved("", preferredLanguages: ["tlh"]) == .englishUS)
    #expect(TranslationLanguage.chineseSimplified.deepLCode == "ZH-HANS")
    #expect(TranslationLanguage.chineseSimplified.libreTranslateCode == "zh-Hans")
    #expect(TranslationLanguage.englishUS.libreTranslateCode == "en")
}
