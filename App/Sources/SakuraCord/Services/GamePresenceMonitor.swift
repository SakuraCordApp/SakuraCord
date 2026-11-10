import AppKit
import DiscordProtocol
import Foundation
import os
import SakuraCordModels

public nonisolated final class GamePresenceMonitor: @unchecked Sendable {
    private let coordinator: ActivityCoordinator
    private let queue = DispatchQueue(label: "dev.sakuracord.game-presence", qos: .utility)
    private var launchObserver: (any NSObjectProtocol)?
    private var terminateObserver: (any NSObjectProtocol)?
    private var periodicTimer: (any DispatchSourceTimer)?
    private var isMonitoring = false
    private let logger = Logger(subsystem: "dev.sakuracord", category: "GamePresenceMonitor")

    public static let robloxAppID = "363445589247131668"
    public static let robloxIconAsset = "f2b60e350a2097289b3b0b877495e55f"
    public static let robloxIconURL = "https://cdn.discordapp.com/app-icons/\(robloxAppID)/\(robloxIconAsset).png"

    private static let iconLock = NSLock()
    nonisolated(unsafe) private static var _cachedRobloxIconData: Data?

    public static var currentRobloxIconData: Data? {
        get {
            iconLock.lock()
            defer { iconLock.unlock() }
            return _cachedRobloxIconData
        }
        set {
            iconLock.lock()
            _cachedRobloxIconData = newValue
            iconLock.unlock()
        }
    }

    public static func isRobloxApp(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier?.lowercased(),
           bundleID.contains("roblox") {
            return true
        }
        if let localizedName = app.localizedName?.lowercased(),
           localizedName.contains("roblox") {
            return true
        }
        if let exeName = app.executableURL?.lastPathComponent.lowercased(),
           exeName.contains("roblox") {
            return true
        }
        if let bundlePath = app.bundleURL?.path.lowercased(),
           bundlePath.contains("roblox") {
            return true
        }
        return false
    }

    public init(coordinator: ActivityCoordinator) {
        self.coordinator = coordinator
    }

    deinit {
        stop()
    }

    public func start() {
        queue.sync {
            guard !isMonitoring else { return }
            isMonitoring = true

            #if os(macOS)
            let center = NSWorkspace.shared.notificationCenter
            launchObserver = center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleAppNotification(notification, isLaunch: true)
            }

            terminateObserver = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleAppNotification(notification, isLaunch: false)
            }

            checkRunningGames()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in
                self?.checkRunningGames()
            }
            timer.resume()
            periodicTimer = timer
            #endif
            logger.info("Game presence monitor started.")
        }
    }

    public func stop() {
        queue.sync {
            guard isMonitoring else { return }
            isMonitoring = false

            #if os(macOS)
            if let timer = periodicTimer {
                timer.cancel()
                periodicTimer = nil
            }
            if let launchObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
                self.launchObserver = nil
            }
            if let terminateObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
                self.terminateObserver = nil
            }
            #endif

            Self.currentRobloxIconData = nil
            Task { [coordinator] in
                await coordinator.clearActivity(for: .custom(sourceID: "game:roblox"))
            }
            logger.info("Game presence monitor stopped.")
        }
    }

    private func handleAppNotification(_ notification: Notification, isLaunch: Bool) {
        #if os(macOS)
        checkRunningGames()
        if isLaunch {
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.checkRunningGames()
            }
        }
        #endif
    }

    public func checkRunningGames() {
        #if os(macOS)
        let running = NSWorkspace.shared.runningApplications
        if let first = running.first(where: { !$0.isTerminated && Self.isRobloxApp($0) }) {
            publishRobloxActivity(app: first)
            return
        } else {
            Self.currentRobloxIconData = nil
            Task { [coordinator] in
                await coordinator.clearActivity(for: .custom(sourceID: "game:roblox"))
            }
        }
        #endif
    }

    private func publishRobloxActivity(app: NSRunningApplication? = nil) {
        let startTimeMs = Int64((app?.launchDate ?? Date()).timeIntervalSince1970 * 1000)
        if let icon = app?.icon, let tiff = icon.tiffRepresentation {
            Self.currentRobloxIconData = tiff
        }
        let payload = OutgoingActivityPayload(
            name: "Roblox",
            type: .playing,
            details: "Playing Roblox",
            timestamps: ActivityTimestamps(start: startTimeMs, end: nil),
            assets: ActivityAssets(
                largeImage: Self.robloxIconURL,
                largeText: "Roblox"
            ),
            applicationId: Self.robloxAppID
        )
        Task { [coordinator] in
            await coordinator.setActivity(payload, for: .custom(sourceID: "game:roblox"))
        }
    }
}
