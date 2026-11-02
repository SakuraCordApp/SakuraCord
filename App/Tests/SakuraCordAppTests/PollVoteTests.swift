import DiscordProtocol
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test(arguments: [(false, false), (true, false), (false, true)])
func `poll votes apply before confirmation ignore their echo and roll back on failure`(failure: (losesConfirmedResponse: Bool, finalizesOnRejection: Bool)) async throws {
    let provider = PollVoteTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let message = try #require(model.messages.first { $0.poll != nil })
    model.pinnedMessages.items = [PinnedMessage(pinnedAt: .now, message: message)]
    model.inbox.tab = .mentions
    let refresh = model.beginConversationRefresh(in: message.channelID)

    if failure.losesConfirmedResponse { await provider.failNextRequest() }
    #expect(model.vote(on: message, answerIDs: [2]))
    var poll = try #require(model.messages.first?.poll)
    #expect(poll.selectedAnswerIDs == [2])
    #expect(poll.count(for: 2) == 2)
    model.presentInbox()
    await model.inbox.loadTask?.value
    #expect(model.inbox.mentions.first?.poll?.selectedAnswerIDs == [2])
    model.messageSearch.queryText = "Lunch"
    model.submitMessageSearch()
    await provider.waitForSearch()
    // An optimistic selection is presentation, not an authoritative history edit.
    let mutations = model.conversationRefreshMutations(in: message.channelID, revision: refresh)
    #expect(AppModel.applyingConversationRefreshMutations(mutations, to: [message]).first?.poll == message.poll)
    // A server snapshot arriving before the vote response must keep every
    // retained surface on the same pending selection.
    model.consumeImmediately(.messageUpdated(message))
    #expect(model.pinnedMessages.items.first?.message.poll == model.messages.first?.poll)
    #expect(model.inbox.mentions.first?.poll == model.messages.first?.poll)
    model.replaceSelectedMessages(with: [message])
    #expect(model.messages.first?.poll?.selectedAnswerIDs == [2])
    model.presentPinnedMessages()
    await model.pinnedMessages.loadTask?.value
    #expect(model.pinnedMessages.errorMessage == nil)
    #expect(model.pinnedMessages.items.first?.message.poll?.selectedAnswerIDs == [2])

    var echo = MessageUpdate(messageID: message.id, channelID: message.channelID)
    echo.pollUpdates = [.vote(answerID: 2, isAddition: true, isCurrentUser: true)]
    var otherVote = MessageUpdate(messageID: message.id, channelID: message.channelID)
    otherVote.pollUpdates = [.vote(answerID: 1, isAddition: true, isCurrentUser: false)]
    await provider.emit(.messagePatched(echo))
    await provider.emit(.messagePatched(otherVote))
    #expect(await eventually { model.messages.first?.poll?.count(for: 1) == 2 })
    await provider.resumeRequest()
    #expect(await eventually { model.pollVoteMutations.isEmpty })
    poll = try #require(model.messages.first?.poll)
    #expect(poll.selectedAnswerIDs == [2])
    #expect(poll.count(for: 2) == 2)
    await provider.resumeSearch()
    await model.messageSearch.requestTask?.value
    #expect(model.messageSearch.page?.messages.first?.poll?.selectedAnswerIDs == [2])
    #expect(model.messageSearch.rows.first?.message.poll?.count(for: 1) == 2)

    await provider.failNextRequest()
    #expect(model.vote(on: message, answerIDs: [1]))
    poll = try #require(model.messages.first?.poll)
    #expect(poll.selectedAnswerIDs == [1])
    #expect(poll.count(for: 1) == 3 && poll.count(for: 2) == 1)
    if failure.finalizesOnRejection {
        var finalized = poll
        finalized.results = PollResults(isFinalized: true, answerCounts: [
            .init(id: 1, count: 2), .init(id: 2, count: 2)
        ])
        var update = MessageUpdate(messageID: message.id, channelID: message.channelID)
        update.pollUpdates = [.snapshot(finalized, preservingSelection: true)]
        model.consumeImmediately(.messagePatched(update))
    }
    await provider.resumeRequest()
    #expect(await eventually { model.pollVoteMutations.isEmpty })
    poll = try #require(model.messages.first?.poll)
    #expect(poll.selectedAnswerIDs == [2])
    #expect(poll.count(for: 1) == 2 && poll.count(for: 2) == 2)
    let confirmedMutations = model.conversationRefreshMutations(in: message.channelID, revision: refresh)
    #expect(AppModel.applyingConversationRefreshMutations(confirmedMutations, to: [message]).first?.poll == poll)
    model.endConversationRefresh(in: message.channelID, revision: refresh)
    #expect(await provider.requests() == [[2], [1]])
}

