@testable import SakuraCord
import Foundation
import SakuraCordModels
import Observation
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

    @Test func `batched initial state matches incremental bootstrap semantics`() {
        let forumID = ChannelID(rawValue: 201)
        let threadID = ChannelID(rawValue: 202)
        let guilds = [
            Guild(
                id: guildID,
                name: "Guild",
                defaultMessageNotifications: .allMessages
            )
        ]
        let channels = [
            Channel(
                id: categoryID,
                guildID: guildID,
                name: "Category"
            ),
            Channel(
                id: channelID,
                guildID: guildID,
                name: "General",
                categoryID: categoryID,
                lastMessageID: MessageID(rawValue: 20)
            ),
            Channel(
                id: forumID,
                guildID: guildID,
                name: "Forum",
                kind: .forum,
                lastMessageID: MessageID(rawValue: 19)
            ),
        ]
        let threads = [
            MessageThreadSummary(
                id: threadID,
                guildID: guildID,
                parentID: forumID,
                name: "Post",
                lastMessageID: MessageID(rawValue: 21)
            )
        ]
        let readStates = [
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10),
                mentionCount: 2,
                version: 4
            ),
            ChannelReadState(
                channelID: threadID,
                lastAcknowledgedMessageID: MessageID(rawValue: 18),
                version: 5
            ),
        ]
        let settings = [
            GuildNotificationSettings(
                guildID: guildID,
                channelOverrides: [
                    ChannelNotificationOverride(
                        channelID: categoryID,
                        isMuted: true,
                        isCollapsed: true
                    ),
                    ChannelNotificationOverride(
                        channelID: channelID,
                        messageNotifications: .allMessages
                    ),
                ]
            )
        ]

        let incremental = AccountReadStateModel()
        incremental.reset(accountID: "account")
        incremental.configure(
            accountID: "account",
            guilds: guilds,
            channels: channels,
            readStates: readStates,
            notificationSettings: settings
        )
        for thread in threads {
            incremental.merge(thread: thread)
        }
        incremental.replaceActiveJoinedThreads(threads)
        incremental.setCurrentUserID(currentUser.id)

        let batched = AccountReadStateModel()
        batched.applyInitialState(AccountReadStateModel.makeInitialState(.init(
            accountID: "account",
            guilds: guilds,
            channels: channels,
            threads: threads,
            readStates: readStates,
            notificationSettings: settings,
            usesNewNotifications: true,
            currentUserID: currentUser.id,
            activeJoinedThreads: threads
        )))

        #expect(batched.entries == incremental.entries)
        #expect(batched.settingsByGuild == incremental.settingsByGuild)
        #expect(batched.remoteReadStateOrder == incremental.remoteReadStateOrder)
        #expect(batched.quickSwitcherProjection() == incremental.quickSwitcherProjection())
        #expect(
            batched.unreadPresentationProjection()
                == incremental.unreadPresentationProjection()
        )
        #expect(batched.isCategoryMuted(categoryID: categoryID, guildID: guildID))
        #expect(batched.isCategoryCollapsed(categoryID: categoryID, guildID: guildID))
    }

    @Test func `forum post newness follows Discord's visit label and sidebar count rules`() {
        let newPostID = ChannelID(rawValue: 300)
        let joinedBefore = Date(timeIntervalSince1970: 1_420_070_000)
        let joinedAfter = Date(timeIntervalSince1970: 1_500_000_000)
        let newPost = ForumPost(
            thread: MessageThreadSummary(
                id: newPostID,
                guildID: guildID,
                parentID: channelID,
                name: "First unread post",
                // A reply a millisecond later, past Discord's fallback boundary.
                lastMessageID: MessageID(rawValue: newPostID.rawValue + (1 << 22))
            )
        )
        func model(acknowledging boundary: MessageID?, joinedAt: Date?) -> AccountReadStateModel {
            let model = AccountReadStateModel()
            model.configure(
                accountID: "account",
                guilds: [
                    Guild(id: guildID, name: "Guild", defaultMessageNotifications: .allMessages, joinedAt: joinedAt)
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
                // READY omits a never-acknowledged forum's read state.
                readStates: boundary.map { [ChannelReadState(channelID: channelID, lastAcknowledgedMessageID: $0)] } ?? [],
                notificationSettings: []
            )
            model.merge(forumPost: newPost)
            return model
        }
        func visitAndAcknowledge(_ model: AccountReadStateModel) {
            model.beginForumVisit(channelID: channelID)
            model.acknowledge(channelID: channelID, messageID: MessageID(rawValue: 1_000))
        }

        // Outside a visit the sidebar counts past the acknowledgement with no
        // join check; a visit labels and counts against the captured boundary.
        let acknowledged = model(acknowledging: MessageID(rawValue: 100), joinedAt: joinedBefore)
        #expect(acknowledged.forumNewPostCount(channelID: channelID) == 1)
        // Discord's forum unread count includes a never-opened post past the
        // forum's acknowledgement, which enables the row's Mark as Read.
        #expect(acknowledged.hasUnreadForumPosts(channelID: channelID))
        // Its own Mark as Read ignores membership, unlike aggregate unread.
        #expect(acknowledged.isForumPostUnread(channelID: newPostID) == true)
        #expect(!acknowledged.unread(channelID: newPostID))
        visitAndAcknowledge(acknowledged)
        #expect(acknowledged.isNewForumPost(newPost))
        #expect(acknowledged.forumNewPostCount(channelID: channelID) == 1)
        #expect(acknowledged.endForumVisit(channelID: channelID))
        #expect(acknowledged.forumNewPostCount(channelID: channelID) == 0)

        let joinedLater = model(acknowledging: MessageID(rawValue: 100), joinedAt: joinedAfter)
        #expect(joinedLater.forumNewPostCount(channelID: channelID) == 1)
        joinedLater.beginForumVisit(channelID: channelID)
        #expect(!joinedLater.isNewForumPost(newPost))
        #expect(joinedLater.forumNewPostCount(channelID: channelID) == 0)

        // A never-acknowledged forum uses the join time as its boundary, and
        // keeps it for the whole visit after the visit acknowledges.
        let neverRead = model(acknowledging: nil, joinedAt: joinedBefore)
        #expect(neverRead.forumNewPostCount(channelID: channelID) == 1)
        visitAndAcknowledge(neverRead)
        #expect(neverRead.isNewForumPost(newPost))
        #expect(model(acknowledging: nil, joinedAt: joinedAfter).forumNewPostCount(channelID: channelID) == 0)
        #expect(model(acknowledging: nil, joinedAt: nil).forumNewPostCount(channelID: channelID) == 0)

        // A local acknowledgement is tracked at once, so leaving or reopening
        // the forum shows no read post as new.
        #expect(neverRead.endForumVisit(channelID: channelID))
        #expect(neverRead.forumNewPostCount(channelID: channelID) == 0)
        neverRead.beginForumVisit(channelID: channelID)
        #expect(!neverRead.isNewForumPost(newPost))

        // Mark as Read clears a never-read forum's count despite its seeded
        // boundary hiding the forum's own unread state.
        let unvisited = model(acknowledging: nil, joinedAt: joinedBefore)
        #expect(!unvisited.hasUnreadForumPosts(channelID: channelID))
        let targets = unvisited.allServerAcknowledgements(in: [guildID])
        #expect(targets.map(\.channelID) == [channelID])
        // Like the visit, bulk acknowledgement covers the forum up to now.
        #expect(targets.allSatisfy { $0.messageID > MessageID(rawValue: newPostID.rawValue) })
        for target in targets {
            unvisited.acknowledge(channelID: target.channelID, messageID: target.messageID)
        }
        #expect(unvisited.forumNewPostCount(channelID: channelID) == 0)

        // Joined posts keep their label but leave the sidebar count.
        let joined = model(acknowledging: nil, joinedAt: joinedBefore)
        joined.beginForumVisit(channelID: channelID)
        joined.replaceActiveJoinedThreads([newPost.thread])
        #expect(joined.isNewForumPost(newPost))
        #expect(joined.forumNewPostCount(channelID: channelID) == 0)
    }

    @Test func `forum catalogue unread state seeds omitted thread read state`() {
        // Snowflakes a millisecond apart, so the reply is past the post's creation.
        let threadID = ChannelID(rawValue: 1 << 22)
        let latestMessageID = MessageID(rawValue: 2 << 22)
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
        #expect(model.entries[threadID]?.isUnread == true)
        #expect(model.unreadMessageCount(channelID: threadID) == 3)
        #expect(!model.guildUnread(guildID))
    }

    /// Discord's MESSAGE_CREATE acknowledges the account's own message
    /// locally, clearing earlier unseen messages (build 649389).
    @Test func `own messages acknowledge the conversation`() {
        let unreadModel = makeModel(latest: 12, acknowledged: 10, mentions: 1)
        #expect(unreadModel.receive(
            message(id: 13, author: currentUser), currentUserID: currentUser.id
        ).acknowledgesOwnMessage)
        #expect(unreadModel.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 13))
        #expect(!unreadModel.unread(channelID: channelID))
        #expect(unreadModel.mentions(channelID: channelID) == 0)
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
            model.updatePresentation(
                channelID: channelID,
                windowIsActive: true,
                hasReachedReadBoundary: false
            )
                == nil
        )
        #expect(
            model.updatePresentation(
                channelID: channelID,
                hasReachedReadBoundary: true
            ) == nil
        )
        #expect(
            model.updatePresentation(channelID: channelID, initialPositionEstablished: true)
                == MessageID(rawValue: 12)
        )
    }

    @Test func `held backlog visit resumes acknowledgement once the backlog is read elsewhere`() {
        let model = makeModel(latest: 12, acknowledged: 10)
        #expect(
            model.updatePresentation(
                channelID: channelID,
                isPresented: true,
                initialHistoryLoaded: true,
                initialPositionEstablished: true,
                windowIsActive: true,
                hasReachedReadBoundary: true,
                blocksAutomaticAcknowledgement: true
            ) == nil
        )
        // Discord acknowledges the backlog itself, e.g. after a reply is sent.
        #expect(model.applyRemote(ChannelReadState(
            channelID: channelID,
            lastAcknowledgedMessageID: MessageID(rawValue: 12)
        )))
        #expect(model.receive(message(id: 13), currentUserID: currentUser.id).accepted)
        #expect(model.updatePresentation(channelID: channelID) == MessageID(rawValue: 13))
        // Messages missed while disconnected arrive with reloaded history
        // rather than as live messages; the lapsed hold must not return.
        model.observeLoadedMessages(channelID: channelID, messages: [message(id: 14)])
        #expect(model.updatePresentation(channelID: channelID) == MessageID(rawValue: 14))
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

    @Test func `acknowledgement metadata uses Discord epoch days and channel thread flags`() {
        let model = makeModel(latest: 12, acknowledged: 10)
        let twoDaysAfterEpoch = Date(timeIntervalSince1970: 1_420_070_400 + 2 * 86_400)
        #expect(
            model.acknowledgementMetadata(channelID: channelID, now: twoDaysAfterEpoch)
                == .init(flags: 1, lastViewed: 2)
        )
        // Only READY carries a read state's flags.
        model.replaceReadStates([
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10),
                mentionCount: 0,
                flags: 1
            )
        ])
        #expect(
            model.acknowledgementMetadata(channelID: channelID, now: twoDaysAfterEpoch)
                == .init(flags: nil, lastViewed: 2)
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

    /// Discord's `ack()` ends Mark Unread's suppression at any boundary (E2,
    /// E11), so another client's earlier read cannot leave reading blocked.
    @Test func `any acknowledgement ends Mark Unread's hold`() {
        let model = makeModel(latest: 20, acknowledged: 20)
        _ = model.updatePresentation(
            channelID: channelID, isPresented: true, initialHistoryLoaded: true,
            initialPositionEstablished: true, windowIsActive: true, hasReachedReadBoundary: true
        )
        model.holdUntilSelectionChange(channelID: channelID)
        #expect(model.applyRemote(ChannelReadState(
            channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 10), isManual: true
        )))
        #expect(model.holdsAutomaticAcknowledgement(channelID))
        #expect(model.applyRemote(ChannelReadState(channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 5))))
        #expect(!model.holdsAutomaticAcknowledgement(channelID))
        #expect(model.updatePresentation(channelID: channelID, hasReachedReadBoundary: true) == MessageID(rawValue: 20))
    }

    /// Discord's MESSAGE_ACK (build 649389) applies events in received order,
    /// with no version or boundary comparison.
    @Test func `gateway acknowledgements apply in received order`() {
        let model = makeModel(latest: 20, acknowledged: 10, mentions: 3)
        // An ordinary echo of the current boundary changes nothing.
        #expect(!model.applyRemote(ChannelReadState(
            channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 10), mentionCount: 0
        )))
        #expect(model.mentions(channelID: channelID) == 3)
        // Any other acknowledges there, clearing mentions, even when older.
        #expect(model.applyRemote(ChannelReadState(
            channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 18), mentionCount: 2, version: 12
        )))
        #expect(model.mentions(channelID: channelID) == 0)
        #expect(model.applyRemote(ChannelReadState(
            channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 9), mentionCount: 0, version: 11
        )))
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 9))
        #expect(model.unread(channelID: channelID))
        // A manual event always rebuilds with its mention count.
        #expect(model.applyRemote(ChannelReadState(
            channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 9), mentionCount: 2, isManual: true
        )))
        #expect(model.mentions(channelID: channelID) == 2)
        // READY replaces the read state outright.
        model.replaceReadStates([
            ChannelReadState(channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 20), mentionCount: 0)
        ])
        #expect(!model.unread(channelID: channelID))
    }

    @Test func `loaded local sends never become the read boundary`() {
        let model = makeModel(latest: 10, acknowledged: 10)
        var pending = message(id: UInt64.max, author: currentUser)
        pending.nonce = "nonce"
        pending.outboxState = .sending
        // A failed command placeholder is settled but keeps its local ID.
        var notice = message(id: UInt64.max - 1, author: currentUser)
        notice.nonce = "command"
        notice.flags = [.ephemeral, .localInteractionFailure]
        model.observeLoadedMessages(
            channelID: channelID,
            messages: [message(id: 10), notice, pending]
        )
        #expect(model.entries[channelID]?.latestKnownMessageID == MessageID(rawValue: 10))
        #expect(!model.unread(channelID: channelID))

        // A later message still counts and remains acknowledgeable.
        let disposition = model.receive(
            message(id: 11, mentionedUsers: [currentUser]),
            currentUserID: currentUser.id
        )
        #expect(disposition.accepted)
        #expect(model.mentions(channelID: channelID) == 1)
        #expect(
            model.updatePresentation(
                channelID: channelID,
                isPresented: true,
                initialHistoryLoaded: true,
                initialPositionEstablished: true,
                windowIsActive: true,
                hasReachedReadBoundary: true
            ) == MessageID(rawValue: 11)
        )
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

        var silentMention = message(id: 17, mentionedUsers: [currentUser])
        silentMention.flags = [.suppressNotifications]
        let silent = model.receive(silentMention, currentUserID: currentUser.id)
        #expect(silent.mentionKind == .direct)
        #expect(!silent.shouldNotify)

        let duplicate = model.receive(silentMention, currentUserID: currentUser.id)
        #expect(!duplicate.accepted)
        #expect(!duplicate.shouldNotify)
    }

    @Test func `account reset fully isolates state token settings and presentations`() {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 2)
        _ = model.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialHistoryLoaded: true,
            windowIsActive: true,
            hasReachedReadBoundary: true
        )
        model.completeAcknowledgement(token: "token", sentWith: nil)
        model.reset(accountID: "other")
        #expect(model.entries.isEmpty)
        #expect(model.settingsByGuild.isEmpty)
        #expect(model.presentations.isEmpty)
        #expect(model.acknowledgementToken == nil)
        #expect(model.totalMentions == 0)
    }

    /// A joined thread READY lists without a read state is read only up to
    /// Discord's fallback boundary. Without it the thread lost its unread
    /// row and server Mark as Read skipped it.
    @Test func `joined threads without a saved read state use Discord's fallback boundary`() {
        let model = makeModel(latest: 10, acknowledged: 10)
        let serverJoin = Date(timeIntervalSince1970: 1_750_000_000)
        model.merge(guilds: [Guild(id: guildID, name: "Guild", defaultMessageNotifications: .allMessages, joinedAt: serverJoin)])
        let created = serverJoin.addingTimeInterval(3_600)
        func thread(_ offset: TimeInterval, lastMessageAfter: TimeInterval, archivedAfter: TimeInterval)
            -> MessageThreadSummary
        {
            let start = created.addingTimeInterval(offset)
            return MessageThreadSummary(
                id: ChannelID(timestamp: start), guildID: guildID, parentID: channelID, name: "Thread",
                lastMessageID: MessageID(timestamp: start.addingTimeInterval(lastMessageAfter)),
                archiveTimestamp: start.addingTimeInterval(archivedAfter),
                notificationSettings: ThreadNotificationSettings(joinedAt: start.addingTimeInterval(1))
            )
        }
        let unread = thread(0, lastMessageAfter: 60, archivedAfter: 0)
        // Reopened after its last message: the archive time is the boundary.
        let reopened = thread(10, lastMessageAfter: 60, archivedAfter: 120)
        model.replaceActiveJoinedThreads([unread, reopened])

        #expect(model.unread(channelID: unread.id))
        #expect(!model.unread(channelID: reopened.id))
        #expect(model.guildUnread(guildID))
        #expect(model.allServerAcknowledgements(in: [guildID]).map(\.channelID) == [unread.id])
        // Discord keeps a joined thread unread, and its server lit, under a muted parent.
        model.apply(GuildNotificationSettings(
            guildID: guildID,
            messageNotifications: .allMessages,
            channelOverrides: [ChannelNotificationOverride(channelID: channelID, isMuted: true)]
        ))
        #expect(model.unread(channelID: unread.id))
        #expect(model.guildUnread(guildID))
        // Nor do inherited unread settings apply, so navigation and the Dock
        // count agree with its row and server.
        model.apply(GuildNotificationSettings(
            guildID: guildID,
            messageNotifications: .allMessages,
            channelOverrides: [ChannelNotificationOverride(channelID: channelID, flags: 1 << 9)]
        ))
        #expect(model.unread(channelID: unread.id))
        #expect(model.unreadPresentationProjection().unreadConversationCount == 1)
    }

    /// Discord's server Mark as Read acknowledges muted channels too.
    @Test func `server mark as read targets include muted channels`() {
        let model = makeModel(
            latest: 20,
            acknowledged: 10,
            settings: GuildNotificationSettings(
                guildID: guildID,
                channelOverrides: [ChannelNotificationOverride(channelID: channelID, isMuted: true)]
            )
        )
        #expect(!model.unread(channelID: channelID))
        #expect(model.allServerAcknowledgements(in: [guildID]).map(\.channelID) == [channelID])
    }

    @Test func `guild unread comes from unseen forum posts not the forum boundary`() {
        let forumID = ChannelID(rawValue: 250)
        let postID = ChannelID(rawValue: 300)
        let model = makeModel(latest: 10, acknowledged: 10)
        model.merge(channels: [
            Channel(
                id: forumID,
                guildID: guildID,
                name: "forum",
                kind: .forum,
                categoryID: categoryID,
                lastMessageID: MessageID(rawValue: postID.rawValue)
            )
        ])
        model.applyRemote(
            ChannelReadState(
                channelID: forumID,
                lastAcknowledgedMessageID: MessageID(rawValue: 275)
            )
        )
        #expect(!model.guildUnread(guildID))

        model.merge(
            forumPost: ForumPost(
                thread: MessageThreadSummary(
                    id: postID,
                    guildID: guildID,
                    parentID: forumID,
                    name: "Unseen post",
                    lastMessageID: MessageID(rawValue: postID.rawValue)
                )
            )
        )
        #expect(model.guildUnread(guildID))
        // Discord's category action also acknowledges the read channel, and
        // targets the forum's latest post rather than the current time.
        #expect(
            model.categoryAcknowledgements(for: categoryID, guildID: guildID)
                == [
                    BulkReadStateAcknowledgement(channelID: channelID, messageID: MessageID(rawValue: 10)),
                    BulkReadStateAcknowledgement(channelID: forumID, messageID: MessageID(rawValue: postID.rawValue)),
                ]
        )

        // A joined thread keeps lighting the server after its forum's
        // boundary has moved past it.
        let joinedThreadID = ChannelID(rawValue: 260)
        model.replaceActiveJoinedThreads([
            MessageThreadSummary(
                id: joinedThreadID,
                guildID: guildID,
                parentID: forumID,
                name: "Joined thread",
                lastMessageID: MessageID(rawValue: 290)
            )
        ])
        model.applyRemote(
            ChannelReadState(
                channelID: postID,
                lastAcknowledgedMessageID: MessageID(rawValue: postID.rawValue)
            )
        )
        model.applyRemote(
            ChannelReadState(
                channelID: joinedThreadID,
                lastAcknowledgedMessageID: MessageID(rawValue: 280)
            )
        )
        #expect(model.unreadPresentationProjection().newForumPostsByChannelID[forumID, default: 0] == 0)
        #expect(model.guildUnread(guildID))
    }

    @Test(arguments: ["archived", "left", "missing parent", "inaccessible parent", "reconnect"])
    func `unpresentable threads retain local unread without lighting aggregate indicators`(change: String) {
        let model = makeModel(latest: 10, acknowledged: 10)
        let parent = Channel(id: channelID, guildID: guildID, name: "Forum", kind: .forum)
        model.merge(channels: [parent])
        let threadID = ChannelID(rawValue: 260)
        var thread = MessageThreadSummary(
            id: threadID,
            parentID: channelID,
            name: "Joined thread",
            lastMessageID: MessageID(rawValue: 290)
        )
        model.replaceActiveJoinedThreads([thread])
        model.applyRemote(ChannelReadState(
            channelID: threadID,
            lastAcknowledgedMessageID: MessageID(rawValue: 280)
        ))
        #expect(model.guildUnread(guildID))
        #expect(model.unreadPresentationProjection().unreadConversationCount == 1)
        #expect(model.allServerAcknowledgements(in: [guildID]).contains { $0.channelID == threadID })

        switch change {
        case "archived":
            thread.isArchived = true
            model.merge(thread: thread)
        case "left":
            model.replaceActiveJoinedThreads([])
        case "missing parent":
            model.replaceChannels(in: guildID, with: [])
        case "inaccessible parent":
            model.applyAccessibility([channelID: false])
        default:
            model.replaceSnapshot(BootstrapSnapshot(
                currentUser: currentUser,
                guilds: [Guild(id: guildID, name: "Guild", defaultMessageNotifications: .allMessages)],
                channels: [parent],
                threads: [thread],
                members: [],
                readStates: [ChannelReadState(channelID: threadID, lastAcknowledgedMessageID: MessageID(rawValue: 280))]
            ))
        }
        #expect(model.entries[threadID]?.isUnread == true)
        #expect(!model.guildUnread(guildID))
        let projection = model.unreadPresentationProjection()
        #expect(projection.unreadByGuildID[guildID] != true)
        #expect(projection.unreadConversationCount == 0)
    }

    @Test func `a thread mention surfaces only while its post is a joined active thread`() {
        let model = makeModel(latest: 10, acknowledged: 10)
        model.merge(channels: [Channel(id: channelID, guildID: guildID, name: "Forum", kind: .forum)])
        let threadID = ChannelID(rawValue: 260)
        var thread = MessageThreadSummary(
            id: threadID,
            parentID: channelID,
            name: "Post",
            lastMessageID: MessageID(rawValue: 265)
        )
        model.merge(thread: thread)
        var ping = message(id: 270, mentionsEveryone: true)
        ping.channelID = threadID
        #expect(model.receive(ping, currentUserID: currentUser.id).mentionKind == .everyone)

        func presentedMentions() -> [Int] {
            [
                model.mentions(channelID: threadID),
                model.guildMentions(guildID),
                model.totalMentions,
                model.unreadPresentationProjection().mentionsByGuildID[guildID, default: 0],
            ]
        }
        // Discord keeps the raw count but hides it until the account joins.
        #expect(model.entries[threadID]?.mentionCount == 1)
        #expect(presentedMentions() == [0, 0, 0, 0])

        model.replaceActiveJoinedThreads([thread])
        #expect(presentedMentions() == [1, 1, 1, 1])
        #expect(model.unreadPresentationProjection().mentionsByChannelID[threadID] == 1)

        // A stale archived flag from a delayed catalogue page does not hide a
        // thread the active joined catalogue still lists.
        thread.isArchived = true
        model.merge(thread: thread)
        #expect(presentedMentions() == [1, 1, 1, 1])

        // Archiving through the joined catalogue removes membership.
        model.replaceActiveJoinedThreads([thread])
        #expect(presentedMentions() == [0, 0, 0, 0])

        thread.isArchived = false
        model.replaceActiveJoinedThreads([thread])
        #expect(presentedMentions() == [1, 1, 1, 1])
        model.replaceActiveJoinedThreads([])
        #expect(presentedMentions() == [0, 0, 0, 0])

        // A ping can outrun the thread's metadata: the parentless guild entry
        // must stay hidden until the thread is known and joined.
        let earlyID = ChannelID(rawValue: 261)
        var early = message(id: 280, mentionsEveryone: true)
        early.channelID = earlyID
        _ = model.receive(early, currentUserID: currentUser.id)
        #expect(model.mentions(channelID: earlyID) == 0)
        #expect(model.guildMentions(guildID) == 0)
        let earlyThread = MessageThreadSummary(
            id: earlyID, parentID: channelID, name: "Early", lastMessageID: MessageID(rawValue: 280)
        )
        model.replaceActiveJoinedThreads([earlyThread])
        #expect(model.mentions(channelID: earlyID) == 1)
    }

    @Test func `inaccessible channels are excluded from bulk acknowledgements`() {
        let model = makeModel(latest: 11, acknowledged: 10)
        #expect(!model.categoryAcknowledgements(for: categoryID, guildID: guildID).isEmpty)

        model.applyAccessibility([channelID: false])
        #expect(model.categoryAcknowledgements(for: categoryID, guildID: guildID).isEmpty)
    }

    enum MuteScenario: CaseIterable {
        case guildMute, channelMute, expiredChannelMute, categoryMute, expiredCategoryMute
        case suppressedEveryone, suppressedRole, mutedDirectMessage, nothingLevel, mutedThread
    }

    @Test(arguments: MuteScenario.allCases)
    func `active mutes and suppressions silence alerts while expired mutes do not`(
        scenario: MuteScenario
    ) {
        let roleID = RoleID(rawValue: 77)
        let dmID = ChannelID(rawValue: 301)
        var settings = GuildNotificationSettings(guildID: guildID, messageNotifications: .allMessages)
        var incoming = message(id: 11)
        var alerts = false
        var badges = 0
        var thread: MessageThreadSummary?
        switch scenario {
        case .guildMute:
            settings.isMuted = true
            incoming = message(id: 11, mentionedUsers: [currentUser])
            badges = 1
        case .channelMute:
            settings.channelOverrides = [ChannelNotificationOverride(channelID: channelID, isMuted: true)]
        case .expiredChannelMute:
            settings.channelOverrides = [ChannelNotificationOverride(
                channelID: channelID, isMuted: true,
                muteConfiguration: DiscordMuteConfiguration(endTime: .distantPast)
            )]
            alerts = true
        case .categoryMute, .expiredCategoryMute:
            settings.messageNotifications = .onlyMentions
            settings.channelOverrides = [ChannelNotificationOverride(
                channelID: categoryID, messageNotifications: .allMessages, isMuted: true,
                muteConfiguration: DiscordMuteConfiguration(
                    endTime: scenario == .categoryMute ? .distantFuture : .distantPast
                )
            )]
            alerts = scenario == .expiredCategoryMute
        case .suppressedEveryone:
            settings.messageNotifications = .onlyMentions
            settings.suppressEveryone = true
            incoming = message(id: 11, mentionsEveryone: true)
        case .suppressedRole:
            settings.messageNotifications = .onlyMentions
            settings.suppressRoles = true
            incoming = message(id: 11, mentionedRoles: [roleID])
        case .mutedDirectMessage:
            settings = GuildNotificationSettings(
                guildID: nil,
                channelOverrides: [ChannelNotificationOverride(channelID: dmID, isMuted: true)]
            )
            incoming = Message(
                id: MessageID(rawValue: 11), channelID: dmID, author: sender,
                content: "message"
            )
        case .nothingLevel:
            settings.messageNotifications = .nothing
            incoming = message(id: 11, mentionedUsers: [currentUser])
            badges = 1
        case .mutedThread:
            let threadID = ChannelID(rawValue: 201)
            thread = MessageThreadSummary(
                id: threadID, guildID: guildID, parentID: channelID, name: "Post",
                notificationSettings: ThreadNotificationSettings(
                    flags: ThreadNotificationSettings.allMessagesFlag, isMuted: true
                )
            )
            incoming = Message(
                id: MessageID(rawValue: 11), channelID: threadID, author: sender,
                content: "reply", guildID: guildID
            )
        }
        let model = makeModel(latest: 10, acknowledged: 10, settings: settings)
        model.merge(channels: [Channel(id: dmID, guildID: nil, name: "DM", kind: .directMessage)])
        model.updateCurrentUserRoles([roleID], guildID: guildID)
        if let thread { model.merge(thread: thread) }

        #expect(model.receive(incoming, currentUserID: currentUser.id).shouldNotify == alerts)
        #expect(model.mentions(channelID: incoming.channelID) == badges)
    }

    @Test func `idle messages observe only their channel and preserve unread eligibility`() async {
        let model = makeModel(latest: 12, acknowledged: 10)
        let otherID = ChannelID(rawValue: 201)
        model.merge(channels: [Channel(id: otherID, guildID: guildID, name: "other")])
        let changes = AsyncStream<String>.makeStream()
        withObservationTracking {
            _ = model[channelID]
        } onChange: { changes.continuation.yield("current") }
        withObservationTracking {
            _ = model[otherID]
        } onChange: { changes.continuation.yield("other") }
        withObservationTracking {
            _ = model[unread: channelID]
            _ = model.unread(channelID: channelID)
        } onChange: { changes.continuation.yield("eligibility") }

        let disposition = model.receive(message(id: 13), currentUserID: currentUser.id)
        changes.continuation.finish()
        var invalidations: [String] = []
        for await change in changes.stream { invalidations.append(change) }
        #expect(invalidations == ["current"])
        #expect(disposition.accepted)
        #expect(!disposition.requiresUnreadPresentationRefresh)
        #expect(model[channelID]?.latestKnownMessageID == MessageID(rawValue: 13))
        #expect(model.unreadMessageCount(channelID: channelID) == 2)

        let mention = model.receive(message(id: 14, mentionedUsers: [currentUser]), currentUserID: currentUser.id)
        #expect(mention.requiresUnreadPresentationRefresh)
        #expect(model.mentions(channelID: channelID) == 1)

        let resets = AsyncStream<Void>.makeStream()
        withObservationTracking {
            _ = model[channelID]
        } onChange: { resets.continuation.yield() }
        model.reset(accountID: nil)
        resets.continuation.finish()
        var resetCount = 0
        for await _ in resets.stream { resetCount += 1 }
        #expect(resetCount == 1)
        #expect(model[channelID] == nil)
    }

    @Test func `idle messages refresh unread presentation when a timed mute expires`() {
        let expiration = Date.now.addingTimeInterval(60)
        let settings = GuildNotificationSettings(
            guildID: guildID,
            isMuted: true,
            muteConfiguration: DiscordMuteConfiguration(endTime: expiration)
        )
        let model = makeModel(latest: 12, acknowledged: 10, settings: settings)
        let before = model.receive(message(id: 13), currentUserID: currentUser.id, now: expiration.addingTimeInterval(-1))
        #expect(!before.requiresUnreadPresentationRefresh)
        let expired = model.receive(message(id: 14), currentUserID: currentUser.id, now: expiration)
        #expect(expired.requiresUnreadPresentationRefresh)
        let after = model.receive(message(id: 15), currentUserID: currentUser.id, now: expiration.addingTimeInterval(1))
        #expect(!after.requiresUnreadPresentationRefresh)
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
                ),
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
@Test func `thread membership updates both Dock refresh paths`() async {
    let guildID = GuildID(rawValue: 100)
    let parentID = ChannelID(rawValue: 200)
    let threadID = ChannelID(rawValue: 260)
    var guild = Guild(id: guildID, name: "Guild", defaultMessageNotifications: .allMessages)
    guild.isOwnedByCurrentUser = true
    let thread = MessageThreadSummary(
        id: threadID, guildID: guildID, parentID: parentID,
        name: "Joined post", lastMessageID: MessageID(rawValue: 290)
    )
    let snapshot = BootstrapSnapshot(
        currentUser: User(id: UserID(rawValue: 1), username: "current", displayName: "Current"),
        guilds: [guild],
        channels: [Channel(id: parentID, guildID: guildID, name: "Forum", kind: .forum)],
        activeJoinedThreads: [thread],
        members: [],
        readStates: [ChannelReadState(channelID: threadID, lastAcknowledgedMessageID: MessageID(rawValue: 280))]
    )
    let provider = MockChatProvider(snapshot: snapshot, messages: [])
    let service = RecordingNotificationService()
    let preferences = NotificationPreferences(defaults: InMemoryPreferences())
    preferences.dockBadgeStyle = .unreadConversations
    let model = AppModel(
        launchMode: .offlineTesting, provider: provider,
        notificationService: service, notificationPreferences: preferences
    )
    await model.start()
    #expect(service.badgeCounts.last == 1)
    #expect(model.readState.guildUnread(guildID))
    model.consumeImmediately(.activeJoinedThreadsChanged([]))
    #expect(service.badgeCounts.last == 0)
    #expect(!model.readState.guildUnread(guildID))
    #expect(model.readState.entries[threadID]?.isUnread == true)
    model.refreshDockBadge()
    #expect(service.badgeCounts.last == 0)
    model.consumeImmediately(.activeJoinedThreadsChanged([thread]))
    #expect(service.badgeCounts.last == 1)
    model.refreshDockBadge()
    #expect(service.badgeCounts.last == 1)

    await provider.disconnect()
    model.eventTask?.cancel()
    await model.eventTask?.value
    model.eventTask = nil
    await model.drainAccountChildTasks()
}

