import Foundation

/// Large, seeded worlds for the app's performance benchmarks. Each starts
/// from the demo world so the signed-in account, friends and DMs stay
/// familiar, then adds the scale the benchmark measures.
public enum BenchmarkScenarios {
    public static let all: [any Scenario.Type] = [
        LongServerListScenario.self, ServerRailScenario.self, ChatPerformanceScenario.self,
        ForumPerformanceScenario.self, FriendsPerformanceScenario.self, SideChatMotionScenario.self,
    ]
}

/// The demo world plus 16 more servers (18 in all).
public enum LongServerListScenario: Scenario {
    public static let name = "long-server-list"
    public static let summary = "The demo world plus 16 more small servers (18 in all)."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await DemoScenario.build(into: world, parameters: parameters)
        var bench = await BenchWorld(world: world, label: name)
        try await bench.addServers(count: Int(parameters["extra"] ?? "16") ?? 16)
    }
}

/// 150 servers for the server rail benchmark.
public enum ServerRailScenario: Scenario {
    public static let name = "server-rail"
    public static let summary = "The demo world plus enough servers for a 150-server rail."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await DemoScenario.build(into: world, parameters: parameters)
        var bench = await BenchWorld(world: world, label: name)
        try await bench.addServers(count: (Int(parameters["servers"] ?? "150") ?? 150) - DemoContent.guilds.count)
    }
}

/// A server whose #general holds thousands of messages (`messages`), with
/// optional media, voice messages or files (`content`) and pins (`pins`).
public enum ChatPerformanceScenario: Scenario {
    public static let name = "chat-performance"
    public static let summary = "A server with a 5,000-message #general; params messages, content=text|media|voice|files, pins."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await DemoScenario.build(into: world, parameters: parameters.merging(["demo_servers": "0"]) { $1 })
        var bench = await BenchWorld(world: world, label: name)
        let guild = try await bench.addBenchmarkServer()
        try await bench.fillChannel(guild.general, count: Int(parameters["messages"] ?? "5000") ?? 5_000,
                                    content: parameters["content"] ?? "text", pins: Int(parameters["pins"] ?? "0") ?? 0)
        try await bench.addForumPosts(guild.feedback, count: 40)
    }
}

/// A forum with thousands of posts (`posts`) whose previews carry images.
public enum ForumPerformanceScenario: Scenario {
    public static let name = "forum-performance"
    public static let summary = "A server whose #feedback forum holds 5,000 posts; param posts."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await DemoScenario.build(into: world, parameters: parameters.merging(["demo_servers": "0"]) { $1 })
        var bench = await BenchWorld(world: world, label: name)
        let guild = try await bench.addBenchmarkServer()
        try await bench.fillChannel(guild.general, count: 300, content: "text", pins: 0)
        try await bench.addForumPosts(guild.feedback, count: Int(parameters["posts"] ?? "5000") ?? 5_000)
    }
}

/// 1,000 friends with 100 incoming and 100 outgoing requests.
public enum FriendsPerformanceScenario: Scenario {
    public static let name = "friends-performance"
    public static let summary = "1,000 friends plus 100 incoming and 100 outgoing requests; params friends, incoming, outgoing."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await DemoScenario.build(into: world, parameters: parameters)
        var bench = await BenchWorld(world: world, label: name)
        try await bench.addRelationships(friends: Int(parameters["friends"] ?? "1000") ?? 1_000,
                                         incoming: Int(parameters["incoming"] ?? "100") ?? 100,
                                         outgoing: Int(parameters["outgoing"] ?? "100") ?? 100)
    }
}

/// Threads to open and close beside #general, and a forum, for the side-chat motion benchmark.
public enum SideChatMotionScenario: Scenario {
    public static let name = "side-chat-motion"
    public static let summary = "A server whose #general has many long threads (params threads, thread_messages)."

