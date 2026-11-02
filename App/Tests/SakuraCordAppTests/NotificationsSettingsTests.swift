import AVFAudio
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

@MainActor
@Test func `Settings export keeps system sounds and leaves out custom file sounds`() {
    let defaults = InMemoryPreferences()
    let preferences = NotificationPreferences(defaults: defaults)
    preferences.messageSoundID = NotificationSoundLibrary.systemID(for: "Glass")
    preferences.callRingtoneBookmark = Data([1])
    preferences.callRingtoneID = NotificationSoundLibrary.customID

    let export = SettingsPreferenceStore(defaults: defaults).export(scope: .appWide, page: .notifications)
    #expect(
        export.values[SettingsControlID.notificationMessageSound.rawValue]
            == .string("system:Glass")
    )
    #expect(export.values[SettingsControlID.notificationCallRingtone.rawValue] == nil)
}

@MainActor
@Test func `Custom sounds must be playable, and a file replaced in place gets a new stamp`() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let garbage = directory.appending(path: "garbage.mp3")
    try Data(repeating: 0x5A, count: 4_096).write(to: garbage)
    #expect(NotificationSoundLibrary.makePlayer(at: garbage) == nil)

    let tone = directory.appending(path: "tone.wav")
    func writeTone(seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frames = AVAudioFrameCount(8_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try AVAudioFile(forWriting: tone, settings: format.settings).write(from: buffer)
    }
    try writeTone(seconds: 0.5)
    #expect(NotificationSoundLibrary.makePlayer(at: tone) != nil)
    let stamp = NotificationSoundLibrary.FileStamp(tone)
    try writeTone(seconds: 1)
    #expect(NotificationSoundLibrary.FileStamp(tone) != stamp)
    try FileManager.default.removeItem(at: tone)
    #expect(NotificationSoundLibrary.FileStamp(tone) == nil)
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

@Test func `Notification identities, grouping and deep links are deterministic`() {
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
@Test(arguments: [false, true], [PresenceStatus.online, .dnd])
func `Incoming calls ring in the app whether or not it is in front, and only Do Not Disturb silences them`(
    appIsActive: Bool, status: PresenceStatus
) async throws {
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(
        launchMode: .offlineTesting,
        notificationService: RecordingNotificationService(),
        soundPlayer: sounds,
        notificationPreferences: NotificationPreferences(defaults: InMemoryPreferences())
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let channel = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.recipients.isEmpty
    })
    let caller = try #require(channel.recipients.first)
    model.mainWindowIsActive = appIsActive
    model.applicationIsActive = appIsActive
    model.applyCurrentStatus(status)
    var call = PrivateCall(
        channelID: channel.id,
        messageID: MessageID(rawValue: 40),
        ongoingRings: [
            PrivateCallRing(recipientID: currentUser.id, senderID: caller.id),
        ]
    )

    model.consumePrivateCallChanged(&call)
    #expect(model.incomingPrivateCalls.map(\.channelID) == [channel.id])
    #expect(sounds.looping[.callRinging] == (status != .dnd))

    model.applyCurrentStatus(.dnd)
    #expect(sounds.looping[.callRinging] == false)
    model.applyCurrentStatus(.online)
    #expect(sounds.looping[.callRinging] == true)

    call.ongoingRings = []
    model.consumePrivateCallChanged(&call)
    #expect(model.incomingPrivateCalls.isEmpty)
    #expect(sounds.looping[.callRinging] == false)
}

@MainActor
@Test func `Muting a ringing conversation silences its call`() async throws {
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(
        launchMode: .offlineTesting,
        notificationService: RecordingNotificationService(),
        soundPlayer: sounds,
        notificationPreferences: NotificationPreferences(defaults: InMemoryPreferences())
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let channel = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.recipients.isEmpty
    })
    let caller = try #require(channel.recipients.first)
    model.applyCurrentStatus(.online)
    var call = PrivateCall(
        channelID: channel.id,
        messageID: MessageID(rawValue: 41),
        ongoingRings: [
            PrivateCallRing(recipientID: currentUser.id, senderID: caller.id),
        ]
    )
    model.consumePrivateCallChanged(&call)
    #expect(sounds.looping[.callRinging] == true)

    model.updateLocalChannelNotificationOverride(guildID: nil, channelID: channel.id) { $0.isMuted = true }
    #expect(sounds.looping[.callRinging] == false)
    model.updateLocalChannelNotificationOverride(guildID: nil, channelID: channel.id) { $0.isMuted = false }
    #expect(sounds.looping[.callRinging] == true)

    // A timed mute that ends while the call still rings lets it ring.
    model.updateLocalChannelNotificationOverride(guildID: nil, channelID: channel.id) {
        $0.isMuted = true
        $0.muteConfiguration = DiscordMuteConfiguration(endTime: .now.addingTimeInterval(0.2))
    }
    #expect(sounds.looping[.callRinging] == false)
    #expect(await eventually { sounds.looping[.callRinging] == true })
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
        model.applyCurrentStatus(.dnd)
        model.deliverNativeNotification(for: message)
        for task in Array(model.accountChildTasks.values) { await task.value }
        #expect(service.messageSounds.isEmpty)
        #expect(sounds.played.isEmpty)

        model.applyCurrentStatus(.online)
        let deliversDesktop = desktop && !appIsActive
        // A call's own message stays quiet; the call rings instead.
        var callMessage = message
        callMessage.type = .call
        model.deliverNativeNotification(for: callMessage)
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

        if deliversDesktop {
            preferences.notifiesDirectMessages = true
            model.deliverNativeNotification(for: message)
            model.applyCurrentStatus(.dnd)
            for task in Array(model.accountChildTasks.values) { await task.value }
            #expect(service.messageSounds == [sound])
        }
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func `DND invalidates native notifications awaiting image preparation`(entersDND: Bool) async throws {
    let preparing = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    var submittedIDs: [String] = []
    let service = MacNativeNotificationService(
        preparePreviewImage: { _, _ in
            preparing.continuation.yield(())
            preparing.continuation.finish()
            for await _ in resume.stream { break }
            return nil
        },
        submitRequest: { submittedIDs.append($0.identifier) }
    )
    let preferences = NotificationPreferences(defaults: InMemoryPreferences())
    preferences.playsSound = false
    let message = Message(
        id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 2),
        author: User(id: UserID(rawValue: 3), username: "sender", displayName: "Sender"),
        content: "Photo", attachments: [Attachment(
            id: "image", filename: "photo.png", url: URL(fileURLWithPath: "/tmp/dnd-photo.png"),
            mediaType: "image/png"
        )]
    )
    let delivery = Task {
        await service.deliver(
            message: message, channel: nil, guild: nil, accountID: "offline", preferences: preferences
        )
    }
    defer { resume.continuation.finish(); delivery.cancel() }
    for await _ in preparing.stream { break }
    if entersDND {
        service.setSuppressed(true)
        service.setSuppressed(false)
    }
    resume.continuation.finish()
    await cancellableValue(of: delivery)
    let identifier = NativeNotificationIdentity.message(
        accountID: "offline", channelID: message.channelID, messageID: message.id
    )
    #expect(submittedIDs == (entersDND ? [] : [identifier]))
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

    func cancel(accountID _: String, channelID: ChannelID) async {
        cancelledMessageChannelIDs.append(channelID)
    }

    func setDockBadge(_: Int, enabled _: Bool) {}
}