@MainActor
@Test(arguments: [false, true])
func `bulk Inbox acknowledgement preserves notifications beyond its captured boundary`(receivesNewerMessage: Bool) async throws {
    let provider = MockChatProvider()
    let service = RecordingNotificationService()
    let model = AppModel(launchMode: .offlineTesting, provider: provider, notificationService: service,
        notificationPreferences: NotificationPreferences(defaults: InMemoryPreferences()))
    await model.start()
    let channelID = ChannelID(rawValue: 211)
    let guildID = GuildID(rawValue: 100)
    let boundary = MessageID(rawValue: UInt64.max - 20)
    let sender = User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender")
    let user = try #require(model.currentUser)
    model.consumeImmediately(.messageCreated(Message(id: boundary, channelID: channelID,
        author: sender, content: "Captured mention", guildID: guildID, mentionedUsers: [user])))
    model.inbox.isPresented = true
    model.inbox.groups = [InboxUnreadGroup(channelID: channelID, guildID: guildID,
        title: "Captured", subtitle: nil, oldestReadMessageID: MessageID(rawValue: 2100),
        newestUnreadMessageID: boundary, mentionCount: 1, isLoaded: true)]
    model.markAllInboxRead()
    if receivesNewerMessage {
        model.consumeImmediately(.messageCreated(Message(id: MessageID(rawValue: boundary.rawValue + 1), channelID: channelID,
            author: sender, content: "Newer mention", guildID: guildID, mentionedUsers: [user])))
    }
    await model.inbox.bulkTask?.value
    for task in Array(model.accountChildTasks.values) { await task.value }
    #expect(model.readState.entries[channelID]?.isUnread == receivesNewerMessage)
    #expect(service.cancelledChannelIDs.contains(channelID) == !receivesNewerMessage)
    #expect(await provider.bulkAcknowledgementRequests.last?.first?.messageID == boundary)
}

