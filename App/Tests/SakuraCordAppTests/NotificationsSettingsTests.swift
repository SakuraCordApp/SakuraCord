@testable import SakuraCord
import Foundation
import SakuraCordModels
import Testing
import UserNotifications

@MainActor
@Test func `Notification preferences migrate historical values export and reset`() {
    let defaults = InMemoryPreferences()
    defaults.set(false, forKey: "notifications.dockBadge")
    defaults.set(22, forKey: "notifications.quietStart")
    defaults.set(8, forKey: "notifications.quietEnd")

    let value = NotificationPreferences(defaults: defaults)
    #expect(value.dockBadgeStyle == .off)
    #expect(value.weekdayQuietStartMinutes == 22 * 60)
    #expect(value.weekdayQuietEndMinutes == 8 * 60)

    value.notifiesMentions = false
    value.groupsByConversation = true
    value.quietDays = [2, 3, 4, 5, 6]
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
    #expect(!value.groupsByConversation)
    #expect(value.quietDays == Set(1 ... 7))
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
}

@MainActor
@Test func `Notification policy narrows events without overriding Focus`() throws {
    let preferences = NotificationPreferences(defaults: InMemoryPreferences())
    let server = NotificationEventContext(
        type: .serverActivity,
        isDirectConversation: false
    )
    #expect(!preferences.allows(
        server,
        isApplicationActive: true,
        isCurrentConversation: true
    ))

    preferences.suppressesCurrentConversation = false
    preferences.notifiesOnlyInBackground = true
    #expect(!preferences.allows(
        server,
        isApplicationActive: true,
        isCurrentConversation: false
    ))
    #expect(preferences.allows(
        server,
        isApplicationActive: false,
        isCurrentConversation: false
    ))

    preferences.notifiesServerActivity = false
    #expect(!preferences.allows(
        server,
        isApplicationActive: false,
        isCurrentConversation: false
    ))
    #expect(preferences.allows(
        .incomingCall,
        isApplicationActive: true,
        isCurrentConversation: true
    ))
    #expect(NotificationFocusPolicy.interruptionLevel == .active)
    #expect(NotificationFocusPolicy.interruptionLevel != .timeSensitive)
    #expect(NotificationFocusPolicy.interruptionLevel != .critical)
}

@MainActor
@Test func `Quiet schedules follow enabled start days overnight ranges and time zones`() throws {
    let preferences = NotificationPreferences(defaults: InMemoryPreferences())
    preferences.quietHoursEnabled = true
    preferences.quietDays = [2]
    preferences.weekdayQuietStartMinutes = 22 * 60
    preferences.weekdayQuietEndMinutes = 8 * 60

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    #expect(preferences.isQuiet(
        at: try localDate(2026, 8, 24, 23, 30, calendar: utc),
        calendar: utc
    ))
    #expect(preferences.isQuiet(
        at: try localDate(2026, 8, 25, 7, 59, calendar: utc),
        calendar: utc
    ))
    #expect(!preferences.isQuiet(
        at: try localDate(2026, 8, 25, 8, 0, calendar: utc),
        calendar: utc
    ))

    preferences.quietDays = [1, 2]
    preferences.weekendQuietStartMinutes = 22 * 60
    preferences.weekendQuietEndMinutes = 8 * 60
    preferences.weekdayQuietStartMinutes = 12 * 60
    preferences.weekdayQuietEndMinutes = 13 * 60
    #expect(preferences.isQuiet(
        at: try localDate(2026, 8, 24, 7, 30, calendar: utc),
        calendar: utc
    ))

    preferences.quietDays = [7]
    preferences.weekendQuietStartMinutes = 20 * 60
    preferences.weekendQuietEndMinutes = 10 * 60
    var kyiv = Calendar(identifier: .gregorian)
    kyiv.timeZone = try #require(TimeZone(identifier: "Europe/Kyiv"))
    #expect(preferences.isQuiet(
        at: try localDate(2026, 3, 29, 4, 30, calendar: kyiv),
        calendar: kyiv
    ))
    #expect(!preferences.isQuiet(
        at: try localDate(2026, 3, 29, 10, 0, calendar: kyiv),
        calendar: kyiv
    ))

    preferences.quietDays = [1]
    preferences.weekendQuietStartMinutes = 12 * 60
    preferences.weekendQuietEndMinutes = 12 * 60
    #expect(preferences.isQuiet(
        at: try localDate(2026, 3, 29, 18, 0, calendar: kyiv),
        calendar: kyiv
    ))
    #expect(!preferences.isQuiet(
        at: try localDate(2026, 3, 30, 1, 0, calendar: kyiv),
        calendar: kyiv
    ))
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
@Test func `Incoming call notifications deduplicate and cancel at the ringing boundary`() async throws {
    let service = RecordingNotificationService()
    let model = AppModel(
        launchMode: .offlineTesting,
        notificationService: service,
        notificationPreferences: NotificationPreferences(defaults: InMemoryPreferences())
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let channel = try #require(model.snapshot?.channels.first {
        $0.kind == .directMessage && !$0.recipients.isEmpty
    })
    let caller = try #require(channel.recipients.first)
    var call = PrivateCall(
        channelID: channel.id,
        messageID: MessageID(rawValue: 40),
        ongoingRings: [
            PrivateCallRing(recipientID: currentUser.id, senderID: caller.id),
        ]
    )

    model.consumePrivateCallChanged(&call)
    #expect(await eventuallyNotification { service.deliveredCallChannelIDs == [channel.id] })
    model.consumePrivateCallChanged(&call)
    await Task.yield()
    #expect(service.deliveredCallChannelIDs == [channel.id])

    call.ongoingRings = []
    model.consumePrivateCallChanged(&call)
    #expect(await eventuallyNotification { service.cancelledCallChannelIDs == [channel.id] })
}

