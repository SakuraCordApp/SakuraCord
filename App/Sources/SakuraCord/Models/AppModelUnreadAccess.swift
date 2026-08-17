import DiscordProtocol
import Foundation
import SakuraCordModels

nonisolated struct UnreadAccessProjection: Sendable {
    let accessByChannelID: [ChannelID: ConversationAccess]
    let accessibilityByChannelID: [ChannelID: Bool]
    let hiddenChannelIDs: Set<ChannelID>
    let checkingChannelIDs: Set<ChannelID>

    init(
        accessByChannelID: [ChannelID: ConversationAccess],
        accessibilityByChannelID: [ChannelID: Bool],
        hiddenChannelIDs: Set<ChannelID>? = nil,
        checkingChannelIDs: Set<ChannelID>? = nil
    ) {
        self.accessByChannelID = accessByChannelID
        self.accessibilityByChannelID = accessibilityByChannelID
        self.hiddenChannelIDs = hiddenChannelIDs ?? Set(
            accessByChannelID.compactMap { channelID, access in
                access == .hidden ? channelID : nil
            }
        )
        self.checkingChannelIDs = checkingChannelIDs ?? Set(
            accessByChannelID.compactMap { channelID, access in
                access == .checking ? channelID : nil
            }
        )
    }
}

nonisolated struct UnreadAccessProjectionSource: Sendable {
    let channels: [Channel]
    let authoritativeAccessEvidence: Set<ChannelID>
    let permissionBasisByGuildID: [GuildID: ConversationPermissionBasis]

    func prepare() -> UnreadAccessProjection {
        AppPerformanceSignposts.measureSync("UnreadAccessChannelResolution") {
            var accessByChannelID = [ChannelID: ConversationAccess](
                minimumCapacity: channels.count
            )
            var accessibilityByChannelID = [ChannelID: Bool](
                minimumCapacity: channels.count
            )
            var hiddenChannelIDs: Set<ChannelID> = []
            var checkingChannelIDs: Set<ChannelID> = []
            hiddenChannelIDs.reserveCapacity(channels.count / 4)
            checkingChannelIDs.reserveCapacity(channels.count / 4)
            for channel in channels {
                let access = AppModel.resolveConversationAccess(
                    for: channel,
                    permissionBasis: channel.guildID.flatMap {
                        permissionBasisByGuildID[$0]
                    }
                )
                accessByChannelID[channel.id] = access
                switch access {
                case .hidden:
                    hiddenChannelIDs.insert(channel.id)
                    accessibilityByChannelID[channel.id] = false
                case .checking:
                    checkingChannelIDs.insert(channel.id)
                    // Untouched guilds can remain in permission-checking state
                    // until activation loads their member roles. Preserve unread
                    // supplied by Discord's authoritative account read state,
                    // without admitting channels for which no such evidence exists.
                    accessibilityByChannelID[channel.id] =
                        authoritativeAccessEvidence.contains(channel.id)
                case .readable:
                    accessibilityByChannelID[channel.id] = true
                }
            }
            return UnreadAccessProjection(
                accessByChannelID: accessByChannelID,
                accessibilityByChannelID: accessibilityByChannelID,
                hiddenChannelIDs: hiddenChannelIDs,
                checkingChannelIDs: checkingChannelIDs
            )
        }
    }
}

@MainActor
extension AppModel {
    nonisolated static func changedCurrentUserRoleGuildIDs(
        from previous: [GuildID: Set<RoleID>],
        to current: [GuildID: Set<RoleID>]
    ) -> Set<GuildID> {
        Set(previous.keys).union(current.keys).filter {
            previous[$0] != current[$0]
        }
    }

    func refreshUnreadAccessAfterCurrentRoleSnapshot(
        affectedGuildIDs: Set<GuildID>
    ) {
        AppPerformanceSignposts.measureSync(
            "UnreadAccessTriggerCurrentRolesSnapshot"
        ) {
            refreshUnreadPresentation(
                appliesAccessImmediately: true,
                accessAffectedGuildIDs: affectedGuildIDs
            )
        }
    }

