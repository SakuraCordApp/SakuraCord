import Foundation
import SakuraCordModels
import Testing

private let author = User(id: UserID(rawValue: 5), username: "maya", displayName: "Maya")

private func message(
    _ content: String,
    embedTitle: String? = nil,
    pollQuestion: String? = nil
) -> Message {
    Message(
        id: MessageID(rawValue: 900), channelID: ChannelID(rawValue: 7), author: author,
        content: content,
        embeds: embedTitle.map { [MessageEmbed(title: $0)] } ?? [],
        mentionedUsers: [author],
        poll: pollQuestion.map { MessagePoll(question: $0, answers: [], expiry: nil) }
    )
}

struct ThreadNameCase: Sendable, CustomTestStringConvertible {
    var starter: Message
    var expected: String
    var testDescription: String { expected }

    init(_ content: String, embedTitle: String? = nil, pollQuestion: String? = nil, expected: String) {
        starter = message(content, embedTitle: embedTitle, pollQuestion: pollQuestion)
        self.expected = expected
    }
}

/// First-party default-name rule (web build 641004, observed 19 October 2026).
@Test(arguments: [
    ThreadNameCase("## Release planning notes for the next milestone and beyond",
                   expected: "Release planning notes for the next"),
    ThreadNameCase("- list item\nsecond line", expected: "list item"),
    ThreadNameCase("<:sakura:123> hi <@5>, welcome", expected: ":sakura: hi @maya, welcome"),
    ThreadNameCase("||The culprit is Alice||", expected: "<spoiler>"),
    ThreadNameCase("Plot twist: ||Alice|| did it", expected: "Plot twist: <spoiler> did it"),
    ThreadNameCase(String(repeating: "a", count: 50), expected: String(repeating: "a", count: 40) + "..."),
    ThreadNameCase("ignored", embedTitle: "An embed title that is longer than forty characters",
                   expected: "An embed title that is longer than forty..."),
    ThreadNameCase("ignored", pollQuestion: "Which day?", expected: "Which day?"),
    ThreadNameCase("Release notes", embedTitle: "   ", pollQuestion: " ", expected: "Release notes"),
    ThreadNameCase("  \n  ", expected: "Thread"),
])
func `default thread names follow the first-party starter-message rule`(_ value: ThreadNameCase) {
    #expect(ThreadNamePolicy.defaultName(for: value.starter) == value.expected)
    #expect(ThreadNamePolicy.validatedName(value.expected) == value.expected)
}

struct ThreadPolicyCase: Sendable, CustomTestStringConvertible {
    var testDescription: String
    var owned = false
    var isPrivate = false
    var isJoined = false
    var isArchived = false
    var isLocked = false
    var permissions: UInt64
    var kind = ChannelKindValue.text
    /// read, rename, close, reopen, unarchive, delete, membership, notifications, lock
    var expected: [Bool]
}

private let view = DiscordPermissionBits.viewChannel
private let send = DiscordPermissionBits.sendMessages | DiscordPermissionBits.sendMessagesInThreads
private let manage = DiscordPermissionBits.manageThreads

