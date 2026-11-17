import Foundation

/// The hand-written demo world built from `DemoContent`: the realistic world's
/// close servers and friends, and on its own a small world for quick tests.
public enum DemoScenario: Scenario {
    public static let name = "demo-lite"
    public static let summary = "A small friendly server, a busier boosted one, DMs and friends, with history and media."

    /// The signed-in account's sign-in details, shown by `discord-simulator` at startup.
    public static let email = "wren@example.net"
    public static let password = "porch-light"

    public static func build(into world: World, parameters: [String: String]) async throws {
        var converter = await DemoConverter(world: world)
        // Benchmark worlds that find their targets by name leave the demo servers out.
        converter.includesGuilds = parameters["demo_servers"] != "0"
        try await converter.build()
    }
}

/// Converts `DemoContent` into world records, assigning IDs in time order.
struct DemoConverter {
    let world: World
    var includesGuilds = true
    var builder: WorldBuilder
    var people: [String: Snowflake] = [:]
    var roles: [String: Snowflake] = [:]
    var channels: [String: Snowflake] = [:]
    var emojis: [String: Emoji] = [:]
    var stickers: [String: Snowflake] = [:]
    var guildKeys: [Snowflake: String] = [:]
    var avatars: [String: String] = [:]
    /// Message labels to IDs, scoped by channel key (labels are unique per channel).
    var labels: [String: (channel: Snowflake, message: Snowflake)] = [:]

    init(world: World) async {
        self.world = world
        builder = await WorldBuilder(world: world, label: "demo")
    }

    func date(_ time: DemoTime) -> Date {
        world.epoch.addingTimeInterval(Double(time.secondsFromNow))
    }

    mutating func build() async throws {
        try await buildPeople()
        for sticker in DemoContent.standardStickers { await addSticker(sticker, guildID: nil) }
        if includesGuilds {
            for guild in DemoContent.guilds { try await buildGuild(guild) }
            try await buildServerExtras()
        }
        for direct in DemoContent.directChannels { try await buildDirectChannel(direct) }
        guard let me = people[DemoContent.selfKey] else { throw WorldError.invalidBody("demo content has no self person") }
        for relationship in DemoContent.relationships {
            guard let other = people[relationship.person] else { continue }
            let type: RelationshipType = switch relationship.kind {
            case .friend: .friend
            case .incomingRequest: .incoming
            case .outgoingRequest: .outgoing
            }
            await world.setRelationship(me, Relationship(userID: other, type: type, nickname: relationship.nickname, since: date(relationship.since)))
            if type == .friend { await world.setRelationship(other, Relationship(userID: me, type: .friend, since: date(relationship.since))) }
        }
        await world.setUnfurler(DemoConverter.unfurl)
        try await dressSelf(me)
        await registerBotCommands()
        try await addInboxState(me: me)
        try await addProfileState(me: me)
        await addActivities()
    }

    /// Pip answers its slash commands with this week's cards, and its RSVP
    /// buttons move the presser into the matching group.
    mutating func registerBotCommands() async {
        let nextGameNight = DemoContent.gameNight(on: 4, rsvps: "nobody yet", games: "whatever the birthday frog wants")
        await world.setCommandReply("gamenight", CommandReply(
            embeds: [await embed(nextGameNight)], components: DemoContent.gameNightButtons.map(Self.component)))
        let digest = DemoContent.digest(week: 4, top: "Nico turned a year older 🐸", newFaces: "nobody yet",
                                        next: "Game night (Thu)", at: DemoContent.at(0, 21, 0))
        await world.setCommandReply("digest", CommandReply(embeds: [await embed(digest)]))
        await world.setComponentResponder(prefix: "gamenight:", Self.rsvp)
    }

    /// Rewrites the "RSVPs" field, e.g. "✅ Wren, Nico · 🤔 Tomás", with `name` in the group `customID` picks.
    static func rsvp(_ embeds: [JSON], customID: String, name: String) -> [JSON] {
        let marks = [("gamenight:yes", "✅"), ("gamenight:maybe", "🤔"), ("gamenight:no", "❌")]
        guard let mark = marks.first(where: { $0.0 == customID })?.1 else { return embeds }
        return embeds.map { embed in
            guard case var .object(object) = embed, let fields = object["fields"]?.arrayValue else { return embed }
            object["fields"] = .array(fields.map { field in
                guard case var .object(entry) = field, entry["name"]?.stringValue == "RSVPs" else { return field }
                var groups = Dictionary(uniqueKeysWithValues: marks.map { ($0.1, [String]()) })
                for group in (entry["value"]?.stringValue ?? "").components(separatedBy: " · ") {
                    let parts = group.split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2, groups[parts[0]] != nil else { continue }
                    // "Nico (birthday rules: he picks)" is still Nico; "Sam Smith" is not Sam.
                    groups[parts[0]] = parts[1].components(separatedBy: ", ").filter { $0 != name && !$0.hasPrefix(name + " (") }
                }
                groups[mark, default: []].append(name)
                let text = marks.compactMap { groups[$0.1]?.isEmpty == false ? "\($0.1) \(groups[$0.1]!.joined(separator: ", "))" : nil }
                entry["value"] = .string(text.joined(separator: " · "))
                return .object(entry)
            })
            return .object(object)
        }
    }

