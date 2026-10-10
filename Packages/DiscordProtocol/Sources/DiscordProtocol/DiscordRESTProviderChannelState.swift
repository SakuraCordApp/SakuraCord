import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    public func channels(in guildID: GuildID?) async throws -> [Channel] {
        if let cached = cachedChannels[guildID] {
            return cached
        }
        guard let guildID else { return cachedChannels[nil] ?? [] }
        if let task = guildChannelTasks[guildID] {
            return try await task.value
        }
        let task = Task { [self] in
            let values: [ChannelDTO] = try await request("/guilds/\(guildID)/channels")
            cachedGuildChannelDTOs[guildID] = ChannelDTOStore(
                values.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            return try Self.domainChannels(values, guildID: guildID)
        }
        guildChannelTasks[guildID] = task
        do {
            let channels = try await task.value
            guildChannelTasks[guildID] = nil
            cachedChannels[guildID] = channels
            return channels
        } catch {
            guildChannelTasks[guildID] = nil
            throw error
        }
    }

    func privateChannel(id: ChannelID) -> Channel? {
        cachedChannels[nil]?.first { $0.id == id }
    }

    func upsertPrivateChannel(_ channel: Channel) {
        var channels = cachedChannels[nil] ?? []
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            var channel = channel
            // `cachedChannels[nil]` is reordered by last activity for the DM
            // sidebar. Preserve the independent READY/store insertion rank used
            // by Discord's equal-score forwarding search.
            channel.position = channels[index].position
            channels[index] = channel
        } else {
            var channel = channel
            channel.position = (channels.lazy.map(\.position).max() ?? -1) + 1
            channels.append(channel)
        }
        cachedChannels[nil] = channels
        continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
        continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
    }

    /// Removes a DM or group and publishes the list once; an already removed
    /// channel is left alone, so a later `CHANNEL_DELETE` does no extra work.
    func removePrivateChannel(_ channelID: ChannelID) {
        guard cachedChannels[nil]?.contains(where: { $0.id == channelID }) == true else { return }
        privateChannelRevisions[channelID, default: 0] &+= 1
        cachedChannels[nil]?.removeAll { $0.id == channelID }
        lazyPrivateChannelIDs.remove(channelID)
        continuation?.yield(.channelsChanged(guildID: nil, channels: cachedChannels[nil] ?? []))
        continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
    }

    func cachePrivateRecipientReferences(_ values: [ChannelDTO]) {
        for value in values {
            guard let channelID = ChannelID(value.id), value.type == 1 || value.type == 3,
                  let recipientIDs = value.recipientIDs ?? value.recipients?.map(\.id)
            else { continue }
            cachedPrivateRecipientIDsByChannelID[channelID] =
                DiscordPrivateRecipientOrdering.sortedIDs(
                    recipientIDs,
                    channelID: value.id,
                    channelType: value.type
                )
        }
    }

    func admitCachedPrivateRecipientUsersToMessageSearch() {
        for channel in cachedChannels[nil] ?? [] {
            for recipientID in cachedPrivateRecipientIDsByChannelID[channel.id] ?? [] {
                includeCachedGatewayUserInKnownUserStore(recipientID)
            }
        }
    }

    /// READY_SUPPLEMENTAL may carry a broad user hydration table, but Discord's
    /// UserStore only admits the raw recipients referenced by lazy private
    /// channels. Preserve their payload order independently of the deterministic
    /// recipient ordering used to render a group DM.
    func cacheLazyPrivateRecipientUsers(_ values: [ChannelDTO]) {
        for value in values where value.type == 1 || value.type == 3 {
            if let recipients = value.recipients {
                for recipient in recipients {
                    cacheGatewayUser(recipient)
                }
            } else {
                for recipientID in value.recipientIDs ?? [] {
                    includeCachedGatewayUserInKnownUserStore(recipientID)
                }
            }
        }
    }

    /// READY can describe private channels with only `recipient_ids`, while
    /// the corresponding UserStore records arrive in READY_SUPPLEMENTAL. The
    /// official client retains those references and resolves the recipients
    /// once its UserStore advances; do the same without issuing a REST read.
    func rehydratePrivateChannelRecipients() {
        guard var channels = cachedChannels[nil] else { return }
        var changed = false
        for index in channels.indices {
            let channel = channels[index]
            guard let recipientIDs = cachedPrivateRecipientIDsByChannelID[channel.id]
            else { continue }
            let recipients = recipientIDs.compactMap {
                cachedGatewayUsersByID[$0].flatMap { try? $0.domain() }
            }
            guard recipients != channel.recipients else { continue }
            channels[index].recipients = recipients
            if !channel.hasExplicitName {
                let recipientName = recipients
                    .map { cachedRelationshipNicknamesByUserID[$0.id] ?? $0.displayName }
                    .joined(separator: ", ")
                if !recipientName.isEmpty {
                    channels[index].name = recipientName
                } else if channel.kind == .groupDirectMessage,
                          let ownerID = channel.ownerID,
                          let owner = cachedGatewayUsersByID[ownerID.description]
                            .flatMap({ try? $0.domain() })
                {
                    channels[index].name = "\(owner.displayName)'s Group"
                } else {
                    channels[index].name = channel.kind == .groupDirectMessage
                        ? "Group Direct Message" : "Direct Message"
                }
            }
            changed = true
        }
        guard changed else { return }
        cachedChannels[nil] = channels
        continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
        continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
    }

    func promotePrivateChannel(
        channelID: ChannelID,
        lastMessageID: MessageID
    ) {
        var channels = cachedChannels[nil] ?? []
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else {
            return
        }
        var channel = channels.remove(at: index)
        channel.lastMessageID = lastMessageID
        channels.insert(channel, at: 0)
        cachedChannels[nil] = channels
        continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
    }

    func privateMembersInChannelOrder() -> [Member] {
        var seen: Set<UserID> = []
        return membersWithCurrentStatus((cachedChannels[nil] ?? []).flatMap(\.recipients).compactMap { user in
            guard seen.insert(user.id).inserted else { return nil }
            var member = cachedPrivateMembersByID[user.id]
                ?? Member(user: user, roleName: "Direct Message", status: .offline)
            // READY presence records only contain a partial user. Keep DM
            // identity sourced from the hydrated private-channel recipient.
            member.user = user
            // Private conversations show a friend nickname in place of the
            // name, as a guild nickname does in its server.
            if let nickname = cachedRelationshipNicknamesByUserID[user.id] {
                member.globalDisplayName = user.displayName
                member.user.displayName = nickname
            }
            return member
        })
    }

    func cachePrivatePresence(_ update: PresenceUpdateDTO) {
        guard update.guildID == nil,
              let userID = UserID(update.user.id),
              let status = PresenceStatus(rawValue: update.status)
        else { return }
        let user =
            cachedChannels[nil]?.lazy.flatMap(\.recipients)
                .first(where: { $0.id == userID })
                ?? cachedGatewayUsersByID[update.user.id].flatMap { try? $0.domain() }
        guard let user else { return }
        var member =
            cachedPrivateMembersByID[userID]
                ?? Member(user: user, roleName: "Direct Message", status: status)
        member.user = user
        member.status = status
        if let clientStatus = update.clientStatus {
            member.isMobileOnly = clientStatus.isMobileOnly
        }
        if let activities = update.activities {
            let primaryActivity = activities.memberListActivity
            member.customStatus = activities.first(where: { $0.type == 4 })?.displayText
            member.activityText =
                primaryActivity?.displayText
                    ?? member.customStatus
            member.isListeningToMusic = primaryActivity?.type == 2
        }
        cachedPrivateMembersByID[userID] = member
    }

    static func orderedPrivateChannels(_ channels: [Channel]) -> [Channel] {
        channels.sorted { lhs, rhs in
            let lhsActivity = lhs.lastMessageID?.rawValue ?? lhs.id.rawValue
            let rhsActivity = rhs.lastMessageID?.rawValue ?? rhs.id.rawValue
            return lhsActivity > rhsActivity
        }
    }

    static func coalescingChannelSnapshots(_ previous: ClientEvent, _ next: ClientEvent) -> ClientEvent? {
        guard case let .channelsChanged(previousGuild, previousChannels) = previous,
              case let .channelsChanged(nextGuild, nextChannels) = next,
              previousGuild == nextGuild,
              previousChannels.count == nextChannels.count
        else { return nil }
        // Channel snapshots also drive cooldown, access, and removal effects.
        // Only name/topic edits are replaceable; every other change is a barrier.
        for (previousChannel, nextChannel) in zip(previousChannels, nextChannels) {
            var presentationOnly = previousChannel
            presentationOnly.name = nextChannel.name
            presentationOnly.topic = nextChannel.topic
            guard presentationOnly == nextChannel else { return nil }
        }
        return next
    }

    func publishGuildChannelUpdate(_ dto: ChannelDTO, guildID: GuildID) {
        // Category changes affect their children. Ordinary updates only need
        // to convert the changed channel, not every channel in the server.
        guard dto.type != 4, var channels = cachedChannels[guildID] else {
            publishGuildChannels(guildID)
            return
        }
        let category = dto.parentID.flatMap { cachedGuildChannelDTOs[guildID]?[$0] }
            .flatMap { $0.type == 4 ? $0 : nil }
        guard let channel = try? dto.domain(
            guildID: guildID, categoryName: category?.name,
            categoryPosition: category?.position ?? -1
        ) else { return }
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            let previous = channels[index]
            guard previous != channel else { return }
            channels[index] = channel
            if previous.categoryPosition != channel.categoryPosition || previous.position != channel.position {
                channels.sort(by: Self.guildChannelPrecedes)
            }
        } else {
            channels.append(channel)
            channels.sort(by: Self.guildChannelPrecedes)
        }
        cachedChannels[guildID] = channels
        continuation?.yield(.channelsChanged(guildID: guildID, channels: channels))
    }

    static func domainChannels(_ values: [ChannelDTO], guildID: GuildID) throws -> [Channel] {
        let categories = Dictionary(
            uniqueKeysWithValues: values.filter { $0.type == 4 }.map { ($0.id, $0) }
        )
        return try values.filter { $0.type != 4 && !$0.isThread }.map { dto in
            let category = dto.parentID.flatMap { categories[$0] }
            return try dto.domain(
                guildID: guildID,
                categoryName: category?.name,
                categoryPosition: category?.position ?? -1
            )
        }.sorted(by: guildChannelPrecedes)
    }

    private static func guildChannelPrecedes(_ lhs: Channel, _ rhs: Channel) -> Bool {
        if lhs.categoryPosition != rhs.categoryPosition {
            return lhs.categoryPosition < rhs.categoryPosition
        }
        return lhs.position < rhs.position
    }
}
