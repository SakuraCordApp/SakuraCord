@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
struct GuildTimeoutTests {
    @Test(arguments: [false, true])
    func replacementReadyClearsOmittedTimeoutWithoutRestoringCachedEvidence(storedSelfMember: Bool) async throws {
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
        await model.start()
        await model.memberLoadTask?.value
        let guildID = try #require(model.selectedGuildID)
        let user = try #require(model.currentUser)
        var member = Member(user: user, roleName: "Member", isOnline: false, flags: 9)
        member.isPending = true
        member.joinedAt = Date(timeIntervalSince1970: 1_000)
        member.communicationDisabledUntil = .now.addingTimeInterval(300)
        model.membersByGuildID[guildID, default: [:]][user.id] = member
        model.members = [member]
        if storedSelfMember {
            model.receiveOnboardingMember(member, guildID: guildID)
        } else {
            model.onboarding.members[guildID] = nil
        }
        let previousTimer = model.onboarding.timeoutExpiryTasks[guildID]
        var replacement = try #require(model.snapshot)
        replacement.currentMembersByGuildID = [:]

        model.consumeSnapshotChanged(replacement)

        #expect(model.onboardingMember(in: guildID)?.communicationDisabledUntil == nil)
        #expect(model.onboardingMember(in: guildID)?.flags == member.flags)
        #expect(model.onboardingMember(in: guildID)?.isPending == member.isPending)
        #expect(model.onboardingMember(in: guildID)?.joinedAt == member.joinedAt)
        #expect(model.onboarding.timeoutExpiryTasks[guildID] == nil)
        #expect(previousTimer?.isCancelled != false)
        // The retained presentation cache still contains its old record.
        #expect(model.membersByGuildID[guildID]?[user.id]?.communicationDisabledUntil != nil)
    }

    @Test func timeoutMasksOverwritesAndExpiresWithoutGrantingChannelAccess() throws {
        let guild = Guild(id: .init(rawValue: 1), name: "Guild")
        let channel = Channel(id: .init(rawValue: 2), guildID: guild.id, name: "chat", permissionOverwrites: [
            .init(id: "3", type: 1, allow: DiscordPermissionBits.sendMessages | DiscordPermissionBits.addReactions, deny: 0),
        ])
        let now = Date(timeIntervalSince1970: 1_000)
        let read = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
        let normal = read | DiscordPermissionBits.sendMessages | DiscordPermissionBits.connect | DiscordPermissionBits.sendMessagesInThreads
        func permissions(base: UInt64, until: Date, at date: Date) -> UInt64? {
            ConversationPermissionResolver.effectivePermissions(
                guild: guild, channel: channel, resolvedBasePermissions: base,
                overwritePrincipals: .init(guildID: guild.id, currentUserID: .init(rawValue: 3), roleIDs: []),
                hasCurrentRoleIdentity: true, communicationDisabledUntil: until, now: date
            )
        }
        let until = now.addingTimeInterval(60)
        #expect(permissions(base: normal, until: until, at: now) == read)
        #expect(permissions(base: normal, until: until, at: until) == normal | DiscordPermissionBits.addReactions)
        #expect(permissions(base: 0, until: until, at: now) == 0)
        #expect(permissions(base: DiscordPermissionBits.administrator, until: until, at: now) == .max)
    }

