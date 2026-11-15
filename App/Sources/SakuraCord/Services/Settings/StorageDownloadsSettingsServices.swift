import Foundation

nonisolated enum LocalStorageLimit: Int64, CaseIterable, Identifiable, Sendable {
    case megabytes512 = 536_870_912
    case gigabytes2 = 2_147_483_648
    case gigabytes5 = 5_368_709_120
    case gigabytes10 = 10_737_418_240

    var id: Int64 { rawValue }

    var title: String {
        rawValue.formatted(.byteCount(style: .memory))
    }
}

nonisolated struct StorageDownloadsSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(reading: SettingsPreferenceRegistry.foundation.defaultValue(for:))

    var localStorageLimit: LocalStorageLimit
    var revealsCompletedDownloads: Bool
}

nonisolated extension StorageDownloadsSettingsSnapshot {
    init(reading value: (SettingsControlID) -> SettingsPreferenceValue) {
        // The registration accepts any size, so an unlisted one keeps the registered default.
        localStorageLimit = LocalStorageLimit(rawValue: Int64(value(.localStorageLimit).integerValue))
            ?? Self.defaults.localStorageLimit
        revealsCompletedDownloads = value(.revealCompletedDownloads).boolValue
    }
}

@MainActor
final class StorageDownloadsSettingsStore {
    static let shared = StorageDownloadsSettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> StorageDownloadsSettingsSnapshot {
        StorageDownloadsSettingsSnapshot { preferences.value(for: $0) }
    }

    func save(_ value: StorageDownloadsSettingsSnapshot) {
        preferences.set(.integer(Int(value.localStorageLimit.rawValue)), for: .localStorageLimit)
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
        let encoded = preferences.string(.downloadFolderBookmark)
        guard !encoded.isEmpty, let data = Data(base64Encoded: encoded) else { return nil }
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
        let value = preferences.string(.downloadFolderName)
        return value.isEmpty ? nil : value
    }

    func recordMediaCacheClear(at date: Date) {
        preferences.set(.double(date.timeIntervalSince1970), for: .mediaCacheLastCleared)
    }

    var lastMediaCacheClearDate: Date? {
        let value = preferences.double(.mediaCacheLastCleared)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}

nonisolated enum LocalStorageBudget {
    static func mediaCacheMaximumBytes(
        totalMaximumBytes: Int64,
        draftBytes: Int64
    ) -> Int64 {
        max(1, totalMaximumBytes - max(0, draftBytes))
    }
}

@MainActor
final class LocalStorageBudgetCoordinator {
    static let shared = LocalStorageBudgetCoordinator()

    private var draftBytes: Int64 = 0
    private var updateTask: Task<Void, Never>?

    func apply(
        limit: LocalStorageLimit,
        measuredDraftBytes: Int64
    ) async throws {
        updateTask?.cancel()
        draftBytes = max(0, measuredDraftBytes)
        try await apply(limit: limit)
    }

    func scheduleAdjustment(draftByteDelta: Int64) {
        draftBytes = max(0, draftBytes + draftByteDelta)
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let limit = StorageDownloadsSettingsStore.shared.load().localStorageLimit
                try await self.apply(limit: limit)
            } catch {}
        }
    }

    private func apply(limit: LocalStorageLimit) async throws {
        let mediaMaximumBytes = LocalStorageBudget.mediaCacheMaximumBytes(
            totalMaximumBytes: limit.rawValue,
            draftBytes: draftBytes
        )
        try await SharedMediaDataLoader.shared.setDiskCacheLimit(mediaMaximumBytes)
    }
}
