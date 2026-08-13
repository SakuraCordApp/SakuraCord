import Foundation
import SakuraCordModels

/// Mirrors the stable insertion order Discord's ChannelStore restores from
/// disk before READY reconciliation. Replacing this order with each READY
/// payload changes every equal-score channel result after a relaunch.
nonisolated struct DiscordQuickSwitcherChannelStoreCache: Codable, Sendable {
    static let currentVersion = 1
    static let maximumChannels = 50_000

    var version = currentVersion
    var channelIDs: [ChannelID]

    static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == currentVersion
        else { return nil }
        return value
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension DiscordRESTProvider {
    func loadQuickSwitcherChannelStoreCache() {
        cachedForwardChannelStoreOrder = []
        guard let url = quickSwitcherChannelStoreCacheURL(),
              let cache = DiscordQuickSwitcherChannelStoreCache.load(from: url)
        else { return }

        var seen = Set<ChannelID>()
        cachedForwardChannelStoreOrder = cache.channelIDs.suffix(
            DiscordQuickSwitcherChannelStoreCache.maximumChannels
        ).filter { seen.insert($0).inserted }
    }

    func reconcileQuickSwitcherChannelStoreOrder(with liveChannelIDs: [ChannelID]) {
        var seen = Set<ChannelID>()
        cachedForwardChannelStoreOrder = cachedForwardChannelStoreOrder.filter {
            seen.insert($0).inserted
        } + liveChannelIDs.filter { seen.insert($0).inserted }
    }

    func appendQuickSwitcherChannelStoreOrder(_ channelIDs: [ChannelID]) {
        var seen = Set(cachedForwardChannelStoreOrder)
        cachedForwardChannelStoreOrder += channelIDs.filter { seen.insert($0).inserted }
    }

    func persistQuickSwitcherChannelStoreCache() {
        guard let url = quickSwitcherChannelStoreCacheURL() else { return }
        try? DiscordQuickSwitcherChannelStoreCache(
            channelIDs: Array(cachedForwardChannelStoreOrder.suffix(
                DiscordQuickSwitcherChannelStoreCache.maximumChannels
            ))
        ).save(to: url)
    }

    func quickSwitcherChannelStoreCacheURL() -> URL? {
        guard usesForwardSearchPeopleDiskCache, let accountID else { return nil }
        let safeAccountID = accountID.replacingOccurrences(
            of: #"[^A-Za-z0-9_.-]"#,
            with: "-",
            options: .regularExpression
        )
        let base = forwardPeopleCacheDirectoryOverride
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(
                    path: "dev.sakuracord.SakuraCord/QuickSwitcherChannelStore",
                    directoryHint: .isDirectory
                )
        return base?.appending(path: "\(safeAccountID).json")
    }
}
