@testable import SakuraCord
import Foundation
import SakuraCordModels
import Testing
import DiscordProtocol
import UserNotifications

@MainActor
struct AccountReadStateModelTests {
    private let currentUser = User(
        id: UserID(rawValue: 1), username: "current", displayName: "Current"
    )
    private let sender = User(
        id: UserID(rawValue: 2), username: "sender", displayName: "Sender"
    )
    private let guildID = GuildID(rawValue: 100)
    private let channelID = ChannelID(rawValue: 200)
    private let categoryID = ChannelID(rawValue: 199)

    @Test func `ready state combines acknowledged and authoritative latest snowflakes`() {
        let model = makeModel(latest: 9007199254740995, acknowledged: 9007199254740994)
        #expect(model.unread(channelID: channelID))
        #expect(model.entries[channelID]?.latestKnownMessageID?.rawValue == 9007199254740995)
        #expect(
            model.entries[channelID]?.lastAcknowledgedMessageID?.rawValue == 9007199254740994
        )
    }

    @Test func `channels omitted from ready read state begin read and become unread live`() {
        let model = AccountReadStateModel()
        model.reset(accountID: "account")
        model.setCurrentUserID(currentUser.id)
        model.configure(
            accountID: "account",
            guilds: [
                Guild(
                    id: guildID,
                    name: "Guild",
                    defaultMessageNotifications: .allMessages
                )
            ],
            channels: [
                Channel(
                    id: channelID,
                    guildID: guildID,
                    name: "general",
                    categoryID: categoryID,
                    lastMessageID: MessageID(rawValue: 10)
                )
            ],
            readStates: [],
            notificationSettings: []
        )

        #expect(model.entries[channelID]?.latestKnownMessageID == MessageID(rawValue: 10))
        #expect(model.entries[channelID]?.latestUnreadMessageID == nil)
        #expect(!model.unread(channelID: channelID))
        #expect(!model.guildUnread(guildID))

        #expect(model.receive(message(id: 11), currentUserID: currentUser.id).accepted)
        #expect(model.unread(channelID: channelID))
        #expect(model.guildUnread(guildID))
    }

    @Test func `threads omitted from ready read state begin read and become unread live`() {
        let threadID = ChannelID(rawValue: 201)
        let model = AccountReadStateModel()
        model.reset(accountID: "account")
        model.setCurrentUserID(currentUser.id)
        model.configure(
            accountID: "account",
            guilds: [
                Guild(
                    id: guildID,
                    name: "Guild",
                    defaultMessageNotifications: .allMessages
                )
            ],
            channels: [
                Channel(
                    id: channelID,
                    guildID: guildID,
                    name: "forum",
                    kind: .forum
                )
            ],
            readStates: [],
            notificationSettings: []
        )
        model.merge(
            thread: MessageThreadSummary(
                id: threadID,
                guildID: guildID,
                parentID: channelID,
                name: "Post",
                lastMessageID: MessageID(rawValue: 10)
            )
        )

        #expect(model.entries[threadID]?.latestKnownMessageID == MessageID(rawValue: 10))
        #expect(model.entries[threadID]?.latestUnreadMessageID == nil)
        #expect(!model.unread(channelID: threadID))
        #expect(!model.guildUnread(guildID))

        let disposition = model.receive(
            Message(
                id: MessageID(rawValue: 11),
                channelID: threadID,
                author: sender,
                content: "Live reply",
                guildID: guildID
            ),
            currentUserID: currentUser.id
        )
        #expect(disposition.accepted)
        #expect(model.unread(channelID: threadID))
        #expect(model.guildUnread(guildID))

        #expect(
            model.applyRemote(
                ChannelReadState(
                    channelID: threadID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 11)
                )
            )
        )
        #expect(!model.unread(channelID: threadID))
        #expect(!model.guildUnread(guildID))

        model.merge(
            thread: MessageThreadSummary(
                id: threadID,
                guildID: guildID,
                parentID: channelID,
                name: "Post",
                lastMessageID: MessageID(rawValue: 11)
            )
        )
        #expect(!model.unread(channelID: threadID))
        #expect(!model.guildUnread(guildID))
    }

    @Test func `forum visit acknowledges new posts without clearing unread replies`() {
        let newPostID = ChannelID(rawValue: 300)
        let unreadPostID = ChannelID(rawValue: 240)
        let model = AccountReadStateModel()
        model.configure(
            accountID: "account",
            guilds: [
                Guild(
                    id: guildID,
                    name: "Guild",
                    defaultMessageNotifications: .allMessages
                )
            ],
            channels: [
                Channel(
                    id: channelID,
                    guildID: guildID,
                    name: "forum",
                    kind: .forum,
                    lastMessageID: MessageID(rawValue: newPostID.rawValue)
                )
            ],
            readStates: [
                ChannelReadState(
                    channelID: channelID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 250)
                ),
                ChannelReadState(
                    channelID: unreadPostID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 450)
                ),
            ],
            notificationSettings: []
        )
        model.merge(
            thread: MessageThreadSummary(
                id: unreadPostID,
                guildID: guildID,
                parentID: channelID,
                name: "Unread replies",
                lastMessageID: MessageID(rawValue: 500)
            )
        )
        let newPost = ForumPost(
            thread: MessageThreadSummary(
                id: newPostID,
                guildID: guildID,
                parentID: channelID,
                name: "New post",
                lastMessageID: MessageID(rawValue: newPostID.rawValue)
            )
        )
        model.merge(forumPost: newPost)

        #expect(model.forumNewPostCount(channelID: channelID) == 1)
        #expect(model.unread(channelID: unreadPostID))
        #expect(model.unreadMessageCount(channelID: unreadPostID) == 1)

        model.beginForumVisit(channelID: channelID)
        #expect(model.isNewForumPost(newPost))
        #expect(model.isUnopenedForumPost(newPost))
        model.markAcknowledgementPending(
            channelID: channelID,
            messageID: MessageID(rawValue: 1_000)
        )

        #expect(model.forumNewPostCount(channelID: channelID) == 0)
        #expect(model.isNewForumPost(newPost))
        #expect(model.unread(channelID: unreadPostID))

        _ = model.updatePresentation(channelID: newPost.id, isPresented: true)
        #expect(!model.isUnopenedForumPost(newPost))
        #expect(!model.isNewForumPost(newPost))

        model.endForumVisit(channelID: channelID)
        #expect(!model.isNewForumPost(newPost))
    }

    @Test func `forum visit preserves new badges when the prior parent boundary is null`() {
        let newPostID = ChannelID(rawValue: 300)
        let model = AccountReadStateModel()
        model.configure(
            accountID: "account",
            guilds: [
                Guild(
                    id: guildID,
                    name: "Guild",
                    defaultMessageNotifications: .allMessages
                )
            ],
            channels: [
                Channel(
                    id: channelID,
                    guildID: guildID,
                    name: "forum",
                    kind: .forum,
                    lastMessageID: MessageID(rawValue: newPostID.rawValue)
                )
            ],
            readStates: [
                ChannelReadState(
                    channelID: channelID,
                    lastAcknowledgedMessageID: nil
                )
            ],
            notificationSettings: []
        )
        let newPost = ForumPost(
            thread: MessageThreadSummary(
                id: newPostID,
                guildID: guildID,
                parentID: channelID,
                name: "First unread post",
                lastMessageID: MessageID(rawValue: newPostID.rawValue)
            )
        )
        model.merge(forumPost: newPost)

        #expect(model.forumNewPostCount(channelID: channelID) == 1)
        model.beginForumVisit(channelID: channelID)
        model.markAcknowledgementPending(
            channelID: channelID,
            messageID: MessageID(rawValue: 1_000)
        )

        #expect(model.isNewForumPost(newPost))
    }

    @Test func `forum catalogue unread state seeds omitted thread read state`() {
        let threadID = ChannelID(rawValue: 201)
        let latestMessageID = MessageID(rawValue: 12)
        let model = AccountReadStateModel()
        model.reset(accountID: "account")
        model.setCurrentUserID(currentUser.id)
        model.configure(
            accountID: "account",
            guilds: [
                Guild(
                    id: guildID,
                    name: "Guild",
                    defaultMessageNotifications: .allMessages
                )
            ],
            channels: [
                Channel(
                    id: channelID,
                    guildID: guildID,
                    name: "forum",
                    kind: .forum
                )
            ],
            readStates: [],
            notificationSettings: []
        )
        model.merge(
            forumPost: ForumPost(
                thread: MessageThreadSummary(
                    id: threadID,
                    guildID: guildID,
                    parentID: channelID,
                    name: "Unread post",
                    messageCount: 4,
                    lastMessageID: latestMessageID
                ),
                isUnread: true
            )
        )

        #expect(model.entries[threadID]?.latestKnownMessageID == latestMessageID)
        #expect(model.unread(channelID: threadID))
        #expect(model.unreadMessageCount(channelID: threadID) == 3)
        #expect(model.guildUnread(guildID))

        let reply = Message(
            id: MessageID(rawValue: 13),
            channelID: threadID,
            author: sender,
            content: "New reply",
            guildID: guildID
        )
        #expect(model.receive(reply, currentUserID: currentUser.id).accepted)
        #expect(model.unreadMessageCount(channelID: threadID) == 4)

        model.markAcknowledgementPending(
            channelID: threadID,
            messageID: reply.id
        )
        #expect(!model.unread(channelID: threadID))
        #expect(model.unreadMessageCount(channelID: threadID) == 0)
        #expect(!model.guildUnread(guildID))

        model.failAcknowledgement(channelID: threadID, messageID: reply.id)
        #expect(model.unread(channelID: threadID))
        #expect(model.unreadMessageCount(channelID: threadID) == 4)
    }

    @Test func `live messages are monotonic and own duplicate and older messages preserve unread`() {
        let model = makeModel(latest: 10, acknowledged: 10)
        let first = model.receive(message(id: 12), currentUserID: currentUser.id)
        #expect(first.accepted)
        #expect(model.unread(channelID: channelID))

        #expect(!model.receive(message(id: 12), currentUserID: currentUser.id).accepted)
        #expect(!model.receive(message(id: 11), currentUserID: currentUser.id).accepted)

        let own = model.receive(
            message(id: 13, author: currentUser), currentUserID: currentUser.id
        )
        #expect(own.accepted)
        #expect(model.unread(channelID: channelID))
    }

    @Test func `own messages do not create unread or clear earlier unseen messages`() {
        let readModel = makeModel(latest: 10, acknowledged: 10)
        _ = readModel.receive(
            message(id: 11, author: currentUser), currentUserID: currentUser.id
        )
        #expect(!readModel.unread(channelID: channelID))

        let unreadModel = makeModel(latest: 12, acknowledged: 10, mentions: 1)
        _ = unreadModel.receive(
            message(id: 13, author: currentUser), currentUserID: currentUser.id
        )
        #expect(unreadModel.unread(channelID: channelID))
        #expect(unreadModel.mentions(channelID: channelID) == 1)
    }

    @Test func `selection alone never acknowledges and view gate requires every condition`() {
        let model = makeModel(latest: 12, acknowledged: 10)
        #expect(
            model.updatePresentation(channelID: channelID, isPresented: true) == nil
        )
        #expect(
            model.updatePresentation(channelID: channelID, initialHistoryLoaded: true) == nil
        )
        #expect(
            model.updatePresentation(channelID: channelID, windowIsActive: true, isAtNewest: false)
                == nil
        )
        #expect(
            model.updatePresentation(channelID: channelID, isAtNewest: true) == nil
        )
        #expect(
            model.updatePresentation(channelID: channelID, initialPositionEstablished: true)
                == MessageID(rawValue: 12)
        )
    }

    @Test func `ready replacement preserves established timeline viewing evidence`() {
        let model = makeModel(latest: 12, acknowledged: 10)
        #expect(
            model.updatePresentation(
                channelID: channelID,
                isPresented: true,
                initialHistoryLoaded: true,
                initialPositionEstablished: true,
                windowIsActive: true,
                isAtNewest: true
            ) == MessageID(rawValue: 12)
        )

        model.replaceReadStates([
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10)
            )
        ])

        #expect(model.presentations[channelID]?.initialPositionEstablished == true)
        #expect(model.updatePresentation(channelID: channelID) == MessageID(rawValue: 12))
    }

    @Test func `stale ready replacement cannot resurrect an unread cleared by remote ack`() {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 1)
        #expect(model.unread(channelID: channelID))

        #expect(
            model.applyRemote(
                ChannelReadState(
                    channelID: channelID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 12),
                    mentionCount: 0
                )
            )
        )
        #expect(!model.unread(channelID: channelID))

        model.replaceReadStates([
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10),
                mentionCount: 1
            )
        ])

        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 12))
        #expect(model.mentions(channelID: channelID) == 0)
        #expect(!model.unread(channelID: channelID))
        #expect(!model.guildUnread(guildID))
    }

    @Test func `ready duplicate channel entries use the last value`() {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 1)

        model.replaceReadStates([
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 11),
                mentionCount: 1
            ),
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 12),
                mentionCount: 0
            )
        ])

        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 12))
        #expect(model.mentions(channelID: channelID) == 0)
        #expect(!model.unread(channelID: channelID))
    }

    @Test func `ready replacement drops omitted stale unread conversations`() {
        let model = makeModel(latest: 10, acknowledged: 10)
        let threadID = ChannelID(rawValue: 201)
        model.merge(
            thread: MessageThreadSummary(
                id: threadID,
                guildID: guildID,
                parentID: channelID,
                name: "Stale post",
                lastMessageID: MessageID(rawValue: 20)
            )
        )
        _ = model.receive(
            Message(
                id: MessageID(rawValue: 21),
                channelID: threadID,
                author: sender,
                content: "Live reply",
                guildID: guildID
            ),
            currentUserID: currentUser.id
        )
        #expect(model.guildUnread(guildID))

        model.replaceReadStates([
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10)
            )
        ])

        #expect(model.entries[threadID] == nil)
        #expect(!model.guildUnread(guildID))
    }

    @Test func `inaccessible channels and their threads are excluded from every unread aggregate`() {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 2)
        let threadID = ChannelID(rawValue: 201)
        model.merge(
            thread: MessageThreadSummary(
                id: threadID,
                guildID: guildID,
                parentID: channelID,
                name: "Private post",
                lastMessageID: MessageID(rawValue: 20)
            )
        )
        model.applyRemote(
            ChannelReadState(
                channelID: threadID,
                lastAcknowledgedMessageID: MessageID(rawValue: 19),
                mentionCount: 1
            )
        )

        model.setAccessible(false, channelID: channelID)

        #expect(!model.unread(channelID: channelID))
        #expect(!model.unread(channelID: threadID))
        #expect(model.mentions(channelID: channelID) == 0)
        #expect(model.mentions(channelID: threadID) == 0)
        #expect(!model.guildUnread(guildID))
        #expect(model.guildMentions(guildID) == 0)
        #expect(model.totalMentions == 0)
        #expect(
            !model.receive(message(id: 21), currentUserID: currentUser.id).accepted
        )
    }

    @Test func `ordinary voice and guild resource traffic is excluded from unread aggregates`() {
        let voiceID = ChannelID(rawValue: 210)
        let resourceID = ChannelID(rawValue: 220)
        let resourceThreadID = ChannelID(rawValue: 221)
        let model = AccountReadStateModel()
        model.reset(accountID: "account")
        model.configure(
            accountID: "account",
            guilds: [
                Guild(
                    id: guildID,
                    name: "Guild",
                    defaultMessageNotifications: .allMessages
                )
            ],
            channels: [
                Channel(
                    id: voiceID,
                    guildID: guildID,
                    name: "Voice chat",
                    kind: .voice,
                    lastMessageID: MessageID(rawValue: 20)
                ),
                Channel(
                    id: resourceID,
                    guildID: guildID,
                    name: "Server guide",
                    kind: .text,
                    lastMessageID: MessageID(rawValue: 30),
                    flags: 1 << 7
                ),
            ],
            readStates: [
                ChannelReadState(
                    channelID: voiceID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 19)
                ),
                ChannelReadState(
                    channelID: resourceID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 29),
                    mentionCount: 2
                ),
            ],
            notificationSettings: [],
            usesNewNotifications: false
        )
        model.merge(
            thread: MessageThreadSummary(
                id: resourceThreadID,
                guildID: guildID,
                parentID: resourceID,
                name: "Guide post",
                lastMessageID: MessageID(rawValue: 40)
            )
        )
        model.applyRemote(
            ChannelReadState(
                channelID: resourceThreadID,
                lastAcknowledgedMessageID: MessageID(rawValue: 39),
                mentionCount: 1
            )
        )

        #expect(!model.unread(channelID: voiceID))
        #expect(!model.unread(channelID: resourceID))
        #expect(!model.unread(channelID: resourceThreadID))
        #expect(model.mentions(channelID: resourceID) == 0)
        #expect(model.mentions(channelID: resourceThreadID) == 0)
        #expect(!model.guildUnread(guildID))
        #expect(model.guildMentions(guildID) == 0)

        model.applyRemote(
            ChannelReadState(
                channelID: voiceID,
                lastAcknowledgedMessageID: MessageID(rawValue: 19),
                mentionCount: 1
            )
        )
        #expect(model.unread(channelID: voiceID))
        #expect(model.guildMentions(guildID) == 1)
    }

    @Test func `failed optimistic read mutations restore the authoritative boundary`() {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 1)
        model.markUnread(
            channelID: channelID,
            after: MessageID(rawValue: 5),
            mentionCount: 3
        )
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 5))
        #expect(model.mentions(channelID: channelID) == 3)

        model.failAcknowledgement(channelID: channelID, messageID: MessageID(rawValue: 5))

        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 10))
        #expect(model.mentions(channelID: channelID) == 1)
    }

    @Test func `acknowledgement metadata uses Discord epoch days and channel thread flags`() {
        let model = makeModel(latest: 12, acknowledged: 10)
        let twoDaysAfterEpoch = Date(timeIntervalSince1970: 1_420_070_400 + 2 * 86_400)
        #expect(
            model.acknowledgementMetadata(channelID: channelID, now: twoDaysAfterEpoch)
                == .init(flags: 1, lastViewed: 2)
        )

        let threadID = ChannelID(rawValue: 201)
        model.merge(
            thread: MessageThreadSummary(
                id: threadID,
                guildID: guildID,
                parentID: channelID,
                name: "Thread"
            )
        )
        #expect(
            model.acknowledgementMetadata(channelID: threadID, now: twoDaysAfterEpoch)
                == .init(flags: 3, lastViewed: 2)
        )
    }

    @Test func `remote acknowledgement advances monotonically and clears mention count`() {
        let model = makeModel(latest: 20, acknowledged: 10, mentions: 3)
        model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 18),
                mentionCount: 1
            )
        )
        #expect(model.mentions(channelID: channelID) == 1)
        model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 17),
                mentionCount: 0
            )
        )
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 18))
        #expect(model.mentions(channelID: channelID) == 1)
    }

    @Test func `manual remote acknowledgement can move the unread boundary backward`() {
        let model = makeModel(latest: 20, acknowledged: 18, mentions: 0)
        #expect(model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 12),
                mentionCount: 2,
                isManual: true
            )
        ))
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 12))
        #expect(model.mentions(channelID: channelID) == 2)
        #expect(model.unread(channelID: channelID))
    }

    @Test func `timeline unread summary grows as older unread pages load`() throws {
        let model = makeModel(latest: 20, acknowledged: 10)
        let latestPage = [message(id: 15), message(id: 16)]
        let initial = try #require(model.timelineUnreadSummary(
            channelID: channelID,
            messages: latestPage,
            hasMoreBefore: true
        ))
        #expect(initial.firstUnreadMessageID == MessageID(rawValue: 15))
        #expect(initial.loadedUnreadCount == 2)
        #expect(initial.isLowerBound)

        let expandedPage = (11 ... 16).map { message(id: UInt64($0)) }
        let expanded = try #require(model.timelineUnreadSummary(
            channelID: channelID,
            messages: expandedPage,
            hasMoreBefore: true
        ))
        #expect(expanded.firstUnreadMessageID == MessageID(rawValue: 11))
        #expect(expanded.loadedUnreadCount == 6)
        #expect(expanded.isLowerBound)

        let completePage = [message(id: 10)] + expandedPage
        let complete = try #require(model.timelineUnreadSummary(
            channelID: channelID,
            messages: completePage,
            hasMoreBefore: true
        ))
        #expect(complete.loadedUnreadCount == 6)
        #expect(!complete.isLowerBound)
    }

    @Test func `notification visibility follows active presented bottom state without clearing read state`() {
        let model = makeModel(latest: 12, acknowledged: 10)
        _ = model.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialHistoryLoaded: false,
            windowIsActive: true,
            isAtNewest: true
        )
        #expect(model.isActivelyPresentedAtNewest(channelID))
        #expect(!model.isVisibleAtNewest(channelID))
        #expect(model.unread(channelID: channelID))

        _ = model.updatePresentation(channelID: channelID, windowIsActive: false)
        #expect(!model.isActivelyPresentedAtNewest(channelID))
        _ = model.updatePresentation(
            channelID: channelID,
            windowIsActive: true,
            isAtNewest: false
        )
        #expect(!model.isActivelyPresentedAtNewest(channelID))
    }

    @Test func `direct role everyone and reply user ids drive mentions without content heuristics`() {
        let roleID = RoleID(rawValue: 77)
        let model = makeModel(latest: 10, acknowledged: 10)
        model.updateCurrentUserRoles([roleID], guildID: guildID)

        #expect(
            model.receive(
                message(id: 11, mentionedUsers: [currentUser]),
                currentUserID: currentUser.id
            ).mentionKind == .direct
        )
        #expect(
            model.receive(
                message(id: 12, mentionedRoles: [roleID]),
                currentUserID: currentUser.id
            ).mentionKind == .role
        )
        #expect(
            model.receive(
                message(id: 13, mentionsEveryone: true),
                currentUserID: currentUser.id
            ).mentionKind == .everyone
        )
        #expect(
            model.receive(
                message(id: 14, content: "<@1> is only text"),
                currentUserID: currentUser.id
            ).mentionKind == .none
        )
        var silentReply = message(id: 15)
        silentReply.replyTo = MessageID(rawValue: 5)
        #expect(
            model.receive(silentReply, currentUserID: currentUser.id).mentionKind == .none
        )

        var notifyingReply = message(id: 16, mentionedUsers: [currentUser])
        notifyingReply.replyTo = MessageID(rawValue: 5)
        #expect(
            model.receive(notifyingReply, currentUserID: currentUser.id).mentionKind == .direct
        )
    }

    @Test func `suppression overrides authoritative mention metadata`() {
        let roleID = RoleID(rawValue: 77)
        let model = makeModel(
            latest: 10,
            acknowledged: 10,
            settings: GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .onlyMentions,
                suppressEveryone: true,
                suppressRoles: true
            )
        )
        model.updateCurrentUserRoles([roleID], guildID: guildID)
        #expect(
            model.receive(
                message(id: 11, mentionedRoles: [roleID]),
                currentUserID: currentUser.id
            ).mentionKind == .none
        )
        #expect(
            model.receive(
                message(id: 12, mentionsEveryone: true),
                currentUserID: currentUser.id
            ).mentionKind == .none
        )
        var failedRoleMention = message(id: 13, mentionedRoles: [roleID])
        failedRoleMention.flags = [.failedToMentionRoles]
        #expect(
            model.receive(
                failedRoleMention,
                currentUserID: currentUser.id
            ).mentionKind == .none
        )

        var badgeOnly = message(id: 14, mentionedUsers: [currentUser])
        badgeOnly.flags = [.suppressNotifications]
        let badgeOnlyDisposition = model.receive(
            badgeOnly,
            currentUserID: currentUser.id
        )
        #expect(badgeOnlyDisposition.mentionKind == .direct)
        #expect(!badgeOnlyDisposition.shouldNotify)
        #expect(model.mentions(channelID: channelID) == 1)
    }

    @Test(
        arguments: [
            (MessageNotificationLevel.allMessages, false, true),
            (.onlyMentions, false, false),
            (.nothing, false, false),
            (.allMessages, true, false),
        ]
    )
    func `ordinary notification eligibility follows level and guild mute`(
        level: MessageNotificationLevel,
        guildMuted: Bool,
        expected: Bool
    ) {
        let model = makeModel(
            latest: 10,
            acknowledged: 10,
            settings: GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: level,
                isMuted: guildMuted
            )
        )
        #expect(
            model.receive(message(id: 11), currentUserID: currentUser.id).shouldNotify == expected
        )
    }

    @Test func `forum creation notifications honor the parent forum flags`() {
        let forumID = ChannelID(rawValue: 250)
        let threadID = ChannelID(rawValue: 251)

        func forumModel(
            level: MessageNotificationLevel,
            flags: UInt64
        ) -> AccountReadStateModel {
            let model = AccountReadStateModel()
            model.reset(accountID: "account")
            model.setCurrentUserID(currentUser.id)
            model.configure(
                accountID: "account",
                guilds: [
                    Guild(
                        id: guildID,
                        name: "Guild",
                        defaultMessageNotifications: level
                    )
                ],
                channels: [
                    Channel(
                        id: forumID,
                        guildID: guildID,
                        name: "forum",
                        kind: .forum
                    )
                ],
                readStates: [],
                notificationSettings: [
                    GuildNotificationSettings(
                        guildID: guildID,
                        messageNotifications: level,
                        channelOverrides: [
                            ChannelNotificationOverride(
                                channelID: forumID,
                                flags: flags
                            )
                        ]
                    )
                ]
            )
            model.merge(
                thread: MessageThreadSummary(
                    id: threadID,
                    guildID: guildID,
                    parentID: forumID,
                    name: "Post"
                )
            )
            return model
        }

        let message = Message(
            id: MessageID(rawValue: threadID.rawValue),
            channelID: threadID,
            author: sender,
            content: "New post",
            guildID: guildID
        )
        let enabled = forumModel(level: .nothing, flags: 1 << 14)
        #expect(
            enabled.receive(message, currentUserID: currentUser.id).shouldNotify
        )

        let disabled = forumModel(level: .allMessages, flags: 1 << 13)
        #expect(
            !disabled.receive(message, currentUserID: currentUser.id).shouldNotify
        )

        let inherited = forumModel(level: .allMessages, flags: 0)
        #expect(
            inherited.receive(message, currentUserID: currentUser.id).shouldNotify
        )
    }

    @Test func `guild and channel notification levels and mutes cover their full policy matrix`() {
        let guildLevels: [MessageNotificationLevel] = [.allMessages, .onlyMentions, .nothing]
        let channelLevels: [MessageNotificationLevel] = [
            .inherit, .allMessages, .onlyMentions, .nothing,
        ]
        for guildLevel in guildLevels {
            for channelLevel in channelLevels {
                for guildMuted in [false, true] {
                    for channelMuted in [false, true] {
                        for isMention in [false, true] {
                            let settings = GuildNotificationSettings(
                                guildID: guildID,
                                messageNotifications: guildLevel,
                                isMuted: guildMuted,
                                channelOverrides: [
                                    ChannelNotificationOverride(
                                        channelID: channelID,
                                        messageNotifications: channelLevel,
                                        isMuted: channelMuted
                                    )
                                ]
                            )
                            let model = makeModel(
                                latest: 10,
                                acknowledged: 10,
                                settings: settings
                            )
                            let effectiveLevel =
                                channelLevel == .inherit ? guildLevel : channelLevel
                            let expected =
                                isMention
                                ? (!guildMuted && !channelMuted)
                                : (!guildMuted && !channelMuted
                                    && effectiveLevel == .allMessages)
                            let disposition = model.receive(
                                message(
                                    id: 11,
                                    mentionedUsers: isMention ? [currentUser] : []
                                ),
                                currentUserID: currentUser.id
                            )
                            #expect(
                                disposition.shouldNotify == expected,
                                "guild=\(guildLevel) channel=\(channelLevel) guildMuted=\(guildMuted) channelMuted=\(channelMuted) mention=\(isMention)"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test func `guild inherit uses authoritative default and guild mute preserves badges only`() {
        let model = AccountReadStateModel()
        model.reset(accountID: "account")
        model.setCurrentUserID(currentUser.id)
        model.configure(
            accountID: "account",
            guilds: [
                Guild(
                    id: guildID,
                    name: "Guild",
                    defaultMessageNotifications: .allMessages
                )
            ],
            channels: [
                Channel(
                    id: channelID,
                    guildID: guildID,
                    name: "general",
                    categoryID: categoryID,
                    lastMessageID: MessageID(rawValue: 10)
                )
            ],
            readStates: [
                ChannelReadState(
                    channelID: channelID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 10)
                )
            ],
            notificationSettings: [
                GuildNotificationSettings(
                    guildID: guildID,
                    messageNotifications: .inherit
                )
            ]
        )
        #expect(model.receive(message(id: 11), currentUserID: currentUser.id).shouldNotify)

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .onlyMentions,
                isMuted: true
            )
        )
        let mutedMention = model.receive(
            message(id: 12, mentionedUsers: [currentUser]),
            currentUserID: currentUser.id
        )
        #expect(mutedMention.mentionKind == .direct)
        #expect(!mutedMention.shouldNotify)
        #expect(model.mentions(channelID: channelID) == 1)
    }

    @Test func `channel and category overrides apply mute expiry and notification inheritance`() {
        let expired = DiscordMuteConfiguration(endTime: .distantPast)
        let active = DiscordMuteConfiguration(endTime: .distantFuture)
        let model = makeModel(
            latest: 10,
            acknowledged: 10,
            settings: GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .onlyMentions,
                channelOverrides: [
                    ChannelNotificationOverride(
                        channelID: categoryID,
                        messageNotifications: .allMessages,
                        isMuted: true,
                        muteConfiguration: expired
                    )
                ]
            )
        )
        #expect(model.receive(message(id: 11), currentUserID: currentUser.id).shouldNotify)

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                channelOverrides: [
                    ChannelNotificationOverride(
                        channelID: channelID,
                        messageNotifications: .allMessages,
                        isMuted: true,
                        muteConfiguration: active
                    )
                ]
            )
        )
        #expect(!model.receive(message(id: 12), currentUserID: currentUser.id).shouldNotify)
    }

    @Test func `ordinary unread follows notification level when unread flags are absent`() {
        let model = makeModel(
            latest: 10,
            acknowledged: 10,
            settings: GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .nothing
            )
        )
        #expect(!model.receive(message(id: 11), currentUserID: currentUser.id).shouldNotify)
        #expect(!model.unread(channelID: channelID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .onlyMentions
            )
        )
        #expect(!model.unread(channelID: channelID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages
            )
        )
        #expect(model.unread(channelID: channelID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                isMuted: true
            )
        )
        #expect(!model.unread(channelID: channelID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                flags: 1 << 12
            )
        )
        #expect(!model.unread(channelID: channelID))
    }

    @Test func `explicit unread flags override notification level for guilds and channels`() {
        let model = makeModel(
            latest: 10,
            acknowledged: 10,
            settings: GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .nothing,
                flags: 1 << 11
            )
        )
        _ = model.receive(message(id: 11), currentUserID: currentUser.id)
        #expect(model.unread(channelID: channelID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                flags: 1 << 12
            )
        )
        #expect(!model.unread(channelID: channelID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .nothing,
                flags: 1 << 12,
                channelOverrides: [
                    ChannelNotificationOverride(
                        channelID: channelID,
                        flags: 1 << 10
                    )
                ]
            )
        )
        #expect(model.unread(channelID: channelID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                flags: 1 << 11,
                channelOverrides: [
                    ChannelNotificationOverride(
                        channelID: channelID,
                        flags: 1 << 9
                    )
                ]
            )
        )
        #expect(!model.unread(channelID: channelID))
    }

    @Test func `guild channel opt in excludes ordinary unread until the channel is opted in`() {
        let model = makeModel(
            latest: 10,
            acknowledged: 9,
            settings: GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                flags: 1 << 14
            )
        )
        #expect(!model.unread(channelID: channelID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                flags: 1 << 14,
                channelOverrides: [
                    ChannelNotificationOverride(
                        channelID: channelID,
                        flags: 1 << 12
                    )
                ]
            )
        )
        #expect(model.unread(channelID: channelID))

        let threadID = ChannelID(rawValue: 201)
        model.merge(
            thread: MessageThreadSummary(
                id: threadID,
                guildID: guildID,
                parentID: channelID,
                name: "Post",
                lastMessageID: MessageID(rawValue: 20)
            )
        )
        model.applyRemote(
            ChannelReadState(
                channelID: threadID,
                lastAcknowledgedMessageID: MessageID(rawValue: 19)
            )
        )
        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                flags: 1 << 14
            )
        )
        #expect(!model.unread(channelID: threadID))

        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                flags: 1 << 14,
                channelOverrides: [
                    ChannelNotificationOverride(
                        channelID: channelID,
                        flags: 1 << 12
                    )
                ]
            )
        )
        #expect(model.unread(channelID: threadID))

        model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 9),
                mentionCount: 1
            )
        )
        model.apply(
            GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .allMessages,
                flags: 1 << 14
            )
        )
        #expect(model.unread(channelID: channelID))
        #expect(model.guildMentions(guildID) == 1)
    }

    @Test func `dm messages notify and aggregate while guild folder mentions remain isolated`() {
        let dmID = ChannelID(rawValue: 300)
        let model = makeModel(latest: 10, acknowledged: 10)
        model.merge(channels: [
            Channel(id: dmID, guildID: nil, name: "DM", kind: .directMessage)
        ])
        let disposition = model.receive(
            Message(
                id: MessageID(rawValue: 50),
                channelID: dmID,
                author: sender,
                content: "hello"
            ),
            currentUserID: currentUser.id
        )
        #expect(disposition.mentionKind == .directMessage)
        #expect(disposition.shouldNotify)
        #expect(model.mentions(channelID: dmID) == 1)
        #expect(model.directMessageUnread())
        #expect(model.directMessageMentions == 1)
        #expect(model.guildMentions(guildID) == 0)
        #expect(model.folderMentions([guildID]) == 0)

        model.apply(
            GuildNotificationSettings(
                guildID: nil,
                channelOverrides: [
                    ChannelNotificationOverride(channelID: dmID, isMuted: true)
                ]
            )
        )
        #expect(
            !model.receive(
                Message(
                    id: MessageID(rawValue: 51),
                    channelID: dmID,
                    author: sender,
                    content: "muted"
                ),
                currentUserID: currentUser.id
            ).shouldNotify
        )
        #expect(model.mentions(channelID: dmID) == 1)

        let mutedDirectMention = model.receive(
            Message(
                id: MessageID(rawValue: 52),
                channelID: dmID,
                author: sender,
                content: "explicit mention",
                mentionedUsers: [currentUser]
            ),
            currentUserID: currentUser.id
        )
        #expect(mutedDirectMention.mentionKind == .direct)
        #expect(!mutedDirectMention.shouldNotify)
        #expect(model.mentions(channelID: dmID) == 2)
    }

    @Test func `account reset fully isolates state token settings and presentations`() {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 2)
        _ = model.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialHistoryLoaded: true,
            windowIsActive: true,
            isAtNewest: true
        )
        model.completeAcknowledgement(
            channelID: channelID, messageID: MessageID(rawValue: 12), token: "token"
        )
        model.reset(accountID: "other")
        #expect(model.entries.isEmpty)
        #expect(model.settingsByGuild.isEmpty)
        #expect(model.presentations.isEmpty)
        #expect(model.acknowledgementToken == nil)
        #expect(model.totalMentions == 0)
    }

    @Test func `channel thread and guild removal cannot leave aggregate unread state behind`() {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 2)
        let forumID = ChannelID(rawValue: 250)
        let threadID = ChannelID(rawValue: 251)
        model.merge(channels: [
            Channel(id: forumID, guildID: guildID, name: "forum", kind: .forum)
        ])
        model.replaceThreads(
            parentID: forumID,
            with: [
                MessageThreadSummary(
                    id: threadID,
                    guildID: guildID,
                    parentID: forumID,
                    name: "post",
                    lastMessageID: MessageID(rawValue: 30)
                )
            ]
        )
        model.applyRemote(
            ChannelReadState(
                channelID: threadID,
                lastAcknowledgedMessageID: MessageID(rawValue: 29),
                mentionCount: 1
            )
        )
        #expect(model.guildMentions(guildID) == 3)

        model.replaceThreads(parentID: forumID, with: [])
        #expect(model.guildMentions(guildID) == 2)
        model.replaceChannels(in: guildID, with: [])
        #expect(!model.guildUnread(guildID))
        model.retainGuilds([])
        #expect(model.entries.isEmpty)
    }

    private func makeModel(
        latest: UInt64,
        acknowledged: UInt64,
        mentions: Int = 0,
        settings: GuildNotificationSettings? = nil
    ) -> AccountReadStateModel {
        let model = AccountReadStateModel()
        model.reset(accountID: "account")
        model.setCurrentUserID(currentUser.id)
        model.configure(
            accountID: "account",
            guilds: [
                Guild(
                    id: guildID,
                    name: "Guild",
                    defaultMessageNotifications: .allMessages
                )
            ],
            channels: [
                Channel(
                    id: channelID,
                    guildID: guildID,
                    name: "general",
                    categoryID: categoryID,
                    lastMessageID: MessageID(rawValue: latest)
                )
            ],
            readStates: [
                ChannelReadState(
                    channelID: channelID,
                    lastAcknowledgedMessageID: MessageID(rawValue: acknowledged),
                    mentionCount: mentions
                )
            ],
            notificationSettings: settings.map { [$0] } ?? []
        )
        return model
    }

    private func message(
        id: UInt64,
        author: User? = nil,
        content: String = "message",
        mentionedUsers: [User] = [],
        mentionedRoles: [RoleID] = [],
        mentionsEveryone: Bool = false
    ) -> Message {
        Message(
            id: MessageID(rawValue: id),
            channelID: channelID,
            author: author ?? sender,
            content: content,
            guildID: guildID,
            mentionedUsers: mentionedUsers,
            mentionedRoleIDs: mentionedRoles,
            mentionsEveryone: mentionsEveryone
        )
    }
}