    func refreshUnreadAccessAfterChannelsChanged(
        guildID: GuildID?,
        channels: [Channel],
        previousChannels: [Channel]
    ) {
        let previousByID = Dictionary(
            uniqueKeysWithValues: previousChannels.lazy
                .filter { $0.guildID == guildID }
                .map { ($0.id, $0) }
        )
        let currentByID = Dictionary(
            uniqueKeysWithValues: channels.map { ($0.id, $0) }
        )
        let affectedChannelIDs = Set(previousByID.keys)
            .union(currentByID.keys)
            .filter {
                !Self.hasEqualChannelAccessInputs(
                    previousByID[$0],
                    currentByID[$0]
                )
            }
        AppPerformanceSignposts.measureSync("UnreadAccessTriggerChannelsChanged") {
            guard !affectedChannelIDs.isEmpty else {
                refreshUnreadPresentation()
                return
            }
            refreshUnreadPresentation(
                appliesAccessImmediately: true,
                accessAffectedGuildIDs: [],
                accessAffectedChannelIDs: affectedChannelIDs,
                accessReplacingChannelIDs: affectedChannelIDs,
                accessAffectedChannels: channels.filter {
                    affectedChannelIDs.contains($0.id)
                }
            )
        }
    }

    func refreshUnreadAccessAfterSnapshotChanged(
        previousSnapshot: BootstrapSnapshot?,
        previousGuildsByID: [GuildID: Guild],
        previousAccessEvidence: Set<ChannelID>,
        currentSnapshot: BootstrapSnapshot
    ) {
        let previousChannelsByID = Dictionary(
            uniqueKeysWithValues: (previousSnapshot?.channels ?? []).map {
                ($0.id, $0)
            }
        )
        let currentChannelsByID = Dictionary(
            uniqueKeysWithValues: currentSnapshot.channels.map { ($0.id, $0) }
        )
        let currentGuildsByID = Dictionary(
            uniqueKeysWithValues: currentSnapshot.guilds.map { ($0.id, $0) }
        )
        let affectedGuildIDs = Set(previousGuildsByID.keys)
            .union(currentGuildsByID.keys)
            .filter {
                !Self.hasEqualGuildAccessInputs(
                    previousGuildsByID[$0],
                    currentGuildsByID[$0]
                )
            }
        let affectedChannelIDs = Set(previousChannelsByID.keys)
            .union(currentChannelsByID.keys)
            .filter {
                !Self.hasEqualChannelAccessInputs(
                    previousChannelsByID[$0],
                    currentChannelsByID[$0]
                )
            }
            .union(
                previousAccessEvidence.symmetricDifference(
                    readState.authoritativeAccessEvidenceChannelIDs()
                )
            )
        let replacingChannelIDs = affectedChannelIDs.union(
            previousChannelsByID.values.lazy
                .filter { $0.guildID.map(affectedGuildIDs.contains) == true }
                .map(\.id)
        ).union(
            currentSnapshot.channels.lazy
                .filter { $0.guildID.map(affectedGuildIDs.contains) == true }
                .map(\.id)
        )
        AppPerformanceSignposts.measureSync("UnreadAccessTriggerSnapshotChanged") {
            if previousSnapshot?.currentUser.id != currentSnapshot.currentUser.id {
                refreshUnreadPresentation(appliesAccessImmediately: true)
            } else if affectedGuildIDs.isEmpty, affectedChannelIDs.isEmpty {
                refreshUnreadPresentation()
            } else {
                refreshUnreadPresentation(
                    appliesAccessImmediately: true,
                    accessAffectedGuildIDs: Set(affectedGuildIDs),
                    accessAffectedChannelIDs: affectedChannelIDs,
                    accessReplacingChannelIDs: replacingChannelIDs
                )
            }
        }
    }

