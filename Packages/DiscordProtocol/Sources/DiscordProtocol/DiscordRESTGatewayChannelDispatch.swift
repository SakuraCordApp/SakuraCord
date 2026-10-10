import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func handleGatewayChannelEvent(
        name: String,
        body: JSONValue
    ) async -> Bool {
        switch name {
        case "CHANNEL_CREATE", "CHANNEL_UPDATE":
            await handleChannelCreateDispatch(name: name, body: body)
        case "CHANNEL_RECIPIENT_ADD", "CHANNEL_RECIPIENT_REMOVE":
            await handleChannelRecipientAddDispatch(name: name, body: body)
        case "CHANNEL_DELETE":
            await handleChannelDeleteDispatch(name: name, body: body)
        case "CHANNEL_PINS_UPDATE":
            await handleChannelPinsUpdateDispatch(name: name, body: body)
        default:
            return false
        }
        return true
    }

    func handleChannelCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let dto = try? JSONValueDecoder().decode(ChannelDTO.self, from: body) else {
            return
        }
        if dto.isThread {
            ingestForumThreads(
                [dto],
                fallbackGuildID: dto.guildID.flatMap(GuildID.init),
                advancesParentLatestThreadID: name == "CHANNEL_CREATE"
            )
            return
        }
        if let guildID = dto.guildID.flatMap(GuildID.init) {
            if name == "CHANNEL_CREATE", let channelID = ChannelID(dto.id) {
                appendQuickSwitcherChannelStoreOrder([channelID])
                persistQuickSwitcherChannelStoreCache()
            }
            cachedGuildChannelDTOs[guildID, default: [:]][dto.id] = dto
            publishGuildChannelUpdate(dto, guildID: guildID)
            return
        }
        if let recipients = dto.recipients {
            cacheLiveSearchUsers(recipients)
        }
        if let channelID = ChannelID(dto.id) {
            lazyPrivateChannelIDs.remove(channelID)
            privateChannelRevisions[channelID, default: 0] &+= 1
        }
        cachePrivateRecipientReferences([dto])
        guard dto.type == 1 || dto.type == 3,
              var channel = try? privateChannel(from: dto)
        else { return }
        if name == "CHANNEL_UPDATE", let existing = privateChannel(id: channel.id) {
            // An explicit `null` clears a group's name or icon; only an
            // absent field keeps the cached value.
            let fields: Set<String> = if case let .object(object) = body { Set(object.keys) } else { [] }
            if dto.recipients == nil, dto.recipientIDs == nil {
                channel.recipients = existing.recipients
            }
            if !fields.contains("name"), dto.recipients == nil, dto.recipientIDs == nil {
                channel.name = existing.name
                channel.hasExplicitName = existing.hasExplicitName
            }
            if dto.ownerID == nil {
                channel.ownerID = existing.ownerID
            }
            if !fields.contains("icon") {
                channel.iconURL = existing.iconURL
            }
            if dto.lastMessageID == nil {
                channel.lastMessageID = existing.lastMessageID
            }
        }
        upsertPrivateChannel(applyingFriendNicknames(to: channel))
    }

    func handleChannelRecipientAddDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(
            GatewayChannelRecipientDTO.self,
            from: body
        ),
            let channelID = ChannelID(update.channelID),
            var channel = privateChannel(id: channelID),
            let user = try? update.user.domain()
        else { return }
        privateChannelRevisions[channelID, default: 0] &+= 1
        if name == "CHANNEL_RECIPIENT_ADD" {
            cacheLiveSearchUsers([update.user])
            if !channel.recipients.contains(where: { $0.id == user.id }) {
                channel.recipients.append(user)
            }
            channel.kind = .groupDirectMessage
        } else {
            channel.recipients.removeAll { $0.id == user.id }
        }
        channel.recipients = DiscordPrivateRecipientOrdering.sortedDomainUsers(
            channel.recipients,
            channelID: update.channelID,
            channelType: channel.kind == .groupDirectMessage ? 3 : 1
        )
        cachedPrivateRecipientIDsByChannelID[channelID] =
            channel.recipients.map { $0.id.description }
        upsertPrivateChannel(applyingFriendNicknames(to: channel))
    }

    func handleChannelDeleteDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let deleted = try? JSONValueDecoder().decode(
                GatewayDeletedEntityDTO.self, from: body
            ), let channelID = ChannelID(deleted.id)
        else { return }
        invalidateApplicationCommandCatalog(.channel(channelID))
        let guildID = deleted.guildID.flatMap(GuildID.init)
            ?? cachedGuildChannelDTOs.first(where: { $0.value[deleted.id] != nil })?.key
        if let guildID {
            cachedGuildChannelDTOs[guildID]?[deleted.id] = nil
            cachedForumPosts[channelID] = nil
            for parentID in cachedForumPosts.keys {
                cachedForumPosts[parentID]?[channelID] = nil
            }
            publishGuildChannels(guildID)
            return
        }
        removePrivateChannel(channelID)
    }

    func handleChannelPinsUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let update = try? JSONValueDecoder().decode(
                GatewayChannelPinsUpdateDTO.self, from: body
            ), let channelID = ChannelID(update.channelID)
        else { return }
        let timestamp = update.lastPinTimestamp.flatMap(DiscordDate.parse)
        if let guildID = update.guildID.flatMap(GuildID.init) {
            cachedGuildChannelDTOs[guildID]?[update.channelID]?.lastPinTimestamp =
                update.lastPinTimestamp
            publishGuildChannels(guildID)
        } else if var channels = cachedChannels[nil],
                  let index = channels.firstIndex(where: { $0.id == channelID })
        {
            channels[index].lastPinTimestamp = timestamp
            cachedChannels[nil] = channels
            continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
        }
        continuation?.yield(.channelPinsInvalidated(channelID: channelID))
    }
}
