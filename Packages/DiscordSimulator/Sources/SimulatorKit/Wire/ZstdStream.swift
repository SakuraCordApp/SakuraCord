import Foundation
import libzstd

/// `compress=zstd-stream`: one zstd frame spans the whole connection, and each
/// Gateway message is flushed so the client can decode it on arrival while the
/// window keeps earlier messages as history. One instance per connection.
public final class ZstdStreamCompressor {
    private let context: OpaquePointer

    public init() {
        guard let context = ZSTD_createCCtx() else { fatalError("ZSTD_createCCtx failed") }
        self.context = context
    }

    deinit { ZSTD_freeCCtx(context) }

    public func compress(_ message: Data) -> Data {
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: ZSTD_CStreamOutSize())
        message.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var pending = 1
            while pending != 0 {
                chunk.withUnsafeMutableBytes { buffer in
                    var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                    pending = ZSTD_compressStream2(context, &out, &input, ZSTD_e_flush)
                    // Only misuse or allocation failure can fail here.
                    precondition(ZSTD_isError(pending) == 0, String(cString: ZSTD_getErrorName(pending)))
                    output.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: out.pos)
                }
            }
        }
        return output
    }
}

/// The client side of `zstd-stream`, for tests and tooling.
public final class ZstdStreamDecompressor {
    private let context: OpaquePointer

    public init() {
        guard let context = ZSTD_createDCtx() else { fatalError("ZSTD_createDCtx failed") }
        self.context = context
    }

    deinit { ZSTD_freeDCtx(context) }

    public func decompress(_ chunk: Data) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        try chunk.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var filled = true
            // A full output buffer may hide more flushed data, so drain until it isn't.
            while input.pos < input.size || filled {
                try buffer.withUnsafeMutableBytes { raw in
                    var out = ZSTD_outBuffer(dst: raw.baseAddress, size: raw.count, pos: 0)
                    let result = ZSTD_decompressStream(context, &out, &input)
                    if ZSTD_isError(result) != 0 { throw WireError("zstd: \(String(cString: ZSTD_getErrorName(result)))") }
                    output.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: out.pos)
                    filled = out.pos == out.size
                }
            }
        }
        return output
    }
}
