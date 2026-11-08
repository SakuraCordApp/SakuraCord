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
    private var isMonitoring: Bool = false
    private let logger = Logger(subsystem: "dev.sakuracord", category: "AppleMusicPresenceMonitor")

    public static let musicNotificationName = Notification.Name("com.apple.Music.playerInfo")
    public static let legacyiTunesNotificationName = Notification.Name("com.apple.iTunes.playerInfo")
    public static let artworkPath: String = {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("sakuracord_applemusic_art.png")
    }()

    private func exportArtworkIfAvailable() {
        Task.detached(priority: .utility) {
            let path = Self.artworkPath
            let scriptSource = """
            tell application "Music"
                if it is running then
                    tell current track
                        if (count of artworks) > 0 then
                            set artData to raw data of artwork 1
                            set artPath to POSIX file "\(path)"
                            set artFile to (open for access artPath with write permission)
                            set eof artFile to 0
                            write artData to artFile
                            close access artFile
                            return true
                        end if
                    end tell
                end if
                return false
            end tell
            """
            var errorInfo: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                _ = script.executeAndReturnError(&errorInfo)
            }
        }
    }

    private func removeCachedArtwork() {
        try? FileManager.default.removeItem(atPath: Self.artworkPath)
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
            guard result != "stopped", !result.isEmpty else { return }
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
        checkCurrentTrack()
        logger.info("Apple Music presence monitor started observing notifications.")
    }

    /// Stops observing notifications and clears any active Apple Music presence.
    public func stop() {
        lock.lock()
        let tokens = observationTokens
        observationTokens.removeAll()
        isMonitoring = false
        lock.unlock()

        for token in tokens {
            center.removeObserver(token)
        }

        removeCachedArtwork()
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
            removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        guard trackInfo.playerState.caseInsensitiveCompare("Playing") == .orderedSame else {
            logger.debug("Apple Music player state is '\(trackInfo.playerState, privacy: .public)'; clearing activity.")
            removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        guard let trackName = trackInfo.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trackName.isEmpty else {
            logger.debug("Apple Music playing track missing title; clearing activity.")
            removeCachedArtwork()
            await coordinator.clearActivity(for: .appleMusic)
            return nil
        }

        exportArtworkIfAvailable()

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
