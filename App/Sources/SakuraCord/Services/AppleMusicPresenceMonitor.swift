import AppKit
import DiscordProtocol
import Foundation
import os

/// Resolves live album artwork from iTunes Search API and Spotify oEmbed,
/// matching Boring Notch's multi-source fallback mechanism.
public actor MusicArtworkResolver {
    public static let shared = MusicArtworkResolver()
    private var artworkCache: [String: String] = [:]
    private var artworkCacheKeys: [String] = []
    private var trackURLCache: [String: String] = [:]
    private var trackCacheKeys: [String] = []
    private let maxCacheSize = 64

    public func cachedArtworkURL(title: String, artist: String?, album: String?) -> String? {
        let key = cacheKey(service: "Any", title: title, artist: artist, album: album)
        return artworkCache[key]
    }

    public func cachedTrackURL(service: String = "Apple Music", title: String, artist: String?, album: String?) -> String? {
        let key = cacheKey(service: service, title: title, artist: artist, album: album)
        return trackURLCache[key]
    }

    private func cacheKey(service: String, title: String, artist: String?, album: String?) -> String {
        "\(service):\(artist ?? "") - \(title) - \(album ?? "")"
    }

    private func storeArtworkInCache(key: String, artwork: String) {
        if artworkCache[key] == nil {
            if artworkCacheKeys.count >= maxCacheSize {
                let oldest = artworkCacheKeys.removeFirst()
                artworkCache.removeValue(forKey: oldest)
            }
            artworkCacheKeys.append(key)
        }
        artworkCache[key] = artwork
    }

    private func storeTrackInCache(key: String, trackURL: String) {
        if trackURLCache[key] == nil {
            if trackCacheKeys.count >= maxCacheSize {
                let oldest = trackCacheKeys.removeFirst()
                trackURLCache.removeValue(forKey: oldest)
            }
            trackCacheKeys.append(key)
        }
        trackURLCache[key] = trackURL
    }

    private func resolveSpotifyOEmbed(spotifyTrackID: String?) async -> (artworkURL: String?, trackURL: String?) {
        guard let spotifyTrackID, spotifyTrackID.contains("track:") else { return (nil, nil) }
        let trackPart = spotifyTrackID.components(separatedBy: "track:").last ?? ""
        guard !trackPart.isEmpty else { return (nil, nil) }
        let trackURL = "https://open.spotify.com/track/\(trackPart)"
        guard let oembedURL = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(trackPart)") else {
            return (nil, trackURL)
        }
        var request = URLRequest(url: oembedURL)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumb = json["thumbnail_url"] as? String, !thumb.isEmpty else {
            return (nil, trackURL)
        }
        return (thumb, trackURL)
    }

    private func resolveITunes(title: String, artist: String?) async -> (artworkURL: String?, trackURL: String?)? {
        var query = title
        if let artist, !artist.isEmpty {
            query += " " + artist
        }
        if let item = await queryITunes(term: query, entity: "song") {
            return item
        }
        return await queryITunes(term: query, entity: nil)
    }

    public func resolveMusic(service: String = "Apple Music", title: String, artist: String?, album: String?, spotifyTrackID: String? = nil) async -> (artworkURL: String?, trackURL: String?) {
        let trackKey = cacheKey(service: service, title: title, artist: artist, album: album)
        let artKey = cacheKey(service: "Any", title: title, artist: artist, album: album)
        if let art = artworkCache[artKey], let track = trackURLCache[trackKey] {
            return (art, track)
        }

        var resolvedArt: String? = artworkCache[artKey]
        var resolvedTrack: String? = trackURLCache[trackKey]
        let isSpotify = service.caseInsensitiveCompare("Spotify") == .orderedSame

        if isSpotify {
            let spotify = await resolveSpotifyOEmbed(spotifyTrackID: spotifyTrackID)
            if resolvedArt == nil { resolvedArt = spotify.artworkURL }
            if resolvedTrack == nil { resolvedTrack = spotify.trackURL }
        }

        if resolvedArt == nil || (!isSpotify && resolvedTrack == nil) {
            let itunes = await resolveITunes(title: title, artist: artist)
            if resolvedArt == nil { resolvedArt = itunes?.artworkURL }
            if !isSpotify, resolvedTrack == nil { resolvedTrack = itunes?.trackURL }
        }

        if let resolvedArt {
            storeArtworkInCache(key: artKey, artwork: resolvedArt)
        }
        if let resolvedTrack {
            storeTrackInCache(key: trackKey, trackURL: resolvedTrack)
        }
        return (resolvedArt, resolvedTrack)
    }

    private func queryITunes(term: String, entity: String?) async -> (artworkURL: String?, trackURL: String?)? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        var queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "1")
        ]
        if let entity {
            queryItems.append(URLQueryItem(name: "entity", value: entity))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first else {
            return nil
        }
        let art100 = first["artworkUrl100"] as? String
        let highRes = art100?.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        let trackURL = (first["trackViewUrl"] as? String) ?? (first["collectionViewUrl"] as? String)
        return (artworkURL: highRes, trackURL: trackURL)
    }
}