    // MARK: People

    mutating func buildPeople() async throws {
        for (index, person) in DemoContent.people.enumerated() {
            // Accounts were made over the past few years, in content order.
            let created = ScenarioEpoch.accountsReference(for: world.epoch).addingTimeInterval(-Double(1_400 - index * 61) * 86_400)
            var user = User(id: await world.nextID(at: created), username: person.username, globalName: person.displayName)
            user.bot = person.isBot
            user.bio = person.bio
            user.pronouns = person.pronouns
            user.premiumType = person.premium.premiumType
            user.premiumSince = user.premiumType == .none ? nil : created.addingTimeInterval(200 * 86_400)
            user.accentColor = Int(person.accentColor)
            user.bannerColor = String(format: "#%06x", person.bannerColor)
            if let avatar = person.avatar {
                let avatarHash = builder.hash(seed: avatar.seed, animated: avatar.animated && user.premiumType == .nitro)
                user.avatar = avatarHash
                avatars[person.key] = avatarHash
                await world.setStyle(avatar, forHash: avatarHash)
            }
            if let banner = person.banner, user.premiumType == .nitro {
                let bannerHash = builder.hash(seed: banner.seed)
                user.banner = bannerHash
                await world.setPalette(banner.palette, forHash: bannerHash)
            }
            let isSelf = person.key == DemoContent.selfKey
            var token: String?
            if isSelf {
                user.email = DemoScenario.email
                user.password = DemoScenario.password
                token = builder.token(for: user.id)
            }
            await world.addUser(user, token: token, presence: presence(person.presence))
            if case let .playing(game)? = person.presence.activity { await world.addGame(named: game, releasedAt: world.epoch.addingTimeInterval(-2 * 365 * 86_400)) }
            if isSelf { await world.setPrimaryUser(user.id) }
            people[person.key] = user.id
        }
    }

    /// The signed-in Nitro user wears an avatar decoration and a nameplate bought
    /// from the shop, and the Garden's server tag, so those render paths have data.
    mutating func dressSelf(_ me: Snowflake) async throws {
        let bought = world.epoch.addingTimeInterval(-90 * 86_400)
        let decoration = "a_" + builder.hash(seed: 0xDEC0)
        let nameplate = "nameplates/nameplates/\(builder.hash(seed: 0x9A3E))/"
        guard let garden = DemoContent.guilds.max(by: { $0.boostCount < $1.boostCount }),
              let gardenID = guildKeys.first(where: { $0.value == garden.key })?.key else { return }
        let badge = builder.hash(seed: 0xBAD6E)
        let nameplateHash = nameplate.split(separator: "/").last.map(String.init) ?? nameplate
        let category = await world.addCollectibleCategory(name: "Evening Garden", summary: "Dusk settles over the flower beds.", at: bought)
        let decorationSKU = await world.nextID(at: bought), nameplateSKU = await world.nextID(at: bought)
        for asset in [decoration, nameplateHash, badge, decorationSKU.description, nameplateSKU.description] { await world.registerAsset(asset) }
        let products = [
            CollectibleProduct(skuID: decorationSKU, name: "Garden Lantern", summary: "Give your avatar a new look.", type: 0, items: [
                .object(JSONObject([("type", 0), ("sku_id", decorationSKU.json), ("asset", .string(decoration)),
                                    ("label", "A paper lantern glowing among climbing roses around the avatar.")])),
            ], categorySKU: category, price: 499, nitroPrice: 399),
            CollectibleProduct(skuID: nameplateSKU, name: "Evening Garden", summary: "Give your name a new look.", type: 2, items: [
                .object(JSONObject([("type", 2), ("sku_id", nameplateSKU.json), ("asset", .string(nameplate)),
                                    ("label", "Fireflies drifting over a violet garden at dusk."), ("palette", "violet")])),
            ], categorySKU: category, price: 399, nitroPrice: 299),
        ]
        for product in products {
            await world.addCollectibleProduct(product)
            await world.recordPurchase(product.skuID, by: me, at: bought)
        }
        try await world.updateUserQuietly(me) { user in
            user.avatarDecoration = .object(JSONObject([("asset", .string(decoration)), ("sku_id", decorationSKU.json), ("expires_at", .null)]))
            user.collectibles = .object(JSONObject([("nameplate", .object(JSONObject([
                ("asset", .string(nameplate)), ("label", "Evening Garden"), ("palette", "violet"), ("sku_id", nameplateSKU.json), ("expires_at", .null),
            ])))]))
            user.primaryGuild = .object(JSONObject([
                ("identity_guild_id", gardenID.json), ("identity_enabled", true), ("tag", "LNDN"), ("badge", .string(badge)),
            ]))
        }
    }

