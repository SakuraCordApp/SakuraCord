import Foundation

/// Ongoing threads, forum posts and scheduled events in generated servers.
extension RealisticWorld {
    /// Threads the account joined, under the busiest text channels; READY lists them.
    mutating func addThreads(_ count: Int, _ draft: ServerDraft, _ rng: inout SeededRandom) async throws {
        let parents = Array(draft.messageChannels.prefix(max(1, draft.textChannels)))
        guard !parents.isEmpty else { return }
        for index in 0 ..< count {
            let opened = world.epoch.addingTimeInterval(-Double(1 + rng.next() % 72) * 3_600)
            let title = DemoText.forumPostTitle(&rng)
            try await addThread(title, parent: parents[index % parents.count], draft, opened: opened, joined: true, &rng)
        }
    }

    /// Posts in each forum: the ones the account follows (the profile's count) and others around them.
    mutating func addForumPosts(_ followed: Int, _ draft: ServerDraft, _ rng: inout SeededRandom) async throws {
        var remaining = followed
        for forum in draft.forums {
            let tags = try await world.channel(forum).availableTags.map(\.id)
            for _ in 0 ..< 3 + Int(rng.next() % 6) {
                let opened = world.epoch.addingTimeInterval(-Double(1 + rng.next() % 900) * 3_600)
                let post = try await addThread(DemoText.forumPostTitle(&rng), parent: forum, draft, opened: opened, joined: remaining > 0, &rng,
                                               starter: DemoText.forumPostBody(&rng))
                remaining -= 1
                await world.setAppliedTags(post, Array(tags.shuffledPrefix(Int(rng.next() % 3), using: &rng)))
            }
        }
    }

    /// A public thread with a few replies. A forum post's starter message shares the post's ID, as on Discord.
    @discardableResult
    private mutating func addThread(_ name: String, parent: Snowflake, _ draft: ServerDraft, opened: Date, joined: Bool,
                                    _ rng: inout SeededRandom, starter: String? = nil) async throws -> Snowflake {
        let authors = draft.members.filter { $0 != me }
        let owner = rng.pick(authors)
        let id = await world.nextID(at: opened)
        var thread = Channel(id: id, type: .publicThread, guildID: draft.guildID, name: name)
        thread.parentID = parent
        thread.ownerID = owner
        // Kept short: busy accounts have hundreds of forums, and threads are stored up front.
        let replies = 1 + Int(rng.next() % 4)
        let last = opened.addingTimeInterval(Double(replies) * 600)
        thread.thread = ThreadMetadata(archived: last < world.epoch.addingTimeInterval(-7 * 86_400), archiveTimestamp: last, createTimestamp: opened)
        thread.threadMembers = Array(Set([owner] + authors.shuffledPrefix(3, using: &rng) + (joined ? [me] : []))).sorted()
        await world.addChannel(thread)
        if let starter {
            await world.seedMessage(Message(id: id, channelID: id, authorID: owner, content: starter))
        }
        var lastID = id
        for step in 0 ..< replies {
            lastID = try await bench.seed(MessageDraft(content: DemoText.communityMessage(draft.kind, &rng)), author: rng.pick(thread.threadMembers.filter { $0 != me }),
                                          channel: id, at: opened.addingTimeInterval(Double(step + 1) * 600)).id
        }
        await world.setReadState(me, channel: id, ReadState(lastAckedID: lastID))
        return id
    }

    /// Upcoming events: voice hangouts and meetups somewhere else, a few people interested in each.
    func addEvents(_ count: Int, _ draft: ServerDraft, _ rng: inout SeededRandom) async {
        for _ in 0 ..< count {
            let creator = rng.pick(draft.members)
            let start = world.epoch.addingTimeInterval(Double(2 + rng.next() % 300) * 3_600)
            let voice = draft.voiceChannels.isEmpty ? nil : rng.pick(draft.voiceChannels)
            var event = ScheduledEvent(id: await world.nextID(at: world.epoch.addingTimeInterval(-Double(rng.next() % 200) * 3_600)),
                                       guildID: draft.guildID, name: rng.pick(Self.eventNames), creatorID: creator, start: start,
                                       entityType: voice == nil ? .external : .voice)
            event.channelID = voice
            if voice == nil {
                event.location = rng.pick(["the usual café", "online", "the park by the river", "community hall"])
                event.end = start.addingTimeInterval(2 * 3_600)
            }
            event.interested = [creator] + draft.members.shuffledPrefix(Int(rng.next() % 12), using: &rng).filter { $0 != creator }
            await world.setServerState { [event] state in state.scheduledEvents[event.id] = event }
        }
    }

    private static let eventNames = ["Game night", "Community hangout", "Movie night", "Q&A", "Monthly meetup", "Art jam",
                                     "Study session", "Tournament", "Listening party", "Workshop", "Town hall", "Watch party"]
}

extension World {
    func setAppliedTags(_ threadID: Snowflake, _ tags: [Snowflake]) { channels[threadID]?.appliedTags = tags }
}
