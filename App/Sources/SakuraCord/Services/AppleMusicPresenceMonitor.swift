import AppKit
import DiscordProtocol
import Foundation
import os

/// Resolves live album artwork from iTunes Search API and Spotify oEmbed,
/// matching Boring Notch's multi-source fallback mechanism.
public actor MusicArtworkResolver {
    public static let shared = MusicArtworkResolver()
    private var cache: [String: String] = [:]

    public func cachedArtworkURL(title: String, artist: String?, album: String?) -> String? {
        let key = "\(artist ?? "") - \(title) - \(album ?? "")"
        return cache[key]
    }

    public func resolveArtworkURL(title: String, artist: String?, album: String?, spotifyTrackID: String? = nil) async -> String? {
        let key = "\(artist ?? "") - \(title) - \(album ?? "")"
        if let cached = cache[key] {
            return cached
        }

        // 1. Spotify oEmbed if Spotify track ID is available
        if let spotifyTrackID, spotifyTrackID.contains("track:") {
            let trackPart = spotifyTrackID.components(separatedBy: "track:").last ?? ""
            if !trackPart.isEmpty, let oembedURL = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(trackPart)") {
                var request = URLRequest(url: oembedURL)
                request.timeoutInterval = 3
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let thumb = json["thumbnail_url"] as? String, !thumb.isEmpty {
                    cache[key] = thumb
                    return thumb
                }
            }
        }

        // 2. iTunes Search API fallback (as used in Boring Notch for Apple Music and general catalog)
        var query = title
        if let artist, !artist.isEmpty {
            query += " " + artist
        }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let itunesURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=1") else {
            return nil
        }

        var request = URLRequest(url: itunesURL)
        request.timeoutInterval = 3
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let first = results.first,
           let art100 = first["artworkUrl100"] as? String {
            let highRes = art100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            cache[key] = highRes
            return highRes
        }

        return nil
    }
}