@MainActor
@Test func `hidden notification style hides the sender and deep links keep full snowflakes`() {
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
            message: message, channel: channel, guild: nil, style: .hidden
        ).title == "SakuraCord"
    )

    let largeLink = NotificationDeepLink(
        accountID: "account",
        guildID: GuildID(rawValue: UInt64.max - 2),
        channelID: ChannelID(rawValue: UInt64.max - 1),
        messageID: MessageID(rawValue: UInt64.max)
    )
    #expect(NotificationDeepLink(userInfo: largeLink.userInfo) == largeLink)
}

@MainActor
@Test(arguments: [GuildWorkspacePage.guide, .channelsAndRoles])
func `guild pages do not acknowledge the hidden selected conversation`(page: GuildWorkspacePage) async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    let guildID = GuildID(rawValue: 100)
    model.selectedChannelID = channelID
    await model.channelLoadTask?.value
    let guildIndex = try #require(model.snapshot?.guilds.firstIndex { $0.id == guildID })
    let resourceIndex = try #require(model.snapshot?.channels.firstIndex { $0.id == ChannelID(rawValue: 200) })
    model.snapshot?.guilds[guildIndex].features = ["COMMUNITY", "GUILD_ONBOARDING", "GUILD_SERVER_GUIDE"]
    model.serverRailGuildsByID[guildID]?.features = ["COMMUNITY", "GUILD_ONBOARDING", "GUILD_SERVER_GUIDE"]
    model.snapshot?.channels[resourceIndex].flags = 128
    var member = Member(user: try #require(model.currentUser), roleName: "", isOnline: true)
    member.flags = 98
    model.onboarding.members[guildID] = member
    model.featuresSettings.channelManagement = true
    model.reportMainWindowActive(true)
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
    await model.acknowledgementTasks[channelID]?.value
    await model.acknowledgementProcessorTask?.value
    let previousRequests = await provider.acknowledgementRequests.count
    let acknowledged = model.readState.entries[channelID]?.lastAcknowledgedMessageID

    if page == .guide { model.openGuildGuide(in: guildID) }
    else { model.openChannelsAndRoles(in: guildID) }
    #expect(model.guildWorkspacePage == page)
    #expect(model.readState.presentations[channelID]?.isPresented == false)
    let incoming = Message(id: MessageID(rawValue: UInt64.max - 5), channelID: channelID,
        author: User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender"),
        content: "Arrived behind the guild page", guildID: guildID)
    model.consumeImmediately(.messageCreated(incoming))
    // A late load, old viewport callback, reconnect, or window activation must
    // not restore the presentation of a conversation hidden by a guild page.
    model.reportConversationHistoryLoaded(channelID: channelID)
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
    model.consumeReadStateSnapshot([ChannelReadState(channelID: channelID,
        lastAcknowledgedMessageID: acknowledged)])
    model.reportMainWindowActive(false)
    model.reportMainWindowActive(true)
    await model.acknowledgementTasks[channelID]?.value
    await model.acknowledgementProcessorTask?.value
    #expect(await provider.acknowledgementRequests.count == previousRequests)
    #expect(model.readState.entries[channelID]?.isUnread == true)
    #expect(model.readState.presentations[channelID]?.isPresented == false)

    model.channelSidebarSelection = channelID
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
    await model.acknowledgementTasks[channelID]?.value
    await model.acknowledgementProcessorTask?.value
    #expect(await provider.acknowledgementRequests.last?.messageID == incoming.id)
    #expect(await provider.acknowledgementRequests.count == previousRequests + 1)
    if page == .channelsAndRoles {
        model.openChannelsAndRoles(in: guildID)
        model.openCustomizationPreview(try #require(model.selectedChannel))
        model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
        model.closeCustomizationPreview()
        #expect(model.readState.presentations[channelID]?.isPresented == false)
        #expect(model.readState.presentations[channelID]?.initialPositionEstablished == false)
    }
}

@MainActor
@Test func `automated benchmark emits no acknowledgement mutations`() async {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        runsChatPerformanceBenchmarkOverride: true
    )
    let channelID = ChannelID(rawValue: 99_920)
    model.enqueueAcknowledgement(
        channelID: channelID,
        mutation: AppModel.ReadStateMutation(
            messageID: MessageID(rawValue: 99_921),
            flags: 0,
            lastViewed: 0
        )
    )
    await Task.yield()

    #expect(await provider.acknowledgementRequests.isEmpty)
    #expect(model.queuedAcknowledgements.isEmpty)
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
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)

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
    #expect(await until {
        model.readState.entries[channelID]?.latestKnownMessageID == newest.id
    })
    // Establish the viewport only after the synthetic arrivals have reached
    // read state. This tests the intended newest-boundary coalescing without
    // racing the test's 10 ms debounce against event-stream scheduling under
    // a parallel suite.
    model.reportTimelineInitialPosition(
        channelID: channelID,
        hasReachedReadBoundary: true
    )
    #expect(await eventually {
        await provider.acknowledgementRequests.count == 1
            && model.readState.acknowledgementToken == "mock-ack-token"
    })

    let requests = await provider.acknowledgementRequests
    #expect(requests.count == 1)
    #expect(requests.first?.channelID == channelID)
    #expect(requests.first?.messageID == newest.id)
    #expect(model.readState.acknowledgementToken == "mock-ack-token")

    let nextChannelID = ChannelID(rawValue: 211)
    model.selectedChannelID = nextChannelID
    #expect(await until {
        !model.isLoadingMessages && model.selectedChannelID == nextChannelID
    })
    model.reportConversationHistoryLoaded(channelID: nextChannelID)
    model.reportTimelineInitialPosition(
        channelID: nextChannelID,
        hasReachedReadBoundary: true
    )
    #expect(await eventually { await provider.acknowledgementRequests.count == 2 })
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
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    let previousAcknowledgement = model.readState.entries[channelID]?.lastAcknowledgedMessageID
    model.reportMainWindowActive(true)
    model.reportTimelineInitialPosition(
        channelID: channelID,
        hasReachedReadBoundary: true
    )

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

    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    #expect(request.messageID == newest.id)
    #expect(!request.manual)
}

