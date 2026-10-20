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
        #expect(!model.guildUnread(guildID))
    }

    @Test func `own messages do not clear earlier unseen messages`() {
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
        model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10),
                mentionCount: 0,
                flags: 1
            )
        )
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

    @Test func `versioned read state rejects out of order ordinary and manual events`() {
        let model = makeModel(latest: 20, acknowledged: 10, mentions: 3)
        #expect(model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 18),
                mentionCount: 1,
                version: 12
            )
        ))
        #expect(!model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 8),
                mentionCount: 4,
                isManual: true,
                version: 11
            )
        ))
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 18))
        #expect(model.mentions(channelID: channelID) == 1)

        #expect(model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 15),
                mentionCount: 2,
                isManual: true,
                version: 13
            )
        ))
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 15))
        #expect(model.mentions(channelID: channelID) == 2)

        #expect(model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 9),
                mentionCount: 5,
                version: 15
            )
        ))
        #expect(!model.applyRemote(
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 6),
                mentionCount: 6,
                isManual: true,
                version: 14
            )
        ))
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 9))
        #expect(model.readStateVersion == 15)
        model.replaceReadStates([
            ChannelReadState(channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 7), mentionCount: 0)
        ], version: 16)
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 7))
        #expect(model.unread(channelID: channelID))
    }

    @Test func `an in flight read acknowledgement cannot erase a queued Inbox undo`() {
        let model = makeModel(latest: 20, acknowledged: 10, mentions: 2)
        model.markAcknowledgementPending(channelID: channelID, messageID: MessageID(rawValue: 20))
        model.markUnread(channelID: channelID, after: MessageID(rawValue: 10), mentionCount: 0)
        #expect(!model.applyRemote(ChannelReadState(channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 20), mentionCount: 0, version: 5)))
        model.completeAcknowledgement(channelID: channelID, messageID: MessageID(rawValue: 20), token: nil)
        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 10))
        #expect(model.entries[channelID]?.pendingAcknowledgementID == MessageID(rawValue: 10))
        #expect(model.applyRemote(ChannelReadState(channelID: channelID, lastAcknowledgedMessageID: MessageID(rawValue: 10), mentionCount: 0, version: 6)))
        #expect(model.entries[channelID]?.pendingAcknowledgementID == nil)
        #expect(model.unread(channelID: channelID))
    }

    @Test func `stale snapshot preserves an optimistic mark read and acknowledgement token`() {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 1)
        model.completeAcknowledgement(
            channelID: channelID,
            messageID: MessageID(rawValue: 10),
            token: "latest-token"
        )
        model.markAcknowledgementPending(
            channelID: channelID,
            messageID: MessageID(rawValue: 12)
        )

        model.replaceReadStates([
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10),
                mentionCount: 1,
                version: 7
            )
        ])

        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: 12))
        #expect(model.entries[channelID]?.pendingAcknowledgementID == MessageID(rawValue: 12))
        #expect(model.mentions(channelID: channelID) == 0)
        #expect(!model.unread(channelID: channelID))
        #expect(model.acknowledgementToken == "latest-token")
    }

    @Test(arguments: [false, true], [false, true])
    func `workspace replacement preserves pending reads for omitted threads`(
        includesReadState: Bool, acknowledgementSucceeds: Bool
    ) {
        let model = makeModel(latest: 12, acknowledged: 10)
        let threadID = ChannelID(rawValue: 300)
        let remote = ChannelReadState(
            channelID: threadID, lastAcknowledgedMessageID: MessageID(rawValue: 20),
            mentionCount: 1, version: 7
        )
        model.merge(thread: MessageThreadSummary(
            id: threadID, guildID: guildID, parentID: channelID, name: "Archived",
            lastMessageID: MessageID(rawValue: 30), isArchived: true
        ))
        _ = model.applyRemote(remote)
        model.markAcknowledgementPending(channelID: threadID, messageID: MessageID(rawValue: 30))

        model.replaceSnapshot(BootstrapSnapshot(
            currentUser: currentUser, guilds: [Guild(id: guildID, name: "Guild")],
            channels: [Channel(id: channelID, guildID: guildID, name: "Parent")],
            members: [], readStates: includesReadState ? [remote] : []
        ))

        #expect(model.entries[threadID]?.guildID == guildID)
        #expect(model.entries[threadID]?.parentID == channelID)
        #expect(model.entries[threadID]?.pendingAcknowledgementID == MessageID(rawValue: 30))
        #expect(model.entries[threadID]?.lastAcknowledgedMessageID == MessageID(rawValue: 30))
        #expect(!model.unread(channelID: threadID))
        if acknowledgementSucceeds {
            model.completeAcknowledgement(channelID: threadID, messageID: MessageID(rawValue: 30), token: nil)
        } else {
            model.failAcknowledgement(channelID: threadID, messageID: MessageID(rawValue: 30))
        }
        #expect(model.entries[threadID]?.pendingAcknowledgementID == nil)
        #expect(model.entries[threadID]?.lastAcknowledgedMessageID == MessageID(rawValue: acknowledgementSucceeds ? 30 : 20))
        #expect(model.mentions(channelID: threadID) == (acknowledgementSucceeds ? 0 : 1))
        #expect(model.unread(channelID: threadID) == !acknowledgementSucceeds)
    }

    @Test(arguments: [[UInt64(13)], [14, 12]])
    func `later acknowledgement failure preserves an earlier accepted boundary`(failureOrder: [UInt64]) {
        let model = makeModel(latest: 12, acknowledged: 10, mentions: 2)
        let acceptedBoundary: UInt64 = failureOrder.count == 1 ? 12 : 13
        model.markAcknowledgementPending(
            channelID: channelID,
            messageID: MessageID(rawValue: 12)
        )
        #expect(model.receive(
            message(id: 13, mentionedUsers: [currentUser]),
            currentUserID: currentUser.id
        ).accepted)
        if acceptedBoundary == 13 {
            model.markAcknowledgementPending(channelID: channelID, messageID: MessageID(rawValue: 13))
            #expect(model.receive(
                message(id: 14, mentionedUsers: [currentUser]),
                currentUserID: currentUser.id
            ).accepted)
        }
        model.markAcknowledgementPending(
            channelID: channelID,
            messageID: MessageID(rawValue: acceptedBoundary + 1)
        )
        #expect(model.receive(
            message(id: acceptedBoundary + 2, mentionedUsers: [currentUser]),
            currentUserID: currentUser.id
        ).accepted)

        model.completeAcknowledgement(
            channelID: channelID,
            messageID: MessageID(rawValue: acceptedBoundary),
            token: "accepted"
        )
        for target in failureOrder {
            model.failAcknowledgement(channelID: channelID, messageID: MessageID(rawValue: target))
        }

        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: acceptedBoundary))
        #expect(model.entries[channelID]?.pendingAcknowledgementID == nil)
        #expect(model.mentions(channelID: channelID) == 2)
        #expect(model.unreadMessageCount(channelID: channelID) == 2)
        #expect(model.unread(channelID: channelID))
        #expect(model.acknowledgementToken == "accepted")
    }

    @Test(arguments: [false, true], [[0, 1, 2], [2, 1, 0], [1, 0, 2]])
    func `overlapping failures restore every unread contribution exactly once`(manualUnread: Bool, failureOrder: [Int]) {
        let model = makeModel(latest: 12, acknowledged: manualUnread ? 12 : 10, mentions: manualUnread ? 0 : 2)
        let firstTarget = MessageID(rawValue: manualUnread ? 5 : 12)
        if manualUnread {
            model.markUnread(channelID: channelID, after: firstTarget, mentionCount: 3)
        } else {
            model.markAcknowledgementPending(channelID: channelID, messageID: firstTarget)
        }
        #expect(model.receive(
            message(id: 13, mentionedUsers: [currentUser]),
            currentUserID: currentUser.id
        ).accepted)
        model.markAcknowledgementPending(
            channelID: channelID,
            messageID: MessageID(rawValue: 13)
        )
        #expect(model.receive(
            message(id: 14, mentionedUsers: [currentUser]),
            currentUserID: currentUser.id
        ).accepted)
        model.markAcknowledgementPending(
            channelID: channelID,
            messageID: MessageID(rawValue: 14)
        )
        #expect(model.receive(
            message(id: 15, mentionedUsers: [currentUser]),
            currentUserID: currentUser.id
        ).accepted)

        let targets = [firstTarget, MessageID(rawValue: 13), MessageID(rawValue: 14)]
        for index in failureOrder {
            model.failAcknowledgement(channelID: channelID, messageID: targets[index])
        }

        #expect(model.entries[channelID]?.lastAcknowledgedMessageID == MessageID(rawValue: manualUnread ? 12 : 10))
        #expect(model.entries[channelID]?.pendingAcknowledgementID == nil)
        #expect(model.mentions(channelID: channelID) == (manualUnread ? 3 : 5))
        #expect(model.unreadMessageCount(channelID: channelID) == (manualUnread ? 3 : 4))
        #expect(model.unread(channelID: channelID))
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
        #expect(model.bulkAcknowledgements(for: categoryID, guildID: guildID).map(\.channelID) == [forumID])

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
        #expect(model.bulkAcknowledgements(for: guildID).contains { $0.channelID == threadID })

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

    @Test func `inaccessible channels are excluded from bulk acknowledgements`() {
        let model = makeModel(latest: 11, acknowledged: 10)
        #expect(!model.bulkAcknowledgements(for: categoryID, guildID: guildID).isEmpty)

        model.applyAccessibility([channelID: false])
        #expect(model.bulkAcknowledgements(for: categoryID, guildID: guildID).isEmpty)
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
        lastAcknowledgedMessageID: acknowledged)], version: nil)
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
            manual: false,
            mentionCount: nil,
            flags: 0,
            lastViewed: 0
        )
    )
    await Task.yield()

    #expect(await provider.acknowledgementRequests.isEmpty)
    #expect(model.queuedAcknowledgements.isEmpty)
    #expect(model.acknowledgementQueueOrder.isEmpty)
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
@Test func `a coalesced acknowledgement dropped after scrolling away restores the real boundary`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        readAcknowledgementTiming: .init(debounce: .milliseconds(300))
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await eventually { !model.isLoadingMessages && model.selectedChannelID == channelID })
    model.reportMainWindowActive(true)
    model.reportTimelineInitialPosition(channelID: channelID, hasReachedReadBoundary: true)
    #expect(await eventually {
        model.acknowledgementTasks[channelID] == nil
            && model.readState.entries[channelID]?.pendingAcknowledgementID == nil
    })
    let sentBefore = await provider.acknowledgementRequests.count
    let entry = try #require(model.readState.entries[channelID])
    let currentUser = try #require(model.snapshot?.currentUser)
    let author = User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender")
    func message(_ offset: UInt64) -> Message {
        Message(
            id: MessageID(rawValue: UInt64.max - 40 + offset),
            channelID: channelID,
            author: author,
            content: "mention \(offset)",
            guildID: GuildID(rawValue: 100),
            mentionedUsers: [currentUser]
        )
    }

    // Each arrival at the newest message schedules a debounced acknowledgement;
    // the second replaces the first before either reaches Discord.
    await provider.emit(.messageCreated(message(1)))
    #expect(await eventually { model.readState.entries[channelID]?.pendingAcknowledgementID == message(1).id })
    await provider.emit(.messageCreated(message(2)))
    #expect(await eventually { model.readState.entries[channelID]?.pendingAcknowledgementID == message(2).id })
    model.reportTimelinePosition(channelID: channelID, hasReachedReadBoundary: false)
    #expect(await eventually { model.acknowledgementTasks[channelID] == nil })

    let restored = try #require(model.readState.entries[channelID])
    #expect(restored.lastAcknowledgedMessageID == entry.lastAcknowledgedMessageID)
    #expect(restored.pendingAcknowledgementID == nil)
    #expect(restored.mentionCount == entry.mentionCount + 2)
    #expect(restored.unreadMessageCount == entry.unreadMessageCount + 2)
    #expect(await provider.acknowledgementRequests.count == sentBefore)
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
@Test(arguments: [false, true])
func `read state completion releases a held backlog without another geometry callback`(
    manualUnreadFailed: Bool
) async throws {
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
    if manualUnreadFailed {
        #expect(model.readState.applyRemote(ChannelReadState(
            channelID: channelID,
            lastAcknowledgedMessageID: heldThrough
        )))
        model.readState.markUnread(channelID: channelID, after: MessageID(rawValue: 1), mentionCount: 0)
    } else {
        makeLowerBoundBacklog(in: model, channelID: channelID)
    }
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

    if manualUnreadFailed {
        model.rollbackReadAcknowledgement(
            channelID: channelID,
            mutation: model.readStateMutation(
                channelID: channelID,
                messageID: MessageID(rawValue: 1),
                manual: true,
                mentionCount: 0
            )
        )
    } else {
        model.consumeImmediately(.readStateChanged(ChannelReadState(
            channelID: channelID,
            lastAcknowledgedMessageID: heldThrough
        )))
    }

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
@Test func `mark read survives a stale snapshot before transport`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider
    )
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = channelID
    #expect(await until { !model.isLoadingMessages && model.selectedChannelID == channelID })
    let oldBoundary = model.readState.entries[channelID]?.lastAcknowledgedMessageID

    model.markConversationRead(channelID: channelID)
    // Deliver the stale snapshot in the same main-actor turn, before the
    // queued transport task can run. A debounce cannot guarantee that order
    // when the parallel suite delays event-stream consumption.
    model.consumeImmediately(.readStateSnapshot([
        ChannelReadState(
            channelID: channelID,
            lastAcknowledgedMessageID: oldBoundary,
            mentionCount: 3,
            version: 41
        )
    ]))

    #expect(model.readState.readStateVersion == 41)
    #expect(!model.isChannelUnread(channelID))
    #expect(model.channelMentionCount(channelID) == 0)
    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
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

    model.markMessageAndFollowingUnread(selectedMessage)
    #expect(await eventually { await provider.acknowledgementRequests.count == 1 })
    let request = try #require(await provider.acknowledgementRequests.first)
    #expect(request.channelID == channelID)
    #expect(request.messageID.rawValue == selectedMessage.id.rawValue - 1)
    #expect(request.manual)
    #expect(request.mentionCount == expectedMentions)
    #expect((request.mentionCount ?? 0) > 0)
    #expect(request.flags == 1)
    #expect(request.lastViewed != nil)
    #expect(
        model.readState.entries[channelID]?.lastAcknowledgedMessageID
            == request.messageID
    )
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
