import DiscordProtocol
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test(arguments: [ChannelKindValue.text, .forum, .voice])
func commandDestinationRouting(kind: ChannelKindValue) async throws {
    let (model, provider, destination, target) = commandDestinationFixture(kind: kind)
    defer { UserDefaults.standard.removeObject(forKey: "dev.sakuracord.command-frecency-pending.\(provider.scope)") }
    let editor = model.commandComposer(for: destination)
    model.loadApplicationCommands(in: destination)
    await editor.loadTask?.value
    #expect(editor.hasLoadedCatalogs)
    let command = try #require(editor.commands.first { $0.name == "find" })
    if destination == .thread {
        model.commandComposer.activate(command)
        model.commandComposer.setText("parent", for: .field("query"))
        model.draft = "parent text"
    }
    editor.activate(command)
    editor.setText("child", for: .field("query"))
    model.refreshApplicationCommandAutocomplete(in: destination)
    for task in Array(model.accountChildTasks.values) { await task.value }
    let request = try #require(await provider.autocompleteRequests.last)
    #expect(request.invocation.channelID == target)
    #expect(request.invocation.guildID == GuildID(rawValue: 100))
    model.consumePresenceAndCommandEvent(.applicationCommandAutocomplete(.init(
        nonce: request.nonce, choices: [.init(name: "child", value: .string("child"))]
    )))
    #expect(editor.autocompleteStatus.choices.map(\.name) == ["child"])
    if destination == .thread { #expect(model.commandComposer.autocompleteStatus == .idle) }

    model.executeApplicationCommand(in: destination)
    try #require(editor.draft == nil)
    let tasks = Array(model.accountChildTasks.values)
    let invocation = try #require(await provider.nextInvocation())
    #expect(invocation.channelID == target)
    #expect(invocation.guildID == GuildID(rawValue: 100))
    #expect(invocation.values.first?.argument == .string("child"))
    #expect(editor.draft == nil)
    if destination == .thread {
        #expect(model.draft == "parent text")
        #expect(model.commandComposer.draft?.field("query")?.text == "parent")
        #expect(model.threadMessages.contains { $0.nonce == invocation.nonce })
        #expect(!model.messages.contains { $0.nonce == invocation.nonce })
    }
    await provider.finishExecution(failing: false)
    for task in tasks { await task.value }
    model.consumeInteraction(.succeeded(nonce: invocation.nonce, interactionID: nil))
    #expect(model.commandComposer.frecencyStore === model.threadCommandComposer.frecencyStore)
}

@MainActor
@Test(arguments: [false, true])
func threadCommandFailureRestoration(reopen: Bool) async throws {
    let (model, provider, _, _) = commandDestinationFixture(kind: .forum)
    defer { UserDefaults.standard.removeObject(forKey: "dev.sakuracord.command-frecency-pending.\(provider.scope)") }
    let editor = model.threadCommandComposer
    editor.activate(CommandDestinationProvider.command)
    editor.setText("recover me", for: .field("query"))
    model.draft = "keep parent draft"
    model.executeApplicationCommand(in: .thread)
    try #require(editor.draft == nil)
    let tasks = Array(model.accountChildTasks.values)
    _ = try #require(await provider.nextInvocation())
    if reopen {
        let thread = model.openThread
        model.closeThread()
        model.openThread = thread
        model.threadDraft = "new visit"
    }
    await provider.finishExecution(failing: true)
    for task in tasks { await task.value }
    #expect(model.draft == "keep parent draft")
    #expect(model.commandComposer.draft == nil)
    if reopen {
        #expect(editor.draft == nil)
        #expect(model.threadDraft == "new visit")
    } else {
        #expect(editor.draft?.field("query")?.text == "recover me")
    }
    model.closeThread()
    #expect(editor.draft == nil)
    #expect(model.commandContext(for: .thread) == nil)
}

@MainActor
private func commandDestinationFixture(kind: ChannelKindValue) -> (AppModel, CommandDestinationProvider, MessageComposerDestination, ChannelID) {
    let provider = CommandDestinationProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    let guild = Guild(id: .init(rawValue: 100), name: "Fixture", isOwnedByCurrentUser: true, currentUserPermissions: .max)
    let channel = Channel(id: .init(rawValue: 200), guildID: guild.id, name: "parent", kind: kind)
    model.snapshot = BootstrapSnapshot(currentUser: CommandDestinationProvider.user, guilds: [guild], channels: [channel], members: [])
    model.serverRailGuildsByID = [guild.id: guild]
    model.commandComposer.configureFrecencyScope(provider.scope)
    model.visibleChannels = [channel]
    model.selectedGuildID = guild.id
    model.selectedChannelID = channel.id
    model.supportedCapabilities = [.slashCommands]
    let destination: MessageComposerDestination = kind == .voice ? .channel : .thread
    if destination == .thread {
        model.openThread = MessageThreadSummary(id: .init(rawValue: 300), guildID: guild.id, parentID: channel.id, name: "child")
    }
    return (model, provider, destination, destination == .thread ? ChannelID(rawValue: 300) : channel.id)
}

private actor CommandDestinationProvider: ChatProvider {
    nonisolated let scope = "command-destinations-\(UUID().uuidString)"
    static let user = User(id: .init(rawValue: 1), username: "fixture", displayName: "Fixture")
    static let command = ApplicationCommand(
        id: "400", rootCommandID: "400", applicationID: "500", version: "1", name: "find",
        application: .init(id: "500", name: "Fixture"),
        options: [.init(id: "query", name: "query", type: .string, isRequired: true, usesAutocomplete: true)]
    )
    private let executions = AsyncStream<ApplicationCommandInvocation>.makeStream()
    private var completion: CheckedContinuation<Void, any Error>?
    private(set) var autocompleteRequests: [ApplicationCommandAutocompleteRequest] = []

    func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws -> ApplicationCommandCatalog {
        ApplicationCommandCatalog(target: target, applications: [Self.command.application], commands: [Self.command])
    }
    func requestApplicationCommandAutocomplete(_ request: ApplicationCommandAutocompleteRequest) async throws {
        autocompleteRequests.append(request)
    }
    func executeApplicationCommand(_ invocation: ApplicationCommandInvocation, progress: @escaping @Sendable (ApplicationCommandProgress) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            executions.continuation.yield(invocation)
        }
    }
    func nextInvocation() async -> ApplicationCommandInvocation? {
        for await invocation in executions.stream { return invocation }
        return nil
    }
    func finishExecution(failing: Bool) {
        if failing { completion?.resume(throwing: ChatProviderError.invalidRequest("Fixture rejection")) }
        else { completion?.resume() }
        completion = nil
    }
    func bootstrap() async throws -> BootstrapSnapshot { .init(currentUser: Self.user, guilds: [], channels: [], members: []) }
    func channels(in guildID: GuildID?) async throws -> [Channel] { [] }
    func members(in guildID: GuildID?) async throws -> [Member] { [] }
    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile { throw ChatProviderError.invalidRequest("Unused") }
    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage { .init(messages: [], hasMoreBefore: false) }
    func send(_ draft: SendMessageDraft) async throws -> Message { throw ChatProviderError.invalidRequest("Unexpected message send") }
    func edit(_ message: Message, content: String) async throws -> Message { throw ChatProviderError.invalidRequest("Unused") }
    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}
