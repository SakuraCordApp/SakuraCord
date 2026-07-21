@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Test func `mock fixture is synthetic rich and available offline`() async throws {
    let provider = MockChatProvider()
    let snapshot = try await provider.bootstrap()

    #expect(snapshot.currentUser.displayName == "Nova Chen")
    #expect(snapshot.guilds.count == 2)
    #expect(snapshot.guilds.allSatisfy { $0.iconURL?.isFileURL == true })
    #expect(snapshot.guilds.allSatisfy { guild in
        guild.iconURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    })

    for guild in snapshot.guilds {
        let emojis = try await provider.emojis(in: guild.id)
        #expect(!emojis.isEmpty)
        #expect(emojis.allSatisfy { $0.guildID == guild.id })
        #expect(emojis.allSatisfy { $0.imageURL?.isFileURL == true })
        #expect(emojis.allSatisfy { emoji in
            emoji.imageURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        })
    }

    let members = try await provider.members(in: GuildID(rawValue: 100))
    #expect(members.count == 5)
    let searchedMembers = try await provider.searchMembers(
        in: GuildID(rawValue: 100), query: "maya", limit: 25
    )
    #expect(searchedMembers.map(\.user.displayName) == ["Maya • Orbit"])
    #expect(members.allSatisfy { $0.user.avatarURL?.isFileURL == true })
    for member in members {
        let profile = try await provider.profile(for: member.user.id, in: GuildID(rawValue: 100))
        #expect(profile.bio?.isEmpty == false)
        #expect(profile.pronouns?.isEmpty == false)
        #expect(!profile.roles.isEmpty)
    }

    for rawChannelID: UInt64 in [200, 210, 211, 212, 300, 301, 302, 400] {
        let channelID = ChannelID(rawValue: rawChannelID)
        let page = try await provider.messages(in: channelID, before: nil, limit: 50)
        #expect(!page.messages.isEmpty)
    }

    let threadID = ChannelID(rawValue: 901)
    let threadPage = try await provider.messages(in: threadID, before: nil, limit: 50)
    #expect(threadPage.messages.map(\.id) == [MessageID(rawValue: 9011), MessageID(rawValue: 9012)])
    #expect(threadPage.messages.allSatisfy { $0.channelID == threadID })
}

@Test func `mock long server list fixture provides scrollable guild and emoji rails`() async throws {
    let provider = MockChatProvider(includesLongServerList: true)
    let snapshot = try await provider.bootstrap()

    #expect(snapshot.guilds.count == 20)
    let lastGuild = try #require(snapshot.guilds.last)
    #expect(lastGuild.name == "Scroll Test 18")
    #expect(lastGuild.iconURL == nil)
    #expect(snapshot.guildRailItems.count == 11)
    #expect(snapshot.guildRailItems.compactMap { item -> GuildFolder? in
        guard case let .folder(folder) = item else { return nil }
        return folder
    }.map(\.name) == ["Native Projects", "Communities"])

    let channels = try await provider.channels(in: lastGuild.id)
    let channel = try #require(channels.first)
    #expect(channel.name == "general")
    #expect(try await !(provider.messages(in: channel.id, before: nil, limit: 50)).messages.isEmpty)
    #expect(try await (provider.members(in: lastGuild.id)).count == 2)
}

@Test func `mock reactions provide local avatar fixtures and reconcile the current reactor`() async throws {
    let provider = MockChatProvider()
    let snapshot = try await provider.bootstrap()
    let channelID = ChannelID(rawValue: 210)
    let messageID = MessageID(rawValue: 2002)
    var message = try #require(
        try await provider.messages(in: channelID, before: nil, limit: 50).messages.first {
            $0.id == messageID
        }
    )
    let reaction = try #require(message.reactions.first { $0.emoji == "😭" })
    #expect(reaction.reactors.count == 2)
    #expect(reaction.reactors.allSatisfy { $0.avatarURL?.isFileURL == true })
    #expect(reaction.didCurrentUserReact)

    let overflowing = try #require(message.reactions.first { $0.emoji == "🔥" })
    let overflowingReactors = try await provider.reactionReactors(
        for: overflowing.emoji,
        messageID: messageID,
        channelID: channelID,
        reactionCount: overflowing.count
    )
    #expect(overflowingReactors.count == 5)
    #expect(overflowingReactors.allSatisfy { $0.avatarURL?.isFileURL == true })

    try await provider.toggleReaction(reaction.emoji, messageID: messageID, channelID: channelID)
    message = try #require(
        try await provider.messages(in: channelID, before: nil, limit: 50).messages.first {
            $0.id == messageID
        }
    )
    var updated = try #require(message.reactions.first { $0.emoji == reaction.emoji })
    #expect(!updated.didCurrentUserReact)
    #expect(!updated.reactors.contains { $0.id == snapshot.currentUser.id })

    try await provider.toggleReaction(reaction.emoji, messageID: messageID, channelID: channelID)
    message = try #require(
        try await provider.messages(in: channelID, before: nil, limit: 50).messages.first {
            $0.id == messageID
        }
    )
    updated = try #require(message.reactions.first { $0.emoji == reaction.emoji })
    #expect(updated.didCurrentUserReact)
    #expect(updated.reactors.contains { $0.id == snapshot.currentUser.id })
}