@Test(arguments: [
    ThreadPolicyCase(testDescription: "owner of an active thread", owned: true, permissions: view | send,
                     expected: [true, true, true, true, true, false, true, false, false]),
    ThreadPolicyCase(testDescription: "member of another user's thread", isJoined: true, permissions: view | send,
                     expected: [true, false, false, true, true, false, true, true, false]),
    ThreadPolicyCase(testDescription: "owner of an archived thread without send", owned: true, isArchived: true,
                     permissions: view, expected: [true, false, true, false, true, false, false, false, false]),
    ThreadPolicyCase(testDescription: "owner of an archived thread with send", owned: true, isArchived: true,
                     permissions: view | send, expected: [true, true, true, true, true, false, false, false, false]),
    ThreadPolicyCase(testDescription: "owner of a locked thread", owned: true, isLocked: true, permissions: view | send,
                     expected: [true, false, false, false, false, false, true, false, false]),
    ThreadPolicyCase(testDescription: "moderator of an archived locked thread", isArchived: true, isLocked: true,
                     permissions: view | manage, expected: [true, false, true, true, true, true, false, false, true]),
    ThreadPolicyCase(testDescription: "forum author of an empty post", owned: true, permissions: view, kind: .forum,
                     expected: [true, true, true, false, true, true, true, false, false]),
    ThreadPolicyCase(testDescription: "unjoined private thread", isPrivate: true, permissions: view | send,
                     expected: [false, false, false, false, false, false, false, false, false]),
    ThreadPolicyCase(testDescription: "joined private thread", isPrivate: true, isJoined: true, permissions: view,
                     expected: [true, false, false, false, true, false, true, true, false]),
    ThreadPolicyCase(testDescription: "moderator without view", permissions: manage,
                     expected: [false, false, false, false, false, false, false, false, false]),
])
func `thread actions follow first-party ownership, lock and archive rules`(_ value: ThreadPolicyCase) {
    let userID = UserID(rawValue: 1)
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 2), name: "thread", isArchived: value.isArchived, isLocked: value.isLocked,
        ownerID: value.owned ? userID : UserID(rawValue: 3),
        notificationSettings: value.isJoined ? ThreadNotificationSettings() : nil, isPrivate: value.isPrivate
    )
    let policy = ThreadActionPolicy(
        thread: thread, currentUserID: userID, parentPermissions: value.permissions, parentKind: value.kind
    )
    #expect([
        policy.canRead, policy.canRename, policy.canClose, policy.canReopen, policy.canUnarchive,
        policy.canDelete, policy.canChangeMembership, policy.canChangeNotifications, policy.canLock,
    ] == value.expected)
}

@Test func `starting a thread requires an eligible parent, message and permission`() {
    let createPublic = view | DiscordPermissionBits.createPublicThreads | DiscordPermissionBits.readMessageHistory
    let text = Channel(id: ChannelID(rawValue: 7), guildID: GuildID(rawValue: 1), name: "general")
    let starter = message("Hello")
    #expect(ThreadActionPolicy.canCreateThread(from: starter, in: text, permissions: createPublic))
    #expect(!ThreadActionPolicy.canCreateThread(
        from: starter, in: text, permissions: createPublic & ~DiscordPermissionBits.readMessageHistory))

    var started = starter
    started.flags.insert(.hasThread)
    var system = starter
    system.type = .threadCreated
    var pending = starter
    pending.outboxState = .sending
    var voice = text
    voice.kind = .voice
    let threadMessage = Message(id: MessageID(rawValue: 901), channelID: ChannelID(rawValue: 900),
                                author: author, content: "Inside a thread")
    #expect(!ThreadActionPolicy.canCreateThread(from: started, in: text, permissions: createPublic))
    #expect(!ThreadActionPolicy.canCreateThread(from: system, in: text, permissions: createPublic))
    #expect(!ThreadActionPolicy.canCreateThread(from: pending, in: text, permissions: createPublic))
    #expect(!ThreadActionPolicy.canCreateThread(from: starter, in: voice, permissions: createPublic))
    #expect(!ThreadActionPolicy.canCreateThread(from: threadMessage, in: text, permissions: createPublic))

    let draft = CreateThreadDraft.startingFrom(starter, in: text)
    #expect(draft.name == "Hello" && draft.autoArchiveDuration == 4_320 && draft.starterMessageID == starter.id)

    #expect(ThreadActionPolicy.creationPermissions(parentKind: .announcement, permissions: createPublic)
        == ThreadCreationPermissions(canCreatePublic: true, canCreatePrivate: false))
    #expect(ThreadActionPolicy.creationPermissions(
        parentKind: .text, permissions: view | DiscordPermissionBits.createPrivateThreads
    ) == ThreadCreationPermissions(canCreatePublic: false, canCreatePrivate: true))
    #expect(ThreadActionPolicy.canBrowseThreads(parentKind: .text, permissions: view | DiscordPermissionBits.readMessageHistory))
    #expect(!ThreadActionPolicy.canBrowseThreads(parentKind: .voice, permissions: .max))
}
