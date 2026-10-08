@testable import SakuraCord
import Foundation
import SakuraCordModels
import Observation
import Testing
import UserNotifications

@MainActor
@Test func `Notification preferences migrate historical values export and reset`() {
    let defaults = InMemoryPreferences()
    defaults.set(false, forKey: "notifications.dockBadge")

    let value = NotificationPreferences(defaults: defaults)
    #expect(value.dockBadgeStyle == .off)
    value.notifiesMentions = false
    value.groupsByConversation = true
    let store = SettingsPreferenceStore(defaults: defaults)
    let export = store.export(scope: .appWide, page: .notifications)
    #expect(
        export.values[SettingsControlID.notificationMentions.rawValue] == .bool(false)
    )
    #expect(
        export.values[SettingsControlID.notificationGroupBursts.rawValue] == .bool(true)
    )
    #expect(export.values[SettingsControlID.launchDestination.rawValue] == nil)

    store.reset(scope: .appWide, page: .notifications)
    value.reload()
    #expect(value.dockBadgeStyle == .mentions)
    #expect(value.notifiesMentions)
    #expect(value.groupsByConversation)
}

@Test func `Message notification events classify replies mentions and conversation kinds`() {
    let currentUser = User(
        id: UserID(rawValue: 1),
        username: "current",
        displayName: "Current"
    )
    let sender = User(id: UserID(rawValue: 2), username: "sender", displayName: "Sender")
    let directChannel = Channel(
        id: ChannelID(rawValue: 10),
        guildID: nil,
        name: "Direct",
        kind: .directMessage
    )
    let groupChannel = Channel(
        id: ChannelID(rawValue: 11),
        guildID: nil,
        name: "Group",
        kind: .groupDirectMessage
    )
    let serverChannel = Channel(
        id: ChannelID(rawValue: 12),
        guildID: GuildID(rawValue: 13),
        name: "general"
    )
    let directMessage = Message(
        id: MessageID(rawValue: 20),
        channelID: directChannel.id,
        author: sender,
        content: "Direct"
    )
    let groupMessage = Message(
        id: MessageID(rawValue: 21),
        channelID: groupChannel.id,
        author: sender,
        content: "Group"
    )
    var reply = Message(
        id: MessageID(rawValue: 22),
        channelID: serverChannel.id,
        author: sender,
        content: "Reply"
    )
    reply.replyPreview = MessageReplyPreview(
        messageID: MessageID(rawValue: 19),
        author: currentUser,
        content: "Earlier"
    )

    #expect(NotificationEventContext.message(
        directMessage,
        channel: directChannel,
        isMention: false,
        currentUserID: currentUser.id
    ).type == .directMessage)
    #expect(NotificationEventContext.message(
        groupMessage,
        channel: groupChannel,
        isMention: false,
        currentUserID: currentUser.id
    ).type == .groupDirectMessage)
    #expect(NotificationEventContext.message(
        reply,
        channel: serverChannel,
        isMention: true,
        currentUserID: currentUser.id
    ).type == .reply)
    #expect(NotificationEventContext.message(
        directMessage,
        channel: serverChannel,
        isMention: true,
        currentUserID: currentUser.id
    ).type == .mention)
    #expect(NotificationEventContext.message(
        directMessage,
        channel: serverChannel,
        isMention: false,
        currentUserID: currentUser.id
    ).type == .serverActivity)

    var directReply = reply
    directReply.channelID = directChannel.id
    #expect(NotificationEventContext.message(
        directReply,
        channel: directChannel,
        isMention: true,
        currentUserID: currentUser.id
    ).type == .directMessage)
    directReply.channelID = groupChannel.id
    #expect(NotificationEventContext.message(
        directReply,
        channel: groupChannel,
        isMention: true,
        currentUserID: currentUser.id
    ).type == .groupDirectMessage)
}

