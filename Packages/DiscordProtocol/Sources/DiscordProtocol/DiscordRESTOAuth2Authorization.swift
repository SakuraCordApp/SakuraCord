import Foundation
import SakuraCordModels

/// An authorization-code grant for an application the person explicitly asked
/// to sign in to. The redirect is never followed; only its code is returned.
public struct OAuth2AuthorizationRequest: Hashable, Sendable {
    public var clientID: String
    public var scopes: [String]
    public var redirectURI: URL
    public var state: String

    public init(clientID: String, scopes: [String], redirectURI: URL, state: String) {
        self.clientID = clientID
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.state = state
    }
}

public struct OAuth2AuthorizationGrant: Hashable, Sendable {
    public var code: String
    public var applicationName: String

    public init(code: String, applicationName: String) {
        self.code = code
        self.applicationName = applicationName
    }
}

public enum OAuth2AuthorizationError: Error, Equatable, LocalizedError {
    case unavailable
    case invalidRequest
    case denied(String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Discord sign-in is unavailable in this session."
        case .invalidRequest: "Discord rejected the sign-in request."
        case let .denied(reason): "Discord did not authorize the sign-in: \(reason)"
        case .unexpectedResponse: "Discord returned an unexpected sign-in response. Try again."
        }
    }
}

extension DiscordRESTProvider {
    /// Mirrors the first-party consent flow: read the authorization details,
    /// then authorize once. The POST is a single attempt and never replayed.
    public func authorizeOAuth2(
        _ request: OAuth2AuthorizationRequest
    ) async throws -> OAuth2AuthorizationGrant {
        guard UInt64(request.clientID) != nil,
              !request.scopes.isEmpty,
              !request.state.isEmpty,
              request.redirectURI.scheme == "https",
              request.redirectURI.host() != nil
        else { throw OAuth2AuthorizationError.invalidRequest }
        let query = Self.oauth2AuthorizeQuery(
            clientID: request.clientID, redirectURI: request.redirectURI, scopes: request.scopes, state: request.state
        )
        let preview: OAuth2AuthorizationPreviewDTO = try await self.request(
            "/oauth2/authorize",
            query: query,
            mapFailure: { status, _ in
                (400 ..< 500).contains(status) && status != 401 && status != 429
                    ? OAuth2AuthorizationError.invalidRequest : nil
            }
        )
        guard preview.application.id == request.clientID else {
            throw OAuth2AuthorizationError.unexpectedResponse
        }
        let authorized: OAuth2AuthorizationLocationDTO = try await self.request(
            "/oauth2/authorize",
            method: "POST",
            query: query,
            body: [
                "authorize": .bool(true),
                // The first-party client sends this placeholder outside a channel.
                "location_context": .object([
                    "guild_id": .string("10000"),
                    "channel_id": .string("10000"),
                    "channel_type": .number(10_000),
                ]),
            ]
        )
        return try Self.grant(
            from: authorized.location,
            for: request,
            applicationName: preview.application.name
        )
    }

    static func grant(
        from location: String,
        for request: OAuth2AuthorizationRequest,
        applicationName: String
    ) throws -> OAuth2AuthorizationGrant {
        guard let components = URLComponents(string: location),
              components.scheme == request.redirectURI.scheme,
              components.host?.lowercased() == request.redirectURI.host()?.lowercased(),
              components.port == request.redirectURI.port,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path == request.redirectURI.path()
        else { throw OAuth2AuthorizationError.unexpectedResponse }
        let code = try oauth2AuthorizationCode(in: oauth2RedirectItems(components), state: request.state)
        return OAuth2AuthorizationGrant(code: code, applicationName: applicationName)
    }

    /// The `/oauth2/authorize` query both consent flows send, in the
    /// first-party client's order.
    static func oauth2AuthorizeQuery(
        clientID: String, redirectURI: URL?, scopes: [String], state: String?
    ) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        if let redirectURI { query.append(URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString)) }
        query.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        if let state { query.append(URLQueryItem(name: "state", value: state)) }
        return query
    }

    /// The query of the redirect Discord names, throwing the denial it reports.
    static func oauth2RedirectItems(_ components: URLComponents?) throws -> [URLQueryItem] {
        let items = components?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw OAuth2AuthorizationError.denied(items.first { $0.name == "error_description" }?.value ?? error)
        }
        return items
    }

    static func oauth2AuthorizationCode(in items: [URLQueryItem], state: String?) throws -> String {
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else { throw OAuth2AuthorizationError.unexpectedResponse }
        return code
    }
}

struct OAuth2AuthorizationPreviewDTO: Decodable {
    struct Application: Decodable {
        let id: String
        let name: String
    }

    let application: Application
    /// Only the Activity consent flow reads this.
    let authorized: Bool?
}

struct OAuth2AuthorizationLocationDTO: Decodable {
    let location: String
}