@MainActor
@Test func `guide resource messages reconcile reactions and pending poll votes`() async throws {
    let provider = PollVoteTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let message = try #require(model.messages.first { $0.poll != nil })
    let guildID = GuildID(rawValue: 99_003)
    model.replaceSelectedMessages(with: [])
    model.messageCache.removeAll()
    model.selectedGuildID = guildID
    model.onboarding.presentedGuildID = guildID
    model.onboarding.page = .guide
    model.sideConversations.context = .guideResource(guildID, message.channelID)
    model.guideResource = GuildResourceState(
        channelID: message.channelID, messages: [message], rows: [MessageGrouping.resourceRow(for: message)]
    )
    func resourceMessage() throws -> Message {
        try #require(model.presentedGuideResource?.rows.first?.message)
    }
    // The resource pane is the only retained copy; account actions must use it.
    _ = try #require(model.retainedMessage(channelID: message.channelID, messageID: message.id))
    await model.toggleReaction("👍", on: message)
    #expect(try resourceMessage().reactions.first?.didCurrentUserReact == true)
    #expect(await eventually { model.reactionMutations.isEmpty })
    await model.toggleReaction("👍", on: message)
    #expect(await eventually { model.reactionMutations.isEmpty })
    #expect(await provider.reactionRequests() == [true, false])
    model.consumeImmediately(.messageReactionUpdated(.add(
        channelID: message.channelID, messageID: message.id,
        userID: UserID(rawValue: 99_004), emoji: "👍", kind: .normal
    )))
    #expect(try resourceMessage().reactions.first?.count == 1)
    #expect(try resourceMessage().reactions.first?.didCurrentUserReact == false)
    let reactor = ReactionReactor(id: UserID(rawValue: 99_004), displayName: "Resource reader", avatarURL: nil)
    model.inbox.isPresented = true
    model.inbox.tab = .mentions
    model.inbox.mentions = [try resourceMessage()]
    model.applyReactionReactors([reactor], for: .init(
        channelID: message.channelID, messageID: message.id, reactionID: Reaction(emoji: "👍", count: 0).id
    ))
    #expect(try resourceMessage().reactions.first?.reactors == [reactor])
    #expect(model.inbox.mentions.first?.reactions.first?.reactors == [reactor])

    #expect(model.vote(on: message, answerIDs: [2]))
    #expect(try resourceMessage().poll?.selectedAnswerIDs == [2])
    model.consumeImmediately(.messageUpdated(message))
    #expect(try resourceMessage().poll?.selectedAnswerIDs == [2])
    var echo = MessageUpdate(messageID: message.id, channelID: message.channelID)
    echo.pollUpdates = [.vote(answerID: 2, isAddition: true, isCurrentUser: true)]
    model.consumeImmediately(.messagePatched(echo))
    #expect(try resourceMessage().poll?.count(for: 2) == 2)
    await provider.resumeRequest()
    #expect(await eventually { model.pollVoteMutations.isEmpty })
    await provider.failNextRequest()
    #expect(model.vote(on: message, answerIDs: [1]))
    #expect(try resourceMessage().poll?.selectedAnswerIDs == [1])
    await provider.resumeRequest()
    #expect(await eventually { model.pollVoteMutations.isEmpty })
    #expect(try resourceMessage().poll?.selectedAnswerIDs == [2])
    #expect(try resourceMessage().poll?.count(for: 2) == 2)
    let historyMessage = Message(id: MessageID(rawValue: 99_101), channelID: message.channelID,
                                 author: message.author, content: "Page snapshot")
    let liveMessage = Message(id: MessageID(rawValue: 99_102), channelID: message.channelID,
                              author: message.author, content: "Arrived after snapshot")
    model.loadGuideResource()
    await provider.waitForHistory()
    var edit = MessageUpdate(messageID: historyMessage.id, channelID: message.channelID)
    edit.content = "Edited during load"
    model.consumeImmediately(.messagePatched(edit))
    model.consumeImmediately(.messageCreated(liveMessage))
    await provider.resumeHistory(MessagePage(messages: [historyMessage], hasMoreBefore: false, hasMoreAfter: true))
    #expect(await eventually { model.guideResource?.loading == false })
    #expect(model.guideResource?.messages.map(\.id) == [message.id, historyMessage.id])
    model.loadGuideResource()
    await provider.waitForHistory()
    let newest = Message(id: MessageID(rawValue: 99_103), channelID: message.channelID,
                         author: message.author, content: "Arrived during final page")
    model.consumeImmediately(.messageCreated(newest))
    await provider.resumeHistory(MessagePage(messages: [liveMessage], hasMoreBefore: false, hasMoreAfter: false))
    #expect(await eventually { model.guideResource?.loading == false })
    let loaded = try #require(model.guideResource)
    #expect(loaded.messages.map(\.id) == [message.id, historyMessage.id, liveMessage.id, newest.id])
    #expect(loaded.rows.first(where: { $0.id == historyMessage.id })?.message.content == "Edited during load")
}

