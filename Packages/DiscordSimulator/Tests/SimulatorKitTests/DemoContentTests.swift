import Foundation
@testable import SimulatorKit
import Testing

/// One ordered message list (channel, DM, thread or forum post) and the
/// channel key forwards and labels resolve against.
private struct MessageList {
    let name: String
    let channel: String
    let messages: [DemoMessage]
}

private let allLists: [MessageList] = {
    var lists: [MessageList] = []
    func add(_ name: String, _ channel: String, _ messages: [DemoMessage]) {
        lists.append(MessageList(name: name, channel: channel, messages: messages))
        for message in messages {
            if let thread = message.thread { add("\(name) › \(thread.name)", channel, thread.messages) }
        }
    }
    for channel in DemoContent.guilds.flatMap(\.channels) {
        add(channel.name, channel.key, channel.messages)
        for post in channel.posts { add("\(channel.name) › \(post.title)", channel.key, post.messages) }
    }
    for direct in DemoContent.directChannels { add(direct.key, direct.key, direct.messages) }
    return lists
}()

private let allMessages = allLists.flatMap(\.messages)
private let personKeys = Set(DemoContent.people.map(\.key))
private let emojiNames = Set(DemoContent.guilds.flatMap(\.emojis).map(\.name))
private let roleKeys = Set(DemoContent.guilds.flatMap(\.roles).map(\.key))
private let channelKeys = DemoContent.guilds.flatMap(\.channels).map(\.key) + DemoContent.directChannels.map(\.key)

/// Every piece of text a person could read in the demo.
private func readableText(_ message: DemoMessage) -> [String] {
    var text = [message.content]
    text += message.attachments.flatMap { [$0.filename, $0.altText ?? ""] }
    text += message.embeds.flatMap { embed in
        [embed.title, embed.description, embed.footer, embed.authorName, embed.provider, embed.url].compactMap(\.self)
            + embed.fields.flatMap { [$0.name, $0.value] }
    }
    if let poll = message.poll { text += [poll.question] + poll.answers.map(\.text) }
    if let thread = message.thread { text.append(thread.name) }
    for component in message.components.flatMap(\.components) {
        switch component {
        case .button(let label, _, _, _, let url, _): text += [label, url ?? ""]
        case .select(_, let placeholder, let options, _, _): text += [placeholder] + options.flatMap { [$0.label, $0.description ?? ""] }
        }
    }
    return text
}

private func emojiRefs(_ message: DemoMessage) -> [DemoEmojiRef] {
    var refs = message.reactions.map(\.emoji)
    refs += message.poll?.answers.compactMap(\.emoji) ?? []
    for case .select(_, _, let options, _, _) in message.components.flatMap(\.components) {
        refs += options.compactMap(\.emoji)
    }
    return refs
}

struct DemoContentTests {
    @Test func peopleHaveUniqueKeysAndUsernames() {
        #expect(personKeys.count == DemoContent.people.count)
        #expect(Set(DemoContent.people.map(\.username)).count == DemoContent.people.count)
        #expect(DemoContent.people.allSatisfy { $0.username == $0.username.lowercased() })
        #expect(personKeys.contains(DemoContent.selfKey))
        #expect(DemoContent.people.first { $0.key == DemoContent.selfKey }?.premium == .nitro)
        #expect(DemoContent.people.contains { $0.premium == .nitroBasic })
        #expect(DemoContent.people.filter(\.isBot).count == 1)
    }

    @Test func generalHasAboutTwoWeeksOfHistory() throws {
        let general = try #require(DemoContent.porch.channels.first { $0.key == "general" })
        #expect((110 ... 130).contains(general.messages.count))
        #expect(Set(general.messages.map(\.at.day)).count == 14)
        for channel in DemoContent.porch.channels where [.text, .announcement].contains(channel.kind) && channel.key != "general" {
            #expect(channel.messages.count >= 9, "\(channel.name) is thin")
        }
    }

