import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
struct ChannelPinTests {
    @Test func `pinned channels lead the list in Discord's position order`() {
        let guildID = GuildID(rawValue: 1)
        func channel(_ id: UInt64, _ position: Int, category: UInt64?, kind: ChannelKindValue = .text) -> Channel {
            Channel(
                id: .init(rawValue: id), guildID: guildID, name: "\(id)", kind: kind,
                category: category.map { "c\($0)" }, categoryID: category.map { .init(rawValue: $0) },
                position: position, categoryPosition: Int(category ?? 0)
            )
        }
        let voice = channel(10, 0, category: 2, kind: .voice)
        let laterTie = channel(11, 3, category: 2)
        let earlierTie = channel(12, 3, category: 3)
        let first = channel(13, 1, category: nil)
        let unpinned = channel(14, 0, category: 3)
        let groups = ChannelGroup.make(from: [voice, laterTie, earlierTie, first, unpinned])

        // Voice channels follow the rest; equal positions keep override order.
        let pinned = ChannelGroup.pinning(
            [voice.id, earlierTie.id, laterTie.id, first.id, ChannelID(rawValue: 99)],
            in: groups, excluding: []
        )
        #expect(pinned.map(\.id) == [ChannelGroup.pinnedSectionID, "3"])
        #expect(pinned[0].channels.map(\.id) == [first.id, earlierTie.id, laterTie.id, voice.id])
        #expect(pinned[1].channels == [unpinned])
        #expect(ChannelGroup.pinning(pinned[0].channels.map(\.id), in: pinned, excluding: []) == pinned)

        let hidden = ChannelGroup.pinning([first.id], in: groups, excluding: [first.id])
        #expect(hidden == groups)
    }

    @Test func `rapid pin toggles save only the settled state`() async throws {
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
        await model.start()
        let guildID = try #require(model.selectedGuildID)
        let channel = try #require(model.visibleChannels.first { $0.guildID == guildID })
        func savedFlags() -> UInt64? {
            model.readState.notificationOverride(channelID: channel.id, guildID: guildID)?.flags
        }
        let original = savedFlags()

        model.toggleChannelPin(channel)
        model.toggleChannelPin(channel)
        #expect(!model.isChannelPinned(channel))
        await model.channelPinMutationTasks[channel.id]?.value
        #expect(savedFlags() == original)

        for _ in 0 ..< 3 { model.toggleChannelPin(channel) }
        #expect(model.isChannelPinned(channel))
        #expect(model.pinnedChannelIDs(in: guildID) == [channel.id])
        await model.channelPinMutationTasks[channel.id]?.value
        #expect(savedFlags() == (original ?? 0) | (1 << 11) | (1 << 12))
        #expect(model.optimisticChannelPinnedByID.isEmpty)
        #expect(model.isChannelPinned(channel))
    }
}
