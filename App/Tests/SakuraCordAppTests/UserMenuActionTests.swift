@testable import DiscordProtocolTestSupport
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct UserMenuActionTests {
    @Test func `mention actions retain their source conversation and never redirect a draft`() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        await model.start()
        let channel = try #require(model.snapshot?.channels.first { $0.kind == .directMessage })
        let user = try #require(channel.recipients.first)
        model.selectedGuildID = nil
        model.selectedChannelID = channel.id
        model.draft = "Existing draft"
        let context = UserMenuContext(channelID: channel.id)
        let mention = try #require(model.userMenuActions(for: user, context: context).first { $0.id == "mention" })
        mention.perform()
        #expect(model.draft == "Existing draft <@\(user.id)> ")
        model.selectedChannelID = nil
        model.draft = "Different conversation"
        mention.perform()
        #expect(model.draft == "Different conversation")
        #expect(!model.userMenuActions(for: user, context: context).contains { $0.id == "mention" })
    }

    @Test func `stale relationship menus cannot cross accounts or replace a newer relationship`() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        await model.start()
        let user = User(id: .init(rawValue: 9991), username: "friend", displayName: "Friend")
        model.applyRelationships([Relationship(id: user.id, type: .friend, user: user)])
        let remove = try #require(model.userMenuActions(for: user, context: .init()).first { $0.id == "remove-friend" })
        model.applyRelationships([Relationship(id: user.id, type: .blocked, user: user)])
        remove.perform()
        #expect(model.friends.confirmation == nil)
        model.applyRelationships([Relationship(id: user.id, type: .friend, user: user)])
        let block = try #require(model.userMenuActions(for: user, context: .init()).first { $0.id == "block" })
        model.invalidateAccountSession()
        block.perform()
        #expect(model.friends.confirmation == nil)
    }

    @Test func `user actions respect identity eligibility and pending relationship mutations`() async throws {
        let model = AppModel(isEphemeral: true, provider: MockChatProvider())
        await model.start()
        let ownUser = try #require(model.currentUser)
        #expect(!model.userMenuActions(for: ownUser, context: .init()).contains { $0.group == .destructive || $0.group == .relationship })
        let user = User(id: .init(rawValue: 9992), username: "member", displayName: "Member")
        #expect(model.userMenuActions(for: user, context: .init(isLocalIdentity: true)).allSatisfy { $0.group == .copy })
        model.applyRelationships([Relationship(id: user.id, type: .friend, user: user)])
        model.friends.pendingUserIDs.insert(user.id)
        let actions = model.userMenuActions(for: user, context: .init())
        #expect(actions.filter { $0.group == .destructive }.allSatisfy { !$0.isEnabled })
        #expect(actions.filter { $0.group == .copy || $0.id == "profile" }.allSatisfy { $0.isEnabled })
    }
}