@MainActor
@Test func `notification delivery deduplicates cancels by conversation and badges mentions`() async {
    let provider = MockChatProvider()
    let service = RecordingNotificationService()
    let defaults = UserDefaults(suiteName: "NotificationTests.\(UUID().uuidString)")!
    let preferences = NotificationPreferences(defaults: defaults)
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        notificationService: service,
        notificationPreferences: preferences
    )
    await model.start()
    let baselineBadgeCount = model.readState.totalMentions

    let message = Message(
        id: MessageID(rawValue: UInt64.max - 10),
        channelID: ChannelID(rawValue: 211),
        author: User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender"),
        content: "Authoritative mention",
        guildID: GuildID(rawValue: 100),
        mentionedUsers: [User(id: UserID(rawValue: 1), username: "nova", displayName: "Nova")]
    )
    await provider.emit(.messageCreated(message))
    #expect(await eventually { service.deliveredMessageIDs == [message.id] })
    #expect(service.badgeCounts.last == baselineBadgeCount + 1)

    await provider.emit(.messageCreated(message))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(service.deliveredMessageIDs == [message.id])

    await provider.emit(
        .readStateChanged(
            ChannelReadState(
                channelID: message.channelID,
                lastAcknowledgedMessageID: message.id,
                mentionCount: 0
            )
        )
    )
    #expect(await eventually { service.cancelledChannelIDs.contains(message.channelID) })
    #expect(service.badgeCounts.last == baselineBadgeCount)
}