@MainActor
@Test(arguments: [true, false])
func `incoming message plants a new divider only when the newest edge is not on screen`(
    isAtNewest: Bool
) async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 212)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    model.reportTimelineInitialPosition(
        channelID: channelID,
        hasReachedReadBoundary: isAtNewest
    )
    #expect(model.unreadDividerMessageID(channelID: channelID) == nil)

    let incoming = Message(
        id: MessageID(rawValue: UInt64.max - 4),
        channelID: channelID,
        author: User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender"),
        content: "arrived",
        guildID: GuildID(rawValue: 100)
    )
    model.consumeImmediately(.messageCreated(incoming))

    if isAtNewest {
        #expect(model.unreadDividerMessageID(channelID: channelID) == nil)
        #expect(model.readState.entries[channelID]?.isUnread == false)
    } else {
        #expect(model.unreadDividerMessageID(channelID: channelID) == incoming.id)
        #expect(model.readState.entries[channelID]?.isUnread == true)
    }
}

@MainActor
@Test func `batched gateway message in an inactive window still plants a new divider`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = ChannelID(rawValue: 212)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(false)
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)

    let incoming = Message(
        id: MessageID(rawValue: UInt64.max - 3),
        channelID: channelID,
        author: User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender"),
        content: "arrived while away",
        guildID: GuildID(rawValue: 100)
    )
    await provider.emit(.messageCreated(incoming))

    #expect(await eventually { model.unreadDividerMessageID(channelID: channelID) == incoming.id })
}