    func refreshUnreadAccessAfterGuildLayoutChanged(
        previousGuildsByID: [GuildID: Guild],
        currentGuilds: [Guild]
    ) {
        let retainedGuildIDs = Set(currentGuilds.map(\.id))
        let affectedGuildIDs = Set(
            currentGuilds.lazy.filter {
                !Self.hasEqualGuildAccessInputs(
                    previousGuildsByID[$0.id],
                    $0
                )
            }.map(\.id)
        ).union(previousGuildsByID.keys.filter { !retainedGuildIDs.contains($0) })
        AppPerformanceSignposts.measureSync("UnreadAccessTriggerGuildLayoutChanged") {
            if affectedGuildIDs.isEmpty {
                refreshUnreadPresentation()
            } else {
                refreshUnreadPresentation(
                    appliesAccessImmediately: true,
                    accessAffectedGuildIDs: affectedGuildIDs
                )
            }
        }
    }

    nonisolated static func hasEqualGuildAccessInputs(
        _ previous: Guild?,
        _ current: Guild?
    ) -> Bool {
        switch (previous, current) {
        case (nil, nil):
            true
        case let (previous?, current?):
            previous.id == current.id
                && previous.isOwnedByCurrentUser
                    == current.isOwnedByCurrentUser
                && previous.currentUserPermissions
                    == current.currentUserPermissions
        default:
            false
        }
    }

    nonisolated static func hasEqualChannelAccessInputs(
        _ previous: Channel?,
        _ current: Channel?
    ) -> Bool {
        switch (previous, current) {
        case (nil, nil):
            true
        case let (previous?, current?):
            previous.id == current.id
                && previous.guildID == current.guildID
                && previous.kind == current.kind
                && previous.permissionOverwrites
                    == current.permissionOverwrites
                && previous.isOfficialSystemDirectMessage
                    == current.isOfficialSystemDirectMessage
        default:
            false
        }
    }

    func applyImmediateUnreadAccessProjection(
        for channels: [Channel],
        affectedGuildIDs: Set<GuildID>?,
        affectedChannelIDs: Set<ChannelID> = [],
        replacingChannelIDs: Set<ChannelID>? = nil,
        affectedChannels suppliedAffectedChannels: [Channel]? = nil
    ) -> UnreadAccessProjection {
        unreadAccessProjectionGeneration &+= 1
        let affectedChannels = AppPerformanceSignposts.measureSync(
            "UnreadAccessAffectedChannelProjection"
        ) {
            suppliedAffectedChannels
                ?? affectedGuildIDs.map { guildIDs in
                    channels.filter { channel in
                        affectedChannelIDs.contains(channel.id)
                            || channel.guildID.map(guildIDs.contains) == true
                    }
                }
                ?? channels
        }
        let projection = AppPerformanceSignposts.measureSync(
            "UnreadAccessResolution"
        ) {
            unreadAccessProjection(for: affectedChannels)
        }
        AppPerformanceSignposts.measureSync("UnreadAccessApplication") {
            applyUnreadAccessProjection(
                projection,
                replacingChannelIDs: affectedGuildIDs == nil
                    ? nil
                    : replacingChannelIDs
                        ?? Set(projection.accessByChannelID.keys)
            )
        }
        return projection
    }

    func prepareBootstrapUnreadAccessProjection(
        account: AppModelAccountSession
    ) async -> UnreadAccessProjection? {
        while !Task.isCancelled {
            guard isCurrentAccountSession(account) else { return nil }
            guard let channels = snapshot?.channels else { return nil }
            let generation = unreadAccessProjectionGeneration
            let source = AppPerformanceSignposts.measureSync(
                "BootstrapUnreadAccessSourceSnapshot"
            ) {
                unreadAccessProjectionSource(for: channels)
            }
            let worker = Task.detached(priority: .userInitiated) {
                source.prepare()
            }
            let projection = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard isCurrentAccountSession(account) else { return nil }
            guard !Task.isCancelled else { return nil }
            if unreadAccessProjectionGeneration == generation {
                return projection
            }
        }
        return nil
    }