@MainActor
@Test func `notification privacy quiet hours and deep links are deterministic`() throws {
    let message = Message(
        id: MessageID(rawValue: 9),
        channelID: ChannelID(rawValue: 8),
        author: User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender"),
        content: "private body",
        guildID: GuildID(rawValue: 7)
    )
    let channel = Channel(
        id: message.channelID, guildID: message.guildID, name: "general"
    )
    #expect(
        NotificationContentPresentation.make(
            message: message, channel: channel, guild: nil, style: .full
        ) == NotificationContentPresentation(
            title: "Sender", subtitle: "#general", body: "private body"
        )
    )
    #expect(
        NotificationContentPresentation.make(
            message: message, channel: channel, guild: nil, style: .senderOnly
        ).body == "New message"
    )
    #expect(
        NotificationContentPresentation.make(
            message: message, channel: channel, guild: nil, style: .hidden
        ).title == "SakuraCord"
    )

    let defaults = UserDefaults(suiteName: "QuietHoursTests.\(UUID().uuidString)")!
    let preferences = NotificationPreferences(defaults: defaults)
    preferences.quietHoursEnabled = true
    preferences.quietStartHour = 22
    preferences.quietEndHour = 8
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    #expect(preferences.isQuiet(at: date(hour: 23, calendar: calendar), calendar: calendar))
    #expect(!preferences.isQuiet(at: date(hour: 12, calendar: calendar), calendar: calendar))

    let link = NotificationDeepLink(
        accountID: "account",
        guildID: message.guildID,
        channelID: message.channelID,
        messageID: message.id
    )
    #expect(try JSONDecoder().decode(
        NotificationDeepLink.self,
        from: JSONEncoder().encode(link)
    ) == link)
    let largeLink = NotificationDeepLink(
        accountID: "account",
        guildID: GuildID(rawValue: UInt64.max - 2),
        channelID: ChannelID(rawValue: UInt64.max - 1),
        messageID: MessageID(rawValue: UInt64.max)
    )
    #expect(NotificationDeepLink(userInfo: largeLink.userInfo) == largeLink)
}

