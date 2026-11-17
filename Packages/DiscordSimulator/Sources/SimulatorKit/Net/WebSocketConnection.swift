import CryptoKit
import Foundation
import Synchronization

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
    case close(code: UInt16?, reason: String)
}

/// The server side of an upgraded RFC 6455 connection. Outgoing messages go
/// through one writer task, so the conditioner can delay them without
/// reordering and senders never wait on the network.
public final class WebSocketConnection: Sendable {
    private struct Outgoing {
        var frame: Data
        var start: ContinuousClock.Instant
    }

    private enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    private static let messageLimit = 64 * 1024 * 1024

    public let request: HTTPRequest
    /// Client messages. A client close is delivered as `.close` and ends the stream.
    public let messages: AsyncStream<WebSocketMessage>
    private let server: String
    private let channel: TCPChannel
    private let shaper: ConnectionShaper
    private let incoming: AsyncStream<WebSocketMessage>.Continuation
    private let outgoing: AsyncStream<Outgoing>.Continuation
    private let writer: Task<Void, Never>
    /// Whether frames may still be queued. Also serializes queueing so
    /// scheduled start times rise in queue order.
    private let open = Mutex(true)

    init(request: HTTPRequest, server: String, reader: ByteReader, shaper: ConnectionShaper) {
        self.request = request
        self.server = server
        channel = reader.channel
        self.shaper = shaper
        (messages, incoming) = AsyncStream.makeStream()
        let (queue, outgoing) = AsyncStream<Outgoing>.makeStream()
        self.outgoing = outgoing
        writer = Task { [channel] in
            for await item in queue {
                if item.start > .now { try? await Task.sleep(until: item.start) }
                do { try await shaper.write(item.frame, to: channel) } catch { break }
            }
            channel.close()
        }
        Task { await readLoop(reader) }
    }

    public var isOpen: Bool { open.withLock { $0 } }

    /// Queues a message without suspending, so a caller that numbers or compresses
    /// frames (a Gateway's sequence and zstd stream) queues them in that same order.
    public func send(binary: Data) { enqueue(.binary, binary) }

    public func send(text: String) { enqueue(.text, Data(text.utf8)) }

    /// Sends a close frame after anything already queued, then closes TCP.
    public func close(code: UInt16, reason: String) async {
        enqueue(.close, Self.closePayload(code: code) + Data(reason.utf8), last: true)
        await writer.value
    }

    /// Abrupt TCP close with no close frame, for fault injection.
    public func drop() {
        open.withLock { $0 = false }
        outgoing.finish()
        channel.reset()
        incoming.finish()
    }

    /// Called when the handler returns: the connection does not outlive it.
    func finish() async {
        if isOpen { await close(code: 1000, reason: "") } else { await writer.value }
    }

    static func acceptValue(for request: HTTPRequest) -> String? {
        let connectionTokens = request.header("connection")?.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        guard request.method == "GET",
              request.header("upgrade")?.lowercased() == "websocket",
              connectionTokens.contains("upgrade"),
              request.header("sec-websocket-version") == "13",
              let key = request.header("sec-websocket-key"), !key.isEmpty
        else { return nil }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    private func enqueue(_ opcode: Opcode, _ payload: Data, last: Bool = false) {
        open.withLock { isOpen in
            guard isOpen else { return }
            let frame = Self.frame(opcode, payload)
            outgoing.yield(Outgoing(frame: frame, start: shaper.messageStart(bytes: frame.count)))
            if last {
                isOpen = false
                outgoing.finish()
            }
        }
    }

    private func readLoop(_ reader: ByteReader) async {
        var reader = reader
        var partial: (opcode: Opcode, payload: Data)?
        do {
            while true {
                let frame = try await Self.readFrame(&reader)
                let (opcode, payload) = (frame.opcode, frame.payload)
                switch opcode {
                case .text, .binary, .continuation:
                    var message: (opcode: Opcode, payload: Data)
                    if opcode == .continuation {
                        guard let partial else { throw NetError.protocolViolation("continuation without a start") }
                        message = (partial.opcode, partial.payload + payload)
                    } else {
                        guard partial == nil else { throw NetError.protocolViolation("interleaved message") }
                        message = (opcode, payload)
                    }
                    guard message.payload.count <= Self.messageLimit else { throw NetError.protocolViolation("message too large") }
                    guard frame.fin else {
                        partial = message
                        continue
                    }
                    partial = nil
                    incoming.yield(message.opcode == .text
                        ? .text(String(bytes: message.payload, encoding: .utf8) ?? "") : .binary(message.payload))
                case .ping:
                    enqueue(.pong, payload)
                case .pong:
                    break
                case .close:
                    let code = payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil
                    let reason = payload.count > 2 ? String(bytes: payload.dropFirst(2), encoding: .utf8) ?? "" : ""
                    incoming.yield(.close(code: code, reason: reason))
                    enqueue(.close, code.map(Self.closePayload) ?? Data(), last: true)
                    incoming.finish()
                    return
                }
            }
        } catch let NetError.protocolViolation(reason) {
            netLog(server, "websocket connection \(request.connectionID): \(reason)")
            enqueue(.close, Self.closePayload(code: 1002), last: true)
        } catch {
            // TCP closed underneath us.
            open.withLock { $0 = false }
            outgoing.finish()
        }
        incoming.finish()
    }

    private struct Frame {
        let fin: Bool
        let opcode: Opcode
        let payload: Data
    }

    private static func readFrame(_ reader: inout ByteReader) async throws -> Frame {
        let head = try await reader.read(2)
        guard head[0] & 0x70 == 0 else { throw NetError.protocolViolation("reserved bits set") }
        guard let opcode = Opcode(rawValue: head[0] & 0x0F) else { throw NetError.protocolViolation("unknown opcode") }
        guard head[1] & 0x80 != 0 else { throw NetError.protocolViolation("unmasked client frame") }
        var length = UInt64(head[1] & 0x7F)
        if length >= 126 {
            length = try await reader.read(length == 126 ? 2 : 8).reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard length <= messageLimit else { throw NetError.protocolViolation("frame too large") }
        let mask = [UInt8](try await reader.read(4))
        var payload = try await reader.read(Int(length))
        payload.withUnsafeMutableBytes { bytes in
            for index in bytes.indices { bytes[index] ^= mask[index & 3] }
        }
        return Frame(fin: head[0] & 0x80 != 0, opcode: opcode, payload: payload)
    }

    private static func frame(_ opcode: Opcode, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        switch count {
        case ..<126:
            frame.append(UInt8(count))
        case ...0xFFFF:
            frame.append(126)
            frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
        default:
            frame.append(127)
            frame.append(contentsOf: stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: count >> $0) })
        }
        frame.append(payload)
        return frame
    }

    private static func closePayload(code: UInt16) -> Data { Data([UInt8(code >> 8), UInt8(code & 0xFF)]) }
}
