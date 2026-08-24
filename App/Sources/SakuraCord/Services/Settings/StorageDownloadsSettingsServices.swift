import Foundation

nonisolated enum MediaCacheLimit: Int64, CaseIterable, Identifiable, Sendable {
    case megabytes512 = 536_870_912
    case gigabytes2 = 2_147_483_648
    case gigabytes5 = 5_368_709_120
    case gigabytes10 = 10_737_418_240

    var id: Int64 { rawValue }

    var title: String {
        rawValue.formatted(.byteCount(style: .file))
    }
}

nonisolated enum DownloadLocationMode: String, CaseIterable, Identifiable, Sendable {
    case askEveryTime
    case defaultFolder

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .askEveryTime:
            LocalizedStringResource("Ask Every Time", bundle: #bundle)
        case .defaultFolder:
            LocalizedStringResource("Default Folder", bundle: #bundle)
        }
    }
}

nonisolated enum DownloadFilenameCollisionPolicy: String, CaseIterable, Identifiable, Sendable {
    case automaticallyRename
    case ask

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .automaticallyRename:
            LocalizedStringResource("Automatically Rename", bundle: #bundle)
        case .ask:
            LocalizedStringResource("Ask", bundle: #bundle)
        }
    }

    func destination(
        for proposedURL: URL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        guard fileExists(proposedURL.path) else { return proposedURL }
        guard self == .automaticallyRename else { return nil }
        let stem = proposedURL.deletingPathExtension().lastPathComponent
        let pathExtension = proposedURL.pathExtension
        let directory = proposedURL.deletingLastPathComponent()
        for index in 2 ... 10_000 {
            var name = "\(stem) \(index)"
            if !pathExtension.isEmpty { name += ".\(pathExtension)" }
            let candidate = directory.appendingPathComponent(name)
            if !fileExists(candidate.path) { return candidate }
        }
        return nil
    }
}

nonisolated struct StorageDownloadsSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(
        mediaCacheLimit: .gigabytes2,
        downloadLocationMode: .askEveryTime,
        filenameCollisionPolicy: .automaticallyRename,
        revealsCompletedDownloads: false
    )

    var mediaCacheLimit: MediaCacheLimit
    var downloadLocationMode: DownloadLocationMode
    var filenameCollisionPolicy: DownloadFilenameCollisionPolicy
    var revealsCompletedDownloads: Bool
}

@MainActor
final class StorageDownloadsSettingsStore {
    static let shared = StorageDownloadsSettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> StorageDownloadsSettingsSnapshot {
        var value = StorageDownloadsSettingsSnapshot.defaults
        if case let .integer(rawLimit) = preferences.value(for: .mediaCacheLimit),
           let limit = MediaCacheLimit(rawValue: Int64(rawLimit))
        {
            value.mediaCacheLimit = limit
        }
        if case let .string(rawMode) = preferences.value(for: .downloadLocationMode),
           let mode = DownloadLocationMode(rawValue: rawMode)
        {
            value.downloadLocationMode = mode
        }
        if case let .string(rawCollision) = preferences.value(for: .downloadCollisionPolicy),
           let collision = DownloadFilenameCollisionPolicy(rawValue: rawCollision)
        {
            value.filenameCollisionPolicy = collision
        }
        if case let .bool(reveals) = preferences.value(for: .revealCompletedDownloads) {
            value.revealsCompletedDownloads = reveals
        }
        return value
    }

    func save(_ value: StorageDownloadsSettingsSnapshot) {
        preferences.set(.integer(Int(value.mediaCacheLimit.rawValue)), for: .mediaCacheLimit)
        preferences.set(.string(value.downloadLocationMode.rawValue), for: .downloadLocationMode)
        preferences.set(
            .string(value.filenameCollisionPolicy.rawValue),
            for: .downloadCollisionPolicy
        )
        preferences.set(.bool(value.revealsCompletedDownloads), for: .revealCompletedDownloads)
    }

    func saveDefaultFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        preferences.set(
            .string(bookmark.base64EncodedString()),
            for: .downloadFolderBookmark
        )
        preferences.set(
            .string(url.lastPathComponent),
            for: .downloadFolderName
        )
    }

    func resolvedDefaultFolder() throws -> URL? {
        guard case let .string(encoded) = preferences.value(for: .downloadFolderBookmark),
              !encoded.isEmpty,
              let data = Data(base64Encoded: encoded)
        else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            try saveDefaultFolder(url)
        }
        return url
    }

    var defaultFolderName: String? {
        guard case let .string(value) = preferences.value(for: .downloadFolderName),
              !value.isEmpty
        else { return nil }
        return value
    }

    func recordMediaCacheClear(at date: Date) {
        preferences.set(.double(date.timeIntervalSince1970), for: .mediaCacheLastCleared)
    }

    var lastMediaCacheClearDate: Date? {
        guard case let .double(value) = preferences.value(for: .mediaCacheLastCleared),
              value > 0
        else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}

nonisolated struct StorageByteSummary: Equatable, Sendable {
    let fileCount: Int
    let byteCount: Int64

    static let empty = Self(fileCount: 0, byteCount: 0)
}

nonisolated enum SakuraCordStorageInspector {
    static func directorySummary(_ directory: URL) async throws -> StorageByteSummary {
        try await Task.detached(priority: .utility) {
            try directorySummarySynchronously(directory)
        }.value
    }

    static func incompleteDownloadSummary(
        in root: URL = SharedMediaDataLoader.incompleteDownloadRootDirectory(),
        olderThan cutoff: Date = Date().addingTimeInterval(-3_600)
    ) async throws -> StorageByteSummary {
        try await Task.detached(priority: .utility) {
            try incompleteDownloadDirectories(in: root, olderThan: cutoff)
                .reduce(into: .empty) { result, directory in
                    let summary = try directorySummarySynchronously(directory)
                    result = StorageByteSummary(
                        fileCount: result.fileCount + summary.fileCount,
                        byteCount: result.byteCount + summary.byteCount
                    )
                }
        }.value
    }

    static func clearIncompleteDownloads(
        in root: URL = SharedMediaDataLoader.incompleteDownloadRootDirectory(),
        olderThan cutoff: Date = Date().addingTimeInterval(-3_600)
    ) async throws -> StorageByteSummary {
        try await Task.detached(priority: .utility) {
            let directories = try incompleteDownloadDirectories(
                in: root,
                olderThan: cutoff
            )
            var removed = StorageByteSummary.empty
            for directory in directories {
                try Task.checkCancellation()
                let summary = try directorySummarySynchronously(directory)
                try FileManager.default.removeItem(at: directory)
                removed = StorageByteSummary(
                    fileCount: removed.fileCount + summary.fileCount,
                    byteCount: removed.byteCount + summary.byteCount
                )
            }
            return removed
        }.value
    }

    private static func incompleteDownloadDirectories(
        in root: URL,
        olderThan cutoff: Date
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true
                && values.isSymbolicLink != true
                && (values.contentModificationDate ?? .distantPast) < cutoff
        }
    }

    private static func directorySummarySynchronously(
        _ directory: URL
    ) throws -> StorageByteSummary {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .empty }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return .empty }
        var result = StorageByteSummary.empty
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            result = StorageByteSummary(
                fileCount: result.fileCount + 1,
                byteCount: result.byteCount + Int64(values.fileSize ?? 0)
            )
        }
        return result
    }
}
