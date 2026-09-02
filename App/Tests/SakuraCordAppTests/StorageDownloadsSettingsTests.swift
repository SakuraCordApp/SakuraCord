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
    value.localStorageLimit = .gigabytes5
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
    #expect(export.values[SettingsControlID.localStorageLimit.rawValue] == .integer(5_368_709_120))
    #expect(export.values[SettingsControlID.downloadFolderBookmark.rawValue] == nil)
    #expect(export.values[SettingsControlID.downloadFolderName.rawValue] == nil)
    #expect(export.values[SettingsControlID.mediaCacheLastCleared.rawValue] == nil)
    #expect(export.values[SettingsControlID.revealCompletedDownloads.rawValue] == .bool(true))
    let text = try #require(String(data: export.encodedData(), encoding: .utf8))
    #expect(!text.contains(folder.path))
    #expect(!text.contains(folder.lastPathComponent))

    preferences.reset(scope: .appWide, page: .storageDownloads)
    #expect(store.load() == .defaults)
    #expect(try store.resolvedDefaultFolder() == nil)
    #expect(store.lastMediaCacheClearDate == Date(timeIntervalSince1970: 123))
}

@Test func `Direct download chooses an unused filename without overwriting`() throws {
    let proposed = URL(fileURLWithPath: "/Downloads/photo.png")
    let occupied = Set([
        proposed.path,
        "/Downloads/photo 2.png",
    ])

    #expect(
        MediaViewerActionService.availableDestination(
            for: proposed,
            fileExists: occupied.contains
        )?.path == "/Downloads/photo 3.png"
    )
}

@Test func `Startup removes abandoned downloads only inside the owned root`() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
        path: "sakuracord-partial-cleanup-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let ownedRoot = SharedMediaDataLoader.incompleteDownloadRootDirectory(
        temporaryDirectory: temporaryRoot
    )
    let abandoned = ownedRoot.appending(path: "abandoned", directoryHint: .isDirectory)
    let unrelated = temporaryRoot.appending(path: "unrelated", directoryHint: .isDirectory)
    for directory in [abandoned, unrelated] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: directory.appending(path: "download"))
    }
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    SharedMediaDataLoader.removeAbandonedDownloadsAtStartup(
        temporaryDirectory: temporaryRoot
    )

    #expect(!FileManager.default.fileExists(atPath: ownedRoot.path))
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
    #expect(initial.allAccounts.draftCount == 2)
    #expect(
        LocalStorageBudget.mediaCacheMaximumBytes(
            totalMaximumBytes: 100,
            draftBytes: initial.allAccounts.approximateByteCount
        ) == 89
    )
    #expect(
        LocalStorageBudget.mediaCacheMaximumBytes(
            totalMaximumBytes: 100,
            draftBytes: 101
        ) == 1
    )

    try await model.clearLocalDrafts()
    #expect(try await first.draftStorageSummary().draftCount == 0)
    #expect(try await second.draftStorageSummary().draftCount == 1)

    try await model.clearAllLocalDrafts()
    #expect(try await second.draftStorageSummary().draftCount == 0)
}

@MainActor
@Test func `Storage search exposes live controls and never exposes hidden bookmark state`() {
    let state = SettingsViewState()
    state.searchText = "drafts media storage"
    #expect(state.searchResults.contains { $0.id == .localStorageUsage })
    state.searchText = "default download folder"
    #expect(state.searchResults.contains { $0.id == .downloadFolderName })
    state.searchText = "clear drafts"
    #expect(state.searchResults.contains { $0.id == .clearAllAccountDrafts })
    #expect(!state.catalog.controls.contains { $0.id == .downloadFolderBookmark })
}