    func presence(_ demo: DemoPresence) -> Presence {
        let status = PresenceStatus(rawValue: demo.status.rawValue) ?? .offline
        let started = world.epoch.addingTimeInterval(-1_800)
        let activity: JSON? = switch demo.activity {
        case let .playing(game)?: WorldBuilder.activity(type: 0, name: game, start: started)
        case let .listening(song, artist, album)?:
            WorldBuilder.activity(type: 2, name: "Spotify", details: song, state: artist, start: started)
                .merging([
                    "assets": .object(JSONObject([("large_text", .string(album))])),
                    "sync_id": .string(String(song.hashValueStable, radix: 36)),
                    "party": .object(JSONObject([("id", .string("spotify:\(song.hashValueStable)"))])),
                ])
        case let .watching(show)?: WorldBuilder.activity(type: 3, name: show, start: started)
        case let .competing(event)?: WorldBuilder.activity(type: 5, name: event, start: started)
        case nil: nil
        }
        return WorldBuilder.presence(status, custom: demo.customStatus, emoji: demo.customStatusEmoji, activity: activity)
    }

    // MARK: Guilds

    mutating func buildGuild(_ demo: DemoGuild) async throws {
        guard let owner = people[demo.owner] else { throw WorldError.invalidBody("guild \(demo.key) owner \(demo.owner) unknown") }
        let firstJoin = demo.members.map(\.joined).min() ?? DemoContent.now
        let guildID = await world.nextID(at: date(firstJoin).addingTimeInterval(-3_600))
        guildKeys[guildID] = demo.key
        var guild = Guild(id: guildID, name: demo.name, ownerID: owner)
        guild.description = demo.description
        guild.icon = builder.hash(seed: demo.icon.seed, animated: demo.icon.animated && demo.boostTier >= 1)
        await world.setStyle(demo.icon, forHash: guild.icon!)
        if let banner = demo.banner, demo.boostTier >= 2 {
            guild.banner = builder.hash(seed: banner.seed)
            await world.setPalette(banner.palette, forHash: guild.banner!)
        }
        if let splash = demo.splash, demo.boostTier >= 1 {
            guild.splash = builder.hash(seed: splash.seed)
            await world.setPalette(splash.palette, forHash: guild.splash!)
        }
        guild.features = ["COMMUNITY", "NEWS", "THREADS_ENABLED"] + WorldBuilder.boostFeatures(tier: demo.boostTier)
        guild.roles = [WorldBuilder.everyoneRole(guildID: guildID)]
        await addRoles(demo, to: &guild, firstJoin: firstJoin)
        for member in demo.members {
            guard let userID = people[member.person] else { continue }
            var record = Member(userID: userID, joinedAt: date(member.joined))
            record.nick = member.nickname
            record.roles = member.roles.compactMap { roles["\(demo.key)/\($0)"] }
            record.premiumSince = member.boostingSince.map(date)
            guild.members[userID] = record
            guild.memberOrder.append(userID)
        }
        // Boost count can exceed the number of boosting members: people boost more than once.
        let boosters = demo.members.filter { $0.boostingSince != nil }.compactMap { member in people[member.person].map { ($0, date(member.boostingSince!)) } }
        if !boosters.isEmpty {
            guild.boosts = (0 ..< demo.boostCount).map { boosters[$0 % boosters.count] }
        }
        await addEmojis(demo, to: &guild, owner: owner, firstJoin: firstJoin)
        await world.addGuild(guild)
        for sticker in demo.stickers { await addSticker(sticker, guildID: guildID) }

        await addChannels(demo, guildID: guildID, firstJoin: firstJoin)
        var updated = try await world.guild(guildID)
        updated.systemChannelID = channels[demo.systemChannel]
        updated.rulesChannelID = demo.rulesChannel.flatMap { channels[$0] }
        updated.afkChannelID = demo.afkChannel.flatMap { channels[$0] }
        await world.addGuild(updated)
        for demoChannel in demo.channels {
            guard let channelID = channels[demoChannel.key] else { continue }
            try await addMessages(demoChannel.messages, channelKey: demoChannel.key, channelID: channelID, guildID: guildID)
            for post in demoChannel.posts { try await addForumPost(post, forumID: channelID, guildID: guildID, tags: demoChannel.forumTags) }
            try await applyUnread(demoChannel.unreadFrom, channelKey: demoChannel.key, channelID: channelID)
        }
    }