/// Sendable representation of track metadata received from Apple Music or Spotify notifications.
public nonisolated struct AppleMusicTrackInfo: Sendable {
    public var playerState: String
    public var name: String?
    public var artist: String?
    public var album: String?
    public var currentPositionSeconds: Double?
    public var totalTimeMilliseconds: Double?
    public var trackID: String?
    public var appName: String

    public init(
        playerState: String,
        name: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        currentPositionSeconds: Double? = nil,
        totalTimeMilliseconds: Double? = nil,
        trackID: String? = nil,
        appName: String = "Apple Music"
    ) {
        self.playerState = playerState
        self.name = name
        self.artist = artist
        self.album = album
        self.currentPositionSeconds = currentPositionSeconds
        self.totalTimeMilliseconds = totalTimeMilliseconds
        self.trackID = trackID
        self.appName = appName
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        self.playerState = (userInfo["Player State"] as? String) ?? ""
        self.name = userInfo["Name"] as? String
        self.artist = userInfo["Artist"] as? String
        self.album = userInfo["Album"] as? String
        self.trackID = userInfo["Track ID"] as? String

        if let id = self.trackID, id.contains("spotify") {
            self.appName = "Spotify"
        } else {
            self.appName = "Apple Music"
        }

        let rawPos: Double? = {
            if let num = (userInfo["Playback Position"] ?? userInfo["Current Position"]) as? NSNumber {
                return num.doubleValue
            } else if let val = (userInfo["Playback Position"] ?? userInfo["Current Position"]) as? Double {
                return val
            }
            return nil
        }()

        if let rawPos, rawPos.isFinite, rawPos >= 0, rawPos < 86400 * 7 {
            self.currentPositionSeconds = rawPos
        } else {
            self.currentPositionSeconds = nil
        }

        let maxDurMs: Double = 86_400_000 * 7
        if let dur = (userInfo["Duration"] as? NSNumber)?.doubleValue ?? (userInfo["Duration"] as? Double) {
            if dur.isFinite, dur > 0 {
                let ms = dur > 1000 ? dur : (dur * 1000)
                self.totalTimeMilliseconds = ms < maxDurMs ? ms : nil
            } else {
                self.totalTimeMilliseconds = nil
            }
        } else if let num = userInfo["Total Time"] as? NSNumber {
            let val = num.doubleValue
            self.totalTimeMilliseconds = (val.isFinite && val > 0 && val < maxDurMs) ? val : nil
        } else if let val = userInfo["Total Time"] as? Double {
            self.totalTimeMilliseconds = (val.isFinite && val > 0 && val < maxDurMs) ? val : nil
        } else {
            self.totalTimeMilliseconds = nil
        }
    }
}

