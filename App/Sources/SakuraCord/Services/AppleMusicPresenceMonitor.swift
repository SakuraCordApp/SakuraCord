import AppKit
import DiscordProtocol
import Foundation
import os

/// Sendable representation of track metadata received from Apple Music notifications.
public nonisolated struct AppleMusicTrackInfo: Sendable {
    public var playerState: String
    public var name: String?
    public var artist: String?
    public var album: String?
    public var currentPositionSeconds: Double
    public var totalTimeMilliseconds: Double?

    public init(
        playerState: String,
        name: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        currentPositionSeconds: Double = 0,
        totalTimeMilliseconds: Double? = nil
    ) {
        self.playerState = playerState
        self.name = name
        self.artist = artist
        self.album = album
        self.currentPositionSeconds = currentPositionSeconds
        self.totalTimeMilliseconds = totalTimeMilliseconds
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        self.playerState = (userInfo["Player State"] as? String) ?? ""
        self.name = userInfo["Name"] as? String
        self.artist = userInfo["Artist"] as? String
        self.album = userInfo["Album"] as? String

        if let num = userInfo["Current Position"] as? NSNumber {
            self.currentPositionSeconds = max(0, num.doubleValue)
        } else if let val = userInfo["Current Position"] as? Double {
            self.currentPositionSeconds = max(0, val)
        } else {
            self.currentPositionSeconds = 0
        }

        if let num = userInfo["Total Time"] as? NSNumber {
            let val = num.doubleValue
            self.totalTimeMilliseconds = val > 0 ? val : nil
        } else if let val = userInfo["Total Time"] as? Double {
            self.totalTimeMilliseconds = val > 0 ? val : nil
        } else {
            self.totalTimeMilliseconds = nil
        }
    }
}

/// Monitors macOS Apple Music playback events via system distributed notifications
/// (`com.apple.Music.playerInfo`) and translates them into Rich Presence activity updates.
public nonisolated final class AppleMusicPresenceMonitor: @unchecked Sendable {
    private let coordinator: ActivityCoordinator
    private let center: DistributedNotificationCenter
    private let nowProvider: @Sendable () -> Date
    private let lock = NSLock()
    private var observationTokens: [NSObjectProtocol] = []
    private var appTerminateToken: NSObjectProtocol?
    private var pollingTask: Task<Void, Never>?
    private var isMonitoring: Bool = false
    private let logger = Logger(subsystem: "dev.sakuracord", category: "AppleMusicPresenceMonitor")

    public static let musicNotificationName = Notification.Name("com.apple.Music.playerInfo")
    public static let legacyiTunesNotificationName = Notification.Name("com.apple.iTunes.playerInfo")

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
        currentArtworkData = data
        if let data {
            try? data.write(to: URL(fileURLWithPath: artworkPath), options: .atomic)
            try? data.write(to: URL(fileURLWithPath: fallbackArtworkPath), options: .atomic)
        } else {
            removeCachedArtwork()
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
                    end if
                end if
                return "stopped"
            end tell
            """
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: scriptSource) else { return }
            let descriptor = script.executeAndReturnError(&errorInfo)
            let result = descriptor.stringValue ?? ""
            guard result != "stopped", !result.isEmpty else {
                await self?.handleTrackInfo(nil)
                return
            }
            let parts = result.components(separatedBy: "|||")
            guard parts.count >= 6 else {
                await self?.handleTrackInfo(nil)
                return
            }
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

    /// Starts observing Apple Music playback notifications.
    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isMonitoring else { return }
        isMonitoring = true

        let notificationNames = [Self.musicNotificationName, Self.legacyiTunesNotificationName]
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
               app.bundleIdentifier == "com.apple.Music" {
                Task {
                    await self.handleTrackInfo(nil)
                }
            }
        }
        self.appTerminateToken = termToken
        #endif

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self else { break }
                self.checkCurrentTrack()
            }
        }

        checkCurrentTrack()
        logger.info("Apple Music presence monitor started observing notifications.")
    }

    /// Stops observing notifications and clears any active Apple Music presence.
    public func stop() {
        lock.lock()
        let tokens = observationTokens
        observationTokens.removeAll()
        pollingTask?.cancel()
        pollingTask = nil
        let termToken = appTerminateToken
        appTerminateToken = nil
        isMonitoring = false
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
        logger.info("Apple Music presence monitor stopped.")
    }

    /// Convenience wrapper to process raw user info dictionary.
    @discardableResult
    public func handlePlayerInfo(_ userInfo: [AnyHashable: Any]?) async -> OutgoingActivityPayload? {
        await handleTrackInfo(AppleMusicTrackInfo(userInfo: userInfo))
    }

    /// Processes typed track info and updates presence through the coordinator.
    @discardableResult
    public func handleTrackInfo(_ trackInfo: AppleMusicTrackInfo?) async -> OutgoingActivityPayload? {
        guard let trackInfo else {
            Self.removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        guard trackInfo.playerState.caseInsensitiveCompare("Playing") == .orderedSame else {
            logger.debug("Apple Music player state is '\(trackInfo.playerState, privacy: .public)'; clearing activity.")
            Self.removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        guard let trackName = trackInfo.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trackName.isEmpty else {
            logger.debug("Apple Music playing track missing title; clearing activity.")
            Self.removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        Self.updateArtworkCache()

        let artist = trackInfo.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = trackInfo.album?.trimmingCharacters(in: .whitespacesAndNewlines)

        let now = nowProvider()
        let playbackStartDate = now.addingTimeInterval(-trackInfo.currentPositionSeconds)
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
            return "Apple Music"
        }()

        let assets = ActivityAssets(
            largeImage: "apple_music",
            largeText: largeText,
            smallImage: nil,
            smallText: nil
        )

        let activity = OutgoingActivityPayload(
            name: "Apple Music",
            type: .listening,
            details: trackName,
            state: nonIsolatedState,
            timestamps: ActivityTimestamps(start: startTimestampMs, end: endTimestampMs),
            assets: assets
        )

        logger.info("Apple Music presence updating: '\(trackName, privacy: .public)' by '\(artist ?? "Unknown", privacy: .public)'")
        await coordinator.setActivity(activity, for: .appleMusic)
        return activity
    }
}