    private mutating func addRoles(_ demo: DemoGuild, to guild: inout Guild, firstJoin: DemoTime) async {
        for (index, role) in demo.roles.enumerated() {
            let id = await world.nextID(at: date(firstJoin).addingTimeInterval(Double(index)))
            roles["\(demo.key)/\(role.key)"] = id
            var permissions: Permissions = switch role.permissions {
            case .owner, .admin: [.administrator]
            case .moderator: Permissions.moderator.union(.everyoneDefault)
            case .member, .bot: .everyoneDefault
            }
            if role.permissions == .bot { permissions.formUnion([.manageMessages, .embedLinks]) }
            guild.roles.append(Role(id: id, name: role.name, color: Int(role.color), hoist: role.hoist,
                                    position: demo.roles.count - index, permissions: permissions,
                                    mentionable: role.mentionable, managed: role.managed != nil, unicodeEmoji: role.icon))
        }
    }

    private mutating func addEmojis(_ demo: DemoGuild, to guild: inout Guild, owner: Snowflake, firstJoin: DemoTime) async {
        for emoji in demo.emojis {
            let id = await world.nextID(at: date(firstJoin).addingTimeInterval(7_200))
            let record = Emoji(id: id, name: emoji.name, animated: emoji.animated, creatorID: owner)
            guild.emojis.append(record)
            emojis[emoji.name] = record
            let png = MediaGenerator.emojiPNG(seed: emoji.seed, motif: emoji.motif)
            for ext in ["png", "webp"] { await world.storeMedia("/emojis/\(id).\(ext)", png, contentType: "image/png") }
            if emoji.animated {
                await world.storeMedia("/emojis/\(id).gif", MediaGenerator.animatedGIF(seed: emoji.seed, motif: emoji.motif), contentType: "image/gif")
            }
        }
    }

    private mutating func addChannels(_ demo: DemoGuild, guildID: Snowflake, firstJoin: DemoTime) async {
        // Channels: categories first so children can name their parent.
        var position = 0
        for category in demo.categories {
            var parentID: Snowflake?
            if let name = category.name {
                let id = await world.nextID(at: date(firstJoin).addingTimeInterval(10_000 + Double(position)))
                var channel = Channel(id: id, type: .category, guildID: guildID, name: name)
                channel.position = position
                await world.addChannel(channel)
                parentID = id
                channels["\(demo.key)/\(category.key)"] = id
            }
            for (index, demoChannel) in category.channels.enumerated() {
                let id = await world.nextID(at: date(firstJoin).addingTimeInterval(10_100 + Double(position * 10 + index)))
                channels[demoChannel.key] = id
                channels["\(demo.key)/\(demoChannel.key)"] = id
                var channel = Channel(id: id, type: Self.channelType(demoChannel.kind), guildID: guildID, name: demoChannel.name)
                channel.topic = demoChannel.topic
                channel.position = index
                channel.parentID = parentID
                channel.rateLimitPerUser = demoChannel.slowmodeSeconds
                channel.userLimit = demoChannel.userLimit
                for tag in demoChannel.forumTags {
                    channel.availableTags.append(ForumTag(id: await world.nextID(at: date(firstJoin)), name: tag.name,
                                                          moderated: tag.moderated, emojiName: tag.emoji))
                }
                await world.addChannel(channel)
                await seatVoiceStates(demoChannel.voiceStates, channelID: id, guildID: guildID)
            }
            position += 1
        }
    }

    static func channelType(_ kind: DemoChannelKind) -> ChannelType {
        switch kind {
        case .text: .text
        case .voice: .voice
        case .announcement: .announcement
        case .forum: .forum
        case .stage: .stage
        }
    }

    mutating func addSticker(_ sticker: DemoSticker, guildID: Snowflake?) async {
        let id = await world.nextID(at: world.epoch.addingTimeInterval(-400 * 86_400))
        stickers[sticker.name] = id
        let format = switch sticker.format {
        case .png: 1
        case .apng: 2
        case .lottie: 3
        case .gif: 4
        }
        let record = Sticker(id: id, name: sticker.name, description: sticker.description, tags: sticker.tags, formatType: format)
        if let guildID, var guild = try? await world.guild(guildID) {
            guild.stickers.append(record)
            await world.addGuild(guild)
        } else {
            await world.addStandardSticker(record)
        }
        if let data = MediaGenerator.data(for: sticker.media, width: 320, height: 320) {
            let ext = sticker.format == .lottie ? "json" : (sticker.format == .gif ? "gif" : "png")
            let type = sticker.format == .lottie ? "application/json" : (sticker.format == .gif ? "image/gif" : "image/png")
            await world.storeMedia("/stickers/\(id).\(ext)", data, contentType: type)
            if ext == "png" { await world.storeMedia("/stickers/\(id).webp", data, contentType: type) }
        }
    }