@Test func `mock attachment send copies the selected file into demo storage`() async throws {
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    let sourceDirectory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let source = sourceDirectory.appending(path: "demo-note.txt")
    let contents = Data("A fictional attachment from the SakuraCord demo.".utf8)
    try contents.write(to: source)

    let sent = try await provider.send(SendMessageDraft(
        channelID: ChannelID(rawValue: 210),
        content: "",
        attachmentURLs: [source],
        nonce: "demo-attachment-test"
    ))
    let attachment = try #require(sent.attachments.first)
    defer { try? FileManager.default.removeItem(at: attachment.url) }

    #expect(attachment.filename == "demo-note.txt")
    #expect(attachment.mediaType == "text/plain")
    #expect(attachment.size == contents.count)
    #expect(attachment.url != source)
    #expect(attachment.url.isFileURL)
    #expect(try Data(contentsOf: attachment.url) == contents)
}

@Test func `mock slash commands cover ephemeral deferred followup and failure lifecycles`() async throws {
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    let channelID = ChannelID(rawValue: 210)
    let guildID = GuildID(rawValue: 100)
    let catalog = try await provider.applicationCommandCatalog(for: .guild(guildID))
    let responseCommands = catalog.commands.filter { $0.name == "response" }
    #expect(Set(responseCommands.map(\.subcommandPath.last?.name)) == [
        "normal", "ephemeral", "deferred", "followup", "failure"
    ])

    func command(_ mode: String) throws -> ApplicationCommand {
        try #require(responseCommands.first { $0.subcommandPath.last?.name == mode })
    }
    func invocation(_ mode: String) throws -> ApplicationCommandInvocation {
        ApplicationCommandInvocation(
            command: try command(mode),
            channelID: channelID,
            guildID: guildID,
            values: [],
            nonce: "offline-response-\(mode)"
        )
    }

    try await provider.executeApplicationCommand(try invocation("ephemeral")) { _ in }
    var messages = try await provider.messages(in: channelID, before: nil, limit: 100).messages
    let ephemeral = try #require(messages.first { $0.nonce == "offline-response-ephemeral" })
    #expect(ephemeral.flags.contains(.ephemeral))

    try await provider.executeApplicationCommand(try invocation("deferred")) { _ in }
    messages = try await provider.messages(in: channelID, before: nil, limit: 100).messages
    let deferred = try #require(messages.first { $0.nonce == "offline-response-deferred" })
    #expect(!deferred.flags.contains(.loading))
    #expect(deferred.editedTimestamp != nil)
    #expect(deferred.content.contains("completed successfully"))

    try await provider.executeApplicationCommand(try invocation("followup")) { _ in }
    messages = try await provider.messages(in: channelID, before: nil, limit: 100).messages
    #expect(messages.contains { $0.nonce == "offline-response-followup" })
    #expect(messages.contains { $0.content == "This is the synthetic follow-up response." })

    let events = await provider.eventStream()
    let failure = Task { () -> String? in
        for await event in events {
            if case let .interaction(.failed(nonce, message)) = event,
               nonce == "offline-response-failure"
            {
                return message
            }
        }
        return nil
    }
    try await provider.executeApplicationCommand(try invocation("failure")) { _ in }
    #expect(await failure.value == "Synthetic interaction failure. No retry was attempted.")
    messages = try await provider.messages(in: channelID, before: nil, limit: 100).messages
    #expect(!messages.contains { $0.nonce == "offline-response-failure" })
}
