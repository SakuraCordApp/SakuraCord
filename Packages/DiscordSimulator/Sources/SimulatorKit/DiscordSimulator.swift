import Foundation
import Synchronization

/// The whole simulator: a seeded world behind Discord's REST, Gateway, CDN,
/// media and upload hosts, plus the control API.
public final class DiscordSimulator: Sendable {
    public struct Configuration: Sendable {
        public var basePort: UInt16 = 47100
        public var seed: UInt64 = 1
        public var scenario = "demo"
        public var parameters: [String: String] = [:]
        public var network: NetworkConditioner.Profile = .standard
        public var freezeClock = false
        /// The world's "now"; nil means the most recent Sunday evening.
        public var epoch: Date?
        public var enforcesRateLimits = true
        public var verbose = false

        public init() {}
    }

    /// Offsets from the base port, one per stood-in host.
    public enum Port: UInt16, CaseIterable, Sendable {
        case api = 0, gateway = 1, cdn = 2, media = 3, upload = 4, voice = 5, voiceMedia = 6, activity = 7, control = 9
    }

    public let configuration: Configuration
    public let world: World
    public let catalog: ShapeCatalog
    public let log: SimulatorLog
    public let hub: GatewayHub
    public let router: RESTRouter
    public let faults: FaultInjector
    public let scripts: ScriptRunner
    public let voice: VoiceGateway
    let conditioners: [Port: NetworkConditioner]
    private let servers = Mutex<[HTTPServer]>([])

    public static func make(configuration: Configuration, catalog: ShapeCatalog? = nil) async throws -> DiscordSimulator {
        guard let scenario = ScenarioRegistry.scenario(named: configuration.scenario) else {
            let names = ScenarioRegistry.all.map { $0.name }.joined(separator: ", ")
            throw WorldError.invalidBody("unknown scenario \(configuration.scenario); available: \(names)")
        }
        let resolvedCatalog = try catalog ?? ShapeCatalog.bundled()
        let log = SimulatorLog(verbose: configuration.verbose)
        let world = World(seed: configuration.seed, epoch: configuration.epoch ?? ScenarioEpoch.recentSundayEvening(),
                          freezeClock: configuration.freezeClock)
        try await scenario.build(into: world, parameters: configuration.parameters)
        let faults = FaultInjector(enforcesRateLimits: configuration.enforcesRateLimits)
        let hub = GatewayHub(world: world, catalog: resolvedCatalog, log: log, seed: configuration.seed)
        await world.attach(hub)
        var routes: [String: RouteHandler] = [:]
        MessageRoutes.register(into: &routes)
        AccountRoutes.register(into: &routes)
        ThreadRoutes.register(into: &routes)
        InteractionRoutes.register(into: &routes)
        VoiceRoutes.register(into: &routes)
        ActivityRoutes.register(into: &routes)
        ServerRoutes.register(into: &routes)
        ScheduledEventRoutes.register(into: &routes)
        OAuth2Routes.register(into: &routes)
        SignInRoutes.register(into: &routes, remoteAuth: hub.remoteAuth)
        ScheduledMessageRoutes.register(into: &routes)
        ChannelEditRoutes.register(into: &routes)
        InboxRoutes.register(into: &routes)
        AffinityRoutes.register(into: &routes)
        SearchRoutes.register(into: &routes)
        SessionRoutes.register(into: &routes)
        ProfileRoutes.register(into: &routes)
        RelationshipRoutes.register(into: &routes)
        ExpressionRoutes.register(into: &routes)
        var conditioners: [Port: NetworkConditioner] = [:]
        for port in Port.allCases where port != .control {
            conditioners[port] = NetworkConditioner(seed: configuration.seed ^ UInt64(port.rawValue), profile: configuration.network)
        }
        let router = RESTRouter(world: world, catalog: resolvedCatalog, log: log, faults: faults, routes: routes,
                                unauthenticated: SignInRoutes.unauthenticated.union(OAuth2Routes.unauthenticated).union([
                                    "POST /auth/login", "POST /api/v9/auth/login", "GET /api/v9/experiments", "GET /api/v9/apex/experiments",
                                ]))
        let scripts = ScriptRunner(world: world, log: log, scripts: BenchmarkScripts.all.merging([LiveActivity.name: LiveActivity.script]) { $1 })
        for (name, params) in scenario.liveScripts(parameters: configuration.parameters).sorted(by: { $0.key < $1.key }) {
            _ = try await scripts.start(name, params: params)
        }
        return DiscordSimulator(configuration: configuration, catalog: resolvedCatalog, log: log, world: world, faults: faults,
                                hub: hub, router: router, scripts: scripts, conditioners: conditioners)
    }

