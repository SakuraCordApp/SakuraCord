@testable import DiscordProtocolTestSupport
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct IgnoredUsersTests {
    @Test func `ignored content collapses without deleting history and new messages stay concealed`() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        await model.start()
        let channel = ChannelID(rawValue: 99100)
        let author = User(id: .init(rawValue: 99101), username: "ignored", displayName: "Ignored")
        model.applyRelationships([Relationship(id: author.id, type: .friend, user: author, isUserIgnored: true)])
        let messages = (0 ..< 3).map {
            Message(id: .init(rawValue: UInt64(99200 + $0)), channelID: channel, author: author, content: "Hidden \($0)")
        }
        model.replaceSelectedMessages(with: Array(messages.prefix(2)))
        let timeline = NativeMessageTimelineView(
            model: model, conversation: .channel(channel), beginning: nil,
            firstMessageStartsDayOverride: nil, hasMoreMessages: false,
            isLoadingEarlier: false, bottomContentInset: 0, unreadMessageID: nil, highlightedMessageID: nil,
            scrollRequest: nil, runsPerformanceAutoScroll: false, loadEarlier: {}, openReply: { _ in },
            onScrollActivityChange: { _ in }, onScrollStateChange: { _ in }, onUserScrollBegan: {}, onUserScrollEnded: { _ in }
        )
        let coordinator = timeline.makeCoordinator()
        func items() -> [NativeMessageTimelineItem] { coordinator.makeItems(from: timeline, rows: timeline.conversation.rows(in: model)) }
        #expect(items().count == 1)
        #expect(items().first?.messageID == messages[0].id)
        #expect(items().allSatisfy { $0.messageRow == nil })
        #expect(items().first(where: { $0.containsMessage(messages[1].id) })?.messageID == messages[0].id)
        #expect(model.messages.count == 2)
        model.toggleSuppressedMessages(Array(messages.prefix(2)).map(\.id))
        #expect(items().compactMap(\.messageRow).count == 2)
        #expect(items().compactMap(\.messageID) == Array(messages.prefix(2)).map(\.id))
        #expect(items().first(where: { $0.containsMessage(messages[1].id) })?.messageRow?.id == messages[1].id)
        // An animated conceal holds the rows only until its motion finishes.
        model.toggleSuppressedMessages(Array(messages.prefix(2)).map(\.id), holdsCollapsingRows: true)
        #expect(items().first?.messageID == messages[0].id)
        #expect(items().compactMap(\.messageRow).count == 2)
        model.finishCollapsingSuppressedMessages(Array(messages.prefix(2)).map(\.id))
        #expect(items().count == 1)
        // Dismissing a timeline during Hide must also release the held rows.
        let scrollView = coordinator.makeScrollView()
        let canvas = try #require(coordinator.canvas)
        canvas.model = model
        model.toggleSuppressedMessages(Array(messages.prefix(2)).map(\.id))
        model.toggleSuppressedMessages(Array(messages.prefix(2)).map(\.id), holdsCollapsingRows: true)
        canvas.rowDisclosure = .init(
            key: .suppressedMessages(messages[0].id), isCollapsing: true, requestedUptime: 0,
            heldMessageIDs: Array(messages.prefix(2)).map(\.id), startHeight: 100, revealedHeight: 50,
            startBeforeShift: 0, targetBeforeShift: 100, beforeShift: 50
        )
        model.replaceSelectedMessages(with: messages)
        #expect(items().compactMap(\.messageRow).map(\.id) == Array(messages.prefix(2)).map(\.id))
        NativeMessageTimelineView.dismantleNSView(scrollView, coordinator: coordinator)
        #expect(model.ignoredUsers.collapsingMessageIDs.isEmpty)
        #expect(items().allSatisfy { $0.messageRow == nil })
        model.toggleSuppressedMessages(Array(messages.prefix(2)).map(\.id))
        model.replaceSelectedMessages(with: messages)
        #expect(items().compactMap(\.messageRow).count == 2)
        #expect(items().last?.containsMessage(messages[2].id) == true)
        #expect(items().last?.messageRow == nil)
        model.applyRelationships([Relationship(id: author.id, type: .friend, user: author)])
        #expect(items().compactMap(\.messageRow).map(\.id) == messages.map(\.id))
        #expect(model.ignoredUsers.revealedMessageIDs.isEmpty)
    }

    @Test func `ignore covers command initiators and menus retain eligibility and account guards`() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        await model.start()
        let author = User(id: .init(rawValue: 99300), username: "person", displayName: "Person")
        var bot = User(id: .init(rawValue: 99301), username: "app", displayName: "App")
        bot.isBot = true
        let action = try #require(model.userMenuActions(for: author, context: .init()).first { $0.id == "ignore" })
        #expect(model.userMenuActions(for: bot, context: .init()).contains { $0.id == "ignore" })
        model.applyRelationships([Relationship(id: author.id, type: .none, user: author, isUserIgnored: true)])
        action.perform()
        #expect(model.friends.confirmation == nil)
        let command = Message(id: .init(rawValue: 99302), channelID: .init(rawValue: 99303), author: bot, content: "Command response",
                              interactionMetadata: .init(user: author))
        #expect(model.isMessageSuppressed(command))
        // Reversing actions take the slots of the actions they undo.
        #expect(model.userMenuActions(for: author, context: .init()).filter { $0.group == .destructive }.map(\.id) == ["unignore", "block"])
        model.applyRelationships([Relationship(id: author.id, type: .blocked, user: author, isUserIgnored: true)])
        #expect(!model.isUserIgnored(author.id))
        #expect(!model.userMenuActions(for: author, context: .init()).contains { $0.id == "ignore" || $0.id == "unignore" })
        #expect(model.userMenuActions(for: author, context: .init()).filter { $0.group == .destructive }.map(\.id) == ["unblock"])
        model.applyRelationships([])
        let stale = try #require(model.userMenuActions(for: author, context: .init()).first { $0.id == "ignore" })
        model.invalidateAccountSession()
        stale.perform()
        #expect(model.friends.confirmation == nil)
    }

    @Test func `ignored guild voice requires confirmation and teardown releases the pending join`() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        await model.start()
        let userID = UserID(rawValue: 99400)
        let channel = Channel(id: .init(rawValue: 99401), guildID: .init(rawValue: 99402), name: "Voice", kind: .voice)
        model.applyRelationships([Relationship(id: userID, type: .friend, isUserIgnored: true)])
        model.voiceStates[userID] = VoiceParticipantState(userID: userID, channelID: channel.id, guildID: channel.guildID, sessionID: "test")
        let join = Task { await model.confirmIgnoredVoiceParticipants(in: channel) }
        #expect(await until { model.ignoredUsers.voiceWarning != nil })
        #expect(await model.confirmIgnoredVoiceParticipants(in: channel) == false)
        model.ignoredUsers.resolveVoiceWarning(true)
        #expect(await join.value)
        let cancelledJoin = Task { await model.confirmIgnoredVoiceParticipants(in: channel) }
        #expect(await until { model.ignoredUsers.voiceWarning != nil })
        model.ignoredUsers.reset()
        #expect(await cancelledJoin.value == false)
        #expect(model.ignoredUsers.voiceConfirmation == nil)
        let directMessage = Channel(id: .init(rawValue: 99403), guildID: nil, name: "DM", kind: .directMessage)
        model.applyRelationships([Relationship(id: userID, type: .friend, isUserIgnored: true)])
        model.privateCallsByChannel[directMessage.id] = PrivateCall(channelID: directMessage.id,
            ongoingRings: [.init(recipientID: try #require(model.currentUser?.id), senderID: userID)],
            voiceStates: [.init(userID: userID, channelID: directMessage.id, guildID: nil, sessionID: "test")])
        #expect(model.isIncomingCallSuppressed(try #require(model.privateCallsByChannel[directMessage.id])))
        #expect(await model.confirmIgnoredVoiceParticipants(in: directMessage))
    }

    @Test func `ignored group warnings honor server acknowledgements and reset with the account`() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        await model.start()
        let user = User(id: .init(rawValue: 99500), username: "ignored", displayName: "Ignored")
        var group = Channel(id: .init(rawValue: 99501), guildID: nil, name: "Group", kind: .groupDirectMessage, recipients: [user])
        model.applyRelationships([Relationship(id: user.id, type: .friend, isUserIgnored: true)])
        model.selectedChannel = group
        model.reconcileIgnoredGroupWarning()
        #expect(model.ignoredUsers.groupWarning?.id == group.id)
        model.dismissIgnoredGroupWarning(group)
        model.reconcileIgnoredGroupWarning()
        #expect(model.ignoredUsers.groupWarning == nil)
        model.ignoredUsers.reset()
        #expect(model.ignoredUsers.dismissedGroupWarningIDs.isEmpty)
        group.blockedUserWarningDismissed = true
        model.selectedChannel = group
        model.applyRelationships([Relationship(id: user.id, type: .friend, isUserIgnored: true)])
        model.reconcileIgnoredGroupWarning()
        #expect(model.ignoredUsers.groupWarning == nil)
    }

}