    public static func build(into world: World, parameters: [String: String]) async throws {
        try await DemoScenario.build(into: world, parameters: parameters.merging(["demo_servers": "0"]) { $1 })
        var bench = await BenchWorld(world: world, label: name)
        let guild = try await bench.addBenchmarkServer()
        try await bench.fillChannel(guild.general, count: 400, content: "text", pins: 0)
        try await bench.addThreads(in: guild.general, count: Int(parameters["threads"] ?? "9") ?? 9,
                                   messages: Int(parameters["thread_messages"] ?? "150") ?? 150)
        try await bench.addForumPosts(guild.feedback, count: 60)
    }
}

// MARK: - Building blocks

struct BenchWorld {
    struct BenchGuild { var id: Snowflake; var welcome: Snowflake; var general: Snowflake; var feedback: Snowflake }

    let world: World
    var builder: WorldBuilder
    var random: SeededRandom
    let me: Snowflake
    /// People created for the benchmark, in creation order.
    var people: [Snowflake] = []

    init(world: World, label: String) async {
        self.world = world
        builder = await WorldBuilder(world: world, label: label)
        random = SeededRandom(seed: world.seed).fork("bench-\(label)")
        me = await world.primaryUserID ?? Snowflake(0)
    }

    /// Creates people from `DemoText`, starting after any already made.
    mutating func ensurePeople(_ count: Int) async {
        while people.count < count {
            let person = DemoText.person(index: people.count + 1)
            let created = ScenarioEpoch.accountsReference(for: world.epoch).addingTimeInterval(-Double(900 + people.count % 700) * 86_400)
            let avatar = person.avatar.map { builder.hash(seed: $0.seed) }
            people.append(await world.addPerson(person, created: created, avatar: avatar))
        }
    }

    /// A server named from `DemoText` with #welcome, #general and a #feedback forum.
    mutating func addBenchmarkServer(index: Int = 0, members: Int = 60) async throws -> BenchGuild {
        await ensurePeople(members)
        let founded = world.epoch.addingTimeInterval(-Double(500 + index) * 86_400)
        let guildID = await world.nextID(at: founded)
        var guild = Guild(id: guildID, name: DemoText.serverName(index: index), ownerID: me)
        guild.roles = [WorldBuilder.everyoneRole(guildID: guildID)]
        guild.features = ["COMMUNITY", "THREADS_ENABLED"]
        for (offset, id) in ([me] + people.prefix(members - 1)).enumerated() {
            guild.members[id] = Member(userID: id, joinedAt: founded.addingTimeInterval(Double(offset) * 3_600))
            guild.memberOrder.append(id)
        }
        await world.addGuild(guild)
        var ids: [Snowflake] = []
        for (position, (name, type)) in [("welcome", ChannelType.text), ("general", .text), ("feedback", .forum)].enumerated() {
            var channel = Channel(id: await world.nextID(at: founded.addingTimeInterval(60)), type: type, guildID: guildID, name: name)
            channel.position = position
            if type == .forum {
                for tag in ["idea", "bug", "question", "praise"] {
                    channel.availableTags.append(ForumTag(id: await world.nextID(at: founded), name: tag))
                }
            }
            await world.addChannel(channel)
            ids.append(channel.id)
        }
        var updated = try await world.guild(guildID)
        updated.systemChannelID = ids[0]
        await world.addGuild(updated)
        var welcome = MessageDraft(content: "welcome in! say hi in #general 👋")
        welcome.type = 0
        try await seed(welcome, author: me, channel: ids[0], at: founded.addingTimeInterval(120))
        try await markRead(ids[0])
        return BenchGuild(id: guildID, welcome: ids[0], general: ids[1], feedback: ids[2])
    }

