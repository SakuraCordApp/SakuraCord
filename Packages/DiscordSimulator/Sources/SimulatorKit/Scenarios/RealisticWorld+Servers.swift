import Foundation

/// One generated server per `ServerProfile`: its community, roles, emoji,
/// members, channels, latest messages, read state and notification settings.
extension RealisticWorld {
    struct ServerDraft {
        var guildID: Snowflake
        var kind: CommunityKind
        var founded: Date
        var members: [Snowflake]
        /// Channels that hold messages, text channels first: they carry most of the traffic.
        var messageChannels: [Snowflake] = []
        var textChannels = 0
        var categories: [Snowflake] = []
        var voiceChannels: [Snowflake] = []
        var forums: [Snowflake] = []
    }

    mutating func addServer(_ profile: ServerProfile, index: Int) async throws {
        var rng = random.fork("server-\(index)")
        let kind = CommunityKind.pick(memberCount: profile.memberCount, &rng)
        let founded = world.epoch.addingTimeInterval(-Double(200 + rng.next() % 2_400) * 86_400)
        let guildID = await world.nextID(at: founded)
        // Huge servers report their real size but hold only the members the account meets.
        let held = min(profile.memberCount, 20 + Int(rng.next() % 40))
        let members = [me] + people.shuffledPrefix(max(1, held - 1), using: &rng)
        // Each server gets a name of its own, as people tell their servers apart by name.
        var name = DemoText.communityName(kind, &rng)
        var attempt = 1
        while serverNames.contains(name) {
            attempt += 1
            name = attempt > 8 ? "\(DemoText.communityName(kind, &rng)) \(attempt)" : DemoText.communityName(kind, &rng)
        }
        serverNames.insert(name)
        var guild = Guild(id: guildID, name: name, ownerID: members.count > 1 ? members[1] : me)
        // About one server in thirty has no icon and shows its initials, as in captured READYs.
        if !rng.chance(0.03) {
            let icon = bench.builder.hash(seed: rng.next())
            await world.setArt(.drawing(rng.pick(kind.iconMotifs), background: rng.pick(Self.iconBackgrounds)), forHash: icon)
            guild.icon = icon
        }
        guild.approximateMemberCount = profile.memberCount > members.count ? profile.memberCount : nil
        // Big servers have a small share of members online at once.
        guild.approximatePresenceCount = guild.approximateMemberCount.map { max(members.count, Int(Double($0) * (0.08 + rng.unit() * 0.17))) }
        let roles = await roles(profile.roles - 1, kind: kind, founded: founded, &rng)
        guild.roles = [WorldBuilder.everyoneRole(guildID: guildID)] + roles
        for (offset, id) in members.enumerated() {
            var member = Member(userID: id, joinedAt: founded.addingTimeInterval(Double(offset) * 86_400 * rng.unit()))
            member.roles = guild.roles.dropFirst(id == guild.ownerID ? 1 : 3).map(\.id).shuffledPrefix(Int(rng.next() % 3), using: &rng).sorted()
            guild.members[id] = member
            guild.memberOrder.append(id)
        }
        guild.boosts = boosts(profile, members: members, founded: founded, &rng)
        guild.features = (profile.community ? ["COMMUNITY", "NEWS", "THREADS_ENABLED"] : [])
            + (profile.discoverable ? ["DISCOVERABLE"] : []) + WorldBuilder.boostFeatures(tier: guild.premiumTier)
        guild.emojis = await emojis(profile, kind: kind, owner: guild.ownerID, founded: founded, &rng)
        guild.stickers = await stickers(profile.stickers, kind: kind, founded: founded, &rng)
        await world.addGuild(guild)
        servers.append(guildID)

        var draft = ServerDraft(guildID: guildID, kind: kind, founded: founded, members: members)
        await addChannels(profile, &draft, &rng)
        if var updated = await world.guilds[guildID] {
            updated.systemChannelID = draft.messageChannels.first
            await world.addGuild(updated)
        }
        try await addMessages(profile, draft, &rng)
        try await addThreads(profile.activeThreads, draft, &rng)
        try await addForumPosts(profile.forumPosts, draft, &rng)
        await addEvents(profile.scheduledEvents, draft, &rng)
        try await addSettings(profile, draft, &rng)
        await seatVoice(profile.peopleInVoice, draft, &rng)
        let others = draft.members.filter { $0 != me }
        let shares = profile.activity.channelShares
        await world.addLiveActivity(LiveActivityPlan(
            guildID: guildID, kind: kind, channels: draft.messageChannels, shares: shares.isEmpty ? [] : shares.map { $0 / shares.reduce(0, +) },
            voiceChannels: draft.voiceChannels, members: others, rates: profile.activity, voiceMoves: Double(profile.peopleInVoice) * 3
        ))
        if let reported = guild.approximateMemberCount {
            // Directories never overlap: each server's people start a million indices apart.
            await world.addMemberDirectory(guildID, MemberDirectory(firstIndex: 1_000_000 * (index + 1), size: min(reported - members.count, 2_000),
                                                                    founded: founded, roles: roles.filter { !$0.hoist }.map(\.id)))
        }
    }

