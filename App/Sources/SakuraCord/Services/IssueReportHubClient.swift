import Foundation

nonisolated enum IssueReportKind: String, CaseIterable, Codable, Hashable, Sendable {
    case bug
    case feature
}

/// The hub's shared report schema, as served to the website, so the app files
/// exactly the fields Discord, GitHub issue forms, and sakuracord.app require.
nonisolated struct IssueReportForm: Decodable, Equatable, Sendable {
    struct Definition: Decodable, Equatable, Sendable {
        let kind: IssueReportKind
        let title: String
        let submitLabel: String
        let detailsLabel: String
        let titlePlaceholder: String
        let fields: [IssueReportField]
    }

    struct Area: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let emoji: String
        let description: String
    }

    struct Meta: Decodable, Equatable, Sendable {
        let areas: [Area]
    }

    static let titleLengthRange = 4 ... 100

    let versions: [String]
    let kinds: [IssueReportKind: Definition]
    let meta: Meta

    private enum CodingKeys: String, CodingKey { case versions, kinds, meta }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versions = try container.decode([String].self, forKey: .versions)
        meta = try container.decode(Meta.self, forKey: .meta)
        // Kinds this build doesn't know are ignored rather than breaking reporting.
        let raw = try container.decode([String: LossyDefinition].self, forKey: .kinds)
        kinds = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            guard let kind = IssueReportKind(rawValue: key), let definition = value.definition else { return nil }
            return (kind, definition)
        })
    }

    /// Release names compare like the hub's `normalizeVersion`.
    func supportedVersion(matching value: String?) -> String? {
        guard let value else { return nil }
        let normalized = Self.normalizedVersion(value)
        return versions.first { Self.normalizedVersion($0) == normalized }
    }

    private struct LossyDefinition: Decodable {
        let definition: Definition?

        init(from decoder: any Decoder) throws {
            definition = try? Definition(from: decoder)
        }
    }

    static func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(/^[vV](?=\d)/, with: "")
            .replacing(/(?i)-beta-/, with: " beta ")
            .replacing(/\s+/, with: " ")
            .lowercased()
    }
}

nonisolated struct IssueReportField: Decodable, Equatable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case short, paragraph, choice, version, area, files
        /// A field type newer than this build; the hub validates it on submit.
        case unsupported

        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unsupported
        }
    }

    struct Option: Decodable, Equatable, Identifiable, Sendable {
        let value: String
        let label: String
        var id: String { value }
    }

    let id: String
    let label: String
    let description: String?
    let placeholder: String?
    let kind: Kind
    let required: Bool
    let maxLength: Int?
    let options: [Option]?
    let page: Int
    let diagnostic: Bool?
}

nonisolated struct IssueReportFiled: Decodable, Equatable, Sendable {
    let number: Int
    let threadId: String?
    let issueUrl: URL
    let threadUrl: URL?
    let trackerUrl: URL
}

nonisolated struct IssueReportSimilar: Decodable, Equatable, Identifiable, Sendable {
    let number: Int
    let title: String
    let statusLabel: String
    let open: Bool
    let votes: Int
    let trackerUrl: URL
    let resolution: String?
    var id: Int { number }
}

nonisolated struct IssueReportAuthorization: Decodable, Sendable {
    let applicationId: String
    let redirectUri: URL
    let scopes: [String]
    let state: String
}

/// A verified identity for the report APIs. It lives only in memory.
nonisolated struct IssueReportHubSession: Decodable, Sendable {
    struct User: Decodable, Sendable {
        let id: String
        let name: String
    }

    let token: String
    let expiresAt: Double
    let user: User

    var isFresh: Bool {
        Date(timeIntervalSince1970: expiresAt / 1000).timeIntervalSinceNow > 3600
    }
}

nonisolated struct IssueReportUpload: Sendable {
    let name: String
    let contentType: String
    let data: Data
}

nonisolated enum IssueReportHubError: LocalizedError, Equatable {
    case server(String)
    case unavailable

    static let attachmentLimit = Self.server(
        "Attach at most 5 files, each no larger than 10 MB and 25 MB in total."
    )

    var errorDescription: String? {
        switch self {
        case let .server(message): message
        case .unavailable: "SakuraCord's report service is unavailable. Try again shortly."
        }
    }
}

/// Talks to sakuracord.app, which validates identities and forwards reports to
/// the hub. Discord credentials never pass through this client.
nonisolated struct IssueReportHubClient: Sendable {
    static let maximumFileCount = 5
    static let maximumFileBytes = 10 * 1024 * 1024
    static let maximumTotalBytes = 25 * 1024 * 1024

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "https://sakuracord.app")!) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: IssueReportRedirectPolicy(), delegateQueue: nil)
    }

    func form() async throws -> IssueReportForm {
        try await send(request("api/report/form"))
    }

    func similar(to text: String) async throws -> [IssueReportSimilar] {
        struct Results: Decodable { let results: [IssueReportSimilar] }
        let results: Results = try await send(request(
            "api/report/similar", method: "POST", json: ["text": String(text.prefix(8000))]
        ))
        return results.results
    }

    func beginAuthorization() async throws -> IssueReportAuthorization {
        try await send(request("api/report/app/authorize"))
    }

    func completeAuthorization(code: String, state: String) async throws -> IssueReportHubSession {
        try await send(request(
            "api/report/app/authorize", method: "POST", json: ["code": code, "state": state]
        ))
    }

    func submit(
        kind: IssueReportKind,
        values: [String: String],
        files: [IssueReportUpload],
        session hubSession: IssueReportHubSession
    ) async throws -> IssueReportFiled {
        guard files.count <= Self.maximumFileCount,
              files.allSatisfy({ $0.data.count <= Self.maximumFileBytes }),
              files.reduce(0, { $0 + $1.data.count }) <= Self.maximumTotalBytes
        else { throw IssueReportHubError.attachmentLimit }
        let boundary = "SakuraCord-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("kind", kind.rawValue)
        field("values", String(bytes: try JSONEncoder().encode(values), encoding: .utf8) ?? "{}")
        for file in files.prefix(Self.maximumFileCount) {
            let name = file.name.replacing(/["\r\n\\]/, with: "_")
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\n")
            append("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        var request = request("api/report/submit", method: "POST", session: hubSession)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request)
    }

    func meToo(number: Int, note: String, session hubSession: IssueReportHubSession) async throws -> IssueReportFiled {
        struct Body: Encodable { let number: Int; let note: String? }
        var request = request("api/report/me-too", method: "POST", session: hubSession)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(number: number, note: note.isEmpty ? nil : note))
        return try await send(request)
    }

    private func request(
        _ path: String,
        method: String = "GET",
        json: [String: String]? = nil,
        session hubSession: IssueReportHubSession? = nil
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let hubSession {
            request.setValue("Bearer \(hubSession.token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(json)
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IssueReportHubError.unavailable }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let failure = try? JSONDecoder().decode(IssueReportHubFailure.self, from: data),
               !failure.error.isEmpty
            {
                throw IssueReportHubError.server(failure.error)
            }
            throw http.statusCode == 413 ? IssueReportHubError.attachmentLimit : IssueReportHubError.unavailable
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

/// Never forward report contents or authorization codes to a redirected endpoint.
private final class IssueReportRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private nonisolated struct IssueReportHubFailure: Decodable {
    let error: String
}