    /// `count` small servers, each with a few channels and a little history.
    mutating func addServers(count: Int) async throws {
        guard count > 0 else { return }
        await ensurePeople(40)
        for index in 1 ... count {
            let founded = world.epoch.addingTimeInterval(-Double(200 + index) * 86_400)
            let guildID = await world.nextID(at: founded)
            var guild = Guild(id: guildID, name: DemoText.serverName(index: index), ownerID: people[index % people.count])
            guild.roles = [WorldBuilder.everyoneRole(guildID: guildID)]
            for (offset, id) in ([me] + people.shuffledPrefix(12, using: &random)).enumerated() {
                guild.members[id] = Member(userID: id, joinedAt: founded.addingTimeInterval(Double(offset) * 600))
                guild.memberOrder.append(id)
            }
            await world.addGuild(guild)
            for channelIndex in 0 ..< 3 {
                let channel = Channel(id: await world.nextID(at: founded.addingTimeInterval(60)), type: .text, guildID: guildID,
                                      name: DemoText.channelName(index: channelIndex))
                await world.addChannel(channel)
                let authors = guild.memberOrder.filter { $0 != me }
                for messageIndex in 0 ..< 6 {
                    let at = world.epoch.addingTimeInterval(-Double(index * 3_700 + channelIndex * 900 + (6 - messageIndex) * 240))
                    try await seed(MessageDraft(content: DemoText.message(&random)), author: authors[messageIndex % authors.count],
                                   channel: channel.id, at: at)
                }
                if channelIndex > 0 || index % 3 != 0 { try await markRead(channel.id) }
            }
        }
    }

    /// Fills `channelID` with `count` messages ending just before the epoch.
    /// `content=media` cycles twelve messages through a looping video embed, a Lottie sticker and an
    /// animated GIF, with a photo every 97th message: the animated workloads the media scroll measures.
    mutating func fillChannel(_ channelID: Snowflake, count: Int, content: String, pins: Int) async throws {
        let authors = Array(people.prefix(40))
        let lottie = await world.standardStickers.first { $0.formatType == 3 }?.id
        let converter = await DemoConverter(world: world)
        let start = world.epoch.addingTimeInterval(-Double(count) * 37)
        for index in 0 ..< count {
            let author = index % 9 == 4 ? me : authors[(index * 7) % authors.count]
            let at = start.addingTimeInterval(Double(index) * 37)
            var draft = MessageDraft(content: DemoText.message(&random))
            switch content {
            case "media" where index % 12 == 0:
                draft.embeds = [await converter.embed(DemoEmbed(
                    .gifv, url: "https://tenor.com/view/loop-\(index)", provider: "Tenor",
                    thumbnail: DemoEmbedMedia(.photo(seed: UInt64(index), scene: .landscape), width: 320, height: 180),
                    video: DemoEmbedMedia(.bundled("benchmark-video.mp4"), width: 320, height: 180)
                ))]
            case "media" where index % 12 == 1:
                draft.stickerIDs = lottie.map { [$0] } ?? []
            case "media" where index % 12 == 2:
                draft.attachments = [await loopingGIF(channelID: channelID, at: at, index: index)]
            case "media" where index % 97 == 3:
                draft.attachments = [await lazyPhoto(channelID: channelID, at: at, index: index)]
            case "voice" where index % 5 == 2:
                draft.content = ""
                draft.flags = 1 << 13
                draft.attachments = [await voiceMessage(channelID: channelID, at: at)]
            case "files" where index % 4 != 0:
                draft.attachments = [await file(channelID: channelID, at: at, index: index)]
            default:
                break
            }
            let message = try await seed(draft, author: author, channel: channelID, at: at)
            if index >= count - pins { await world.setPinnedQuietly(message.id, in: channelID, at: at) }
            if index % 23 == 5 {
                try await world.addReactionQuietly(message.id, in: channelID, emoji: random.pick(["👍", "😂", "❤️", "🔥", "👀"]),
                                                   users: Array(authors.shuffledPrefix(Int(1 + random.next() % 4), using: &random)))
            }
        }
        try await markRead(channelID)
    }