/// Monitors macOS Apple Music and Spotify playback events via system distributed notifications
/// (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`)
/// and translates them into Rich Presence activity updates.
public nonisolated final class AppleMusicPresenceMonitor: @unchecked Sendable {
    private let coordinator: ActivityCoordinator
    private let center: DistributedNotificationCenter
    private let nowProvider: @Sendable () -> Date
    private let positionQueryProvider: @Sendable (String) -> Double?
    private let lock = NSLock()
    private var observationTokens: [NSObjectProtocol] = []
    private var appTerminateToken: NSObjectProtocol?
    private var isMonitoring: Bool = false
    private var currentActiveTrackInfo: AppleMusicTrackInfo?
    private var positionPollTask: Task<Void, Never>?
    private var activePollingAppName: String?
    private var artworkFetchGeneration: UInt64 = 0
    private var artworkFetchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.sakuracord", category: "AppleMusicPresenceMonitor")

    public static let musicNotificationName = Notification.Name("com.apple.Music.playerInfo")
    public static let legacyiTunesNotificationName = Notification.Name("com.apple.iTunes.playerInfo")
    public static let spotifyNotificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")
    public static let appleMusicAppID = "1247654840780460125"
    public static let appleMusicIconAsset = "393590f736eaf7d08120700c39b259d7"
    public static let appleMusicIconURL = "https://cdn.discordapp.com/app-icons/\(appleMusicAppID)/\(appleMusicIconAsset).png"

    private static let artworkLock = NSLock()
    nonisolated(unsafe) private static var _cachedArtworkData: Data?

    public static var currentArtworkData: Data? {
        get {
            artworkLock.lock()
            defer { artworkLock.unlock() }
            return _cachedArtworkData
        }
        set {
            artworkLock.lock()
            _cachedArtworkData = newValue
            artworkLock.unlock()
        }
    }

    private struct TrackPlaybackState: Sendable {
        var appName: String
        var trackName: String
        var artist: String?
        var playbackStartDate: Date
        var savedElapsedSeconds: Double
        var isPlaying: Bool
    }
    private var lastPlaybackState: TrackPlaybackState?

    private func cancelArtworkFetchTask() {
        lock.lock()
        defer { lock.unlock() }
        artworkFetchGeneration &+= 1
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
    }

    private func clearMusicActivity(now: Date) async {
        cancelArtworkFetchTask()
        stopPositionPolling()
        updatePlaybackStateOnPauseOrStop(now: now)
        Self.removeCachedArtwork()
        await coordinator.clearActivity(for: .appleMusic)
    }

    private func isCurrentArtworkGeneration(_ gen: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return artworkFetchGeneration == gen
    }

    private func updatePlaybackStateOnResume(
        trackName: String,
        artist: String?,
        currentPositionSeconds: Double?,
        appName: String,
        now: Date
    ) -> (resolvedPosition: Double, playbackStartDate: Date) {
        let queriedPosition: Double? = if currentPositionSeconds == nil {
            positionQueryProvider(appName)
        } else {
            nil
        }

        lock.lock()
        defer { lock.unlock() }
        let resolvedPosition: Double
        if let currentPositionSeconds {
            resolvedPosition = currentPositionSeconds
        } else if let last = lastPlaybackState,
                  !last.isPlaying,
                  last.appName == appName,
                  last.trackName == trackName,
                  artist == nil || last.artist == artist,
                  last.savedElapsedSeconds > 0 {
            resolvedPosition = last.savedElapsedSeconds
        } else if let queried = queriedPosition, queried >= 0 {
            resolvedPosition = queried
        } else {
            resolvedPosition = 0
        }
        let playbackStartDate = now.addingTimeInterval(-resolvedPosition)
        lastPlaybackState = TrackPlaybackState(
            appName: appName,
            trackName: trackName,
            artist: artist,
            playbackStartDate: playbackStartDate,
            savedElapsedSeconds: resolvedPosition,
            isPlaying: true
        )
        return (resolvedPosition, playbackStartDate)
    }

    private func updatePlaybackStateOnPauseOrStop(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        currentActiveTrackInfo = nil
        if var last = lastPlaybackState, last.isPlaying {
            let elapsed = max(0, now.timeIntervalSince(last.playbackStartDate))
            last.savedElapsedSeconds = elapsed
            last.isPlaying = false
            lastPlaybackState = last
        }
    }

    nonisolated(unsafe) private static let musicPositionScript: NSAppleScript? = {
        let script = NSAppleScript(source: """
        tell application "Music"
            if it is running then
                return (player position as real)
            end if
            return -1
        end tell
        """)
        script?.compileAndReturnError(nil)
        return script
    }()

    nonisolated(unsafe) private static let spotifyPositionScript: NSAppleScript? = {
        let script = NSAppleScript(source: """
        tell application "Spotify"
            if it is running then
                return (player position as real)
            end if
            return -1
        end tell
        """)
        script?.compileAndReturnError(nil)
        return script
    }()

    private static func runOnMainThread<T: Sendable>(_ block: @Sendable () -> T) -> T {
        if Thread.isMainThread {
            return block()
        } else {
            return DispatchQueue.main.sync {
                block()
            }
        }
    }

    public static func queryPlayerPosition(appName: String = "Apple Music") -> Double? {
        #if os(macOS)
        guard NSClassFromString("XCTest") == nil else { return nil }
        let bundleID = appName.caseInsensitiveCompare("Spotify") == .orderedSame ? "com.spotify.client" : "com.apple.Music"
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        #endif
        return runOnMainThread {
            let isSpotify = appName.caseInsensitiveCompare("Spotify") == .orderedSame
            guard let script = isSpotify ? spotifyPositionScript : musicPositionScript else { return nil }
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            if errorInfo != nil { return nil }
            let val = descriptor.doubleValue
            return val >= 0 ? val : nil
        }
    }

    private func setCurrentActiveTrackInfo(_ info: AppleMusicTrackInfo?) {
        lock.lock()
        currentActiveTrackInfo = info
        lock.unlock()
    }

    private func getCurrentActiveTrackInfo() -> AppleMusicTrackInfo? {
        lock.lock()
        defer { lock.unlock() }
        return currentActiveTrackInfo
    }

    private func isDriftExceeded(queried: Double, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastPlaybackState, last.isPlaying else { return false }
        let expectedElapsed = max(0, now.timeIntervalSince(last.playbackStartDate))
        return abs(queried - expectedElapsed) > 2.0
    }

    private func startPositionPollingIfNeeded(appName: String) {
        lock.lock()
        defer { lock.unlock() }
        guard isMonitoring else { return }
        if activePollingAppName != appName {
            positionPollTask?.cancel()
            positionPollTask = nil
            activePollingAppName = appName
        }
        guard positionPollTask == nil else { return }
        positionPollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { break }
                await self.checkPositionDrift(appName: appName)
            }
        }
    }

    private func stopPositionPolling() {
        lock.lock()
        defer { lock.unlock() }
        positionPollTask?.cancel()
        positionPollTask = nil
        activePollingAppName = nil
    }

    private func checkPositionDrift(appName: String) async {
        guard let queried = positionQueryProvider(appName), queried >= 0 else { return }
        let now = nowProvider()
        guard isDriftExceeded(queried: queried, now: now) else { return }
        guard var updated = getCurrentActiveTrackInfo() else { return }
        updated.currentPositionSeconds = queried
        await handleTrackInfo(updated)
    }

    public static func fetchCurrentArtworkData() -> Data? {
        #if os(macOS)
        guard NSClassFromString("XCTest") == nil else { return nil }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return nil }
        #endif
        return runOnMainThread {
            let scriptSource = """
            tell application "Music"
                if it is running then
                    tell current track
                        if (count of artworks) > 0 then
                            return raw data of artwork 1
                        end if
                    end tell
                end if
                return missing value
            end tell
            """
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: scriptSource) else { return nil }
            let descriptor = script.executeAndReturnError(&errorInfo)
            let data = descriptor.data
            guard !data.isEmpty, NSImage(data: data) != nil else { return nil }
            return data
        }
    }

    public static func updateArtworkCache() {
        let data = fetchCurrentArtworkData()
        if let data {
            currentArtworkData = data
        }
    }

    public static func removeCachedArtwork() {
        currentArtworkData = nil
    }

    private static func queryTrack(for appName: String, bundleID: String, durationMultiplier: Double) -> (isStopped: Bool, track: AppleMusicTrackInfo?) {
        #if os(macOS)
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return (false, nil) }
        return runOnMainThread {
            let scriptSource = """
            tell application "\(appName)"
                if it is running then
                    set pState to (player state as string)
                    if pState is "playing" then
                        set tName to (name of current track as string)
                        set tArtist to (artist of current track as string)
                        set tAlbum to (album of current track as string)
                        set tPos to (player position as real)
                        set tDur to (duration of current track as real)
                        set tID to ""
                        try
                            set tID to (id of current track as string)
                        end try
                        return pState & "|||" & tName & "|||" & tArtist & "|||" & tAlbum & "|||" & tPos & "|||" & (tDur * \(durationMultiplier)) & "|||" & tID
                    else if pState is "paused" or pState is "stopped" then
                        return "stopped"
                    end if
                end if
                return "unknown"
            end tell
            """
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: scriptSource) else { return (false, nil) }
            let descriptor = script.executeAndReturnError(&errorInfo)
            guard errorInfo == nil else { return (false, nil) }
            let result = descriptor.stringValue ?? ""
            if result == "stopped" { return (true, nil) }
            guard !result.isEmpty, result != "unknown" else { return (false, nil) }
            let parts = result.components(separatedBy: "|||")
            guard parts.count >= 6 else { return (false, nil) }
            let trackID = parts.count >= 7 && !parts[6].isEmpty ? parts[6] : nil
            return (false, AppleMusicTrackInfo(
                playerState: parts[0],
                name: parts[1],
                artist: parts[2],
                album: parts[3],
                currentPositionSeconds: Double(parts[4]),
                totalTimeMilliseconds: Double(parts[5]),
                trackID: trackID,
                appName: appName == "Music" ? "Apple Music" : appName
            ))
        }
        #else
        return (false, nil)
        #endif
    }

    public func checkCurrentTrack() {
        #if os(macOS)
        guard NSClassFromString("XCTest") == nil else { return }
        let isMusicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
        let isSpotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
        guard isMusicRunning || isSpotifyRunning else { return }
        #endif
        Task.detached(priority: .utility) { [weak self, coordinator] in
            guard await coordinator.isSourcePermitted(.appleMusic) else { return }
            let musicResult = await MainActor.run {
                Self.queryTrack(for: "Music", bundleID: "com.apple.Music", durationMultiplier: 1000)
            }
            if let track = musicResult.track {
                await self?.handleTrackInfo(track)
                return
            }

            let spotifyResult = await MainActor.run {
                Self.queryTrack(for: "Spotify", bundleID: "com.spotify.client", durationMultiplier: 1)
            }
            if let track = spotifyResult.track {
                await self?.handleTrackInfo(track)
                return
            }

            if musicResult.isStopped || spotifyResult.isStopped {
                await self?.handleTrackInfo(nil)
            }
        }
    }

    public init(
        coordinator: ActivityCoordinator,
        notificationCenter: DistributedNotificationCenter = .default(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        positionQueryProvider: @escaping @Sendable (String) -> Double? = { AppleMusicPresenceMonitor.queryPlayerPosition(appName: $0) }
    ) {
        self.coordinator = coordinator
        self.center = notificationCenter
        self.nowProvider = nowProvider
        self.positionQueryProvider = positionQueryProvider
    }

    deinit {
        stop()
    }

    /// Starts observing Apple Music and Spotify playback notifications.
    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isMonitoring else { return }
        isMonitoring = true

        let notificationNames = [
            Self.musicNotificationName,
            Self.legacyiTunesNotificationName,
            Self.spotifyNotificationName
        ]
        for name in notificationNames {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self else { return }
                let trackInfo = AppleMusicTrackInfo(userInfo: notification.userInfo)
                Task {
                    await self.handleTrackInfo(trackInfo)
                }
            }
            observationTokens.append(token)
        }

        #if os(macOS)
        let termToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let terminatedApp = app.bundleIdentifier == "com.spotify.client" ? "Spotify" : (app.bundleIdentifier == "com.apple.Music" ? "Apple Music" : nil)
                if let terminatedApp {
                    Task {
                        if self.getCurrentActiveTrackInfo()?.appName == terminatedApp {
                            await self.handleTrackInfo(nil)
                        }
                    }
                }
            }
        }
        self.appTerminateToken = termToken
        #endif

        checkCurrentTrack()
        logger.info("Music presence monitor started observing notifications.")
    }

    /// Stops observing notifications and clears any active music presence.
    public func stop() {
        lock.lock()
        let tokens = observationTokens
        observationTokens.removeAll()
        let termToken = appTerminateToken
        appTerminateToken = nil
        isMonitoring = false
        lastPlaybackState = nil
        currentActiveTrackInfo = nil
        lock.unlock()
        stopPositionPolling()
        cancelArtworkFetchTask()

        for token in tokens {
            center.removeObserver(token)
        }
        #if os(macOS)
        if let termToken {
            NSWorkspace.shared.notificationCenter.removeObserver(termToken)
        }
        #endif

        Self.removeCachedArtwork()
        Task { [coordinator] in
            await coordinator.clearActivity(for: .appleMusic)
        }
        logger.info("Music presence monitor stopped.")
    }

    /// Convenience wrapper to process raw user info dictionary.
    @discardableResult
    public func handlePlayerInfo(_ userInfo: [AnyHashable: Any]?) async -> OutgoingActivityPayload? {
        await handleTrackInfo(AppleMusicTrackInfo(userInfo: userInfo))
    }

    /// Processes typed track info and updates presence through the coordinator.
    @discardableResult
    public func handleTrackInfo(_ trackInfo: AppleMusicTrackInfo?) async -> OutgoingActivityPayload? {
        guard await coordinator.isSourcePermitted(.appleMusic) else {
            await clearMusicActivity(now: nowProvider())
            return nil
        }

        let now = nowProvider()

        guard let trackInfo else {
            await clearMusicActivity(now: now)
            return nil
        }

        guard trackInfo.playerState.caseInsensitiveCompare("Playing") == .orderedSame else {
            logger.debug("Music player state is '\(trackInfo.playerState, privacy: .public)'; clearing activity.")
            await clearMusicActivity(now: now)
            return nil
        }

        guard let trackName = trackInfo.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trackName.isEmpty else {
            logger.debug("Music playing track missing title; clearing activity.")
            await clearMusicActivity(now: now)
            return nil
        }

        let artist = trackInfo.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = trackInfo.album?.trimmingCharacters(in: .whitespacesAndNewlines)

        setCurrentActiveTrackInfo(trackInfo)

        let (_, playbackStartDate) = updatePlaybackStateOnResume(
            trackName: trackName,
            artist: artist,
            currentPositionSeconds: trackInfo.currentPositionSeconds,
            appName: trackInfo.appName,
            now: now
        )

        startPositionPollingIfNeeded(appName: trackInfo.appName)

        let startInterval = playbackStartDate.timeIntervalSince1970
        guard startInterval.isFinite, startInterval > 0, startInterval < Double(Int64.max / 1000) else {
            return nil
        }
        let startTimestampMs = Int64(startInterval * 1000)
        let endTimestampMs: Int64? = {
            guard let ms = trackInfo.totalTimeMilliseconds, ms.isFinite, ms > 0, ms < Double(Int64.max - startTimestampMs) else {
                return nil
            }
            let (endMs, overflow) = startTimestampMs.addingReportingOverflow(Int64(ms))
            return overflow ? nil : endMs
        }()

        let nonIsolatedState: String? = {
            guard let artist, !artist.isEmpty else { return nil }
            return artist
        }()

        let largeText: String? = {
            if let album, !album.isEmpty {
                return album
            }
            return trackInfo.appName
        }()

        let musicAppID = trackInfo.appName.caseInsensitiveCompare("Spotify") == .orderedSame ? "spotify" : Self.appleMusicAppID
        let cachedArtwork = await MusicArtworkResolver.shared.cachedArtworkURL(title: trackName, artist: artist, album: album)
        let cachedTrackURL = await MusicArtworkResolver.shared.cachedTrackURL(service: trackInfo.appName, title: trackName, artist: artist, album: album)
        let resolvedMusic = if cachedArtwork != nil, cachedTrackURL != nil {
            (artworkURL: cachedArtwork, trackURL: cachedTrackURL)
        } else {
            await MusicArtworkResolver.shared.resolveMusic(
                service: trackInfo.appName,
                title: trackName,
                artist: artist,
                album: album,
                spotifyTrackID: trackInfo.trackID
            )
        }
        let initialLargeImage = resolvedMusic.artworkURL ?? Self.appleMusicIconURL

        let assets = ActivityAssets(
            largeImage: initialLargeImage,
            largeText: largeText,
            smallImage: nil,
            smallText: nil
        )

        let activity = OutgoingActivityPayload(
            name: trackInfo.appName,
            type: .listening,
            url: resolvedMusic.trackURL,
            details: trackName,
            state: nonIsolatedState,
            timestamps: ActivityTimestamps(start: startTimestampMs, end: endTimestampMs),
            assets: assets,
            party: nil,
            secrets: nil,
            instance: false,
            flags: nil,
            buttons: nil,
            applicationId: musicAppID
        )

        logger.info("\(trackInfo.appName, privacy: .public) presence updating: '\(trackName, privacy: .public)' by '\(artist ?? "Unknown", privacy: .public)'")
        await coordinator.setActivity(activity, for: .appleMusic)

        spawnArtworkFetchTask(trackInfo: trackInfo, activity: activity)
        return activity
    }

    private func spawnArtworkFetchTask(
        trackInfo: AppleMusicTrackInfo,
        activity: OutgoingActivityPayload
    ) {
        lock.lock()
        artworkFetchGeneration &+= 1
        let artworkGen = artworkFetchGeneration
        artworkFetchTask?.cancel()
        let task = Task.detached(priority: .utility) { [weak self, coordinator] in
            guard let self, self.isCurrentArtworkGeneration(artworkGen), !Task.isCancelled else { return }
            guard await coordinator.isSourcePermitted(.appleMusic) else { return }

            if trackInfo.appName.caseInsensitiveCompare("Spotify") != .orderedSame {
                await MainActor.run {
                    Self.updateArtworkCache()
                }
            }

            guard await coordinator.isSourcePermitted(.appleMusic) else { return }
            let musicAppID = trackInfo.appName.caseInsensitiveCompare("Spotify") == .orderedSame ? "spotify" : Self.appleMusicAppID
            let resolvedMusic = await MusicArtworkResolver.shared.resolveMusic(
                service: trackInfo.appName,
                title: activity.details ?? "",
                artist: activity.state,
                album: trackInfo.album?.trimmingCharacters(in: .whitespacesAndNewlines),
                spotifyTrackID: trackInfo.trackID
            )
            if let resolvedArtwork = resolvedMusic.artworkURL {
                guard self.isCurrentArtworkGeneration(artworkGen), !Task.isCancelled else { return }
                guard await coordinator.isSourcePermitted(.appleMusic) else { return }

                if let url = URL(string: resolvedArtwork),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   NSImage(data: data) != nil {
                    guard self.isCurrentArtworkGeneration(artworkGen), !Task.isCancelled else { return }
                    Self.currentArtworkData = data
                }
            }

            guard self.isCurrentArtworkGeneration(artworkGen), !Task.isCancelled else { return }
            guard await coordinator.isSourcePermitted(.appleMusic) else { return }

            if resolvedMusic.artworkURL != nil || resolvedMusic.trackURL != nil {
                let updatedAssets = ActivityAssets(
                    largeImage: resolvedMusic.artworkURL ?? activity.assets?.largeImage,
                    largeText: activity.assets?.largeText,
                    smallImage: nil,
                    smallText: nil
                )
                let updatedActivity = OutgoingActivityPayload(
                    name: activity.name,
                    type: activity.type,
                    url: resolvedMusic.trackURL ?? activity.url,
                    details: activity.details,
                    state: activity.state,
                    timestamps: activity.timestamps,
                    assets: updatedAssets,
                    party: activity.party,
                    secrets: activity.secrets,
                    instance: activity.instance,
                    flags: activity.flags,
                    buttons: activity.buttons,
                    applicationId: musicAppID
                )
                await coordinator.setActivity(updatedActivity, for: .appleMusic)
            }
        }
        artworkFetchTask = task
        lock.unlock()
    }
}