    @Test func liveMembershipChangesGateCommunicationAndPreserveDrafts() async throws {
        let provider = MockChatProvider()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        await model.start()
        await model.memberLoadTask?.value
        let channel = try #require(model.selectedChannel)
        let guildID = try #require(channel.guildID)
        let user = try #require(model.currentUser)
        let permissions = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
            | DiscordPermissionBits.sendMessages | DiscordPermissionBits.addReactions | DiscordPermissionBits.connect
        model.serverRailGuildsByID[guildID]?.isOwnedByCurrentUser = false
        model.serverRailGuildsByID[guildID]?.currentUserPermissions = permissions
        var member = Member(user: user, roleName: "Member", isOnline: false, flags: 2)
        model.receiveOnboardingMember(member, guildID: guildID)
        let message = try #require(model.messages.first)
        let editableMessage = Message(id: .init(rawValue: 9_001), channelID: channel.id,
                                      author: user, content: "Original edit", guildID: guildID)
        let pollMessage = Message(id: .init(rawValue: 9_002), channelID: channel.id,
                                  author: user, content: "", guildID: guildID,
                                  poll: MessagePoll(question: "Choose", answers: [.init(id: 1, text: "A"), .init(id: 2, text: "B")],
                                                    expiry: .now.addingTimeInterval(600),
                                                    results: PollResults(answerCounts: [.init(id: 1, count: 1, meVoted: true)])))
        let seededMessages = model.messages + [editableMessage, pollMessage]
        await provider.setTimeoutTestMessages(seededMessages, channelID: channel.id)
        model.replaceSelectedMessages(with: seededMessages)
        model.draft = "Keep this draft"
        #expect(model.selectedConversationAccess.canSend)
        // The child task has not started: a live timeout must stop this
        // queued replacement and restore the last confirmed selection.
        #expect(model.vote(on: pollMessage, answerIDs: [2]))
        member.communicationDisabledUntil = .now.addingTimeInterval(300)
        model.consumeMembersChanged(guildID: guildID, members: [member], groups: [])
        #expect(!model.selectedConversationAccess.canSend)
        #expect(!model.allowSlowmodeSubmission(in: channel.id))
        #expect(!model.canCreateReactions(on: message))
        #expect(!model.canUpdateReactions(on: message))
        #expect(!model.vote(on: pollMessage, answerIDs: [2]))
        let queuedVotes = Array(model.accountChildTasks.values)
        for task in queuedVotes { await task.value }
        #expect(model.retainedMessage(channelID: channel.id, messageID: pollMessage.id)?.poll?.selectedAnswerIDs == [1])
        #expect(await provider.messagesByChannel[channel.id]?.first(where: { $0.id == pollMessage.id })?.poll?.selectedAnswerIDs == [1])
        #expect(model.vote(on: pollMessage, answerIDs: []))
        let removals = Array(model.accountChildTasks.values)
        for task in removals { await task.value }
        #expect(await provider.messagesByChannel[channel.id]?.first(where: { $0.id == pollMessage.id })?.poll?.selectedAnswerIDs == [])
        await model.toggleReaction("👍", on: message)
        await model.edit(editableMessage, content: "Blocked edit")
        #expect(await provider.messagesByChannel[channel.id]?.first(where: { $0.id == editableMessage.id })?.content == editableMessage.content)
        #expect(model.draft == "Keep this draft")
        let timer = try #require(model.onboarding.timeoutExpiryTasks[guildID])
        member.communicationDisabledUntil = nil
        model.consumeMembersChanged(guildID: guildID, members: [member], groups: [])
        #expect(timer.isCancelled)
        #expect(model.onboarding.timeoutExpiryTasks[guildID] == nil)
        #expect(model.selectedConversationAccess.canSend)
        #expect(model.canUpdateReactions(on: message))
        #expect(model.vote(on: pollMessage, answerIDs: [2]))
        let resumedVotes = Array(model.accountChildTasks.values)
        for task in resumedVotes { await task.value }
        #expect(await provider.messagesByChannel[channel.id]?.first(where: { $0.id == pollMessage.id })?.poll?.selectedAnswerIDs == [2])
        await model.edit(editableMessage, content: "Allowed edit")
        #expect(await provider.messagesByChannel[channel.id]?.first(where: { $0.id == editableMessage.id })?.content == "Allowed edit")
        #expect(model.draft == "Keep this draft")
    }
}

private extension MockChatProvider {
    func setTimeoutTestMessages(_ messages: [Message], channelID: ChannelID) {
        messagesByChannel[channelID] = messages
    }

}