    @Test func secondServerShowsBoostLevelThree() {
        #expect(DemoContent.garden.boostTier == 3)
        #expect(DemoContent.porch.boostTier == 1)
        #expect(DemoContent.guilds.allSatisfy { guild in guild.members.contains { $0.boostingSince != nil } })
    }

    @Test func everyPersonReferenceExists() {
        var references: [String] = DemoContent.relationships.map(\.person)
        for guild in DemoContent.guilds {
            references += [guild.owner] + guild.members.map(\.person)
            references += guild.channels.flatMap(\.voiceStates).map(\.person)
        }
        for direct in DemoContent.directChannels { references += direct.recipients + [direct.owner].compactMap(\.self) }
        for message in allMessages {
            references.append(message.author)
            references += message.reactions.flatMap { $0.users + $0.burstUsers }
            references += message.poll?.answers.flatMap(\.voters) ?? []
            references += message.embeds.flatMap { [$0.authorIcon, $0.footerIcon].compactMap(\.self) }
            if let interaction = message.interaction { references.append(interaction.user) }
            switch message.system {
            case .recipientAdded(let person), .recipientRemoved(let person): references.append(person)
            case .call(let participants, _): references += participants
            default: break
            }
            for text in readableText(message) {
                for case .user(let key) in DemoMarkup.tokens(in: text) { references.append(key) }
            }
        }
        let missing = Set(references).subtracting(personKeys)
        #expect(missing.isEmpty, "unknown people: \(missing.sorted())")
    }

    @Test func reactionsAreUniquePerPersonAndBurstOnlyFromNitro() {
        let nitro = Set(DemoContent.people.filter { $0.premium == .nitro }.map(\.key))
        for message in allMessages {
            for reaction in message.reactions {
                #expect(Set(reaction.users).count == reaction.users.count, "\(message.content): duplicate reactor")
                #expect(Set(reaction.burstUsers).isSubset(of: nitro))
                #expect(Set(reaction.burstUsers).isSubset(of: Set(reaction.users)))
            }
        }
    }

