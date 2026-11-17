import Foundation

/// One authenticated REST call, with the template's path parameters in order.
public struct RouteContext: Sendable {
    public var request: HTTPRequest
    public var userID: Snowflake
    public var parameters: [String]
    public var world: World

    public func id(_ index: Int) throws -> Snowflake {
        guard index < parameters.count, let id = Snowflake(parameters[index]) else {
            throw WorldError.notFound
        }
        return id
    }

    public var json: JSON {
        get throws {
            guard !request.body.isEmpty else { return .object(JSONObject()) }
            do { return try JSON.parse(request.body) } catch { throw WorldError.invalidBody("body is not JSON") }
        }
    }

    public func query(_ name: String) -> String? { request.query[name]?.first }
}

public typealias RouteHandler = @Sendable (RouteContext) async throws -> RouteResult

public enum RouteResult: Sendable {
    case json(JSON, status: Int = 200)
    case empty
}

/// Routes Discord REST requests. Unmatched routes fail loudly: 404 plus a log line.
public final class RESTRouter: Sendable {
    let world: World
    let catalog: ShapeCatalog
    let log: SimulatorLog
    let faults: FaultInjector
    /// Captcha challenges the control API arms.
    public let captcha = CaptchaGate()
    private let routes: [String: RouteHandler]
    /// Routes the client may call without a token.
    private let unauthenticated: Set<String>

    public init(world: World, catalog: ShapeCatalog, log: SimulatorLog, faults: FaultInjector,
                routes: [String: RouteHandler], unauthenticated: Set<String>) {
        self.world = world
        self.catalog = catalog
        self.log = log
        self.faults = faults
        self.routes = routes
        self.unauthenticated = unauthenticated
    }

    public var routeTemplates: [String] { routes.keys.sorted() }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let response = request.path.hasPrefix("/assets/") ? clientAsset(request) : await route(request)
        log.info("rest", "\(request.method) \(request.target) -> \(response.status)")
        return response
    }

    /// The client's own bundled images on discord.com. Only the default avatars are
    /// served, drawn by us; any other asset fails loudly.
    private func clientAsset(_ request: HTTPRequest) -> HTTPResponse {
        let file = String(request.path.dropFirst("/assets/".count))
        guard request.method == "GET", let index = MediaGenerator.defaultAvatarAssets.firstIndex(of: file) else {
            log.error("rest", "UNKNOWN ASSET \(request.method) \(request.path)")
            return .bytes(404, Data("Not Found".utf8), contentType: "text/plain")
        }
        return .bytes(200, MediaGenerator.defaultAvatarPNG(index: index, size: 256), contentType: "image/png")
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let template = RouteTemplate.template(method: request.method, path: Self.normalizedPath(request.path))
        let parameters = Self.parameters(path: request.path)
        guard let handler = routes[template] else {
            log.error("rest", "UNKNOWN ROUTE \(request.method) \(request.path) (template \(template))")
            return .discordError(404, "404: Not Found")
        }
        if let fault = faults.restFault(for: template) { return fault }
        if let challenge = captcha.check(template: template, request: request) { return challenge }
        let userID: Snowflake
        if unauthenticated.contains(template) {
            userID = Snowflake(0)
        } else {
            guard let token = request.header("Authorization"), let resolved = await world.userID(forToken: token) else {
                return .discordError(401, "401: Unauthorized")
            }
            userID = resolved
        }
        if let limited = faults.rateLimit(template: template, userID: userID, parameters: parameters) { return limited }
        if let denied = await channelAccess(template: template, userID: userID, parameters: parameters) { return denied }
        let context = RouteContext(request: request, userID: userID, parameters: parameters, world: world)
        do {
            switch try await handler(context) {
            case let .json(body, status):
                return .json(status, conform(body, route: template, status: status))
            case .empty:
                return .empty(204)
            }
        } catch let error as WorldError {
            return .discordError(error.status, error.message, code: error.code)
        } catch {
            log.error("rest", "\(template) failed: \(error)")
            return .discordError(500, "500: Internal Server Error")
        }
    }

    /// Every channel route needs a channel the user can see; reading messages
    /// also needs Read Message History, as on Discord.
    private func channelAccess(template: String, userID: Snowflake, parameters: [String]) async -> HTTPResponse? {
        let pathTemplate = template.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        guard pathTemplate.hasPrefix("/api/v9/channels/{id}"), let id = parameters.first.flatMap(Snowflake.init) else { return nil }
        let error: WorldError?
        if let channel = await world.channels[id] {
            let readsMessages = template.hasPrefix("GET ") && pathTemplate.contains("/messages")
            if !(await world.canView(userID, channel)) {
                error = .missingAccess
            } else if readsMessages, !channel.type.isPrivate,
                      !(await world.permissions(of: userID, in: channel)).contains(.readMessageHistory) {
                error = .missingPermissions
            } else {
                error = nil
            }
        } else {
            error = .unknown("Channel", code: 10003)
        }
        guard let error else { return nil }
        return .discordError(error.status, error.message, code: error.code)
    }

    func conform(_ body: JSON, route: String, status: Int) -> JSON {
        guard let shape = catalog.response(route, status: status), !shape.kinds.isEmpty else {
            log.warning("rest", "\(route) \(status) has no captured response shape")
            return body
        }
        let (result, dropped) = shape.conform(body)
        if !dropped.isEmpty { log.debug("rest", "\(route): dropped uncaptured fields \(dropped.prefix(8).joined(separator: ", "))") }
        return result
    }

    /// The app uses API v9; accept v10 the same way Discord does.
    static func normalizedPath(_ path: String) -> String {
        path.hasPrefix("/api/v10/") ? "/api/v9/" + path.dropFirst("/api/v10/".count) : path
    }

    static func parameters(path: String) -> [String] {
        let segments = path.split(separator: "/").map(String.init)
        var values: [String] = []
        for (index, segment) in segments.enumerated() {
            let previous = index > 0 ? segments[index - 1] : ""
            if Snowflake.looksLike(segment) || previous == "reactions" && segment != "@me" && segment != "%40me"
                || previous == "answers" && segment != "@me" || previous == "invites" {
                values.append(segment.removingPercentEncoding ?? segment)
            }
        }
        return values
    }
}
