import Foundation

/// OAuth2 consent for applications.
enum OAuth2Routes {
    /// `@me` authenticates with an application's Bearer access token, not a user token.
    static let unauthenticated: Set<String> = ["GET /api/v9/oauth2/@me"]

    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/oauth2/@me"] = { context in
            guard let header = context.request.header("Authorization"), header.hasPrefix("Bearer ") else { throw WorldError.unauthorized }
            return .json(try await context.world.oauthIdentity(accessToken: String(header.dropFirst("Bearer ".count))))
        }
        routes["GET /api/v9/oauth2/authorize"] = { context in
            .json(try await context.world.oauthPreview(context.request, viewer: context.userID))
        }
        routes["POST /api/v9/oauth2/authorize"] = { context in
            .json(try await context.world.oauthAuthorize(context.request, body: try context.json, viewer: context.userID))
        }
        routes["DELETE /api/v9/oauth2/tokens/{id}"] = { context in
            try await context.world.deauthorize(grant: try context.id(0), by: context.userID)
            return .empty
        }
        routes["GET /api/v9/oauth2/tokens"] = { context in
            let filter = context.request.query["application_ids"].map { Set($0.compactMap(Snowflake.init)) }
            return .json(await context.world.renderOAuthTokens(context.userID, only: filter))
        }
    }
}