@MainActor
@Test func `opening acknowledgement survives a gateway reconnect before transport`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(30))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    model.reportTimelineInitialPosition(
        channelID: channelID,
        hasReachedReadBoundary: true
    )

    await provider.emit(.connectionChanged(.connecting))
    await provider.emit(.connectionChanged(.ready))

    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    #expect(request.messageID == model.readState.entries[channelID]?.latestKnownMessageID)
}

/// The acknowledged boundary predates the loaded page and older history
/// remains, so the backlog's first unread row is not loaded ("N+").
@MainActor
private func makeLowerBoundBacklog(in model: AppModel, channelID: ChannelID) {
    model.hasMoreMessages = true
    model.unreadDividerMessageIDs[channelID] = nil
    #expect(model.readState.applyRemote(ChannelReadState(
        channelID: channelID,
        lastAcknowledgedMessageID: MessageID(rawValue: 1),
        isManual: true
    )))
    #expect(model.hasUnresolvedUnreadBoundary(channelID: channelID))
}

@MainActor
@Test func `opening a backlog at its newest message waits for a further scroll toward it`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    makeLowerBoundBacklog(in: model, channelID: channelID)
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
    // Repeated geometry at the newest edge is not a read on its own.
    model.reportTimelinePosition(channelID: channelID, hasReachedReadBoundary: true)
    #expect(model.readState.entries[channelID]?.isUnread == true)
    #expect(model.acknowledgementTasks[channelID] == nil)

    // A wheel clamped at the bottom edge reports no new position, so the
    // gesture itself must acknowledge.
    model.reportTimelineScrollTowardNewest(channelID: channelID)
    #expect(await until { !model.isChannelUnread(channelID) })
    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    #expect(request.messageID == model.readState.entries[channelID]?.latestKnownMessageID)
    #expect(!request.manual)
}

