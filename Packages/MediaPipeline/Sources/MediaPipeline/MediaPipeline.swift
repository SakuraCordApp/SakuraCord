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
    private let beforeIndexLoad: @Sendable () -> Void
    private let removeCachedFile: @Sendable (URL) throws -> Void
    private var cachedFileIndex: [URL: CachedFile]?
    private var cachedFileIndexTask: Task<[CachedFile], any Error>?

    public init(maximumBytes: Int64 = 2 * 1024 * 1024 * 1024, directory: URL? = nil) throws {
        self.maximumBytes = maximumBytes
        let base = try directory ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.directory = base.appending(path: "SakuraCord/Media", directoryHint: .isDirectory)
        beforeIndexLoad = {}
        removeCachedFile = { try FileManager.default.removeItem(at: $0) }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    init(
        maximumBytes: Int64,
        directory: URL,
        beforeIndexLoad: @escaping @Sendable () -> Void,
        removeCachedFile: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) throws {
        self.maximumBytes = maximumBytes
        self.directory = directory.appending(
            path: "SakuraCord/Media",
            directoryHint: .isDirectory
        )
        self.beforeIndexLoad = beforeIndexLoad
        self.removeCachedFile = removeCachedFile
        try FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    public func removeAll() throws {
        cachedFileIndexTask?.cancel()
        cachedFileIndexTask = nil
        cachedFileIndex = [:]
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func data(for url: URL) async throws -> Data? {
        let fileURL = cachedFileURL(for: url)
        let accessDate = Date()
        let data = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil as Data?
            }
            do {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                try? FileManager.default.setAttributes(
                    [.modificationDate: accessDate],
                    ofItemAtPath: fileURL.path
                )
                return data
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        }.value
        if data == nil {
            cachedFileIndex?[fileURL] = nil
        } else if var cachedFile = cachedFileIndex?[fileURL] {
            cachedFile.lastAccess = accessDate
            cachedFileIndex?[fileURL] = cachedFile
        }
        return data
    }

    public func insert(_ data: Data, for url: URL) async throws {
        guard !data.isEmpty,
              data.count <= Self.maximumEntryBytes,
              Int64(data.count) <= maximumBytes
        else { return }

        try await loadCachedFileIndexIfNeeded()
        let fileURL = cachedFileURL(for: url)
        try await Task.detached(priority: .utility) {
            try data.write(to: fileURL, options: .atomic)
        }.value
        cachedFileIndex?[fileURL] = CachedFile(
            url: fileURL,
            byteCount: Int64(data.count),
            lastAccess: Date()
        )
        await enforceByteLimit()
    }

    public func currentByteCount() async throws -> Int64 {
        try await loadCachedFileIndexIfNeeded()
        return cachedFileIndex?.values.reduce(into: 0) { total, file in
            total += file.byteCount
        } ?? 0
    }

    private func cachedFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: digest, directoryHint: .notDirectory)
    }

    private func loadCachedFileIndexIfNeeded() async throws {
        guard cachedFileIndex == nil else { return }
        let task: Task<[CachedFile], any Error>
        if let cachedFileIndexTask {
            task = cachedFileIndexTask
        } else {
            let directory = directory
            let beforeIndexLoad = beforeIndexLoad
            task = Task.detached(priority: .utility) {
                beforeIndexLoad()
                return try Self.cachedFiles(in: directory)
            }
            cachedFileIndexTask = task
        }
        do {
            let files = try await task.value
            if cachedFileIndex == nil {
                cachedFileIndex = Dictionary(
                    files.map { ($0.url, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
            }
            cachedFileIndexTask = nil
        } catch {
            cachedFileIndexTask = nil
            throw error
        }
    }

    private func enforceByteLimit() async {
        guard var index = cachedFileIndex else { return }
        var byteCount = index.values.reduce(into: Int64(0)) {
            $0 += $1.byteCount
        }
        guard byteCount > maximumBytes else { return }
        let files = index.values.sorted {
            if $0.lastAccess == $1.lastAccess {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.lastAccess < $1.lastAccess
        }
        var evictedFiles: [CachedFile] = []
        for oldest in files where byteCount > maximumBytes {
            index[oldest.url] = nil
            evictedFiles.append(oldest)
            byteCount -= oldest.byteCount
        }
        cachedFileIndex = index
        let removeCachedFile = removeCachedFile
        let undeletedFiles = await Task.detached(priority: .utility) {
            evictedFiles.filter { file in
                do {
                    try removeCachedFile(file.url)
                    return false
                } catch {
                    return FileManager.default.fileExists(
                        atPath: file.url.path
                    )
                }
            }
        }.value
        for file in undeletedFiles where cachedFileIndex?[file.url] == nil {
            cachedFileIndex?[file.url] = file
        }
    }

    nonisolated private static func cachedFiles(
        in directory: URL
    ) throws -> [CachedFile] {
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

    private struct CachedFile: Sendable {
        let url: URL
        let byteCount: Int64
        var lastAccess: Date
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