/// Sendable representation of track metadata received from Apple Music or Spotify notifications.
public nonisolated struct AppleMusicTrackInfo: Sendable {
    public var playerState: String
    public var name: String?
    public var artist: String?
    public var album: String?
    public var currentPositionSeconds: Double
    public var totalTimeMilliseconds: Double?
    public var trackID: String?
    public var appName: String

    public init(
        playerState: String,
        name: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        currentPositionSeconds: Double = 0,
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

        if let num = (userInfo["Playback Position"] ?? userInfo["Current Position"]) as? NSNumber {
            self.currentPositionSeconds = max(0, num.doubleValue)
        } else if let val = (userInfo["Playback Position"] ?? userInfo["Current Position"]) as? Double {
            self.currentPositionSeconds = max(0, val)
        } else {
            self.currentPositionSeconds = 0
        }

        if let dur = userInfo["Duration"] as? NSNumber {
            let val = dur.doubleValue
            self.totalTimeMilliseconds = val > 1000 ? val : (val * 1000)
        } else if let num = userInfo["Total Time"] as? NSNumber {
            let val = num.doubleValue
            self.totalTimeMilliseconds = val > 0 ? val : nil
        } else if let val = userInfo["Total Time"] as? Double {
            self.totalTimeMilliseconds = val > 0 ? val : nil
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
    private let lock = NSLock()
    private var observationTokens: [NSObjectProtocol] = []
    private var appTerminateToken: NSObjectProtocol?
    private var isMonitoring: Bool = false
    private let logger = Logger(subsystem: "dev.sakuracord", category: "AppleMusicPresenceMonitor")

    public static let musicNotificationName = Notification.Name("com.apple.Music.playerInfo")
    public static let legacyiTunesNotificationName = Notification.Name("com.apple.iTunes.playerInfo")
    public static let spotifyNotificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

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

    public static let artworkPath: String = {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("sakuracord_applemusic_art.png")
    }()

    public static let fallbackArtworkPath: String = "/tmp/sakuracord_applemusic_art.png"

    private struct TrackPlaybackState: Sendable {
        var trackName: String
        var artist: String?
        var playbackStartDate: Date
        var savedElapsedSeconds: Double
        var isPlaying: Bool
    }
    private var lastPlaybackState: TrackPlaybackState?

    private func updatePlaybackStateOnResume(
        trackName: String,
        artist: String?,
        currentPositionSeconds: Double,
        now: Date
    ) -> (resolvedPosition: Double, playbackStartDate: Date) {
        lock.lock()
        defer { lock.unlock() }
        var resolvedPosition: Double = currentPositionSeconds
        if resolvedPosition <= 0 {
            if let queried = Self.queryPlayerPosition(), queried > 0 {
                resolvedPosition = queried
            } else if let last = lastPlaybackState,
                      last.trackName == trackName,
                      (artist == nil || last.artist == artist),
                      last.savedElapsedSeconds > 0 {
                resolvedPosition = last.savedElapsedSeconds
            } else {
                resolvedPosition = 0
            }
        }
        let playbackStartDate = now.addingTimeInterval(-resolvedPosition)
        lastPlaybackState = TrackPlaybackState(
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
        if var last = lastPlaybackState, last.isPlaying {
            let elapsed = max(0, now.timeIntervalSince(last.playbackStartDate))
            last.savedElapsedSeconds = elapsed
            last.isPlaying = false
            lastPlaybackState = last
        }
    }

    public static func queryPlayerPosition() -> Double? {
        let scriptSource = """
        tell application "Music"
            if it is running then
                return (player position as real)
            end if
            return -1
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else { return nil }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }
        let val = descriptor.doubleValue
        return val >= 0 ? val : nil
    }

    public static func fetchCurrentArtworkData() -> Data? {
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

    public static func updateArtworkCache() {
        let data = fetchCurrentArtworkData()
        if let data {
            currentArtworkData = data
            try? data.write(to: URL(fileURLWithPath: artworkPath), options: .atomic)
            try? data.write(to: URL(fileURLWithPath: fallbackArtworkPath), options: .atomic)
        }
    }

    public static func removeCachedArtwork() {
        currentArtworkData = nil
        try? FileManager.default.removeItem(atPath: artworkPath)
        try? FileManager.default.removeItem(atPath: fallbackArtworkPath)
    }

    public func checkCurrentTrack() {
        Task.detached(priority: .utility) { [weak self] in
            let scriptSource = """
            tell application "Music"
                if it is running then
                    set pState to (player state as string)
                    if pState is "playing" then
                        set tName to (name of current track as string)
                        set tArtist to (artist of current track as string)
                        set tAlbum to (album of current track as string)
                        set tPos to (player position as real)
                        set tDur to (duration of current track as real)
                        return pState & "|||" & tName & "|||" & tArtist & "|||" & tAlbum & "|||" & tPos & "|||" & (tDur * 1000)
                    else if pState is "paused" or pState is "stopped" then
                        return "stopped"
                    end if
                end if
                return "unknown"
            end tell
            """
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: scriptSource) else { return }
            let descriptor = script.executeAndReturnError(&errorInfo)
            if errorInfo != nil {
                // Do not clear activity on AppleScript error
                return
            }
            let result = descriptor.stringValue ?? ""
            if result == "stopped" {
                await self?.handleTrackInfo(nil)
                return
            }
            guard !result.isEmpty, result != "unknown" else { return }
            let parts = result.components(separatedBy: "|||")
            guard parts.count >= 6 else { return }
            let trackInfo = AppleMusicTrackInfo(
                playerState: parts[0],
                name: parts[1],
                artist: parts[2],
                album: parts[3],
                currentPositionSeconds: Double(parts[4]) ?? 0,
                totalTimeMilliseconds: Double(parts[5])
            )
            await self?.handleTrackInfo(trackInfo)
        }
    }

    public init(
        coordinator: ActivityCoordinator,
        notificationCenter: DistributedNotificationCenter = .default(),
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.coordinator = coordinator
        self.center = notificationCenter
        self.nowProvider = nowProvider
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
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == "com.apple.Music" || app.bundleIdentifier == "com.spotify.client" {
                Task {
                    await self.handleTrackInfo(nil)
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
        lock.unlock()

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
        let now = nowProvider()

        guard let trackInfo else {
            updatePlaybackStateOnPauseOrStop(now: now)
            Self.removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        guard trackInfo.playerState.caseInsensitiveCompare("Playing") == .orderedSame else {
            logger.debug("Music player state is '\(trackInfo.playerState, privacy: .public)'; clearing activity.")
            updatePlaybackStateOnPauseOrStop(now: now)
            Self.removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        guard let trackName = trackInfo.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trackName.isEmpty else {
            logger.debug("Music playing track missing title; clearing activity.")
            updatePlaybackStateOnPauseOrStop(now: now)
            Self.removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        let artist = trackInfo.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = trackInfo.album?.trimmingCharacters(in: .whitespacesAndNewlines)

        let (_, playbackStartDate) = updatePlaybackStateOnResume(
            trackName: trackName,
            artist: artist,
            currentPositionSeconds: trackInfo.currentPositionSeconds,
            now: now
        )

        let startTimestampMs = Int64(playbackStartDate.timeIntervalSince1970 * 1000)
        let endTimestampMs: Int64? = trackInfo.totalTimeMilliseconds.map { ms in
            Int64(playbackStartDate.timeIntervalSince1970 * 1000 + ms)
        }

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

        let cachedArtwork = await MusicArtworkResolver.shared.cachedArtworkURL(title: trackName, artist: artist, album: album)
        let initialLargeImage = cachedArtwork ?? "apple_music"

        let assets = ActivityAssets(
            largeImage: initialLargeImage,
            largeText: largeText,
            smallImage: nil,
            smallText: nil
        )

        let activity = OutgoingActivityPayload(
            name: trackInfo.appName,
            type: .listening,
            details: trackName,
            state: nonIsolatedState,
            timestamps: ActivityTimestamps(start: startTimestampMs, end: endTimestampMs),
            assets: assets
        )

        logger.info("\(trackInfo.appName, privacy: .public) presence updating: '\(trackName, privacy: .public)' by '\(artist ?? "Unknown", privacy: .public)'")
        await coordinator.setActivity(activity, for: .appleMusic)

        // Asynchronously resolve and fetch live high-resolution album artwork (Boring Notch method)
        Task.detached(priority: .utility) { [coordinator] in
            Self.updateArtworkCache()

            if let resolvedArtwork = await MusicArtworkResolver.shared.resolveArtworkURL(
                title: trackName,
                artist: artist,
                album: album,
                spotifyTrackID: trackInfo.trackID
            ) {
                if let url = URL(string: resolvedArtwork),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   NSImage(data: data) != nil {
                    Self.currentArtworkData = data
                    try? data.write(to: URL(fileURLWithPath: Self.artworkPath), options: .atomic)
                    try? data.write(to: URL(fileURLWithPath: Self.fallbackArtworkPath), options: .atomic)
                }

                let updatedAssets = ActivityAssets(
                    largeImage: resolvedArtwork,
                    largeText: largeText,
                    smallImage: nil,
                    smallText: nil
                )
                let updatedActivity = OutgoingActivityPayload(
                    name: trackInfo.appName,
                    type: .listening,
                    details: trackName,
                    state: nonIsolatedState,
                    timestamps: ActivityTimestamps(start: startTimestampMs, end: endTimestampMs),
                    assets: updatedAssets
                )
                await coordinator.setActivity(updatedActivity, for: .appleMusic)
            }
        }

        return activity
    }
}