    // MARK: Messages

    mutating func addMessages(_ messages: [DemoMessage], channelKey: String, channelID: Snowflake, guildID: Snowflake?) async throws {
        for demo in messages.sorted(by: { $0.at < $1.at }) {
            try await addMessage(demo, channelKey: channelKey, channelID: channelID, guildID: guildID)
        }
    }

    @discardableResult
    mutating func addMessage(_ demo: DemoMessage, channelKey: String, channelID: Snowflake, guildID: Snowflake?) async throws -> Snowflake {
        guard let author = people[demo.author] else { throw WorldError.invalidBody("message author \(demo.author) unknown") }
        let sent = date(demo.at)
        var message = Message(id: await world.nextID(at: sent), channelID: channelID, authorID: author, content: resolve(demo.content))
        if let label = demo.label { labels["\(channelKey)/\(label)"] = (channelID, message.id) }
        if let reply = demo.replyTo, let target = labels["\(channelKey)/\(reply)"] {
            message.type = 19
            message.reference = MessageReference(type: 0, messageID: target.message, channelID: target.channel, guildID: guildID)
            if let repliedAuthor = await world.channels[target.channel]?.messages.first(where: { $0.id == target.message })?.authorID,
               repliedAuthor != author { message.mentions.append(repliedAuthor) }
        }
        if let forward = demo.forward, let target = labels["\(forward.channel)/\(forward.label)"],
           let original = await world.channels[target.channel]?.messages.first(where: { $0.id == target.message }) {
            message.reference = MessageReference(type: 1, messageID: target.message, channelID: target.channel,
                                                 guildID: await world.channels[target.channel]?.guildID)
            message.messageSnapshots = [await world.renderForwardSnapshot(original)]
        }
        applyMarkupMentions(in: demo.content, to: &message, guildID: guildID)
        message.mentionEveryone = demo.content.contains("@everyone") || demo.content.contains("@here")
        message.reactions = reactions(for: demo)
        for attachment in demo.attachments {
            message.attachments.append(await attach(attachment, channelID: channelID, at: sent))
        }
        for item in demo.embeds { message.embeds.append(await embed(item)) }
        message.components = demo.components.map(Self.component)
        message.poll = demo.poll.map { poll(from: $0, sent: sent) }
        message.stickerIDs = demo.stickers.compactMap { stickers[$0] }
        if let system = demo.system { applySystem(system, to: &message, channelKey: channelKey, guildID: guildID) }
        message.pinned = demo.pinned
        if demo.pinned { message.pinnedAt = sent.addingTimeInterval(60) }
        message.editedAt = demo.editedAfterMinutes.map { sent.addingTimeInterval(Double($0) * 60) }
        if let thread = demo.thread {
            message.threadID = message.id
            await world.seedMessage(message)
            try await addThread(thread, id: message.id, parentID: channelID, guildID: guildID, owner: author, created: sent)
        } else {
            await world.seedMessage(message)
        }
        if message.pinned { await world.markPinned(channelID, at: sent) }
        return message.id
    }

    private func applyMarkupMentions(in content: String, to message: inout Message, guildID: Snowflake?) {
        for token in DemoMarkup.tokens(in: content) {
            switch token {
            case let .user(key): if let id = people[key], !message.mentions.contains(id) { message.mentions.append(id) }
            case let .role(key): if let guildKey = guildKey(for: guildID), let id = roles["\(guildKey)/\(key)"] { message.mentionRoles.append(id) }
            default: break
            }
        }
    }

    private func reactions(for demo: DemoMessage) -> [Reaction] {
        var result: [Reaction] = []
        for reaction in demo.reactions {
            var record: Reaction
            switch reaction.emoji {
            case let .unicode(value): record = Reaction(emojiName: value)
            case let .custom(name):
                guard let emoji = emojis[name] else { continue }
                record = Reaction(emojiName: emoji.name, emojiID: emoji.id, animated: emoji.animated)
            }
            record.users = reaction.users.compactMap { people[$0] }
            record.burstUsers = reaction.burstUsers.compactMap { people[$0] }
            if !record.burstUsers.isEmpty { record.burstColors = ["#f4a5c0", "#b06ad8"] }
            result.append(record)
        }
        return result
    }

    private func poll(from poll: DemoPoll, sent: Date) -> Poll {
        return Poll(
            question: poll.question,
            answers: poll.answers.enumerated().map { index, answer in
                var emoji: String?
                if case let .unicode(value)? = answer.emoji { emoji = value }
                return Poll.Answer(id: index + 1, text: answer.text, emoji: emoji, voters: answer.voters.compactMap { people[$0] })
            },
            expiry: sent.addingTimeInterval(Double(poll.durationHours) * 3_600),
            allowMultiselect: poll.allowMultiselect, finalized: poll.finalized
        )
    }