    private static let iconBackgrounds: [UInt32] = [0x5865f2, 0x2e7d32, 0xc62828, 0x6a1b9a, 0x00838f, 0xef6c00, 0x37474f,
                                                     0xad1457, 0x1565c0, 0x558b2f, 0x4e342e, 0x283593, 0x00695c, 0xf9a825]

    private func roles(_ count: Int, kind: CommunityKind, founded: Date, _ rng: inout SeededRandom) async -> [Role] {
        var roles: [Role] = []
        for index in 0 ..< max(0, count) {
            var role = Role(id: await world.nextID(at: founded.addingTimeInterval(Double(index))),
                            name: DemoText.numbered(kind.bank.roles, index))
            role.position = count - index
            role.color = index < 12 ? rng.pick(Self.roleColors) : 0
            role.hoist = index < 4
            role.permissions = index == 0 ? [.administrator] : index < 3 ? Permissions.moderator.union(.everyoneDefault) : .everyoneDefault
            role.mentionable = index > 3 && rng.chance(0.3)
            roles.append(role)
        }
        return roles
    }

    private static let roleColors = [0xe91e63, 0x9b59b6, 0x3498db, 0x1abc9c, 0x2ecc71, 0xf1c40f, 0xe67e22, 0xe74c3c, 0x95a5a6, 0xfd79a8, 0x74b9ff]

    /// Boosts that land in the profile's tier (thresholds 2, 7 and 14).
    private func boosts(_ profile: ServerProfile, members: [Snowflake], founded: Date, _ rng: inout SeededRandom) -> [(userID: Snowflake, since: Date)] {
        let range = [0 ... 1, 2 ... 6, 7 ... 13, 14 ... max(14, profile.boostCount)][min(3, max(0, profile.boostTier))]
        let count = min(range.upperBound, max(range.lowerBound, profile.boostCount))
        return (0 ..< count).map { _ in (rng.pick(members), founded.addingTimeInterval(rng.unit() * world.epoch.timeIntervalSince(founded))) }
    }

    private func emojis(_ profile: ServerProfile, kind: CommunityKind, owner: Snowflake, founded: Date, _ rng: inout SeededRandom) async -> [Emoji] {
        var emojis: [Emoji] = []
        for index in 0 ..< profile.emojis {
            let id = await world.nextID(at: founded.addingTimeInterval(3_600 + Double(index)))
            let emoji = Emoji(id: id, name: DemoText.numbered(kind.bank.emoji, index).replacingOccurrences(of: "-", with: "_"),
                              animated: index < profile.animatedEmojis, creatorID: owner)
            // Drawn on first request: a big account has thousands of emoji.
            let seed = rng.next()
            for ext in ["png", "webp"] { await world.storeLazyMedia("/emojis/\(id).\(ext)") { (MediaGenerator.emojiPNG(seed: seed), "image/png") } }
            if emoji.animated {
                await world.storeLazyMedia("/emojis/\(id).gif") { (MediaGenerator.animatedGIF(seed: seed, motif: defaultMotif(seed)), "image/gif") }
            }
            emojis.append(emoji)
        }
        return emojis
    }

    private func stickers(_ count: Int, kind: CommunityKind, founded: Date, _ rng: inout SeededRandom) async -> [Sticker] {
        var stickers: [Sticker] = []
        for index in 0 ..< count {
            let id = await world.nextID(at: founded.addingTimeInterval(7_200 + Double(index)))
            let name = DemoText.numbered(kind.bank.emoji, index)
            stickers.append(Sticker(id: id, name: name, description: nil, tags: name))
            let seed = rng.next()
            for ext in ["png", "webp"] { await world.storeLazyMedia("/stickers/\(id).\(ext)") { (MediaGenerator.stickerPNG(seed: seed), "image/png") } }
        }
        return stickers
    }

