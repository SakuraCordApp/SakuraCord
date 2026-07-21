import Foundation
import SakuraCordModels

public struct GIFResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let previewURL: URL
    public let mediaURL: URL

    public init(id: String, title: String, previewURL: URL, mediaURL: URL) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.mediaURL = mediaURL
    }
}

public protocol GIFProvider: Sendable {
    func search(query: String) async throws -> [GIFResult]
    func trending() async throws -> [GIFResult]
}

public actor MediaCache {
    public let maximumBytes: Int64
    private let directory: URL

    public init(maximumBytes: Int64 = 2 * 1024 * 1024 * 1024, directory: URL? = nil) throws {
        self.maximumBytes = maximumBytes
        let base = try directory ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.directory = base.appending(path: "SakuraCord/Media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func removeAll() throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

public struct URLFallbackGIFProvider: GIFProvider {
    public init() {}
    public func search(query: String) async throws -> [GIFResult] {
        []
    }

    public func trending() async throws -> [GIFResult] {
        []
    }
}