    func guildKey(for guildID: Snowflake?) -> String? { guildID.flatMap { guildKeys[$0] } }

    mutating func addThread(_ thread: DemoThread, id: Snowflake, parentID: Snowflake, guildID: Snowflake?, owner: Snowflake, created: Date) async throws {
        var channel = Channel(id: id, type: .publicThread, guildID: guildID, name: thread.name)
        channel.parentID = parentID
        channel.ownerID = owner
        let last = thread.messages.map { date($0.at) }.max() ?? created
        channel.thread = ThreadMetadata(archived: thread.archived, archiveTimestamp: last, createTimestamp: created)
        channel.threadMembers = Array(Set(thread.messages.compactMap { people[$0.author] } + [owner])).sorted()
        await world.addChannel(channel)
        try await addMessages(thread.messages, channelKey: "thread-\(id)", channelID: id, guildID: guildID)
    }

    mutating func addForumPost(_ post: DemoForumPost, forumID: Snowflake, guildID: Snowflake, tags: [DemoForumTag]) async throws {
        guard let first = post.messages.first, let owner = people[first.author] else { return }
        let created = date(first.at)
        let id = await world.nextID(at: created)
        var channel = Channel(id: id, type: .publicThread, guildID: guildID, name: post.title)
        channel.parentID = forumID
        channel.ownerID = owner
        channel.flags = post.pinned ? 2 : 0
        let forum = try await world.channel(forumID)
        channel.appliedTags = post.tags.compactMap { name in forum.availableTags.first { $0.name == name }?.id }
        let last = post.messages.map { date($0.at) }.max() ?? created
        channel.thread = ThreadMetadata(archived: post.archived, archiveTimestamp: last, createTimestamp: created)
        channel.threadMembers = Array(Set(post.messages.compactMap { people[$0.author] })).sorted()
        await world.addChannel(channel)
        // The starter message shares the post's ID, as in Discord forums.
        var messages = post.messages.sorted { $0.at < $1.at }
        let starter = messages.removeFirst()
        var starterMessage = Message(id: id, channelID: id, authorID: owner, content: resolve(starter.content))
        for attachment in starter.attachments { starterMessage.attachments.append(await attach(attachment, channelID: id, at: created)) }
        for item in starter.embeds { starterMessage.embeds.append(await embed(item)) }
        for reaction in starter.reactions {
            if case let .unicode(value) = reaction.emoji {
                var record = Reaction(emojiName: value)
                record.users = reaction.users.compactMap { people[$0] }
                starterMessage.reactions.append(record)
            }
        }
        await world.seedMessage(starterMessage)
        try await addMessages(messages, channelKey: "post-\(id)", channelID: id, guildID: guildID)
    }

    private func reference(toLabel label: String, channelKey: String, guildID: Snowflake?) -> MessageReference? {
        labels["\(channelKey)/\(label)"].map {
            MessageReference(type: 0, messageID: $0.message, channelID: $0.channel, guildID: guildID)
        }
    }

    func applySystem(_ system: DemoSystemKind, to message: inout Message, channelKey: String, guildID: Snowflake?) {
        switch system {
        case .memberJoin: message.type = 7
        case .boost: message.type = 8
        case let .boostTier(tier): message.type = 8 + min(3, max(1, tier))
        case let .pinned(label):
            message.type = 6
            message.reference = reference(toLabel: label, channelKey: channelKey, guildID: guildID) ?? message.reference
        case .threadCreated: message.type = 18
        case let .recipientAdded(key):
            message.type = 1
            if let id = people[key] { message.mentions = [id] }
        case let .recipientRemoved(key):
            message.type = 2
            if let id = people[key] { message.mentions = [id] }
        case .call: message.type = 3
        case let .channelNameChanged(name):
            message.type = 4
            message.content = name
        case .channelIconChanged: message.type = 5
        case let .pollResult(label):
            message.type = 46
            message.reference = reference(toLabel: label, channelKey: channelKey, guildID: guildID) ?? message.reference
        case .channelFollowAdded: message.type = 12
        }
    }

    mutating func attach(_ demo: DemoAttachment, channelID: Snowflake, at sent: Date) async -> Attachment {
        let id = await world.nextID(at: sent)
        let path = "/attachments/\(channelID)/\(id)/\(demo.filename)"
        var attachment = Attachment(id: id, filename: demo.filename, size: demo.size, contentType: demo.contentType,
                                    width: demo.width, height: demo.height, durationSeconds: demo.durationSeconds,
                                    description: demo.altText, spoiler: demo.spoiler, cdnPath: path)
        if demo.kind == .voice {
            attachment.flags = 1 << 13
            attachment.waveform = Self.waveform(seed: id.rawValue)
        }
        if demo.spoiler { attachment.flags |= 1 << 3 }
        if let data = MediaGenerator.data(for: demo.media, width: demo.width ?? 640, height: demo.height ?? 480) {
            attachment.size = data.count
            await world.storeMedia(path, data, contentType: demo.contentType)
        }
        return attachment
    }

