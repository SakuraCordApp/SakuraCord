import DiscordProtocol
import Foundation
import os
import SakuraCordModels

public nonisolated enum ActivitySource: Hashable, Sendable, CustomStringConvertible {
    case appleMusic
    case localRPC(sourceID: String, clientID: String, processID: pid_t?)
    case custom(sourceID: String)

    public var sourceID: String {
        switch self {
        case .appleMusic:
            return "apple_music"
        case let .localRPC(sourceID, _, _):
            return "rpc:\(sourceID)"
        case let .custom(sourceID):
            return "custom:\(sourceID)"
        }
    }

    public var description: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case let .localRPC(sourceID, clientID, _):
            return "Local RPC (\(clientID) / \(sourceID))"
        case let .custom(sourceID):
            return "Custom (\(sourceID))"
        }
    }
}

public nonisolated struct ActivityCoordinatorPreferences: Equatable, Sendable {
    public var isActivitySharingEnabled: Bool
    public var isAppleMusicPresenceEnabled: Bool
    public var isLocalRPCEnabled: Bool

    public init(
        isActivitySharingEnabled: Bool = false,
        isAppleMusicPresenceEnabled: Bool = false,
        isLocalRPCEnabled: Bool = false
    ) {
        self.isActivitySharingEnabled = isActivitySharingEnabled
        self.isAppleMusicPresenceEnabled = isAppleMusicPresenceEnabled
        self.isLocalRPCEnabled = isLocalRPCEnabled
    }

    public static var enabledAll: ActivityCoordinatorPreferences {
        ActivityCoordinatorPreferences(
            isActivitySharingEnabled: true,
            isAppleMusicPresenceEnabled: true,
            isLocalRPCEnabled: true
        )
    }
}

/// Coordinates and arbitrates active activity/presence sources (Apple Music, local Discord RPC, etc.)
/// and enforces user privacy preferences before dispatching presence updates to the active `ChatProvider`.
public actor ActivityCoordinator {
    private var provider: any ChatProvider
    private var preferences: ActivityCoordinatorPreferences
    private var registeredActivities: [ActivitySource: OutgoingActivityPayload] = [:]
    private var publishedSourceIDs: Set<String> = []
    private var syncGeneration: UInt64 = 0
    private var onActivityChangedHandler: (@Sendable (OutgoingActivityPayload?) -> Void)?
    private let logger = Logger(subsystem: "dev.sakuracord", category: "ActivityCoordinator")

    public init(
        provider: any ChatProvider,
        preferences: ActivityCoordinatorPreferences = ActivityCoordinatorPreferences()
    ) {
        self.provider = provider
        self.preferences = preferences
    }

    public func setProvider(_ newProvider: any ChatProvider) async {
        self.provider = newProvider
        publishedSourceIDs.removeAll()
        syncGeneration &+= 1
        await synchronizeProvider()
    }

    public func updatePreferences(_ newPreferences: ActivityCoordinatorPreferences) async {
        guard preferences != newPreferences else { return }
        preferences = newPreferences
        syncGeneration &+= 1
        await synchronizeProvider()
    }

    public func currentPreferences() -> ActivityCoordinatorPreferences {
        preferences
    }

    public func isSourcePermitted(_ source: ActivitySource) -> Bool {
        guard preferences.isActivitySharingEnabled else { return false }
        switch source {
        case .appleMusic:
            return preferences.isAppleMusicPresenceEnabled
        case .localRPC:
            return preferences.isLocalRPCEnabled
        case .custom(let sourceID):
            if sourceID.hasPrefix("game:") {
                return preferences.isLocalRPCEnabled
            }
            return true
        }
    }

    public func setActivity(_ activity: OutgoingActivityPayload?, for source: ActivitySource) async {
        if let activity {
            registeredActivities[source] = activity
        } else {
            registeredActivities.removeValue(forKey: source)
        }
        syncGeneration &+= 1
        await synchronizeProvider()
    }

    public func clearActivity(for source: ActivitySource) async {
        registeredActivities.removeValue(forKey: source)
        syncGeneration &+= 1
        await synchronizeProvider()
    }

    public func clearAllActivities() async {
        registeredActivities.removeAll()
        syncGeneration &+= 1
        await synchronizeProvider()
    }

    public func resendActivities() async {
        publishedSourceIDs.removeAll()
        syncGeneration &+= 1
        await synchronizeProvider()
    }

    public func currentActivities() -> [ActivitySource: OutgoingActivityPayload] {
        registeredActivities
    }

    public func currentPermittedActivities() -> [ActivitySource: OutgoingActivityPayload] {
        guard preferences.isActivitySharingEnabled else { return [:] }
        return registeredActivities.filter { isSourcePermitted($0.key) }
    }

    public func currentPrimaryActivity() -> OutgoingActivityPayload? {
        let permitted = currentPermittedActivities()
        return permitted.values.sorted { $0.priorityRank < $1.priorityRank }.first
    }

    public func isSourceActive(_ source: ActivitySource) -> Bool {
        registeredActivities[source] != nil
    }

    public func setOnActivityChanged(_ handler: (@Sendable (OutgoingActivityPayload?) -> Void)?) {
        self.onActivityChangedHandler = handler
        let primary = currentPrimaryActivity()
        handler?(primary)
    }

    private func synchronizeProvider() async {
        let generation = syncGeneration
        let permitted = currentPermittedActivities()
        let primary = permitted.values.sorted { $0.priorityRank < $1.priorityRank }.first
        onActivityChangedHandler?(primary)
        let permittedSourceIDs = Set(permitted.keys.map(\.sourceID))

        // 1. Clear any sources that were previously published but are no longer permitted/registered
        let staleSourceIDs = publishedSourceIDs.subtracting(permittedSourceIDs)
        for staleID in staleSourceIDs {
            guard generation == syncGeneration else { return }
            do {
                try await provider.clearActivities(sourceID: staleID)
                guard generation == syncGeneration else { return }
                publishedSourceIDs.remove(staleID)
            } catch {
                logger.debug("Failed to clear activity source \(staleID): \(error.localizedDescription)")
            }
        }

        // 2. Publish all permitted active activities
        for (source, payload) in permitted {
            guard generation == syncGeneration else { return }
            guard isSourcePermitted(source) else { return }
            do {
                try await provider.updateActivity(payload, sourceID: source.sourceID)
                guard generation == syncGeneration else { return }
                guard isSourcePermitted(source) else { return }
                publishedSourceIDs.insert(source.sourceID)
            } catch {
                logger.debug("Failed to update activity for source \(source.sourceID): \(error.localizedDescription)")
            }
        }

        // If completely empty and nothing published, ensure provider has no remaining activities
        if permitted.isEmpty, publishedSourceIDs.isEmpty {
            guard generation == syncGeneration else { return }
            do {
                try await provider.clearActivities(sourceID: nil)
            } catch {
                logger.debug("Failed to clear all activities on provider: \(error.localizedDescription)")
            }
        }
    }
}