    func applyUnreadAccessProjection(
        _ projection: UnreadAccessProjection,
        replacingChannelIDs: Set<ChannelID>? = nil
    ) {
        let updatedHiddenChannelIDs = projection.hiddenChannelIDs
        let projectedHiddenChannelIDs = if let replacingChannelIDs {
            hiddenChannelIDs.subtracting(replacingChannelIDs)
                .union(updatedHiddenChannelIDs)
        } else {
            updatedHiddenChannelIDs
        }
        let selectedChannelBecameHidden = selectedChannelID.map {
            projectedHiddenChannelIDs.contains($0)
                && !hiddenChannelIDs.contains($0)
        } ?? false
        let updatedCheckingChannelIDs = projection.checkingChannelIDs
        let projectedCheckingChannelIDs = if let replacingChannelIDs {
            checkingChannelIDs.subtracting(replacingChannelIDs)
                .union(updatedCheckingChannelIDs)
        } else {
            updatedCheckingChannelIDs
        }
        let selectedChannelBecameReadable = selectedChannelID.map { channelID in
            checkingChannelIDs.contains(channelID)
                && projection.accessByChannelID[channelID]?.isReadable == true
        } ?? false
        if projectedHiddenChannelIDs != hiddenChannelIDs {
            hiddenChannelIDs = projectedHiddenChannelIDs
        }
        if projectedCheckingChannelIDs != checkingChannelIDs {
            checkingChannelIDs = projectedCheckingChannelIDs
        }
        let redirectsAutomaticSelection =
            pendingAutomaticChannelAccessID == selectedChannelID
            && selectedChannelID.map(projectedHiddenChannelIDs.contains) == true
        if redirectsAutomaticSelection {
            pendingAutomaticChannelAccessID = nil
            selectedChannelID = Self.preferredInitialChannelID(
                in: visibleChannels.filter {
                    projection.accessByChannelID[$0.id]?.isReadable == true
                }
            )
        } else if pendingAutomaticChannelAccessID == selectedChannelID,
                  selectedChannelID.map(projectedCheckingChannelIDs.contains) != true
        {
            pendingAutomaticChannelAccessID = nil
        }
        if selectedChannelBecameHidden, !redirectsAutomaticSelection {
            switch selectedChannel?.kind {
            case .forum:
                beginForumLoad()
            case .voice:
                break
            default:
                beginSelectedChannelLoad()
            }
        }
        if selectedChannelBecameReadable {
            if selectedChannel?.kind == .forum {
                beginForumLoad()
            } else if selectedChannel?.kind != .voice {
                refreshSelectedChannelPreservingHistory()
            }
        }
        readState.applyAccessibility(
            projection.accessibilityByChannelID
        )
    }

    func unreadAccessProjection(
        for channels: [Channel]
    ) -> UnreadAccessProjection {
        // Permission resolution walks guild roles and channel overwrites.
        // Resolve once per guild and channel, then share the result with unread
        // and sidebar projection. Bootstrap can prepare this value-semantic
        // source away from the main actor without delaying access publication.
        unreadAccessProjectionSource(for: channels).prepare()
    }

    func unreadAccessProjectionSource(
        for channels: [Channel]
    ) -> UnreadAccessProjectionSource {
        let authoritativeAccessEvidence = AppPerformanceSignposts.measureSync(
            "UnreadAccessEvidenceProjection"
        ) {
            readState.authoritativeAccessEvidenceChannelIDs()
        }
        let permissionBasisByGuildID = AppPerformanceSignposts.measureSync(
            "UnreadAccessPermissionBasisProjection"
        ) {
            var values: [GuildID: ConversationPermissionBasis] = [:]
            for guildID in Set(channels.compactMap(\.guildID)) {
                if let basis = conversationPermissionBasis(for: guildID) {
                    values[guildID] = basis
                }
            }
            return values
        }
        return UnreadAccessProjectionSource(
            channels: channels,
            authoritativeAccessEvidence: authoritativeAccessEvidence,
            permissionBasisByGuildID: permissionBasisByGuildID
        )
    }
}