@MainActor
@Test func `a never acknowledged conversation opened at its newest message acknowledges`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    model.hasMoreMessages = true
    model.unreadDividerMessageIDs[channelID] = nil
    // READY can carry a non-snowflake boundary, which decodes as none.
    #expect(model.readState.applyRemote(ChannelReadState(
        channelID: channelID,
        lastAcknowledgedMessageID: nil,
        isManual: true
    )))
    #expect(model.readState.entries[channelID]?.isUnread == true)
    #expect(!model.hasUnresolvedUnreadBoundary(channelID: channelID))

    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
    #expect(await until { !model.isChannelUnread(channelID) })
    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.messageID == model.readState.entries[channelID]?.latestKnownMessageID)
}

@MainActor
@Test func `read state completion releases a held backlog without another geometry callback`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    let heldThrough = try #require(model.readState.entries[channelID]?.latestKnownMessageID)
    makeLowerBoundBacklog(in: model, channelID: channelID)
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
    let newest = Message(
        id: MessageID(rawValue: UInt64.max - 2),
        channelID: channelID,
        author: User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender"),
        content: "new",
        guildID: GuildID(rawValue: 100)
    )
    model.consumeImmediately(.messageCreated(newest))
    #expect(model.readState.holdsAutomaticAcknowledgement(channelID))
    #expect(model.acknowledgementTasks[channelID] == nil)

    model.consumeImmediately(.readStateChanged(ChannelReadState(
        channelID: channelID,
        lastAcknowledgedMessageID: heldThrough
    )))

    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    #expect(request.messageID == newest.id)
    #expect(!request.manual)
}

