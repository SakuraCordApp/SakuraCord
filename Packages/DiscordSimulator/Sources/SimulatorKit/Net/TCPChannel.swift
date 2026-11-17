import Foundation
import Network

/// Async face of one `NWConnection`.
final class TCPChannel: Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    /// `nil` at end of stream. May return empty data, which callers just retry.
    func receive(maximum: Int = 1 << 20) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Graceful: pending writes go out before the FIN.
    func close() { connection.cancel() }

    func reset() { connection.forceCancel() }
}

enum NetError: Error {
    case truncated
    case malformed(String)
    case headerTooLarge
    case bodyTooLarge
    case protocolViolation(String)
}

/// Buffered reads over a channel. Owned by one task at a time; the HTTP loop
/// hands it to the WebSocket reader after an upgrade so no bytes are lost.
struct ByteReader: Sendable {
    let channel: TCPChannel
    private var buffer: [UInt8] = []
    private var start = 0

    init(channel: TCPChannel) { self.channel = channel }

    private var buffered: Int { buffer.count - start }

    private mutating func fill() async throws -> Bool {
        guard let data = try await channel.receive() else { return false }
        if start > 0, start >= buffer.count / 2 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: data)
        return true
    }

    /// Bytes before `delimiter`, consuming it. `nil` if the stream ends cleanly
    /// with nothing buffered (a keep-alive peer going away between requests).
    mutating func read(until delimiter: [UInt8], limit: Int) async throws -> [UInt8]? {
        var searched = 0
        while true {
            if let match = firstIndex(of: delimiter, from: start + searched) {
                let bytes = Array(buffer[start ..< match])
                start = match + delimiter.count
                return bytes
            }
            guard buffered <= limit else { throw NetError.headerTooLarge }
            searched = max(0, buffered - delimiter.count + 1)
            guard try await fill() else {
                if buffered == 0 { return nil }
                throw NetError.truncated
            }
        }
    }

    mutating func readLine(limit: Int) async throws -> [UInt8] {
        guard let line = try await read(until: [0x0D, 0x0A], limit: limit) else { throw NetError.truncated }
        return line
    }

    /// Exactly `count` bytes. Large reads bypass the buffer.
    mutating func read(_ count: Int) async throws -> Data {
        var out = Data(capacity: count)
        let take = min(count, buffered)
        out.append(contentsOf: buffer[start ..< start + take])
        start += take
        while out.count < count {
            guard let data = try await channel.receive(maximum: min(count - out.count, 1 << 20)) else {
                throw NetError.truncated
            }
            out.append(data)
        }
        return out
    }

    private func firstIndex(of delimiter: [UInt8], from index: Int) -> Int? {
        guard buffer.count - index >= delimiter.count else { return nil }
        for candidate in index ... (buffer.count - delimiter.count)
        where buffer[candidate] == delimiter[0] && buffer[candidate ..< candidate + delimiter.count].elementsEqual(delimiter) {
            return candidate
        }
        return nil
    }
}

func netLog(_ server: String, _ message: String) {
    FileHandle.standardError.write(Data("[net:\(server)] \(message)\n".utf8))
}
