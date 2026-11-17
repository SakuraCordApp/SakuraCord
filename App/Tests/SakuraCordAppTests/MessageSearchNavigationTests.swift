@testable import SakuraCord
import DiscordProtocol
@testable import DiscordProtocolTestSupport
import SakuraCordModels
import Testing

@MainActor
struct MessageSearchNavigationTests {
    @Test func `search is retained per server and across DMs while side threads temporarily hide it`() async throws {
        let provider = MockChatProvider()
        let model = AppModel(isEphemeral: true, provider: provider)
        await model.start()
        model.navigate(to: ChannelID(rawValue: 210))
        await model.guildActivationTask?.value
        let serverSearch = model.messageSearch
        serverSearch.queryText = "original server query"
        serverSearch.isPresented = true
        model.channelSidebarSelection = ChannelID(rawValue: 211)
        #expect(model.isMessageSearchVisible)
        #expect(model.messageSearch === serverSearch)

        let posts = try await provider.forumPosts(in: ChannelID(rawValue: 220), query: .init())
        let post = try #require(posts.posts.first)
        model.channelSidebarSelection = ChannelID(rawValue: 220)
        model.open(post)
        #expect(!model.isMessageSearchVisible)
        #expect(!model.consumeEscapeForUnfocusedMessageSearch())
        #expect(serverSearch.isPresented)
        model.closeThread()
        #expect(model.isMessageSearchVisible)

        model.navigate(to: ChannelID(rawValue: 300))
        await model.guildActivationTask?.value
        #expect(!model.isMessageSearchVisible)
        model.messageSearch.queryText = "other server query"
        model.messageSearch.isPresented = true
        model.navigate(to: ChannelID(rawValue: 400))
        await model.guildActivationTask?.value
        #expect(!model.isMessageSearchVisible)
        let dmSearch = model.messageSearch
        dmSearch.queryText = "DM query"
        dmSearch.isPresented = true
        model.navigate(to: ChannelID(rawValue: 401))
        await model.guildActivationTask?.value
        #expect(model.messageSearch === dmSearch)
        #expect(model.isMessageSearchVisible)

        model.navigate(to: ChannelID(rawValue: 210))
        await model.guildActivationTask?.value
        #expect(model.messageSearch === serverSearch)
        #expect(model.messageSearch.queryText == "original server query")
        #expect(model.isMessageSearchVisible)
        model.dismissMessageSearch()
        model.navigate(to: ChannelID(rawValue: 400))
        await model.guildActivationTask?.value
        #expect(model.messageSearch === dmSearch)
        #expect(model.isMessageSearchVisible)
        model.navigate(to: ChannelID(rawValue: 210))
        await model.guildActivationTask?.value
        #expect(!model.isMessageSearchVisible)

        model.invalidateAccountSession()
        #expect(model.retainedMessageSearches.count == 1)
        #expect(model.messageSearch.page == nil)
        #expect(model.messageSearch.queryText.isEmpty)
        #expect(!dmSearch.isPresented)
        #expect(dmSearch.queryText.isEmpty)
    }

    @Test func `group DM scope suggests only its recipients and the current user`() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        await model.start()
        let group = try #require(model.snapshot?.channels.first { $0.id.rawValue == 401 })
        let currentUser = try #require(model.currentUser)
        model.navigate(to: group.id)
        await model.guildActivationTask?.value
        model.messageSearch.tokens = [.init(kind: .channel(channelID: group.id, name: group.name))]
        model.messageSearch.queryText = "from:"

