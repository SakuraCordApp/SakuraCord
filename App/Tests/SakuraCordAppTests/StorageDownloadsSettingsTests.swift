@testable import SakuraCord
import Foundation
import SakuraCordModels
import SakuraCordPersistence
import Testing

@MainActor
@Test func `Storage preferences persist reset and export without bookmark data`() throws {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = StorageDownloadsSettingsStore(preferences: preferences)
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "sakuracord-download-folder-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    var value = store.load()
    #expect(value == .defaults)
    value.mediaCacheLimit = .gigabytes5
    value.downloadLocationMode = .defaultFolder
    value.filenameCollisionPolicy = .ask
    value.revealsCompletedDownloads = true
    store.save(value)
    try store.saveDefaultFolder(folder)
    store.recordMediaCacheClear(at: Date(timeIntervalSince1970: 123))

    let relaunched = StorageDownloadsSettingsStore(preferences: preferences)
    #expect(relaunched.load() == value)
    #expect(relaunched.defaultFolderName == folder.lastPathComponent)
    #expect(
        try relaunched.resolvedDefaultFolder()?.standardizedFileURL
            == folder.standardizedFileURL
    )

    let export = preferences.export(scope: .appWide, page: .storageDownloads)
    #expect(export.values[SettingsControlID.mediaCacheLimit.rawValue] == .integer(5_368_709_120))
    #expect(export.values[SettingsControlID.downloadLocationMode.rawValue] == .string("defaultFolder"))
    #expect(export.values[SettingsControlID.downloadFolderBookmark.rawValue] == nil)
    #expect(export.values[SettingsControlID.downloadFolderName.rawValue] == nil)
    #expect(export.values[SettingsControlID.mediaCacheLastCleared.rawValue] == nil)
    let text = try #require(String(data: export.encodedData(), encoding: .utf8))
    #expect(!text.contains(folder.path))
    #expect(!text.contains(folder.lastPathComponent))

    preferences.reset(scope: .appWide, page: .storageDownloads)
    #expect(store.load() == .defaults)
    #expect(try store.resolvedDefaultFolder() == nil)
    #expect(store.lastMediaCacheClearDate == Date(timeIntervalSince1970: 123))
}

@Test func `Download collision policy renames deterministically or asks`() throws {
    let proposed = URL(fileURLWithPath: "/Downloads/photo.png")
    let occupied = Set([
        proposed.path,
        "/Downloads/photo 2.png",
    ])

    #expect(
        DownloadFilenameCollisionPolicy.automaticallyRename.destination(
            for: proposed,
            fileExists: occupied.contains
        )?.path == "/Downloads/photo 3.png"
    )
    #expect(
        DownloadFilenameCollisionPolicy.ask.destination(
            for: proposed,
            fileExists: occupied.contains
        ) == nil
    )
}

@Test func `Incomplete cleanup stays inside owned root and preserves recent work`() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
        path: "sakuracord-partial-cleanup-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let ownedRoot = SharedMediaDataLoader.incompleteDownloadRootDirectory(
        temporaryDirectory: temporaryRoot
    )
    let stale = ownedRoot.appending(path: "stale", directoryHint: .isDirectory)
    let recent = ownedRoot.appending(path: "recent", directoryHint: .isDirectory)
    let unrelated = temporaryRoot.appending(path: "unrelated", directoryHint: .isDirectory)
    for directory in [stale, recent, unrelated] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: directory.appending(path: "download"))
    }
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let cutoff = Date()
    try FileManager.default.setAttributes(
        [.modificationDate: cutoff.addingTimeInterval(-60)],
        ofItemAtPath: stale.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: cutoff.addingTimeInterval(60)],
        ofItemAtPath: recent.path
    )

    let summary = try await SakuraCordStorageInspector.incompleteDownloadSummary(
        in: ownedRoot,
        olderThan: cutoff
    )
    #expect(summary == StorageByteSummary(fileCount: 1, byteCount: 7))

    let removed = try await SakuraCordStorageInspector.clearIncompleteDownloads(
        in: ownedRoot,
        olderThan: cutoff
    )
    #expect(removed == summary)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@MainActor
@Test func `Draft summaries and destructive actions remain account scoped`() async throws {
    let first = try SakuraCordDatabase(inMemory: true)
    let second = try SakuraCordDatabase(inMemory: true)
    let databases = [AccountID(rawValue: 100): first, AccountID(rawValue: 200): second]
    try await first.saveDraft("first", channelID: ChannelID(rawValue: 1))
    try await second.saveDraft("second", channelID: ChannelID(rawValue: 2))
    let model = AppModel(
        launchMode: .offlineTesting,
        accountDatabaseFactory: { databases[$0] }
    )
    model.savedAccounts = [
        SavedAccount(accountID: "100", displayName: "First"),
        SavedAccount(accountID: "200", displayName: "Second"),
    ]
    model.activeAccountID = "100"
    model.database = first

    let initial = try await model.localDraftStorageSummary()
    #expect(initial.selectedAccount?.draftCount == 1)
    #expect(initial.allAccounts.draftCount == 2)
    #expect(initial.accountCount == 2)

    try await model.clearLocalDrafts()
    #expect(try await first.draftStorageSummary().draftCount == 0)
    #expect(try await second.draftStorageSummary().draftCount == 1)

    try await model.clearAllLocalDrafts()
    #expect(try await second.draftStorageSummary().draftCount == 0)
}

@MainActor
@Test func `Storage search exposes live controls and never exposes hidden bookmark state`() {
    let state = SettingsViewState()
    state.searchText = "eviction LRU"
    #expect(state.searchResults.contains { $0.id == .mediaCacheUsage })
    state.searchText = "temporary delete"
    #expect(state.searchResults.contains { $0.id == .incompleteDownloadsClear })
    state.searchText = "unsent active account"
    #expect(state.searchResults.contains { $0.id == .clearSelectedAccountDrafts })
    #expect(!state.catalog.controls.contains { $0.id == .downloadFolderBookmark })
}
