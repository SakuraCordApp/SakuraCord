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
    private var isMonitoring = false
    private let logger = Logger(subsystem: "dev.sakuracord", category: "GamePresenceMonitor")

    public static let robloxBundleIDs: Set<String> = [
        "com.roblox.RobloxPlayer",
        "com.Roblox.RobloxPlayer",
        "com.roblox.RobloxStudio",
    ]

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
            #endif
            logger.info("Game presence monitor started.")
        }
    }

    public func stop() {
        queue.sync {
            guard isMonitoring else { return }
            isMonitoring = false

            #if os(macOS)
            if let launchObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
                self.launchObserver = nil
            }
            if let terminateObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
                self.terminateObserver = nil
            }
            #endif

            Task { [coordinator] in
                await coordinator.clearActivity(for: .custom(sourceID: "game:roblox"))
            }
            logger.info("Game presence monitor stopped.")
        }
    }

    private func handleAppNotification(_ notification: Notification, isLaunch: Bool) {
        #if os(macOS)
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }

        if Self.robloxBundleIDs.contains(bundleID) {
            if isLaunch {
                publishRobloxActivity(launchDate: app.launchDate)
            } else {
                let hasRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
                if !hasRunning {
                    Task { [coordinator] in
                        await coordinator.clearActivity(for: .custom(sourceID: "game:roblox"))
                    }
                }
            }
        }
        #endif
    }

    public func checkRunningGames() {
        #if os(macOS)
        for bundleID in Self.robloxBundleIDs {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let first = running.first, !first.isTerminated {
                publishRobloxActivity(launchDate: first.launchDate)
                return
            }
        }
        #endif
    }

    private func publishRobloxActivity(launchDate: Date? = nil) {
        let startTimeMs = Int64((launchDate ?? Date()).timeIntervalSince1970 * 1000)
        let payload = OutgoingActivityPayload(
            name: "Roblox",
            type: .playing,
            details: "Playing Roblox",
            timestamps: ActivityTimestamps(start: startTimeMs, end: nil),
            assets: ActivityAssets(
                largeImage: "https://images.rbxcdn.com/f04a43a059535d50fd92110bd582b1c6.png",
                largeText: "Roblox"
            ),
            applicationId: "roblox"
        )
        Task { [coordinator] in
            await coordinator.setActivity(payload, for: .custom(sourceID: "game:roblox"))
        }
    }
}