@MainActor
@Test func `Notification policy narrows events without overriding Focus`() throws {
    let preferences = NotificationPreferences(defaults: InMemoryPreferences())
    let server = NotificationEventContext(
        type: .serverActivity
    )
    #expect(!preferences.allows(
        server,
        isCurrentConversation: true
    ))

    preferences.suppressesCurrentConversation = false
    #expect(preferences.allows(
        server,
        isCurrentConversation: false
    ))

    preferences.notifiesServerActivity = false
    #expect(!preferences.allows(
        server,
        isCurrentConversation: false
    ))
    preferences.suppressesCurrentConversation = true
    #expect(preferences.allows(
        .incomingCall,
        isCurrentConversation: true
    ))
    #expect(NotificationFocusPolicy.interruptionLevel == .active)
    #expect(NotificationFocusPolicy.interruptionLevel != .timeSensitive)
    #expect(NotificationFocusPolicy.interruptionLevel != .critical)
}

@Test func `Notification privacy identities grouping and call deep links are deterministic`() {
    let hiddenCall = NotificationContentPresentation.makeIncomingCall(
        callerName: "Caller",
        conversationName: "Private group",
        style: .hidden
    )
    #expect(hiddenCall == NotificationContentPresentation(
        title: "SakuraCord",
        subtitle: "",
        body: "Incoming call"
    ))
    #expect(NotificationContentPresentation.makeIncomingCall(
        callerName: "Caller",
        conversationName: "Private group",
        style: .senderOnly
    ).subtitle.isEmpty)
    #expect(NotificationContentPresentation.makeIncomingCall(
        callerName: "Caller",
        conversationName: "Private group",
        style: .full
    ).subtitle == "Private group")

    let channelID = ChannelID(rawValue: 30)
    let messageID = MessageID(rawValue: 31)
    #expect(
        NativeNotificationIdentity.message(
            accountID: "one",
            channelID: channelID,
            messageID: messageID
        ) == NativeNotificationIdentity.message(
            accountID: "one",
            channelID: channelID,
            messageID: messageID
        )
    )
    #expect(
        NativeNotificationIdentity.conversation(accountID: "one", channelID: channelID)
            != NativeNotificationIdentity.conversation(accountID: "two", channelID: channelID)
    )

    let link = NotificationDeepLink(
        accountID: "one",
        guildID: nil,
        channelID: channelID,
        messageID: nil
    )
    #expect(NotificationDeepLink(userInfo: link.userInfo) == link)
    #expect(link.userInfo["message_id"] == nil)
}

@MainActor
@Test(arguments: [false, true])
func `Incoming call notifications deduplicate and cancel at the ringing boundary`(appIsActive: Bool) async throws {
    let service = RecordingNotificationService()
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(
        launchMode: .offlineTesting,
        notificationService: service,
        soundPlayer: sounds,
        notificationPreferences: NotificationPreferences(defaults: InMemoryPreferences())
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let channel = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.recipients.isEmpty
    })
    let caller = try #require(channel.recipients.first)
    model.selectedChannelID = channel.id
    model.mainWindowIsActive = appIsActive
    model.applicationIsActive = appIsActive
    var call = PrivateCall(
        channelID: channel.id,
        messageID: MessageID(rawValue: 40),
        ongoingRings: [
            PrivateCallRing(recipientID: currentUser.id, senderID: caller.id),
        ]
    )

    let expectedNotifications = appIsActive ? [] : [channel.id]
    model.consumePrivateCallChanged(&call)
    #expect(await until { service.deliveredCallChannelIDs == expectedNotifications })
    #expect(sounds.looping[.callRinging] == appIsActive)
    model.consumePrivateCallChanged(&call)
    await Task.yield()
    #expect(service.deliveredCallChannelIDs == expectedNotifications)

    call.ongoingRings = []
    model.consumePrivateCallChanged(&call)
    #expect(await until { service.cancelledCallChannelIDs == [channel.id] })
    #expect(sounds.looping[.callRinging] == false)
}