    private func addChannels(_ profile: ServerProfile, _ draft: inout ServerDraft, _ rng: inout SeededRandom) async {
        let bank = draft.kind.bank
        var used: [String: Int] = [:]
        func name(_ names: [String]) -> String {
            let key = names.first ?? ""
            defer { used[key, default: 0] += 1 }
            return DemoText.numbered(names, used[key, default: 0])
        }
        var restricted = profile.restrictedChannels
        var hasPrivateChannel = false
        for (position, layout) in profile.categories.enumerated() {
            var parentID: Snowflake?
            if position > 0 {
                var category = Channel(id: await world.nextID(at: draft.founded.addingTimeInterval(60)), type: .category,
                                       guildID: draft.guildID, name: name(bank.categories))
                category.position = position
                await world.addChannel(category)
                parentID = category.id
                draft.categories.append(category.id)
            }
            var index = 0
            for kind in ["announcement", "text", "forum", "media", "voice", "stage"] {
                for _ in 0 ..< layout[kind, default: 0] {
                    let type: ChannelType = ["announcement": .announcement, "forum": .forum, "media": .media, "voice": .voice, "stage": .stage][kind] ?? .text
                    let names = switch type {
                    case .announcement: bank.announcements
                    case .forum, .media: bank.forums
                    case .voice, .stage: bank.voice
                    default: bank.text
                    }
                    var channel = Channel(id: await world.nextID(at: draft.founded.addingTimeInterval(120)), type: type,
                                          guildID: draft.guildID, name: type == .voice || type == .stage ? rng.pick(names) : name(names))
                    channel.position = index
                    channel.parentID = parentID
                    if restricted > 0 {
                        restricted -= 1
                        // Never one of the first text channels: #general and its neighbours stay open to all.
                        let hidden = type == .text && draft.textChannels >= 2 && !hasPrivateChannel && profile.restrictedChannels >= 3
                        hasPrivateChannel = hasPrivateChannel || hidden
                        channel.overwrites = restrictedOverwrites(type, hidden: hidden, draft)
                    }
                    if type == .forum || type == .media {
                        for tag in ["question", "solved", "discussion", "showcase"] {
                            channel.availableTags.append(ForumTag(id: await world.nextID(at: draft.founded), name: tag))
                        }
                    }
                    await world.addChannel(channel)
                    // The hidden room stays quiet: the people who chat everywhere else can't see it.
                    let hidden = channel.overwrites.contains { $0.deny.contains(.viewChannel) }
                    if type == .text, !hidden {
                        draft.messageChannels.insert(channel.id, at: draft.textChannels)
                        draft.textChannels += 1
                    } else if type.holdsMessages, type != .stage, type != .text {
                        draft.messageChannels.append(channel.id)
                    }
                    if type == .voice { draft.voiceChannels.append(channel.id) }
                    if type == .forum || type == .media { draft.forums.append(channel.id) }
                    index += 1
                }
            }
        }
    }

    /// Announcements are read-only for @everyone and other restricted channels only stop @everyone pings,
    /// so the account can still use them. A server with several restricted channels also has one hidden
    /// room for the owner, a few regulars and the account, whose member list is its own.
    private func restrictedOverwrites(_ type: ChannelType, hidden: Bool, _ draft: ServerDraft) -> [PermissionOverwrite] {
        if hidden {
            return [PermissionOverwrite(id: draft.guildID, kind: .role, allow: [], deny: .viewChannel)]
                + Set(draft.members.prefix(6)).sorted().map { PermissionOverwrite(id: $0, kind: .member, allow: .viewChannel, deny: []) }
        }
        return [PermissionOverwrite(id: draft.guildID, kind: .role, allow: [], deny: type == .announcement ? .sendMessages : .mentionEveryone)]
    }