@MainActor
@Test(arguments: [InboxTab.mentions, .unread])
func `Inbox loads preserve poll patches for messages not yet retained`(tab: InboxTab) async throws {
    let provider = PollVoteTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let message = try #require(model.messages.first)
    model.replaceSelectedMessages(with: [])
    model.messageCache.removeAll()
    model.inbox.isPresented = true
    model.inbox.tab = tab
    model.inbox.groups = [InboxUnreadGroup(
        channelID: message.channelID, guildID: nil, title: "Pending page", subtitle: nil,
        oldestReadMessageID: MessageID(rawValue: message.id.rawValue - 1),
        newestUnreadMessageID: message.id, mentionCount: 1
    )]
    model.inbox.hasMoreMentions = true
    await provider.holdInboxPages()
    model.loadMoreInbox()
    await provider.waitForInboxPage()
    #expect(model.retainedMessage(channelID: message.channelID, messageID: message.id) == nil)
    var update = MessageUpdate(messageID: message.id, channelID: message.channelID)
    update.content = "Edited while Inbox was loading"
    update.pollUpdates = [.vote(answerID: 2, isAddition: true, isCurrentUser: false)]
    model.consumeImmediately(.messagePatched(update))
    update.content = nil
    model.consumeImmediately(.messagePatched(update))
    model.consumeImmediately(.messageCreated(Message(
        id: MessageID(rawValue: message.id.rawValue + 1), channelID: message.channelID,
        author: message.author, content: "Not in the captured Inbox page"
    )))
    await provider.resumeInboxPage()
    await model.inbox.loadTask?.value
    let loaded = tab == .mentions ? model.inbox.mentions : model.inbox.groups.flatMap(\.messages)
    #expect(loaded.map(\.id) == [message.id])
    #expect(loaded.first?.content == "Edited while Inbox was loading")
    #expect(loaded.first?.poll?.results == nil)
    #expect(model.inbox.rows.first?.message == loaded.first)
}

@MainActor
@Test(arguments: [(false, false), (false, true), (true, false)])
func `search results preserve poll events before their messages are retained`(scenario: (finalizes: Bool, responseIncludesVotes: Bool)) async throws {
    let provider = PollVoteTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let message = try #require(model.messages.first)
    model.replaceSelectedMessages(with: [])
    model.messageCache.removeAll()
    model.messageSearch.queryText = "Lunch"
    model.submitMessageSearch()
    await provider.waitForSearch()
    let search = model.messageSearch
    let searchTask = search.requestTask
    let originalGuildID = model.selectedGuildID
    model.selectedGuildID = GuildID(rawValue: 99_100)
    #expect(model.retainedMessage(channelID: message.channelID, messageID: message.id) == nil)
    var update = MessageUpdate(messageID: message.id, channelID: message.channelID)
    if scenario.finalizes {
        update.pollUpdates = [.vote(answerID: 2, isAddition: true, isCurrentUser: true)]
        model.consumeImmediately(.messagePatched(update))
        var poll = try #require(message.poll)
        poll.results = PollResults(isFinalized: true, answerCounts: [.init(id: 2, count: 7)])
        update.pollUpdates = [.snapshot(poll, preservingSelection: true)]
    } else {
        update.pollUpdates = [.vote(answerID: 2, isAddition: true, isCurrentUser: false)]
        model.consumeImmediately(.messagePatched(update))
    }
    model.consumeImmediately(.messagePatched(update))
    var response = message
    if scenario.responseIncludesVotes {
        response.poll?.applyVote(answerID: 2, isAddition: true, isCurrentUser: false)
        response.poll?.applyVote(answerID: 2, isAddition: true, isCurrentUser: false)
    }
    await provider.resumeSearch(messages: [response])
    await searchTask?.value
    #expect(model.messageSearch.page == nil)
    #expect(!model.messageSearch.isPresented)
    model.selectedGuildID = originalGuildID
    #expect(model.messageSearch === search)
    if !scenario.finalizes {
        let unresolved = try #require(model.messageSearch.page?.messages.first)
        #expect(unresolved.poll?.results == nil)
        var current = message
        current.poll?.applyVote(answerID: 2, isAddition: true, isCurrentUser: false)
        current.poll?.applyVote(answerID: 2, isAddition: true, isCurrentUser: false)
        if scenario.responseIncludesVotes {
            // Another retained surface may establish the tally before reveal.
            model.replaceSelectedMessages(with: [current])
            await model.loadUnknownPollResults(unresolved)
            #expect(await provider.pollResultRequests == 0)
        } else {
            await provider.holdPollResults()
            let load = Task { await model.loadUnknownPollResults(unresolved) }
            await provider.waitForHistory()
            await provider.resumeHistory(MessagePage(messages: [current], hasMoreBefore: false))
            await load.value
            #expect(await provider.pollResultRequests == 1)
        }
    }
    let poll = model.messageSearch.page?.messages.first?.poll
    #expect(poll?.count(for: 2) == (scenario.finalizes ? 7 : 3))
    #expect(poll?.results?.isFinalized == scenario.finalizes)
    #expect(poll?.selectedAnswerIDs == (scenario.finalizes ? [2] : []))
    #expect(model.messageSearch.rows.first?.message.poll == poll)
}

