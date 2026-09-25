import Foundation

nonisolated protocol TextTranslating: Sendable {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

/// Sends user-chosen text to the selected third-party translation provider.
/// Requests never carry Discord credentials, cookies, or client metadata.
nonisolated struct HTTPTextTranslator: TextTranslating {
    static let timeout: TimeInterval = 20
    static let maximumResponseBytes = 1_000_000

    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    init(session: URLSession) {
        self.session = session
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let urlRequest = try Self.urlRequest(for: request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TranslationError.requestFailed(request.provider, error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse(request.provider)
        }
        return try Self.parse(data: data, statusCode: response.statusCode, provider: request.provider)
    }

    static func urlRequest(for request: TranslationRequest) throws -> URLRequest {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptyText
        }
        let apiKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey?.isEmpty == false ? apiKey : nil
        var urlRequest: URLRequest
        let body: [String: Any]
        switch request.provider {
        case .off:
            throw TranslationError.notConfigured
        case .deepL:
            guard let key else { throw TranslationError.missingAPIKey(.deepL) }
            urlRequest = URLRequest(url: TranslationServerAddress.deepLEndpoint(apiKey: key))
            urlRequest.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            body = ["text": [request.text], "target_lang": request.targetLanguage.deepLCode]
        case .libreTranslate:
            urlRequest = try URLRequest(url: TranslationServerAddress.libreTranslateEndpoint(request.serverURL))
            var fields: [String: Any] = [
                "q": request.text,
                "source": "auto",
                "target": request.targetLanguage.libreTranslateCode,
                "format": "text",
            ]
            if let key { fields["api_key"] = key }
            body = fields
        }
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpShouldHandleCookies = false
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return urlRequest
    }

    static func parse(
        data: Data,
        statusCode: Int,
        provider: TranslationProvider
    ) throws -> TranslationResult {
        guard data.count <= maximumResponseBytes else {
            throw TranslationError.invalidResponse(provider)
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200 ..< 300).contains(statusCode) else {
            let message = (object?["error"] as? String ?? object?["message"] as? String)
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
            throw TranslationError.httpStatus(provider, statusCode, message)
        }
        guard let object else { throw TranslationError.invalidResponse(provider) }
        let text: String?
        let source: String?
        switch provider {
        case .off:
            throw TranslationError.notConfigured
        case .deepL:
            let translation = (object["translations"] as? [[String: Any]])?.first
            text = translation?["text"] as? String
            source = translation?["detected_source_language"] as? String
        case .libreTranslate:
            text = object["translatedText"] as? String
            source = (object["detectedLanguage"] as? [String: Any])?["language"] as? String
        }
        guard let text else { throw TranslationError.invalidResponse(provider) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptyResponse(provider)
        }
        return TranslationResult(text: text, detectedSourceLanguage: source)
    }
}

nonisolated enum TranslationServerAddress {
    static let defaultLibreTranslate = "http://127.0.0.1:5000"

    /// DeepL Free keys end in `:fx` and use a separate API host, as in DeepL's own client libraries.
    static func deepLEndpoint(apiKey: String) -> URL {
        apiKey.hasSuffix(":fx")
            ? URL(string: "https://api-free.deepl.com/v2/translate")!
            : URL(string: "https://api.deepl.com/v2/translate")!
    }

    /// Resolves a user-entered LibreTranslate server to its `/translate` endpoint.
    /// An empty value uses the local default server.
    static func libreTranslateEndpoint(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var raw = trimmed.isEmpty ? defaultLibreTranslate : trimmed
        if !raw.contains("://") { raw = "https://" + raw }
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { throw TranslationError.invalidServerURL }
        if scheme == "http", !isLocalNetworkHost(host) {
            throw TranslationError.insecureServerURL
        }
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/translate") { path += "/translate" }
        components.path = path
        guard let url = components.url else { throw TranslationError.invalidServerURL }
        return url
    }

    static func acceptsStoredServer(_ value: String) -> Bool {
        value.isEmpty || (try? libreTranslateEndpoint(value)) != nil
    }

    /// Hosts that App Transport Security's local-networking exception covers:
    /// loopback, unqualified and `.local` names, and private address ranges.
    static func isLocalNetworkHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return !host.contains(".") }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254), (172, 16 ... 31): return true
        default: return false
        }
    }
}