    mutating func addForumPosts(_ forumID: Snowflake, count: Int) async throws {
        let authors = Array(people.prefix(40))
        let forum = try await world.channel(forumID)
        for index in 0 ..< count {
            let at = world.epoch.addingTimeInterval(-Double(count - index) * 173)
            let id = await world.nextID(at: at)
            var thread = Channel(id: id, type: .publicThread, guildID: forum.guildID, name: DemoText.forumPostTitle(&random))
            thread.parentID = forumID
            thread.ownerID = authors[index % authors.count]
            thread.appliedTags = [forum.availableTags[index % forum.availableTags.count].id]
            thread.thread = ThreadMetadata(archiveTimestamp: at, createTimestamp: at)
            thread.threadMembers = [thread.ownerID!]
            await world.addChannel(thread)
            var starter = Message(id: id, channelID: id, authorID: thread.ownerID!, content: DemoText.forumPostBody(&random))
            if index % 3 == 0 { starter.attachments = [await lazyPhoto(channelID: id, at: at, index: index)] }
            await world.seedMessage(starter)
            for reply in 0 ..< Int(random.next() % 4) {
                try await seed(MessageDraft(content: DemoText.message(&random)), author: authors[(index + reply + 1) % authors.count],
                               channel: id, at: at.addingTimeInterval(Double(reply + 1) * 40))
            }
        }
    }

    mutating func addThreads(in channelID: Snowflake, count: Int, messages: Int) async throws {
        let channel = try await world.channel(channelID)
        let parents = channel.messages.suffix(count * 3).enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        for (index, parent) in parents.prefix(count).enumerated() {
            var thread = Channel(id: parent.id, type: .publicThread, guildID: channel.guildID, name: "Motion thread \(index + 1): \(DemoText.forumPostTitle(&random))")
            thread.parentID = channelID
            thread.ownerID = parent.authorID
            thread.thread = ThreadMetadata(archiveTimestamp: parent.timestamp, createTimestamp: parent.timestamp)
            thread.threadMembers = [me, parent.authorID]
            await world.addChannel(thread)
            await world.setThreadQuietly(parent.id, in: channelID)
            try await fillChannel(parent.id, count: messages, content: "text", pins: 0)
        }
    }

    mutating func addRelationships(friends: Int, incoming: Int, outgoing: Int) async throws {
        await ensurePeople(friends + incoming + outgoing)
        for (index, id) in people.prefix(friends + incoming + outgoing).enumerated() {
            let type: RelationshipType = index < friends ? .friend : (index < friends + incoming ? .incoming : .outgoing)
            let since = world.epoch.addingTimeInterval(-Double(index + 1) * 3_100)
            await world.setRelationship(me, Relationship(userID: id, type: type, since: since))
            if type == .friend { await world.setRelationship(id, Relationship(userID: me, type: .friend, since: since)) }
        }
    }

    // MARK: Helpers

    @discardableResult
    mutating func seed(_ draft: MessageDraft, author: Snowflake, channel: Snowflake, at date: Date) async throws -> Message {
        var message = Message(id: await world.nextID(at: date), channelID: channel, authorID: author, content: draft.content)
        message.type = draft.type
        message.flags = draft.flags
        message.attachments = draft.attachments
        message.embeds = draft.embeds
        message.stickerIDs = draft.stickerIDs
        message.mentions = await world.parseMentions(draft.content, in: try await world.channel(channel)).users
        await world.seedMessage(message)
        return message
    }

    func markRead(_ channelID: Snowflake) async throws {
        guard let last = try await world.channel(channelID).lastMessageID else { return }
        await world.setReadState(me, channel: channelID, ReadState(lastAckedID: last))
    }

    mutating func lazyPhoto(channelID: Snowflake, at date: Date, index: Int) async -> Attachment {
        let id = await world.nextID(at: date)
        let width = [1_280, 960, 1_600, 720][index % 4], height = [960, 1_280, 900, 720][index % 4]
        let path = "/attachments/\(channelID)/\(id)/IMG_\(4_000 + index).jpg"
        let seed = random.next()
        await world.storeLazyMedia(path) { (MediaGenerator.photoJPEG(seed: seed, width: width, height: height), "image/jpeg") }
        return Attachment(id: id, filename: "IMG_\(4_000 + index).jpg", size: width * height / 9, contentType: "image/jpeg",
                          width: width, height: height, cdnPath: path)
    }