    private init(configuration: Configuration, catalog: ShapeCatalog, log: SimulatorLog, world: World, faults: FaultInjector,
                 hub: GatewayHub, router: RESTRouter, scripts: ScriptRunner, conditioners: [Port: NetworkConditioner]) {
        self.configuration = configuration
        self.catalog = catalog
        self.log = log
        self.world = world
        self.faults = faults
        self.hub = hub
        self.router = router
        self.scripts = scripts
        self.conditioners = conditioners
        voice = VoiceGateway(world: world, log: log, seed: configuration.seed, mediaPort: configuration.basePort + Port.voiceMedia.rawValue)
    }

    public func port(_ port: Port) -> UInt16 { configuration.basePort + port.rawValue }

    public func setNetworkProfile(_ profile: NetworkConditioner.Profile) {
        conditioners.values.forEach { $0.setProfile(profile) }
    }

    public func start() async throws {
        let control = ControlAPI(simulator: self)
        let cdn = CDNHandler(world: world, log: log, host: "cdn.discordapp.com")
        let media = CDNHandler(world: world, log: log, host: "media.discordapp.net")
        let upload = UploadHandler(world: world, log: log)
        let activities = ActivityHost(world: world, log: log)
        let hub = hub, router = router, voice = voice
        await world.attachVoiceMedia(voice)
        try await voice.start()
        let instant = NetworkConditioner(seed: configuration.seed, profile: .instant)
        let definitions: [ServerDefinition] = [
            ServerDefinition(.api) { await router.handle($0) },
            ServerDefinition(.gateway, webSocket: { await hub.handle($0) }, handler: { [log] request in
                log.error("gateway", "plain HTTP request to the Gateway host: \(request.method) \(request.target)")
                return .discordError(400, "Bad Request")
            }),
            ServerDefinition(.voice, webSocket: { await voice.handle($0) }, handler: { [log] request in
                log.error("voice", "plain HTTP request to the voice server: \(request.method) \(request.target)")
                return .discordError(400, "Bad Request")
            }),
            ServerDefinition(.cdn) { await cdn.handle($0) },
            ServerDefinition(.activity) { [activities] in await activities.handle($0) },
            ServerDefinition(.media) { await media.handle($0) },
            ServerDefinition(.upload) { await upload.handle($0) },
            ServerDefinition(.control) { await control.handle($0) },
        ]
        for definition in definitions {
            let port = definition.port
            let server = HTTPServer(name: "\(port)", port: self.port(port), conditioner: conditioners[port] ?? instant,
                                    handler: definition.handler, webSocketHandler: definition.webSocket)
            try await server.start()
            servers.withLock { $0.append(server) }
        }
    }

    public func stop() {
        scripts.cancelAll()
        voice.stop()
        servers.withLock { servers in
            servers.forEach { $0.stop() }
            servers.removeAll()
        }
    }
}

/// One listening endpoint: its port, HTTP handler and optional WebSocket upgrade handler.
private struct ServerDefinition {
    let port: DiscordSimulator.Port
    let webSocket: HTTPServer.WebSocketHandler?
    let handler: HTTPServer.Handler

    init(_ port: DiscordSimulator.Port, webSocket: HTTPServer.WebSocketHandler? = nil, handler: @escaping HTTPServer.Handler) {
        self.port = port
        self.webSocket = webSocket
        self.handler = handler
    }
}
