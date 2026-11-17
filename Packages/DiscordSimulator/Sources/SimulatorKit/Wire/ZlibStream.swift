import Foundation
import zlib

/// `compress=zlib-stream`: one deflate stream per connection, each message
/// ending in a sync flush (`00 00 ff ff`), which is how clients find message ends.
public final class ZlibStreamCompressor {
    // zlib keeps a pointer back to the stream, so it must not move.
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)

    public init() {
        stream.initialize(to: z_stream())
        let status = deflateInit_(stream, Z_DEFAULT_COMPRESSION, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK, "deflateInit failed: \(status)")
    }

    deinit {
        deflateEnd(stream)
        stream.deallocate()
    }

    public func compress(_ message: Data) -> Data {
        zlibPump(stream, message) { stream in
            let status = deflate(stream, Z_SYNC_FLUSH)
            // Z_BUF_ERROR only means there was nothing left to flush.
            precondition(status == Z_OK || status == Z_BUF_ERROR, "deflate failed: \(status)")
        }
    }
}

/// The client side of `zlib-stream`, for tests and tooling.
public final class ZlibStreamDecompressor {
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)

    public init() {
        stream.initialize(to: z_stream())
        let status = inflateInit_(stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK, "inflateInit failed: \(status)")
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
    }

    public func decompress(_ chunk: Data) throws -> Data {
        var failure: Int32?
        let output = zlibPump(stream, chunk) { stream in
            let status = inflate(stream, Z_SYNC_FLUSH)
            if status != Z_OK, status != Z_BUF_ERROR, status != Z_STREAM_END { failure = status }
        }
        if let failure { throw WireError("zlib inflate failed: \(failure)") }
        return output
    }
}

/// Feeds `input` through `step` until the input is consumed and the output buffer is no longer full.
private func zlibPump(_ stream: UnsafeMutablePointer<z_stream>, _ input: Data, step: (UnsafeMutablePointer<z_stream>) -> Void) -> Data {
    var output = Data()
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    input.withUnsafeBytes { source in
        stream.pointee.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
        stream.pointee.avail_in = uInt(source.count)
        repeat {
            chunk.withUnsafeMutableBytes { buffer in
                stream.pointee.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.pointee.avail_out = uInt(buffer.count)
                step(stream)
                output.append(buffer.bindMemory(to: UInt8.self).baseAddress!, count: buffer.count - Int(stream.pointee.avail_out))
            }
        } while stream.pointee.avail_out == 0
        stream.pointee.next_in = nil
    }
    return output
}