    func loopingGIF(channelID: Snowflake, at date: Date, index: Int) async -> Attachment {
        let id = await world.nextID(at: date)
        let name = "loop-\(index).gif"
        let path = "/attachments/\(channelID)/\(id)/\(name)"
        await world.storeLazyMedia(path) { (MediaGenerator.animatedGIF(seed: UInt64(index), size: 320), "image/gif") }
        return Attachment(id: id, filename: name, size: 180_000, contentType: "image/gif", width: 320, height: 320, cdnPath: path)
    }

    func voiceMessage(channelID: Snowflake, at date: Date) async -> Attachment {
        let id = await world.nextID(at: date)
        let path = "/attachments/\(channelID)/\(id)/voice-message.ogg"
        let data = MediaGenerator.bundled("demo-voice-message.ogg") ?? Data()
        await world.storeMedia(path, data, contentType: "audio/ogg")
        var attachment = Attachment(id: id, filename: "voice-message.ogg", size: data.count, contentType: "audio/ogg",
                                    durationSeconds: 6.2, cdnPath: path)
        attachment.flags = 1 << 13
        attachment.waveform = DemoConverter.waveform(seed: id.rawValue)
        return attachment
    }

    mutating func file(channelID: Snowflake, at date: Date, index: Int) async -> Attachment {
        struct Kind {
            let filename: String
            let contentType: String
            let size: Int
        }
        let kinds = [
            Kind(filename: "setlist.txt", contentType: "text/plain; charset=utf-8", size: 2_400),
            Kind(filename: "recipe-notes.pdf", contentType: "application/pdf", size: 182_000),
            Kind(filename: "trip-photos.zip", contentType: "application/zip", size: 48_000_000),
            Kind(filename: "budget.csv", contentType: "text/csv", size: 12_000),
            Kind(filename: "practice-take.mp3", contentType: "audio/mpeg", size: 3_400_000),
            Kind(filename: "garden-plan.key", contentType: "application/x-iwork-keynote-sffkey", size: 2_100_000),
        ]
        let kind = kinds[index % kinds.count]
        let id = await world.nextID(at: date)
        let path = "/attachments/\(channelID)/\(id)/\(kind.filename)"
        await world.storeLazyMedia(path) {
            (MediaGenerator.bundled("demo-notes.txt") ?? Data("notes\n".utf8), kind.contentType)
        }
        return Attachment(id: id, filename: kind.filename, size: kind.size, contentType: kind.contentType, cdnPath: path)
    }
}

extension Array {
    func shuffledPrefix(_ count: Int, using random: inout SeededRandom) -> ArraySlice<Element> {
        var copy = self
        for index in copy.indices.reversed() where index > 0 {
            copy.swapAt(index, Int(random.next() % UInt64(index + 1)))
        }
        return copy.prefix(count)
    }
}

extension World {
    func setPinnedQuietly(_ messageID: Snowflake, in channelID: Snowflake, at date: Date) {
        guard let index = channels[channelID]?.messages.firstIndex(where: { $0.id == messageID }) else { return }
        channels[channelID]?.messages[index].pinned = true
        channels[channelID]?.messages[index].pinnedAt = date
        markPinned(channelID, at: date)
    }

    func setThreadQuietly(_ messageID: Snowflake, in channelID: Snowflake) {
        guard let index = channels[channelID]?.messages.firstIndex(where: { $0.id == messageID }) else { return }
        channels[channelID]?.messages[index].threadID = messageID
    }

    func addReactionQuietly(_ messageID: Snowflake, in channelID: Snowflake, emoji: String, users: [Snowflake]) throws {
        guard let index = try channel(channelID).messages.firstIndex(where: { $0.id == messageID }) else { return }
        var reaction = Reaction(emojiName: emoji)
        reaction.users = users
        channels[channelID]?.messages[index].reactions.append(reaction)
    }
}