@MainActor
@Test(arguments: [(false, false, false), (false, true, false), (false, true, true), (true, false, false)])
func `poll result fetch preserves updates received while awaiting history`(scenario: (finalizes: Bool, responseIncludesVote: Bool, keepsChanging: Bool)) async throws {
    let provider = PollVoteTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let stale = try #require(model.messages.first)
    var unknown = stale
    unknown.poll?.results = nil
    model.replaceSelectedMessages(with: [unknown])
    await provider.holdPollResults()
    let load = Task { await model.loadUnknownPollResults(unknown) }
    await provider.waitForHistory()
    var finalized = try #require(stale.poll)
    finalized.results = PollResults(isFinalized: true, answerCounts: [.init(id: 1, count: 4)])
    var update = MessageUpdate(messageID: stale.id, channelID: stale.channelID)
    update.content = "Edited during the poll fetch"
    update.pollUpdates = scenario.finalizes ? [.snapshot(finalized, preservingSelection: true)]
        : [.vote(answerID: 1, isAddition: true, isCurrentUser: false)]
    model.consumeImmediately(.messagePatched(update))
    model.consumeImmediately(.messageReactionUpdated(.add(
        channelID: stale.channelID, messageID: stale.id, userID: UserID(rawValue: 99_004), emoji: "👍", kind: .normal
    )))
    var current = stale
    current.poll?.applyVote(answerID: 1, isAddition: true, isCurrentUser: false)
    await provider.resumeHistory(MessagePage(messages: [scenario.responseIncludesVote ? current : stale], hasMoreBefore: false))
    if !scenario.finalizes {
        await provider.waitForHistory()
        if scenario.keepsChanging { model.consumeImmediately(.messagePatched(update)) }
        await provider.resumeHistory(MessagePage(messages: [current], hasMoreBefore: false))
    }
    await load.value
    #expect(model.messages.first?.content == update.content)
    if scenario.keepsChanging {
        #expect(model.messages.first?.poll?.results == nil)
        #expect(model.errorMessage != nil)
    } else {
        #expect(model.messages.first?.poll?.results?.isFinalized == scenario.finalizes)
        #expect(model.messages.first?.poll?.count(for: 1) == (scenario.finalizes ? 4 : 2))
    }
    #expect(model.messages.first?.reactions.first?.count == 1)
    #expect(await provider.pollResultRequests == (scenario.finalizes ? 1 : 2))
}