@MainActor
@Test func `view acknowledgements coalesce serialize and chain the response token`() async {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await eventually { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    model.reportTimelineInitialPosition(channelID: channelID, isAtNewest: true)

    let author = User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender")
    let first = Message(
        id: MessageID(rawValue: UInt64.max - 20),
        channelID: channelID,
        author: author,
        content: "first",
        guildID: GuildID(rawValue: 100)
    )
    let newest = Message(
        id: MessageID(rawValue: UInt64.max - 10),
        channelID: channelID,
        author: author,
        content: "newest",
        guildID: GuildID(rawValue: 100)
    )
    await provider.emit(.messageCreated(first))
    await provider.emit(.messageCreated(newest))
    #expect(await eventually {
        model.readState.entries[channelID]?.latestKnownMessageID == newest.id
    })
    try? await Task.sleep(for: .milliseconds(40))

    let requests = await provider.acknowledgementRequests
    #expect(requests.count == 1)
    #expect(requests.first?.channelID == channelID)
    #expect(requests.first?.messageID == newest.id)
    #expect(model.readState.acknowledgementToken == "mock-ack-token")

    let nextChannelID = ChannelID(rawValue: 211)
    model.selectedChannelID = nextChannelID
    #expect(await eventually {
        !model.isLoadingMessages && model.selectedChannelID == nextChannelID
    })
    model.reportConversationHistoryLoaded(channelID: nextChannelID)
    model.reportTimelineInitialPosition(channelID: nextChannelID, isAtNewest: true)
    for _ in 0 ..< 500 {
        if await provider.acknowledgementRequests.count == 2 { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    let chainedRequests = await provider.acknowledgementRequests
    #expect(chainedRequests.count == 2)
    guard chainedRequests.count == 2 else { return }
    #expect(chainedRequests[1].channelID == nextChannelID)
    #expect(chainedRequests[1].token == "mock-ack-token")
}

@MainActor
@Test func `ready read state arriving after timeline setup still permits automatic acknowledgement`() async
    throws
{
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 212)
    model.selectedChannelID = channelID
    #expect(await eventually { !model.isLoadingMessages && model.selectedChannelID == channelID })
    let previousAcknowledgement = model.readState.entries[channelID]?.lastAcknowledgedMessageID
    model.reportMainWindowActive(true)
    model.reportTimelineInitialPosition(channelID: channelID, isAtNewest: true)

    let newest = Message(
        id: MessageID(rawValue: UInt64.max - 2),
        channelID: channelID,
        author: User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender"),
        content: "new",
        guildID: GuildID(rawValue: 100)
    )
    await provider.emit(.messageCreated(newest))
    await provider.emit(.readStateSnapshot([
        ChannelReadState(
            channelID: channelID,
            lastAcknowledgedMessageID: previousAcknowledgement
        )
    ]))

    for _ in 0 ..< 500 {
        if await provider.acknowledgementRequests.count == 1 { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await provider.acknowledgementRequests.count == 1)
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    #expect(request.messageID == newest.id)
    #expect(!request.manual)
}

@MainActor
@Test func `mark unread sends one backward manual acknowledgement`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await eventually { !model.isLoadingMessages && !model.messages.isEmpty })
    let selectedMessage = try #require(model.messages.dropFirst().first)
    let currentUserID = try #require(model.snapshot?.currentUser.id)
    let expectedMentions = model.readState.mentionCountForManualUnread(
        channelID: channelID,
        messages: model.messages,
        startingAt: selectedMessage.id,
        currentUserID: currentUserID
    )

    model.markMessageAndFollowingUnread(selectedMessage)
    for _ in 0 ..< 500 {
        if await provider.acknowledgementRequests.count == 1 { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await provider.acknowledgementRequests.count == 1)
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    #expect(request.messageID.rawValue == selectedMessage.id.rawValue - 1)
    #expect(request.manual)
    #expect(request.mentionCount == expectedMentions)
    #expect(request.flags == 1)
    #expect(request.lastViewed != nil)
    #expect(
        model.readState.entries[channelID]?.lastAcknowledgedMessageID
            == request.messageID
    )
}

@MainActor
private final class RecordingNotificationService: NativeNotificationService {
    var deliveredMessageIDs: [MessageID] = []
    var cancelledChannelIDs: [ChannelID] = []
    var badgeCounts: [Int] = []

    func requestAuthorization() async throws -> Bool { true }
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func deliver(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        preferences: NotificationPreferences
    ) async {
        deliveredMessageIDs.append(message.id)
    }
    func cancel(accountID: String, channelID: ChannelID) async {
        cancelledChannelIDs.append(channelID)
    }
    func setDockBadge(_ count: Int, enabled: Bool) {
        badgeCounts.append(enabled ? count : 0)
    }
}

@MainActor
private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private func date(hour: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 7, day: 25, hour: hour))!
}