@MainActor
@Test func `opening above the newest message acknowledges once the reader reaches it`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    makeLowerBoundBacklog(in: model, channelID: channelID)
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: false)
    #expect(model.readState.entries[channelID]?.isUnread == true)
    #expect(model.acknowledgementTasks[channelID] == nil)

    model.reportTimelinePosition(channelID: channelID, hasReachedReadBoundary: true)
    #expect(await until { !model.isChannelUnread(channelID) })
    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    #expect(request.messageID == model.readState.entries[channelID]?.latestKnownMessageID)
}

@MainActor
@Test func `rapid channel switching preserves both qualified acknowledgements`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(30))
    )
    await model.start()
    model.reportMainWindowActive(true)

    let firstChannelID = ChannelID(rawValue: 210)
    model.selectedChannelID = firstChannelID
    #expect(await until {
        !model.isLoadingMessages && model.selectedChannelID == firstChannelID
    })
    model.reportTimelineInitialPosition(
        channelID: firstChannelID,
        hasReachedReadBoundary: true
    )

    let secondChannelID = ChannelID(rawValue: 211)
    model.selectedChannelID = secondChannelID
    #expect(await until {
        !model.isLoadingMessages && model.selectedChannelID == secondChannelID
    })
    model.reportTimelineInitialPosition(
        channelID: secondChannelID,
        hasReachedReadBoundary: true
    )

    #expect(await eventually { await provider.acknowledgementRequests.count == 2 })
    let requests = await provider.acknowledgementRequests
    #expect(requests.count == 2)
    #expect(Set(requests.map(\.channelID)) == Set([firstChannelID, secondChannelID]))
    for request in requests {
        #expect(request.messageID == model.readState.entries[request.channelID]?.latestKnownMessageID)
    }
}