    @Test func labelsRepliesPinsAndForwardsResolve() {
        var labelsByChannel: [String: Set<String>] = [:]
        for list in allLists {
            let labels = list.messages.compactMap(\.label)
            #expect(Set(labels).count == labels.count, "\(list.name): duplicate labels")
            labelsByChannel[list.channel, default: []].formUnion(labels)
            for message in list.messages {
                if let reply = message.replyTo { #expect(labels.contains(reply), "\(list.name): reply to \(reply)") }
                switch message.system {
                case .pinned(let label):
                    #expect(list.messages.contains { $0.label == label && $0.pinned }, "\(list.name): pin of \(label)")
                case .pollResult(let label):
                    #expect(list.messages.contains { $0.label == label && $0.poll?.finalized == true }, "\(list.name): poll \(label)")
                default: break
                }
            }
        }
        for forward in allMessages.compactMap(\.forward) {
            #expect(labelsByChannel[forward.channel]?.contains(forward.label) == true, "forward of \(forward)")
        }
        for channel in DemoContent.guilds.flatMap(\.channels) {
            if let unread = channel.unreadFrom { #expect(channel.messages.contains { $0.label == unread }) }
        }
        for direct in DemoContent.directChannels {
            if let unread = direct.unreadFrom { #expect(direct.messages.contains { $0.label == unread }) }
        }
    }

    @Test func keysEmojiStickersRolesAndChannelsResolve() {
        #expect(Set(channelKeys).count == channelKeys.count)
        #expect(emojiNames.count == DemoContent.guilds.flatMap(\.emojis).count)
        let stickers = DemoContent.guilds.flatMap(\.stickers).map(\.name) + DemoContent.standardStickers.map(\.name)
        #expect(Set(stickers).count == stickers.count)
        for guild in DemoContent.guilds {
            let roles = Set(guild.roles.map(\.key))
            #expect(guild.members.allSatisfy { Set($0.roles).isSubset(of: roles) })
            #expect(Set(guild.channels.map(\.key)).contains(guild.systemChannel))
            for forum in guild.channels where forum.kind == .forum {
                let tags = Set(forum.forumTags.map(\.name))
                #expect(forum.posts.allSatisfy { Set($0.tags).isSubset(of: tags) })
            }
        }
        for message in allMessages {
            #expect(Set(message.stickers).isSubset(of: Set(stickers)))
            for case .custom(let name) in emojiRefs(message) { #expect(emojiNames.contains(name), "unknown emoji \(name)") }
            for text in readableText(message) {
                for token in DemoMarkup.tokens(in: text) {
                    switch token {
                    case .emoji(let name, _): #expect(emojiNames.contains(name), "unknown emoji \(name)")
                    case .role(let key): #expect(roleKeys.contains(key), "unknown role \(key)")
                    case .channel(let key): #expect(channelKeys.contains(key), "unknown channel \(key)")
                    case .user, .timestamp, .weekday: break
                    }
                }
            }
        }
    }

    @Test func historyIsChronologicalAndInThePast() {
        for list in allLists {
            let times = list.messages.map(\.at)
            #expect(times == times.sorted(), "\(list.name) is out of order")
            #expect(times.allSatisfy { $0 <= DemoContent.now }, "\(list.name) has future messages")
        }
    }

    @Test func textStaysInWorld() {
        var text = allMessages.flatMap(readableText)
        text += DemoContent.people.flatMap { [$0.displayName, $0.bio, $0.presence.customStatus ?? ""] }
        for guild in DemoContent.guilds {
            text += [guild.name, guild.description] + guild.roles.map(\.name)
            text += guild.categories.compactMap(\.name) + guild.stickers.flatMap { [$0.name, $0.description] }
            text += guild.channels.flatMap { [$0.name, $0.topic ?? ""] + $0.posts.map(\.title) }
        }
        text += DemoContent.directChannels.compactMap(\.name)
        for line in text {
            let lowered = line.lowercased()
            for word in ["sakuracord", "simulator", "benchmark", "test", "discord"] {
                #expect(!lowered.contains(word), "\"\(line)\" mentions \(word)")
            }
        }
    }

    @Test func bundledMediaExists() {
        var names: Set<String> = []
        for message in allMessages {
            for case .bundled(let name) in message.attachments.map(\.media) { names.insert(name) }
            for embed in message.embeds {
                for case .bundled(let name) in [embed.image, embed.thumbnail, embed.video].compactMap({ $0?.media }) { names.insert(name) }
            }
        }
        for case .bundled(let name) in (DemoContent.guilds.flatMap(\.stickers) + DemoContent.standardStickers).map(\.media) {
            names.insert(name)
        }
        #expect(!names.isEmpty)
        for name in names { #expect(MediaGenerator.bundled(name) != nil, "missing \(name)") }
    }

    @Test func markupResolvesPlaceholders() {
        let text = "hi <@wren> in <#general> <@&band> <a:busybee:> <t:-1@09:30:R> <3 a<b"
        let resolved = DemoMarkup.resolve(text, id: { token in
            switch token {
            case .user: "1"
            case .channel: "2"
            case .role: "3"
            case .emoji: "4"
            case .timestamp, .weekday: "x"
            }
        }, date: { Date(timeIntervalSince1970: Double($0.secondsFromStartOfDayZero)) })
        #expect(resolved == "hi <@1> in <#2> <@&3> <a:busybee:4> <t:\(-86_400 + 34_200):R> <3 a<b")
        let sunday = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        let days = DemoMarkup.resolve("<day:-1:l> <day:0:S> <day:1:L> <day:2:s> <day:3:x>", id: { _ in "" },
                                      date: { sunday.addingTimeInterval(Double($0.secondsFromStartOfDayZero)) })
        #expect(days == "saturday Sun Monday tue <day:3:x>")
        #expect(DemoTime(day: -1, 23, 50).adding(minutes: 20) == DemoTime(day: 0, 0, 10))
    }
}
