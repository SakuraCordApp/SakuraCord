import Foundation
import Network
@testable import SimulatorKit
import Testing

struct NetTests {
    private static func echoHandler(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/v9/hello"):
            .json(200, ["connection": .int(request.connectionID), "q": .array((request.query["q"] ?? []).map(JSON.string))])
        case ("POST", "/echo"), ("PUT", "/echo"):
            .bytes(200, request.body, contentType: request.header("content-type") ?? "application/octet-stream")
        default:
            .json(404, ["message": "404: Not Found", "code": 0])
        }
    }

    private static func startServer(
        profile: NetworkConditioner.Profile = .instant,
        webSocketHandler: HTTPServer.WebSocketHandler? = nil
    ) async throws -> HTTPServer {
        let server = HTTPServer(
            name: "test", port: 0, conditioner: NetworkConditioner(seed: 1, profile: profile),
            handler: echoHandler, webSocketHandler: webSocketHandler
        )
        try await server.start()
        return server
    }

    private static func session() -> URLSession { URLSession(configuration: .ephemeral) }

    private static func url(_ server: HTTPServer, _ path: String, scheme: String = "http") -> URL {
        URL(string: "\(scheme)://127.0.0.1:\(server.port)\(path)")!
    }

    @Test func keepAliveGetsShareAConnection() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        #expect(server.port != 0)
        let session = Self.session()
        let (first, response) = try await session.data(from: Self.url(server, "/api/v9/hello?q=a%20b&q=c+d"))
        let (second, _) = try await session.data(from: Self.url(server, "/api/v9/hello"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let firstJSON = try JSON.parse(first)
        #expect(firstJSON["q"] == ["a b", "c d"])
        #expect(firstJSON["connection"] == (try JSON.parse(second))["connection"])
    }

    @Test func postJSONEchoesAndUnknownPathIs404() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        var request = URLRequest(url: Self.url(server, "/echo"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSON = ["content": "hi", "nonce": "1"]
        request.httpBody = body.data()
        let (data, _) = try await Self.session().data(for: request)
        #expect(try JSON.parse(data) == body)

        let (missing, response) = try await Self.session().data(from: Self.url(server, "/api/v9/nope"))
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(try JSON.parse(missing)["code"] == 0)
    }

    @Test func largeUpload() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        var payload = Data(repeating: 0xAB, count: 24 * 1024 * 1024)
        payload[payload.count - 1] = 0x01
        var request = URLRequest(url: Self.url(server, "/echo"))
        request.httpMethod = "PUT"
        let (data, _) = try await Self.session().upload(for: request, from: payload)
        #expect(data == payload)
    }

    @Test func chunkedBodyWithExpectContinueOverRawSocket() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
        connection.start(queue: .global())
        let channel = TCPChannel(connection)
        defer { channel.reset() }
        var reader = ByteReader(channel: channel)

        let head = "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n"
        try await channel.send(Data(head.utf8))
        #expect(try await reader.readLine(limit: 100) == Array("HTTP/1.1 100 Continue".utf8))
        #expect(try await reader.readLine(limit: 100).isEmpty)
        try await channel.send(Data("5;ext=1\r\nhello\r\n7\r\n, world\r\n0\r\nTrailer: x\r\n\r\n".utf8))

        let responseHead = try #require(try await reader.read(until: Array("\r\n\r\n".utf8), limit: 4096))
        let lines = (String(bytes: responseHead, encoding: .utf8) ?? "").components(separatedBy: "\r\n")
        #expect(lines[0] == "HTTP/1.1 200 OK")
        #expect(lines.contains("Connection: keep-alive"))
        #expect(lines.contains("Content-Length: 12"))
        #expect(try await reader.read(12) == Data("hello, world".utf8))
    }

    @Test func busyPortThrows() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        let rival = HTTPServer(name: "rival", port: server.port, conditioner: NetworkConditioner(seed: 1), handler: Self.echoHandler)
        await #expect(throws: (any Error).self) { try await rival.start() }
    }

    @Test func webSocketRoundTripAndServerClose() async throws {
        let server = try await Self.startServer { _, socket in
            for await message in socket.messages {
                switch message {
                case .text("bye"): await socket.close(code: 4004, reason: "Authentication failed.")
                case let .text(text): await socket.send(text: text)
                case let .binary(data): await socket.send(binary: data)
                case .close: break
                }
            }
        }
        defer { server.stop() }
        let task = Self.session().webSocketTask(with: Self.url(server, "/?v=9&encoding=json", scheme: "ws"))
        task.resume()

        try await task.send(.string("hello"))
        guard case .string("hello") = try await task.receive() else { Issue.record("text echo"); return }
        let big = Data((0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0) })
        try await task.send(.data(big))
        guard case let .data(echoed) = try await task.receive() else { Issue.record("binary echo"); return }
        #expect(echoed == big)
        try await withCheckedThrowingContinuation { continuation in
            task.sendPing { error in error.map { continuation.resume(throwing: $0) } ?? continuation.resume() }
        }

        try await task.send(.string("bye"))
        await #expect(throws: (any Error).self) { try await task.receive() }
        #expect(task.closeCode.rawValue == 4004)
        #expect(task.closeReason == Data("Authentication failed.".utf8))
    }

    @Test func webSocketKeepsOrderUnderJitter() async throws {
        let server = try await Self.startServer(profile: .mobile) { _, socket in
            for index in 0 ..< 20 { await socket.send(text: String(index)) }
            for await _ in socket.messages {}
        }
        defer { server.stop() }
        let task = Self.session().webSocketTask(with: Self.url(server, "/", scheme: "ws"))
        task.resume()
        for index in 0 ..< 20 {
            guard case let .string(text) = try await task.receive() else { Issue.record("expected text"); return }
            #expect(text == String(index))
        }
        task.cancel(with: .normalClosure, reason: nil)
    }

    @Test func latencyDelaysResponses() async throws {
        let server = try await Self.startServer(profile: .init(latencyMilliseconds: 50, jitterMilliseconds: 0))
        defer { server.stop() }
        let started = ContinuousClock.now
        _ = try await Self.session().data(from: Self.url(server, "/api/v9/hello"))
        #expect(ContinuousClock.now - started >= .milliseconds(50))
    }

    @Test func instantProfileAddsNoDelay() {
        // Asserted on the conditioner, not the wall clock, which a busy test runner stretches.
        #expect(NetworkConditioner(seed: 1).requestDelay("rest GET /", uploadBytes: 1 << 20) == .zero)
    }

    @Test func sameSeedGivesSameDelays() {
        func delays(seed: UInt64, path: String) -> [Duration] {
            let conditioner = NetworkConditioner(seed: seed, profile: .mobile)
            return (0 ..< 10).map { _ in conditioner.requestDelay("rest GET \(path)", uploadBytes: 1000) }
        }
        #expect(delays(seed: 42, path: "/a") == delays(seed: 42, path: "/a"))
        #expect(delays(seed: 42, path: "/a") != delays(seed: 42, path: "/b"))
        #expect(delays(seed: 42, path: "/a") != delays(seed: 43, path: "/a"))
        #expect(delays(seed: 42, path: "/a").allSatisfy { $0 >= .zero })
    }

    @Test func profilesByName() {
        #expect(NetworkConditioner.Profile.named("Mobile") == .mobile)
        #expect(NetworkConditioner.Profile.named("satellite") == nil)
    }
}