@MainActor
@Test func `Read clearing and denied permission remain honest`() async throws {
    let service = RecordingNotificationService(status: .denied)
    let preferences = NotificationPreferences(defaults: InMemoryPreferences())
    let model = AppModel(
        launchMode: .offlineTesting,
        notificationService: service,
        notificationPreferences: preferences
    )
    #expect(await model.notificationAuthorizationStatus() == .denied)
    #expect(try await model.requestNotificationPermission() == false)
    service.requestError = .unavailable
    await #expect(throws: RecordingNotificationService.AuthorizationError.unavailable) {
        try await model.requestNotificationPermission()
    }

    let channelID = ChannelID(rawValue: 50)
    preferences.clearsWhenRead = false
    model.cancelNativeNotifications(channelID: channelID)
    await Task.yield()
    #expect(service.cancelledMessageChannelIDs.isEmpty)

    preferences.clearsWhenRead = true
    model.cancelNativeNotifications(channelID: channelID)
    #expect(await until {
        service.cancelledMessageChannelIDs == [channelID]
    })
}

@Test func `Notification settings catalog registers every production control`() {
    let expected: Set<SettingsControlID> = [
        .notificationPermission, .notificationEnabled, .notificationPreview,
        .notificationSound, .notificationMessageSound, .notificationCallRingtone,
        .notificationDockBadge,
        .notificationDirectMessages, .notificationGroupDirectMessages,
        .notificationMentions, .notificationReplies, .notificationIncomingCalls,
        .notificationServerActivity,
        .notificationSuppressCurrent, .notificationGroupBursts,
        .notificationClearWhenRead,
        .notificationReset,
    ]
    let controls = Set(
        SettingsCatalog.foundation.controls
            .filter { $0.destination.page == .notifications }
            .map(\.id)
    )
    #expect(controls == expected)

    let preferenceIDs = Set(
        SettingsPreferenceRegistry.foundation.registrations(page: .notifications).map(\.id)
    )
    #expect(preferenceIDs == expected.subtracting([
        .notificationPermission,
        .notificationReset,
    ]))
}

@MainActor
@Test(arguments: [false, true])
func `Desktop and sound delivery are independent and share message filters`(appIsActive: Bool) async throws {
    for (desktop, sound) in [(false, false), (false, true), (true, false), (true, true)] {
        let service = RecordingNotificationService()
        let sounds = RecordingAppSoundPlayer()
        let preferences = NotificationPreferences(defaults: InMemoryPreferences())
        preferences.isEnabled = desktop
        preferences.playsSound = sound
        preferences.suppressesCurrentConversation = false
        let model = AppModel(
            launchMode: .offlineTesting,
            notificationService: service,
            soundPlayer: sounds,
            notificationPreferences: preferences
        )
        await model.start()
        let sender = User(id: UserID(rawValue: 999), username: "sender", displayName: "Sender")
        let channel = try #require(model.snapshot?.channels.first { $0.kind == .directMessage })
        let message = Message(
            id: MessageID(rawValue: 789), channelID: channel.id,
            author: sender, content: "Hello", timestamp: .now
        )
        model.applicationIsActive = appIsActive
        let deliversDesktop = desktop && !appIsActive
        model.deliverNativeNotification(for: message)
        if deliversDesktop {
            #expect(await until { service.messageSounds == [sound] })
            #expect(sounds.played.isEmpty)
        } else {
            #expect(service.messageSounds.isEmpty)
            #expect(sounds.played == (sound ? [.message] : []))
        }
        preferences.notifiesDirectMessages = false
        model.deliverNativeNotification(for: message)
        await Task.yield()
        #expect(service.messageSounds.count == (deliversDesktop ? 1 : 0))
        #expect(sounds.played.count == (!deliversDesktop && sound ? 1 : 0))
    }
}

