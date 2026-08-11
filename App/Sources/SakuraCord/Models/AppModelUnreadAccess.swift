import DiscordProtocol
import Foundation
import SakuraCordModels

@MainActor
extension AppModel {
    func applyImmediateUnreadAccessProjection(
        for channels: [Channel],
        affectedGuildIDs: Set<GuildID>?
    ) -> UnreadAccessProjection {
        let affectedChannels = affectedGuildIDs.map { guildIDs in
            channels.filter { channel in
                channel.guildID.map(guildIDs.contains) == true
            }
        } ?? channels
        let projection = unreadAccessProjection(for: affectedChannels)
        applyUnreadAccessProjection(
            projection,
            replacingChannelIDs: affectedGuildIDs == nil
                ? nil : Set(affectedChannels.map(\.id))
        )
        return projection
    }

    func applyUnreadAccessProjection(
        _ projection: UnreadAccessProjection,
        replacingChannelIDs: Set<ChannelID>? = nil
    ) {
        let updatedHiddenChannelIDs = Set(
            projection.accessByChannelID.compactMap { channelID, access in
                access == .hidden ? channelID : nil
            }
        )
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
        let updatedCheckingChannelIDs = Set(
            projection.accessByChannelID.compactMap { channelID, access in
                access == .checking ? channelID : nil
            }
        )
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
        // Resolve once per channel and share the result with unread and
        // sidebar projection.
        var accessByChannelID = [ChannelID: ConversationAccess](
            minimumCapacity: channels.count
        )
        var accessibilityByChannelID = [ChannelID: Bool](
            minimumCapacity: channels.count
        )
        let authoritativeAccessEvidence =
            readState.authoritativeAccessEvidenceChannelIDs()
        var permissionBasisByGuildID: [GuildID: ConversationPermissionBasis] = [:]
        var unresolvedGuildIDs: Set<GuildID> = []
        for channel in channels {
            let access: ConversationAccess
            if let guildID = channel.guildID {
                let permissionBasis: ConversationPermissionBasis?
                if let cached = permissionBasisByGuildID[guildID] {
                    permissionBasis = cached
                } else if unresolvedGuildIDs.contains(guildID) {
                    permissionBasis = nil
                } else if let resolved = conversationPermissionBasis(for: guildID) {
                    permissionBasisByGuildID[guildID] = resolved
                    permissionBasis = resolved
                } else {
                    unresolvedGuildIDs.insert(guildID)
                    permissionBasis = nil
                }
                access = conversationAccess(
                    for: channel,
                    permissionBasis: permissionBasis
                )
            } else {
                access = conversationAccess(for: channel)
            }
            accessByChannelID[channel.id] = access
            switch access {
            case .hidden:
                accessibilityByChannelID[channel.id] = false
            case .checking:
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
            accessibilityByChannelID: accessibilityByChannelID
        )
    }
}
