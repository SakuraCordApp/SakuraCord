import Foundation

/// The Gateway wire format one connection asked for in its URL
/// (`encoding=etf|json`, `compress=zstd-stream|zlib-stream`). A class because
/// the compression stream lives as long as the connection.
public final class GatewayFrameCodec {
    public enum Encoding: String, Sendable { case json, etf }
    public enum Compression: String, Sendable { case zstdStream = "zstd-stream", zlibStream = "zlib-stream" }

    private enum Compressor {
        case none
        case zstd(ZstdStreamCompressor)
        case zlib(ZlibStreamCompressor)
    }

    public let encoding: Encoding
    public let compression: Compression?
    private let compressor: Compressor

    /// Unknown values fall back to JSON and no compression.
    public init(encoding: String, compression: String?) {
        self.encoding = Encoding(rawValue: encoding) ?? .json
        self.compression = compression.flatMap(Compression.init(rawValue:))
        compressor = switch self.compression {
        case .zstdStream: .zstd(ZstdStreamCompressor())
        case .zlibStream: .zlib(ZlibStreamCompressor())
        case nil: .none
        }
    }

    public struct EncodedFrame {
        public let data: Data
        public let isBinary: Bool
    }

    public func encode(_ frame: JSON, shape: ShapeNode?) -> EncodedFrame {
        let payload = switch encoding {
        case .etf: ETFEncoder.bytes(frame, shape: shape)
        case .json: frame.data(spaced: false)
        }
        switch compressor {
        case .none: return EncodedFrame(data: payload, isBinary: encoding == .etf)
        case let .zstd(stream): return EncodedFrame(data: stream.compress(payload), isBinary: true)
        case let .zlib(stream): return EncodedFrame(data: stream.compress(payload), isBinary: true)
        }
    }

    /// Clients send their frames uncompressed in the connection's encoding.
    public func decodeClientFrame(_ data: Data) throws -> JSON {
        switch encoding {
        case .etf: try ETFDecoder.decode(data)
        case .json: try JSON.parse(data)
        }
    }
}
