import OSLog
import SakuraCordModels
import SwiftUI

nonisolated enum ForwardPickerLayoutMetrics {
    static var width: CGFloat { InterfaceScale.metric(480) }
    static var height: CGFloat { InterfaceScale.metric(679) }
    static var iconSize: CGFloat { InterfaceScale.metric(32) }
}

nonisolated enum ForwardDestinationID: Hashable {
    case channel(ChannelID)
    case user(UserID)

    var accessibilityIdentifier: String {
        switch self {
        case .channel(let channelID): "forward-destination-channel-\(channelID)"
        case .user(let userID): "forward-destination-user-\(userID)"
        }
    }
}

nonisolated enum ForwardDestinationSelectionPolicy {
    static func searchPins(
        afterSelecting destinationID: ForwardDestinationID,
        query: String,
        selectedDestinationIDs: [ForwardDestinationID],
        existing: [ForwardDestinationID]
    ) -> [ForwardDestinationID] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return existing
        }
        let newlyPinned = [destinationID]
            + selectedDestinationIDs.filter { $0 != destinationID }
        let newlyPinnedSet = Set(newlyPinned)
        return newlyPinned + existing.filter { !newlyPinnedSet.contains($0) }
    }

    static func mergingPinnedDestinations(
        _ pins: [ForwardDestinationID],
        into destinations: [ForwardDestination],
        fallbacks: [ForwardDestination],
        limit: Int = 15
    ) -> [ForwardDestination] {
        guard !pins.isEmpty else { return Array(destinations.prefix(limit)) }
        let destinationsByID = Dictionary(
            (destinations + fallbacks).map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        var seen = Set<ForwardDestinationID>()
        return (pins + destinations.map(\.id)).compactMap { destinationID in
            guard seen.insert(destinationID).inserted else { return nil }
            return destinationsByID[destinationID]
        }.prefix(limit).map { $0 }
    }
}

nonisolated struct ForwardDestination: Identifiable, Equatable {
    // A destination appears in both the ordered corpus and search records.
    // Share its immutable payload instead of copying the largest enum case
    // into every slot in both indexes.
    indirect enum Kind: Equatable {
        case channel(Channel)
        case thread(MessageThreadSummary, parent: Channel?)
        case user(User, directMessage: Channel?)
    }

    let kind: Kind
    let guild: Guild?
    var titleOverride: String?
    var detailOverride: String?
    var unavailableReason: String?

    var id: ForwardDestinationID {
        switch kind {
        case .channel(let channel): .channel(channel.id)
        case .thread(let thread, _): .channel(thread.id)
        case .user(let user, _): .user(user.id)
        }
    }

    var resolvedChannelID: ChannelID? {
        switch kind {
        case .channel(let channel): channel.id
        case .thread(let thread, _): thread.id
        case .user(_, let directMessage): directMessage?.id
        }
    }

    var userID: UserID? {
        guard case .user(let user, _) = kind else { return nil }
        return user.id
    }

    var title: String {
        if let titleOverride { return titleOverride }
        return switch kind {
        case .channel(let channel): channel.name
        case .thread(let thread, _): thread.name
        case .user(let user, _): user.displayName
        }
    }

    var detail: String {
        if let detailOverride { return detailOverride }
        return switch kind {
        case .channel(let channel):
            channel.kind == .groupDirectMessage ? "" : guild?.name ?? "Channel"
        case .thread(_, let parent): parent?.name ?? guild?.name ?? "Thread"
        case .user(let user, _): user.tag
        }
    }

    var avatarURL: URL? {
        switch kind {
        case .channel(let channel):
            channel.kind == .groupDirectMessage ? channel.iconURL : guild?.iconURL
        case .thread: guild?.iconURL
        case .user(let user, _): user.avatarURL
        }
    }
}