@MainActor
@Test func `Read clearing and denied permission remain honest`() async {
    let service = RecordingNotificationService(status: .denied)
    let preferences = NotificationPreferences(defaults: InMemoryPreferences())
    let model = AppModel(
        launchMode: .offlineTesting,
        notificationService: service,
        notificationPreferences: preferences
    )
    #expect(await model.notificationAuthorizationStatus() == .denied)

    let channelID = ChannelID(rawValue: 50)
    preferences.clearsWhenRead = false
    model.cancelNativeNotifications(channelID: channelID)
    await Task.yield()
    #expect(service.cancelledMessageChannelIDs.isEmpty)

    preferences.clearsWhenRead = true
    model.cancelNativeNotifications(channelID: channelID)
    #expect(await eventuallyNotification {
        service.cancelledMessageChannelIDs == [channelID]
    })
}

@Test func `Notification settings catalog registers every production control`() {
    let expected: Set<SettingsControlID> = [
        .notificationPermission, .notificationEnabled, .notificationPreview,
        .notificationSound, .notificationDockBadge, .notificationFocus,
        .notificationDirectMessages, .notificationGroupDirectMessages,
        .notificationMentions, .notificationReplies, .notificationIncomingCalls,
        .notificationServerActivity, .notificationOnlyInBackground,
        .notificationSuppressCurrent, .notificationGroupBursts,
        .notificationClearWhenRead, .notificationCallsBypassSuppression,
        .notificationQuietHours, .notificationQuietDays, .notificationQuietStart,
        .notificationQuietEnd, .notificationWeekendQuietStart,
        .notificationWeekendQuietEnd, .notificationAllowDirectMessages,
        .notificationAllowCalls, .notificationDiscordOwnership,
        .notificationExport, .notificationReset,
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
        .notificationPermission, .notificationFocus, .notificationDiscordOwnership,
        .notificationExport, .notificationReset,
    ]))
}

private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    calendar: Calendar
) throws -> Date {
    try #require(calendar.date(from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    )))
}

@MainActor
private func eventuallyNotification(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0 ..< 100 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private final class RecordingNotificationService: NativeNotificationService {
    let status: UNAuthorizationStatus
    private(set) var deliveredCallChannelIDs: [ChannelID] = []
    private(set) var cancelledCallChannelIDs: [ChannelID] = []
    private(set) var cancelledMessageChannelIDs: [ChannelID] = []

    init(status: UNAuthorizationStatus = .authorized) {
        self.status = status
    }

    func requestAuthorization() async throws -> Bool { status == .authorized }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func deliver(
        message _: Message,
        channel _: Channel?,
        guild _: Guild?,
        accountID _: String,
        preferences _: NotificationPreferences
    ) async {}

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