    /// Discord's waveform: 256 bytes of amplitude, base64.
    static func waveform(seed: UInt64) -> String {
        var random = SeededRandom(seed: seed)
        return Data((0 ..< 256).map { index in UInt8(40 + Int(abs(sin(Double(index) / 9)) * 150) + Int(random.next() % 40)) }).base64EncodedString()
    }

    // MARK: Embeds and components

    func embed(_ demo: DemoEmbed) async -> JSON {
        var object = JSONObject([("type", .string(demo.kind.rawValue))])
        if let url = demo.url { object["url"] = .string(url) }
        if let title = demo.title { object["title"] = .string(resolve(title)) }
        if let description = demo.description { object["description"] = .string(resolve(description)) }
        if let color = demo.color { object["color"] = .int(Int64(color)) }
        if let timestamp = demo.timestamp { object["timestamp"] = World.timestamp(date(timestamp)) }
        if let name = demo.authorName {
            var author = JSONObject([("name", .string(name))])
            if let url = demo.authorURL { author["url"] = .string(url) }
            if let key = demo.authorIcon, let icon = avatarURL(key) { author["icon_url"] = .string(icon); author["proxy_icon_url"] = .string(icon) }
            object["author"] = .object(author)
        }
        if let provider = demo.provider { object["provider"] = .object(JSONObject([("name", .string(provider))])) }
        if let footer = demo.footer {
            var value = JSONObject([("text", .string(footer))])
            if let key = demo.footerIcon, let icon = avatarURL(key) { value["icon_url"] = .string(icon); value["proxy_icon_url"] = .string(icon) }
            object["footer"] = .object(value)
        }
        if !demo.fields.isEmpty {
            object["fields"] = .array(demo.fields.map { field in
                .object(JSONObject([("name", .string(resolve(field.name))), ("value", .string(resolve(field.value))), ("inline", .bool(field.inline))]))
            })
        }
        if let image = demo.image { object["image"] = await mediaObject(image, page: demo.url, slot: "image") }
        if let thumbnail = demo.thumbnail { object["thumbnail"] = await mediaObject(thumbnail, page: demo.url, slot: "thumbnail") }
        if let video = demo.video { object["video"] = await mediaObject(video, page: demo.url, slot: "video") }
        object["content_scan_version"] = 3
        return .object(object)
    }

    /// Embed media keep their page's real URL and a media-proxy URL, like Discord's.
    func mediaObject(_ media: DemoEmbedMedia, page: String?, slot: String) async -> JSON {
        let host = page.flatMap { URL(string: $0)?.host() } ?? "images.example.org"
        let seed: UInt64 = switch media.media {
        case let .photo(seed, _), let .animation(seed, _), let .sticker(seed, _): seed
        case let .bundled(name): name.hashValueStable
        }
        let ext = if case .animation = media.media { "gif" } else if case .bundled = media.media { "mp4" } else { "jpg" }
        let original = "https://\(host)/media/\(String(seed, radix: 36))-\(slot).\(ext)"
        let proxyPath = "/external/\(String(seed &* 0x9e37_79b9, radix: 36))/https/\(host)/media/\(String(seed, radix: 36))-\(slot).\(ext)"
        let contentType = ext == "gif" ? "image/gif" : (ext == "mp4" ? "video/mp4" : "image/jpeg")
        let ref = media.media, width = media.width, height = media.height
        await world.storeLazyMedia(proxyPath) { (MediaGenerator.data(for: ref, width: width, height: height) ?? Data(), contentType) }
        return .object(JSONObject([
            ("url", .string(original)), ("proxy_url", .string("https://images-ext-1.discordapp.net\(proxyPath)")),
            ("width", .int(media.width)), ("height", .int(media.height)), ("content_type", .string(contentType)),
            ("flags", 0),
        ]))
    }

    func avatarURL(_ key: String) -> String? {
        guard let id = people[key], let hash = avatars[key] else { return nil }
        return "https://cdn.discordapp.com/avatars/\(id)/\(hash).png"
    }

