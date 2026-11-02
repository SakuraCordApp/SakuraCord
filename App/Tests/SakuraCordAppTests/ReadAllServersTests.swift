import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
struct ReadAllServersTests {
    @Test func `Read All targets current server channels including mutes and voice but only active joined threads`() {
        let readState = AccountReadStateModel()
        let guildID = GuildID(rawValue: 100)
        let secondGuildID = GuildID(rawValue: 101)
        let parentID = ChannelID(rawValue: 200)
        let channels = [
            Channel(id: parentID, guildID: guildID, name: "Muted", lastMessageID: MessageID(rawValue: 400)),
            Channel(id: ChannelID(rawValue: 201), guildID: secondGuildID, name: "Voice", kind: .voice, lastMessageID: MessageID(rawValue: 400)),
            Channel(id: ChannelID(rawValue: 202), guildID: guildID, name: "Denied", lastMessageID: MessageID(rawValue: 400)),
            Channel(id: ChannelID(rawValue: 203), guildID: guildID, name: "Already read", lastMessageID: MessageID(rawValue: 300)),
            Channel(id: ChannelID(rawValue: 204), guildID: nil, name: "DM", kind: .directMessage, lastMessageID: MessageID(rawValue: 400)),
            Channel(id: ChannelID(rawValue: 205), guildID: GuildID(rawValue: 999), name: "Unavailable server", lastMessageID: MessageID(rawValue: 400)),
        ]
        readState.configure(accountID: "fixture", guilds: [], channels: channels,
                            readStates: channels.map { ChannelReadState(channelID: $0.id, lastAcknowledgedMessageID: MessageID(rawValue: 300)) },
                            notificationSettings: [GuildNotificationSettings(guildID: guildID, isMuted: true, hideMutedChannels: true)])
        readState.applyAccessibility([ChannelID(rawValue: 202): false])
        let active = MessageThreadSummary(id: ChannelID(rawValue: 210), guildID: guildID, parentID: parentID,
                                          name: "Joined", lastMessageID: MessageID(rawValue: 400))
        var archived = active
        archived.id = ChannelID(rawValue: 211)
        archived.isArchived = true
        var left = active
        left.id = ChannelID(rawValue: 212)
        var orphan = active
        orphan.id = ChannelID(rawValue: 213)
        orphan.parentID = ChannelID(rawValue: 999)
        readState.merge(thread: left)
        readState.replaceActiveJoinedThreads([active, archived, orphan])
        for thread in [active, archived, left, orphan] {
            readState.applyRemote(ChannelReadState(channelID: thread.id, lastAcknowledgedMessageID: MessageID(rawValue: 300)))
        }
        #expect(readState.hasUnreadServerConversations(in: [guildID, secondGuildID]))
        let targets = readState.allServerAcknowledgements(in: [guildID, secondGuildID])
        #expect(targets == [
            BulkReadStateAcknowledgement(channelID: parentID, messageID: MessageID(rawValue: 400)),
            BulkReadStateAcknowledgement(channelID: ChannelID(rawValue: 201), messageID: MessageID(rawValue: 400)),
            BulkReadStateAcknowledgement(channelID: active.id, messageID: MessageID(rawValue: 400)),
        ])
        for target in targets {
            readState.acknowledge(channelID: target.channelID, messageID: target.messageID)
        }
        #expect(!readState.hasUnreadServerConversations(in: [guildID, secondGuildID]))
    }

    @Test(arguments: [false, true])
    func `Read All preserves new messages and keeps rejected targets read`(fails: Bool) async {
        let (model, provider) = await fixture()
        // Explicitly disable the feature, independently of this Mac’s saved settings.
        model.featuresSettings.readAllButton = false
        model.markAllServersRead()
        #expect(await provider.bulkAcknowledgementRequests.isEmpty)
        model.featuresSettings.readAllButton = true
        #expect(model.hasUnreadServers)
        if fails { await provider.failBulkAcknowledgement() }
        model.markAllServersRead()
        let task = model.allServersReadTask
        model.markAllServersRead()
        let incoming = Message(id: MessageID(rawValue: 500), channelID: ChannelID(rawValue: 200),
                               author: User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender"),
                               content: "After confirmation", guildID: GuildID(rawValue: 100))
        model.consumeImmediately(.messageCreated(incoming))
        await task?.value
        let requests = await provider.bulkAcknowledgementRequests
        #expect(requests.count == 1)
        #expect(requests.first?.map(\.messageID) == [MessageID(rawValue: 400), MessageID(rawValue: 400)])
        #expect(model.readState.entries[ChannelID(rawValue: 200)]?.lastAcknowledgedMessageID == MessageID(rawValue: 400))
        #expect(model.readState.entries[ChannelID(rawValue: 200)]?.isUnread == true)
        // As in Discord, a rejected batch changes no read state.
        #expect(model.readState.entries[ChannelID(rawValue: 201)]?.lastAcknowledgedMessageID == MessageID(rawValue: 400))
        #expect(model.readState.entries[ChannelID(rawValue: 201)]?.isUnread == false)
        #expect(model.errorMessage == nil)
        #expect(!model.isMarkingAllServersRead)
        if !fails {
            model.consumeImmediately(.readStateChanged(ChannelReadState(channelID: incoming.channelID, lastAcknowledgedMessageID: incoming.id)))
            #expect(!model.hasUnreadServers)
            model.markAllServersRead()
            #expect(model.allServersReadTask == nil)
            #expect(await provider.bulkAcknowledgementRequests.count == 1)
        }
    }

    @Test func `account reset cancels Read All before dispatch`() async {
        let (model, provider) = await fixture()
        model.featuresSettings.readAllButton = true
        model.markAllServersRead()
        let task = model.allServersReadTask
        model.resetAcknowledgementWork()
        await task?.value
        #expect(await provider.bulkAcknowledgementRequests.isEmpty)
        #expect(model.allServersReadTask == nil)
        #expect(!model.isMarkingAllServersRead)
    }

    private func fixture() async -> (AppModel, MockChatProvider) {
        let user = User(id: UserID(rawValue: 1), username: "reader", displayName: "Reader")
        let guildID = GuildID(rawValue: 100)
        let channels = [200, 201].map { id in
            Channel(id: ChannelID(rawValue: UInt64(id)), guildID: guildID, name: "Channel \(id)", lastMessageID: MessageID(rawValue: 400))
        }
        let snapshot = BootstrapSnapshot(currentUser: user, guilds: [Guild(id: guildID, name: "Fixture")], channels: channels,
                                         members: [], readStates: channels.map {
                                             ChannelReadState(channelID: $0.id, lastAcknowledgedMessageID: MessageID(rawValue: 300))
                                         })
        let provider = MockChatProvider(snapshot: snapshot, messages: [])
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        await model.start()
        return (model, provider)
    }
}
