import Foundation

/// A user's authorization of an application.
public struct OAuth2Grant: Sendable {
    public var id: Snowflake
    public var scopes: [String]
    public var accessToken: String
}

// OAuth2 consent: the preview, approving or denying it, and the token events.
extension World {
    private func oauthApplication(_ clientID: String?) throws -> User {
        guard let id = clientID.flatMap(Snowflake.init), let bot = users[id], bot.bot else {
            throw WorldError.invalidBody("client_id: Unknown application")
        }
        return bot
    }

    /// The redirect named in the request, which must be registered, or the application's first.
    private func oauthRedirect(_ appID: Snowflake, request: HTTPRequest) throws -> String {
        let registered = servers.oauthRedirects[appID] ?? []
        guard let redirect = request.query["redirect_uri"]?.first ?? registered.first, registered.contains(redirect) else {
            throw WorldError.invalidBody("redirect_uri: Invalid \"redirect_uri\" in request.")
        }
        return redirect
    }

    private func scopes(_ request: HTTPRequest) -> [String] {
        (request.query["scope"]?.first ?? "identify").split(separator: " ").map(String.init)
    }

    /// `GET /oauth2/authorize`: what the consent screen shows. Adding a bot lists the servers the user
    /// can add it to (Manage Server) instead of a redirect.
    func oauthPreview(_ request: HTTPRequest, viewer: Snowflake) throws -> JSON {
        let app = try oauthApplication(request.query["client_id"]?.first)
        var object = JSONObject([
            ("application", renderOAuthApplication(app)), ("user", renderUser(viewer)),
            ("authorized", .bool(servers.oauthGrants[viewer]?[app.id] != nil)),
            ("integration_type", .int(Int(request.query["integration_type"]?.first ?? "0") ?? 0)),
        ])
        if scopes(request).contains("bot") {
            object["bot"] = renderUser(app.id).merging(["approximate_guild_count": .int(guilds.values.count { $0.members[app.id] != nil })])
            object["guilds"] = .array(guilds(of: viewer).filter { $0.permissions(of: viewer, at: clock.now).contains(.manageGuild) }.map { guild in
                .object(JSONObject([("id", guild.id.json), ("name", .string(guild.name)), ("icon", .optional(guild.icon)), ("mfa_level", 0),
                                    ("permissions", .string(guild.permissions(of: viewer, at: clock.now).wireString))]))
            })
        } else {
            object["redirect_uri"] = .string(try oauthRedirect(app.id, request: request))
        }
        return .object(object)
    }

    /// `POST /oauth2/authorize`: approving replaces any earlier grant; either way Discord answers with where to redirect.
    func oauthAuthorize(_ request: HTTPRequest, body: JSON, viewer: Snowflake) async throws -> JSON {
        let app = try oauthApplication(request.query["client_id"]?.first)
        let scopes = scopes(request)
        if scopes.contains("bot"), body["authorize"]?.boolValue == true {
            guard let guildID = body["guild_id"]?.stringValue.flatMap(Snowflake.init) else { throw WorldError.invalidBody("guild_id: required") }
            try await installBot(app, in: guildID, by: viewer, scopes: scopes)
            return .object(JSONObject([("location", "https://discord.com/oauth2/authorized")]))
        }
        let redirect = try oauthRedirect(app.id, request: request)
        let issuer = "iss=https%3A%2F%2Fdiscord.com"
        guard body["authorize"]?.boolValue == true else {
            let denied = "error=access_denied&error_description=The+resource+owner+or+authorization+server+denied+the+request&\(issuer)"
            return .object(JSONObject([("location", .string("\(redirect)?\(denied)"))]))
        }
        if let previous = servers.oauthGrants[viewer]?[app.id] {
            await emit("OAUTH2_TOKEN_REVOKE", .object(JSONObject([("access_token", .string(previous.accessToken))])), to: .users([viewer]))
            await emit("OAUTH2_TOKEN_DELETE", .object(JSONObject([("application_id", app.id.json), ("id", previous.id.json)])), to: .users([viewer]))
        }
        let grant = OAuth2Grant(id: nextID(), scopes: scopes, accessToken: random.urlSafeString(30))
        servers.oauthGrants[viewer, default: [:]][app.id] = grant
        await emit("OAUTH2_TOKEN_CREATE", .object(JSONObject([
            ("application", renderOAuthApplication(app)), ("id", grant.id.json), ("scopes", .array(scopes.map(JSON.string))),
        ])), to: .users([viewer]))
        await emit("USER_APPLICATION_UPDATE", .object(JSONObject([("application_id", app.id.json)])), to: .users([viewer]))
        var location = "\(redirect)?\(issuer)&code=\(random.urlSafeString(30))"
        if let state = request.query["state"]?.first?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { location += "&state=\(state)" }
        return .object(JSONObject([("location", .string(location))]))
    }

    /// `GET /oauth2/@me`: who an access token belongs to, for which application and scopes.
    func oauthIdentity(accessToken: String) throws -> JSON {
        for (userID, grants) in servers.oauthGrants {
            guard let (appID, grant) = grants.first(where: { $0.value.accessToken == accessToken }), let app = users[appID] else { continue }
            return .object(JSONObject([
                ("application", renderOAuthApplication(app)),
                ("expires", World.timestamp(grant.id.date.addingTimeInterval(604_800))),
                ("scopes", .array(grant.scopes.map(JSON.string))),
                ("user", renderUser(userID)),
            ]))
        }
        throw WorldError.unauthorized
    }

    func renderOAuthApplication(_ bot: User) -> JSON {
        let install = JSON.object(JSONObject([("scopes", ["applications.commands"]), ("permissions", "0")]))
        return .object(JSONObject([
            ("id", bot.id.json), ("name", .string(bot.globalName ?? bot.username)), ("icon", .optional(bot.avatar)),
            ("description", .string(bot.bio)), ("summary", ""), ("type", .null), ("is_monetized", false), ("is_verified", false),
            ("is_discoverable", false), ("flags", 0), ("flags_new", "0"), ("hook", true), ("storefront_available", false),
            ("bot", renderUser(bot.id)), ("bot_public", true), ("bot_require_code_grant", false), ("install_params", install),
            ("integration_types_config", .object(JSONObject([
                ("0", .object(JSONObject([("oauth2_install_params", install)]))),
                ("1", .object(JSONObject([("oauth2_install_params", install)]))),
            ]))),
            ("verify_key", .string(String(format: "%064llx", bot.id.rawValue))),
            ("embedded_surfaces", []), ("max_participants", .null), ("tags", []),
        ]))
    }
}