    static func component(_ row: DemoActionRow) -> JSON {
        .object(JSONObject([("type", 1), ("components", .array(row.components.map { component in
            switch component {
            case let .button(label, style, emoji, customID, url, disabled):
                var button = JSONObject([("type", 2), ("style", .int(buttonStyle(style))), ("label", .string(label))])
                if case let .unicode(value)? = emoji { button["emoji"] = .object(JSONObject([("name", .string(value))])) }
                if let customID { button["custom_id"] = .string(customID) }
                if let url { button["url"] = .string(url) }
                if disabled { button["disabled"] = true }
                return .object(button)
            case let .select(customID, placeholder, options, minValues, maxValues):
                return .object(JSONObject([
                    ("type", 3), ("custom_id", .string(customID)), ("placeholder", .string(placeholder)),
                    ("min_values", .int(minValues)), ("max_values", .int(maxValues)),
                    ("options", .array(options.map { option in
                        var value = JSONObject([("label", .string(option.label)), ("value", .string(option.value))])
                        if let description = option.description { value["description"] = .string(description) }
                        if case let .unicode(emoji)? = option.emoji { value["emoji"] = .object(JSONObject([("name", .string(emoji))])) }
                        return .object(value)
                    })),
                ]))
            }
        }))]))
    }

    static func buttonStyle(_ style: DemoButtonStyle) -> Int {
        switch style {
        case .primary: 1
        case .secondary: 2
        case .success: 3
        case .danger: 4
        case .link: 5
        }
    }

    // MARK: Direct messages and read state

    mutating func buildDirectChannel(_ demo: DemoDirectChannel) async throws {
        guard let me = people[DemoContent.selfKey] else { return }
        let recipients = demo.recipients.compactMap { people[$0] } + [me]
        let first = demo.messages.map(\.at).min() ?? DemoContent.now
        var channel = Channel(id: await world.nextID(at: date(first).addingTimeInterval(-60)), type: demo.isGroup ? .groupDM : .dm)
        channel.recipients = recipients.sorted()
        channel.name = demo.name
        if demo.isGroup { channel.ownerID = demo.owner.flatMap { people[$0] } ?? me }
        if let icon = demo.icon {
            channel.icon = builder.hash(seed: icon.seed)
            await world.setStyle(icon, forHash: channel.icon!)
        }
        channels[demo.key] = channel.id
        await world.addChannel(channel)
        try await addMessages(demo.messages, channelKey: demo.key, channelID: channel.id, guildID: nil)
        try await applyUnread(demo.unreadFrom, channelKey: demo.key, channelID: channel.id)
    }

    /// Marks everything before `label` read for the signed-in user and counts
    /// mentions after it, as the server's read state would.
    func applyUnread(_ label: String?, channelKey: String, channelID: Snowflake) async throws {
        guard let me = people[DemoContent.selfKey] else { return }
        let messages = try await world.channel(channelID).messages
        guard let last = messages.last else { return }
        var state = ReadState(lastAckedID: last.id)
        if let label, let target = labels["\(channelKey)/\(label)"], let index = messages.firstIndex(where: { $0.id == target.message }) {
            state.lastAckedID = index > 0 ? messages[index - 1].id : Snowflake(target.message.rawValue - 1)
            let channel = try await world.channel(channelID)
            state.mentionCount = await world.mentionCount(of: me, in: channel, after: state.lastAckedID ?? Snowflake(0))
        }
        await world.setReadState(me, channel: channelID, state)
    }

    func resolve(_ text: String) -> String {
        DemoMarkup.resolve(text, id: { token in
            switch token {
            case let .user(key): people[key]?.description ?? "0"
            case let .role(key): roles.first { $0.key.hasSuffix("/\(key)") }?.value.description ?? "0"
            case let .channel(key): channels[key]?.description ?? "0"
            case let .emoji(name, _): emojis[name]?.id.description ?? "0"
            case .timestamp: "0"
            }
        }, unix: { time in Int(date(time).timeIntervalSince1970) })
    }

    /// Links the demo's people share unfurl into the embeds their pages would give.
    @Sendable static func unfurl(_ content: String) -> [JSON] {
        guard let range = content.range(of: #"https?://[^\s>]+"#, options: .regularExpression),
              let url = URL(string: String(content[range])), let host = url.host() else { return [] }
        let title = url.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized
        return [.object(JSONObject([
            ("type", "link"), ("url", .string(url.absoluteString)),
            ("title", .string(title.isEmpty ? host : title)),
            ("provider", .object(JSONObject([("name", .string(host))]))),
            ("content_scan_version", 3),
        ]))]
    }
}

public extension World {
    /// Changes a user while building a scenario, without dispatching.
    func updateUserQuietly(_ id: Snowflake, _ change: (inout User) -> Void) throws {
        var user = try user(id)
        change(&user)
        users[id] = user
    }

    func addStandardSticker(_ sticker: Sticker) { standardStickers.append(sticker) }

    func setStyle(_ style: DemoImageStyle, forHash hash: String) {
        setPalette(style.palette, forHash: hash)
        if let art = style.art { setArt(art, forHash: hash) }
    }

    func markPinned(_ channelID: Snowflake, at date: Date) {
        if (channels[channelID]?.lastPinTimestamp ?? .distantPast) < date { channels[channelID]?.lastPinTimestamp = date }
    }
}