@MainActor
@Test func `local send releases a held backlog like scrolling to the newest message`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    makeLowerBoundBacklog(in: model, channelID: channelID)
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
    #expect(model.readState.holdsAutomaticAcknowledgement(channelID))

    #expect(model.advanceTimelineForLocalSend(channelID: channelID))
    #expect(!model.readState.holdsAutomaticAcknowledgement(channelID))
}

@MainActor
@Test func `local send scrolls once and confirmation leaves unseen messages unread`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(10))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    // Before the initial position exists a backlog hold can still appear, so
    // that send takes the confirmation path instead.
    #expect(!model.advanceTimelineForLocalSend(channelID: channelID))
    #expect(model.conversationNewestRequest == nil)

    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: false)
    model.reportTimelinePosition(channelID: channelID, hasReachedReadBoundary: false)
    let divider = try #require(model.unreadDividerMessageID(channelID: channelID))
    #expect(model.conversationNewestRequest == nil)

    #expect(model.advanceTimelineForLocalSend(channelID: channelID))
    let request = try #require(model.conversationNewestRequest)
    #expect(request.channelID == channelID)
    model.completeConversationNewestRequest(requestID: request.requestID)

    // The reader scrolled away while delivery was pending.
    model.completeConfirmedSend(channelID: channelID, advancedLocally: true)
    #expect(model.conversationNewestRequest == nil)
    #expect(model.isChannelUnread(channelID))
    #expect(model.unreadDividerMessageID(channelID: channelID) == divider)

    // An older page keeps the local row and loads nothing before delivery.
    model.hasMoreLaterMessages = true
    #expect(!model.advanceTimelineForLocalSend(channelID: channelID))
    model.completeConfirmedSend(channelID: channelID, advancedLocally: true)
    #expect(model.conversationNewestRequest == nil)
    #expect(!model.isLoadingMessages)
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
    let currentUser = try #require(model.snapshot?.currentUser)
    let selectedIndex = try #require(model.messages.indices.dropFirst().first)
    model.messages[selectedIndex].mentionedUsers = [currentUser]
    let selectedMessage = model.messages[selectedIndex]
    let currentUserID = currentUser.id
    let expectedMentions = model.readState.mentionCountForManualUnread(
        channelID: channelID,
        messages: model.messages,
        startingAt: selectedMessage.id,
        currentUserID: currentUserID
    )

    let boundary = model.readState.entries[channelID]?.lastAcknowledgedMessageID

    model.markMessageAndFollowingUnread(selectedMessage)
    // As in Discord, read state changes only on the manual Gateway event.
    #expect(model.readState.entries[channelID]?.lastAcknowledgedMessageID == boundary)
    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    // Discord's boundary is the previous loaded message, not the selected
    // ID less one, which its millisecond comparison would treat as read.
    #expect(request.messageID == model.messages[model.messages.index(before: selectedIndex)].id)
    #expect(request.manual)
    #expect(request.mentionCount == expectedMentions)
    #expect((request.mentionCount ?? 0) > 0)
    #expect(request.token == nil && request.flags == nil && request.lastViewed == nil)
    #expect(await eventually {
        model.readState.entries[channelID]?.lastAcknowledgedMessageID == request.messageID
    })
    #expect(model.channelMentionCount(channelID) == expectedMentions)
    #expect(model.readState.holdsAutomaticAcknowledgement(channelID))
    #expect(model.unreadDividerMessageID(channelID: channelID) == selectedMessage.id)
    // As in Discord, only a selection change or a read ends the hold.
    model.reportTimelineScrollTowardNewest(channelID: channelID)
    #expect(model.readState.holdsAutomaticAcknowledgement(channelID))
}

/// Discord's manual MESSAGE_ACK cancels a read not yet sent, which would
/// otherwise undo Mark Unread once it reached Discord.
@MainActor
@Test func `a manual acknowledgement cancels an unsent read`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .seconds(60))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    let newest = try #require(model.readState.entries[channelID]?.latestKnownMessageID)
    model.scheduleAcknowledgement(channelID: channelID, messageID: newest)
    let unsent = try #require(model.acknowledgementTasks[channelID])

    let boundary = MessageID(rawValue: 1)
    model.consumeImmediately(.readStateChanged(ChannelReadState(
        channelID: channelID, lastAcknowledgedMessageID: boundary, mentionCount: 1, isManual: true
    )))
    await unsent.value

    #expect(model.readState.entries[channelID]?.lastAcknowledgedMessageID == boundary)
    #expect(model.channelMentionCount(channelID) == 1)
    #expect(model.readState.holdsAutomaticAcknowledgement(channelID))
    #expect(await provider.acknowledgementRequests.isEmpty)
}

/// Discord sends an explicit read at once (module 334738), so a manual echo
/// arriving later cannot cancel it, even while the account queue holds it.
@MainActor
@Test func `a manual echo keeps a queued explicit read`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    let newest = try #require(model.readState.entries[channelID]?.latestKnownMessageID)
    model.enqueueAcknowledgement(
        channelID: channelID, mutation: model.readStateMutation(channelID: channelID, messageID: newest)
    )

    model.consumeImmediately(.readStateChanged(ChannelReadState(
        channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 1), isManual: true
    )))
    await model.acknowledgementProcessorTask?.value

    #expect(await provider.acknowledgementRequests.map(\.messageID) == [newest])
}

@MainActor
@Observable
private final class RecordingNotificationService: NativeNotificationService {
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
    ) async {}
    func cancel(accountID: String, channelID: ChannelID) async {
        cancelledChannelIDs.append(channelID)
    }
    func setDockBadge(_ count: Int, enabled: Bool) {
        badgeCounts.append(enabled ? count : 0)
    }
}