@Test func `Notification previews resolve tokens and protect private image previews`() {
    let sender = User(id: UserID(rawValue: 1), username: "sender", displayName: "Sender")
    let mentioned = User(id: UserID(rawValue: 2), username: "friend", displayName: "Friend")
    let channel = Channel(id: ChannelID(rawValue: 3), guildID: nil, name: "Group", kind: .groupDirectMessage)
    let image = Attachment(
        id: "image", filename: "photo.png", url: URL(fileURLWithPath: "/tmp/photo.png"),
        mediaType: "image/png"
    )
    var message = Message(
        id: MessageID(rawValue: 4), channelID: channel.id, author: sender,
        content: "Hi <@2> <@&5> <#6> <:wave:7>", timestamp: .now,
        attachments: [image], mentionedUsers: [mentioned]
    )
    let preview = NotificationContentPresentation.make(
        message: message, channel: channel, guild: nil, style: .full,
        mentionLabel: { mention in
            switch mention.kind {
            case .user: "@Friend"
            case .role: "@Designers"
            case .channel: "#general"
            default: "Link"
            }
        }
    )
    #expect(preview.subtitle.isEmpty)
    #expect(preview.body == "Hi @Friend @Designers #general :wave:")
    let spoilerPreview = { (content: String) in
        var spoilered = message
        spoilered.content = content
        return NotificationContentPresentation.make(
            message: spoilered, channel: channel, guild: nil, style: .full,
            mentionLabel: { _ in "@Friend" }
        ).body
    }
    #expect(spoilerPreview("||only||") == "<spoiler>")
    #expect(spoilerPreview("||a||||b||") == "<spoiler><spoiler>")
    #expect(
        spoilerPreview("<@2> said ||the **end** <@2> <:wave:7>|| then ||more||")
            == "@Friend said <spoiler> then <spoiler>"
    )
    #expect(NotificationContentPresentation.make(
        message: message, channel: channel, guild: nil, style: .senderOnly
    ).body == "New message")
    #expect(NotificationMedia.imageAttachment(in: message, style: .full) == image)
    #expect(NotificationMedia.imageAttachment(in: message, style: .senderOnly) == nil)
    #expect(NotificationMedia.imageAttachment(in: message, style: .hidden) == nil)
    message.attachments[0].isSpoiler = true
    #expect(NotificationMedia.imageAttachment(in: message, style: .full) == nil)
}

@MainActor
@Observable
private final class RecordingNotificationService: NativeNotificationService {
    enum AuthorizationError: Error { case unavailable }
    var requestError: AuthorizationError?
    let status: UNAuthorizationStatus
    private(set) var messageSounds: [Bool] = []
    private(set) var deliveredCallChannelIDs: [ChannelID] = []
    private(set) var cancelledCallChannelIDs: [ChannelID] = []
    private(set) var cancelledMessageChannelIDs: [ChannelID] = []

    init(status: UNAuthorizationStatus = .authorized) {
        self.status = status
    }

    func requestAuthorization() async throws -> Bool {
        if let requestError { throw requestError }
        return status == .authorized
    }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func deliver(
        message _: Message,
        channel _: Channel?,
        guild _: Guild?,
        accountID _: String,
        preferences: NotificationPreferences
    ) async {
        messageSounds.append(preferences.playsSound)
    }

    func deliverIncomingCall(
        call: PrivateCall,
        channel _: Channel?,
        caller _: User?,
        accountID _: String,
        preferences _: NotificationPreferences
    ) async {
        deliveredCallChannelIDs.append(call.channelID)
    }

    func cancel(accountID _: String, channelID: ChannelID) async {
        cancelledMessageChannelIDs.append(channelID)
    }

    func cancelIncomingCall(accountID _: String, channelID: ChannelID) async {
        cancelledCallChannelIDs.append(channelID)
    }

    func setDockBadge(_: Int, enabled _: Bool) {}
}