        let suggested = MessageSearchAutocompletePolicy.result(model: model).suggestions.compactMap {
            if case .user(_, let user) = $0 { user.id } else { nil }
        }
        #expect(Set(suggested) == Set(group.recipients.map(\.id) + [currentUser.id]))
    }

    @Test(arguments: [UInt64(300), 400, 220])
    func `search stays within its scope and thread results use the primary pane`(destinationID: UInt64) async throws {
        let provider = MockChatProvider()
        let model = AppModel(isEphemeral: true, provider: provider)
        await model.start()
        let destination = try #require(model.snapshot?.channels.first { $0.id.rawValue == destinationID })
        model.navigate(to: destination.id)
        await model.guildActivationTask?.value
        let hit: Message
        var resultChannels: [Channel] = []
        if destination.kind == .forum {
            let posts = try await provider.forumPosts(in: destination.id, query: .init())
            let post = try #require(posts.posts.first)
            hit = try #require(post.firstMessage)
            resultChannels = [Channel(id: post.id, guildID: destination.guildID, name: post.thread.name)]
            model.navigate(to: destination.id)
            await model.guildActivationTask?.value
            await model.channelLoadTask?.value
            _ = model.readState.updatePresentation(
                channelID: destination.id, isPresented: true,
                windowIsActive: true, hasReachedReadBoundary: true
            )
            #expect(model.readState.isActivelyPresentedAtNewest(destination.id))
        } else {
            let page = try await provider.messages(in: destination.id, before: nil, limit: 50)
            hit = try #require(page.messages.first)
        }
        model.messageSearch.submittedQuery = MessageSearchQuery(
            scope: destination.guildID.map(MessageSearchScope.guild) ?? .directMessages,
            content: "fixture"
        )
        model.messageSearch.page = MessageSearchPage(messages: [hit], channels: resultChannels, totalResults: 1)
        model.messageSearch.isPresented = true

        model.navigateToSearchResult(hit)
        await model.guildActivationTask?.value

        #expect(model.messageSearch.isPresented)
        #expect(model.canShowMessageSearch)
        #expect(model.messageNavigationRequest?.messageID == hit.id)
        #expect(model.messageNavigationRequest?.channelID == hit.channelID)
        if destination.kind == .forum {
            #expect(model.openThread?.id == hit.channelID)
            #expect(model.isThreadFullWidth)
            #expect(!model.readState.isActivelyPresentedAtNewest(destination.id))
            model.presentMessageSearchFromCommand()
            #expect(model.messageSearch.tokens.contains { token in
                if case .channel(let channelID, _) = token.kind { return channelID == hit.channelID }
                return false
            })

            // The sidebar closes the thread before selecting its already-selected parent.
            model.closeThread()
            model.channelSidebarSelection = destination.id
            #expect(model.messageSearch.isPresented)
            model.navigateToSearchResult(hit)
            await model.guildActivationTask?.value

            // Another hit must replace the primary thread and retain the results.
            let page = try await provider.messages(in: ChannelID(rawValue: 210), before: nil, limit: 50)
            let rootHit = try #require(page.messages.first)
            model.messageSearch.page = MessageSearchPage(messages: [rootHit], totalResults: 1)
            model.navigateToSearchResult(rootHit)
            await model.guildActivationTask?.value
            #expect(model.openThread == nil)
            #expect(model.selectedChannelID == rootHit.channelID)
            #expect(model.messageSearch.isPresented)
        } else {
            #expect(model.selectedChannelID == destination.id)
        }

        model.navigate(to: ChannelID(rawValue: 211))
        await model.guildActivationTask?.value
        if destination.guildID == model.selectedGuildID {
            #expect(model.messageSearch.isPresented)
        } else {
            #expect(!model.messageSearch.isPresented)
            model.navigate(to: destination.id)
            await model.guildActivationTask?.value
            #expect(model.messageSearch.isPresented)
        }
    }

    @Test func `manual selection cancels navigation without dismissing its search`() async throws {
        let provider = MockChatProvider()
        let model = AppModel(isEphemeral: true, provider: provider)
        await model.start()
        let page = try await provider.messages(in: ChannelID(rawValue: 300), before: nil, limit: 50)
        let hit = try #require(page.messages.first)
        model.messageSearch.page = MessageSearchPage(messages: [hit], totalResults: 1)
        model.messageSearch.isPresented = true

        model.navigateToSearchResult(hit)
        let pending = model.guildActivationTask
        model.channelSidebarSelection = ChannelID(rawValue: 211)
        await pending?.value

        #expect(model.selectedChannelID == ChannelID(rawValue: 211))
        #expect(model.messageSearch.isPresented)
    }
}