    /// Each channel gets its latest message now (so READY carries real last-message IDs
    /// and unread state) and older history on first look. Busy servers' busy channels spoke recently.
    private mutating func addMessages(_ profile: ServerProfile, _ draft: ServerDraft, _ rng: inout SeededRandom) async throws {
        let authors = draft.members.filter { $0 != me }
        guard !authors.isEmpty else { return }
        let shares = profile.activity.channelShares
        var mentions = profile.readState.mentions[...]
        let unread = Set(draft.messageChannels.shuffledPrefix(profile.readState.unreadChannels, using: &rng))
        for (index, channelID) in draft.messageChannels.enumerated() {
            let perHour = profile.activity.messages * (index < shares.count ? shares[index] : 0.02)
            let gap = perHour > 0 ? 3_600 / perHour : 86_400 * (3 + 60 * rng.unit())
            let last = world.epoch.addingTimeInterval(-min(400 * 86_400, max(20, gap * rng.unit() * 2)))
            let mentionCount = unread.contains(channelID) ? mentions.popFirst() ?? 0 : 0
            var ids: [Snowflake] = []
            for step in 0 ... mentionCount {
                let content = step < mentionCount ? "<@\(me)> \(DemoText.communityMessage(draft.kind, &rng))"
                    : DemoText.communityMessage(draft.kind, &rng)
                ids.append(try await bench.seed(MessageDraft(content: content), author: rng.pick(authors), channel: channelID,
                                                at: last.addingTimeInterval(Double(step - mentionCount) * 90)).id)
            }
            var state = ReadState(lastAckedID: ids.last)
            if unread.contains(channelID) {
                state.lastAckedID = Snowflake(ids[0].rawValue - 1)
                state.mentionCount = mentionCount
            }
            await world.setReadState(me, channel: channelID, state)
            let count = min(600, 15 + Int(perHour * 24 * 3) + Int(rng.next() % 40))
            await world.planHistory(channelID, HistoryPlan(count: count, seed: rng.next(), authors: authors, kind: draft.kind,
                                                           start: last.addingTimeInterval(-max(gap * Double(count), 7 * 86_400)),
                                                           end: last.addingTimeInterval(-60)))
        }
    }

    /// Notification settings, stored only for servers the account changed, as Discord does. They go
    /// through the same patch as `PATCH /users/@me/guilds/settings`; nothing is connected yet to hear it.
    private func addSettings(_ profile: ServerProfile, _ draft: ServerDraft, _ rng: inout SeededRandom) async throws {
        let settings = profile.settings
        guard settings != ServerSettingsProfile() else { return }
        var overrides: [Snowflake: JSONObject] = [:]
        for id in draft.messageChannels.shuffledPrefix(settings.mutedChannels, using: &rng) { overrides[id, default: JSONObject()]["muted"] = true }
        for id in draft.categories.shuffledPrefix(settings.collapsedCategories, using: &rng) { overrides[id, default: JSONObject()]["collapsed"] = true }
        for id in draft.messageChannels.shuffledPrefix(settings.notificationOverrides, using: &rng) {
            overrides[id, default: JSONObject()]["message_notifications"] = .int(Int64(rng.next() % 3))
        }
        let patch = JSONObject([
            ("suppress_everyone", .bool(settings.suppressEveryone)), ("suppress_roles", .bool(settings.suppressRoles)),
            ("message_notifications", .int(Int64(settings.messageNotifications))), ("muted", .bool(settings.muted)),
            ("hide_muted_channels", .bool(settings.hideMutedChannels)),
            ("channel_overrides", .object(JSONObject(overrides.keys.sorted().map { ($0.description, .object(overrides[$0]!)) }))),
        ])
        _ = try await world.patchGuildSettings(me, guilds: JSONObject([(draft.guildID.description, .object(patch))]))
    }

    private func seatVoice(_ count: Int, _ draft: ServerDraft, _ rng: inout SeededRandom) async {
        guard !draft.voiceChannels.isEmpty else { return }
        for (index, userID) in draft.members.filter({ $0 != me }).shuffledPrefix(count, using: &rng).enumerated() {
            // People gather: most sit in the first room or two.
            let channelID = draft.voiceChannels[rng.chance(0.7) ? 0 : Int(rng.next() % UInt64(draft.voiceChannels.count))]
            var state = VoiceState(userID: userID, guildID: draft.guildID, channelID: channelID, sessionID: await world.nextHash(),
                                   connectedAt: Int64(world.epoch.timeIntervalSince1970) - 600 - Int64(index) * 240)
            state.selfMute = rng.chance(0.4)
            state.selfDeaf = rng.chance(0.1)
            state.simulated = true
            await world.seedVoiceState(state)
        }
    }
}