private actor PollVoteTestProvider: ChatProvider {
    private let user = User(id: UserID(rawValue: 99_001), username: "poll-tester", displayName: "Poll Tester")
    private let channel = Channel(id: ChannelID(rawValue: 99_002), guildID: nil, name: "poll-tests")
    private var recordedRequests: [[Int]] = []
    private var recordedReactions: [Bool] = []
    private var failsNextRequest = false
    private var continuation: AsyncStream<ClientEvent>.Continuation?
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var searchContinuation: CheckedContinuation<Void, Never>?
    private var searchResponseMessages: [Message]?
    private var historyContinuation: CheckedContinuation<MessagePage, Never>?
    private var holdsPollResults = false
    private(set) var pollResultRequests = 0
    private var holdsInboxPages = false
    private var inboxContinuation: CheckedContinuation<Void, Never>?

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [], channels: [channel], members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] { [channel] }
    func members(in guildID: GuildID?) async throws -> [Member] { [] }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage {
        let poll = MessagePoll(question: "Lunch?", answers: [.init(id: 1, text: "Pizza"), .init(id: 2, text: "Sushi")],
                               expiry: .now.addingTimeInterval(3600),
                               results: PollResults(answerCounts: [.init(id: 1, count: 1), .init(id: 2, count: 1)]))
        return MessagePage(messages: [Message(id: MessageID(rawValue: 99_100), channelID: channel.id, author: user,
                                              content: "", isPinned: true, poll: poll)], hasMoreBefore: false)
    }

    func messages(in channelID: ChannelID, anchoredAt anchor: MessageHistoryAnchor, limit: Int) async throws -> MessagePage {
        if case .after = anchor { return await withCheckedContinuation { historyContinuation = $0 } }
        if case .around = anchor, holdsPollResults {
            pollResultRequests += 1
            return await withCheckedContinuation { historyContinuation = $0 }
        }
        return try await messages(in: channelID, before: nil, limit: limit)
    }

    func holdPollResults() { holdsPollResults = true }

    func waitForHistory() async {
        while historyContinuation == nil { await Task.yield() }
    }

    func resumeHistory(_ page: MessagePage) {
        historyContinuation?.resume(returning: page)
        historyContinuation = nil
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func inboxMentions(_ query: InboxMentionQuery, before: MessageID?) async throws -> InboxMentionPage {
        let page = try await messages(in: channel.id, before: nil, limit: 25)
        await holdInboxPageIfRequested()
        return InboxMentionPage(messages: page.messages, nextBefore: nil, hasMore: false)
    }

    func messagesForImmediatePresentation(in channelID: ChannelID, anchoredAt anchor: MessageHistoryAnchor, limit: Int) async throws -> MessagePage {
        let page = try await messages(in: channelID, anchoredAt: anchor, limit: limit)
        await holdInboxPageIfRequested()
        return page
    }

    func holdInboxPages() { holdsInboxPages = true }

    private func holdInboxPageIfRequested() async {
        if holdsInboxPages { await withCheckedContinuation { inboxContinuation = $0 } }
    }

    func waitForInboxPage() async {
        while inboxContinuation == nil { await Task.yield() }
    }

    func resumeInboxPage() {
        holdsInboxPages = false
        inboxContinuation?.resume()
        inboxContinuation = nil
    }

    func searchMessages(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        let page = try await messages(in: channel.id, before: nil, limit: 25)
        await withCheckedContinuation { searchContinuation = $0 }
        let messages = searchResponseMessages ?? page.messages
        searchResponseMessages = nil
        return MessageSearchPage(messages: messages, totalResults: messages.count)
    }

    func waitForSearch() async {
        while searchContinuation == nil { await Task.yield() }
    }

    func resumeSearch(messages: [Message]? = nil) {
        searchResponseMessages = messages
        searchContinuation?.resume()
        searchContinuation = nil
    }

    func pinnedMessages(in channelID: ChannelID, before: Date?, limit: Int) async throws -> PinnedMessagePage {
        let page = try await messages(in: channelID, before: nil, limit: limit)
        return PinnedMessagePage(items: page.messages.map { PinnedMessage(pinnedAt: .now, message: $0) }, hasMore: false)
    }

    func edit(_ message: Message, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}

    func setReaction(_ emoji: String, reacted: Bool, messageID: MessageID, channelID: ChannelID) async throws {
        recordedReactions.append(reacted)
    }

    func reactionRequests() -> [Bool] { recordedReactions }

    func setPollAnswers(_ answerIDs: [Int], messageID: MessageID, channelID: ChannelID) async throws {
        recordedRequests.append(answerIDs)
        await withCheckedContinuation { requestContinuation = $0 }
        if failsNextRequest {
            failsNextRequest = false
            throw ChatProviderError.invalidRequest("Synthetic vote failure.")
        }
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { continuation = $0 }
    }

    func disconnect() async {
        resumeInboxPage()
        historyContinuation?.resume(returning: MessagePage(messages: [], hasMoreBefore: false))
        historyContinuation = nil
        searchContinuation?.resume()
        searchContinuation = nil
        requestContinuation?.resume()
        requestContinuation = nil
        continuation?.finish()
        continuation = nil
    }

    func resumeRequest() async {
        while requestContinuation == nil { await Task.yield() }
        requestContinuation?.resume()
        requestContinuation = nil
    }

    func failNextRequest() { failsNextRequest = true }
    func requests() -> [[Int]] { recordedRequests }
    func emit(_ event: ClientEvent) { continuation?.yield(event) }
}
