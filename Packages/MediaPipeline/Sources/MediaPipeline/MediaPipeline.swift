import CryptoKit
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
    private static let maximumEntryBytes = 32 * 1024 * 1024
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

    public func data(for url: URL) throws -> Data? {
        let fileURL = cachedFileURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: fileURL.path
            )
            return data
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    public func insert(_ data: Data, for url: URL) throws {
        guard !data.isEmpty,
              data.count <= Self.maximumEntryBytes,
              Int64(data.count) <= maximumBytes
        else { return }

        try data.write(to: cachedFileURL(for: url), options: .atomic)
        try enforceByteLimit()
    }

    public func currentByteCount() throws -> Int64 {
        try cachedFiles().reduce(into: 0) { total, file in
            total += file.byteCount
        }
    }

    private func cachedFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: digest, directoryHint: .notDirectory)
    }

    private func enforceByteLimit() throws {
        var files = try cachedFiles().sorted {
            if $0.lastAccess == $1.lastAccess {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.lastAccess < $1.lastAccess
        }
        var byteCount = files.reduce(into: Int64(0)) {
            $0 += $1.byteCount
        }
        while byteCount > maximumBytes, !files.isEmpty {
            let oldest = files.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            byteCount -= oldest.byteCount
        }
    }

    private func cachedFiles() throws -> [CachedFile] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return CachedFile(
                url: url,
                byteCount: Int64(values.fileSize ?? 0),
                lastAccess: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private struct CachedFile {
        let url: URL
        let byteCount: Int64
        let lastAccess: Date
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
