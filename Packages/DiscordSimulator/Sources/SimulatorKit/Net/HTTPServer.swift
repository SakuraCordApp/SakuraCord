import Foundation
import Network
import Synchronization

/// HTTP/1.1 server on 127.0.0.1 with keep-alive, chunked request bodies and
/// optional WebSocket upgrades. Requests on one connection are handled in order.
public final class HTTPServer: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    public typealias WebSocketHandler = @Sendable (HTTPRequest, WebSocketConnection) async -> Void

    private struct State {
        var listener: NWListener?
        var pendingStart: CheckedContinuation<Void, Error>?
        var boundPort: UInt16?
        var accepted = 0
        var connections: [Int: TCPChannel] = [:]
        var stopped = false
    }

    private static let headerLimit = 64 * 1024
    private static let bodyLimit = 512 * 1024 * 1024

    public let name: String
    private let requestedPort: UInt16
    private let conditioner: NetworkConditioner
    private let handler: Handler
    private let webSocketHandler: WebSocketHandler?
    private let queue: DispatchQueue
    private let state = Mutex(State())

    public init(
        name: String,
        port: UInt16,
        conditioner: NetworkConditioner,
        handler: @escaping Handler,
        webSocketHandler: WebSocketHandler? = nil
    ) {
        self.name = name
        requestedPort = port
        self.conditioner = conditioner
        self.handler = handler
        self.webSocketHandler = webSocketHandler
        queue = DispatchQueue(label: "simulator.net.\(name)")
    }

    /// The bound port once started; `0` asks the OS for a free one.
    public var port: UInt16 { state.withLock { $0.boundPort } ?? requestedPort }

    /// Returns once listening. Throws if the port is taken.
    public func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] newState in self?.listenerChanged(newState) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.withLock {
                $0.listener = listener
                $0.pendingStart = continuation
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        let (listener, connections) = state.withLock { state in
            state.stopped = true
            defer {
                state.listener = nil
                state.connections = [:]
            }
            return (state.listener, Array(state.connections.values))
        }
        listener?.cancel()
        for channel in connections { channel.reset() }
    }

    private func listenerChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            let continuation = state.withLock { state in
                state.boundPort = state.listener?.port?.rawValue
                defer { state.pendingStart = nil }
                return state.pendingStart
            }
            continuation?.resume()
        case let .failed(error), let .waiting(error):
            let (continuation, listener) = state.withLock { state in
                defer {
                    state.pendingStart = nil
                    state.listener = nil
                }
                return (state.pendingStart, state.listener)
            }
            listener?.cancel()
            if let continuation {
                continuation.resume(throwing: error)
            } else {
                netLog(name, "listener failed on port \(port): \(error)")
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let channel = TCPChannel(connection)
        let ordinal: Int? = state.withLock { state in
            guard !state.stopped else { return nil }
            state.accepted += 1
            state.connections[state.accepted] = channel
            return state.accepted
        }
        guard let ordinal else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        Task {
            await serve(channel, ordinal: ordinal)
            state.withLock { _ = $0.connections.removeValue(forKey: ordinal) }
        }
    }

    private func serve(_ channel: TCPChannel, ordinal: Int) async {
        let shaper = conditioner.shaper(server: name, connection: ordinal)
        var reader = ByteReader(channel: channel)
        do {
            while let (request, keepAlive) = try await readRequest(&reader, connectionID: ordinal) {
                if let webSocketHandler, let accept = WebSocketConnection.acceptValue(for: request) {
                    try await hold(conditioner.requestDelay("\(name) WS \(request.path)", uploadBytes: 0))
                    let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
                    try await channel.send(Data(head.utf8))
                    let socket = WebSocketConnection(request: request, server: name, reader: reader, shaper: shaper)
                    await webSocketHandler(request, socket)
                    await socket.finish()
                    return
                }
                let response = await handler(request)
                try await hold(conditioner.requestDelay("\(name) \(request.method) \(request.path)", uploadBytes: request.body.count))
                try await shaper.write(response.serialized(keepAlive: keepAlive), to: channel)
                guard keepAlive else { break }
            }
        } catch let error as NetError {
            let status: Int? = switch error {
            case .malformed: 400
            case .headerTooLarge: 431
            case .bodyTooLarge: 413
            case .truncated, .protocolViolation: nil
            }
            if let status {
                netLog(name, "connection \(ordinal): \(error)")
                try? await channel.send(HTTPResponse.empty(status).serialized(keepAlive: false))
            }
        } catch {
            // The peer went away or the server stopped; nothing to answer.
        }
        channel.close()
    }

    /// No sleep at all for a zero delay, so the instant profile stays instant.
    private func hold(_ delay: Duration) async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
    }

    private func readRequest(_ reader: inout ByteReader, connectionID: Int) async throws -> (HTTPRequest, keepAlive: Bool)? {
        guard let head = try await reader.read(until: Array("\r\n\r\n".utf8), limit: Self.headerLimit) else { return nil }
        let lines = (String(bytes: head, encoding: .utf8) ?? "").components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw NetError.malformed(lines[0]) }
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw NetError.malformed(line) }
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        var request = HTTPRequest(
            method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, connectionID: connectionID
        )

        let chunked = request.header("transfer-encoding")?.lowercased().contains("chunked") == true
        let length = try request.header("content-length").map { text in
            guard let length = Int(text), length >= 0 else { throw NetError.malformed("Content-Length \(text)") }
            guard length <= Self.bodyLimit else { throw NetError.bodyTooLarge }
            return length
        } ?? 0
        if chunked || length > 0, request.header("expect")?.lowercased() == "100-continue" {
            try await reader.channel.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        request.body = chunked ? try await readChunkedBody(&reader) : try await reader.read(length)

        let connection = request.header("connection")?.lowercased() ?? ""
        let keepAlive = !connection.contains("close") && (requestLine[2] == "HTTP/1.1" || connection.contains("keep-alive"))
        return (request, keepAlive)
    }

    private func readChunkedBody(_ reader: inout ByteReader) async throws -> Data {
        var body = Data()
        while true {
            let line = String(bytes: try await reader.readLine(limit: 1024), encoding: .utf8) ?? ""
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw NetError.malformed("chunk size \(line)") }
            if size == 0 { break }
            guard body.count + size <= Self.bodyLimit else { throw NetError.bodyTooLarge }
            body.append(try await reader.read(size))
            guard try await reader.read(2) == Data("\r\n".utf8) else { throw NetError.malformed("chunk terminator") }
        }
        // Trailers are not used by any client we serve; skip them.
        while try await !reader.readLine(limit: Self.headerLimit).isEmpty {}
        return body
    }
}
