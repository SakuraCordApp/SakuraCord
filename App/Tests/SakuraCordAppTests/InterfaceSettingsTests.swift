@testable import SakuraCord
import AppKit
import Foundation
import SakuraCordModels
import Testing

@Test func `Interface timestamps honor explicit clocks and seconds`() throws {
    var calendar = Calendar(identifier: .gregorian)
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    calendar.timeZone = timeZone
    let date = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 24,
        hour: 13,
        minute: 5,
        second: 9
    )))
    let locale = Locale(identifier: "en_US_POSIX")

    #expect(InterfaceTimestampFormatter.text(
        for: date,
        format: .twelveHour,
        includesSeconds: false,
        locale: locale,
        timeZone: timeZone,
        calendar: calendar
    ) == "1:05 PM")
    #expect(InterfaceTimestampFormatter.text(
        for: date,
        format: .twelveHour,
        includesSeconds: true,
        locale: locale,
        timeZone: timeZone,
        calendar: calendar
    ) == "1:05:09 PM")
    #expect(InterfaceTimestampFormatter.text(
        for: date,
        format: .twentyFourHour,
        includesSeconds: false,
        locale: locale,
        timeZone: timeZone,
        calendar: calendar
    ) == "13:05")
    #expect(InterfaceTimestampFormatter.text(
        for: date,
        format: .twentyFourHour,
        includesSeconds: true,
        locale: locale,
        timeZone: timeZone,
        calendar: calendar
    ) == "13:05:09")

    let systemUS = InterfaceTimestampFormatter.text(
        for: date,
        format: .system,
        includesSeconds: false,
        locale: Locale(identifier: "en_US"),
        timeZone: timeZone,
        calendar: calendar
    )
    let systemFrance = InterfaceTimestampFormatter.text(
        for: date,
        format: .system,
        includesSeconds: false,
        locale: Locale(identifier: "fr_FR"),
        timeZone: timeZone,
        calendar: calendar
    )
    #expect(systemUS != systemFrance)
}

@MainActor
@Test func `Interface preferences persist export and reset by page`() {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = InterfaceSettingsStore(preferences: preferences)
    preferences.set(.integer(90), for: .groupingInterval)

    var loaded = store.load()
    #expect(loaded.groupingIntervalMinutes == 30)

    loaded.timestampFormat = .twentyFourHour
    loaded.showsMemberList = false
    store.save(loaded)
    #expect(store.load() == loaded)
    let export = preferences.export(scope: .appWide, page: .interface)
    #expect(
        export.values[SettingsControlID.timestampFormat.rawValue]
            == .string(InterfaceTimestampFormat.twentyFourHour.rawValue)
    )
    #expect(export.values[SettingsControlID.launchDestination.rawValue] == nil)

    preferences.reset(scope: .appWide, page: .interface)
    #expect(store.load() == .defaults)
}

@MainActor
@Test func `Interface grouping interval changes continuation boundaries`() throws {
    let author = User(
        id: UserID(rawValue: 1),
        username: "fixture",
        displayName: "Fixture"
    )
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let messages = [
        Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            author: author,
            content: "First",
            timestamp: base
        ),
        Message(
            id: MessageID(rawValue: 2),
            channelID: ChannelID(rawValue: 2),
            author: author,
            content: "Second",
            timestamp: base.addingTimeInterval(5 * 60)
        ),
    ]

    let fiveMinutes = MessageGrouping.rows(
        for: messages,
        continuationInterval: 5 * 60
    )
    let sixMinutes = MessageGrouping.rows(
        for: messages,
        continuationInterval: 6 * 60
    )
    #expect(try #require(fiveMinutes.last).startsGroup)
    #expect(!(try #require(sixMinutes.last)).startsGroup)
}

@MainActor
@Test func `Interface live changes invalidate only affected timeline presentation`() {
    let model = AppModel(launchMode: .offlineTesting)
    model.applyInterfaceSettings(.defaults, persists: false)
    let initialRevision = model.timelinePresentationRevision

    var actions = model.interfaceSettings
    actions.messageActionVisibility = .always
    model.applyInterfaceSettings(actions, persists: false)
    #expect(model.timelinePresentationRevision == initialRevision)

    var links = model.interfaceSettings
    links.underlinesLinks = true
    model.applyInterfaceSettings(links, persists: false)
    #expect(model.timelinePresentationRevision > initialRevision)

    var memberList = model.interfaceSettings
    memberList.showsMemberList = false
    model.applyInterfaceSettings(memberList, persists: false)
    #expect(!model.showInspector)
}

@MainActor
@Test func `Interface link decoration reaches native timeline layout`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let message = Message(
        id: MessageID(rawValue: 10),
        channelID: ChannelID(rawValue: 11),
        author: User(
            id: UserID(rawValue: 12),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "[SakuraCord](https://example.com)"
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let item = NativeMessageTimelineItem.message(
        row,
        isUnreadBoundary: false,
        isHighlighted: false
    )

    var settings = InterfaceSettingsSnapshot.defaults
    settings.underlinesLinks = true
    model.applyInterfaceSettings(settings, persists: false)
    let layout = NativeTimelineRowLayout.make(
        item: item,
        width: 620,
        model: model
    )

    let underline = try #require(
        layout.attributedContent?.attribute(
            .underlineStyle,
            at: 0,
            effectiveRange: nil
        ) as? Int
    )
    #expect(underline == NSUnderlineStyle.single.rawValue)
}

@MainActor
@Test func `Interface member presentation hides activity`() throws {
    let member = Member(
        user: User(
            id: UserID(rawValue: 20),
            username: "member",
            displayName: "Member"
        ),
        roleName: "Member",
        status: .online,
        activityText: "Building SakuraCord"
    )
    let sections = [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 1,
            members: [member]
        ),
    ]
    let shown = try #require(NativeMemberListCanvasView.prepareDocument(
        sections: sections,
        presentation: NativeMemberListPresentation(
            showsActivityDetails: true,
            showsRoleColors: true
        )
    ))
    let hidden = try #require(NativeMemberListCanvasView.prepareDocument(
        sections: sections,
        presentation: NativeMemberListPresentation(
            showsActivityDetails: false,
            showsRoleColors: false
        )
    ))
    let itemID = NativeMemberListCanvasView.ItemID.member(member.id)
    #expect(try #require(shown.preparedText[itemID]).activity != nil)
    #expect(try #require(hidden.preparedText[itemID]).activity == nil)
}

@MainActor
@Test func `Interface catalog exposes every control and required search synonym`() {
    let expected: Set<SettingsControlID> = [
        .timestampFormat,
        .timestampSeconds,
        .groupingInterval,
        .underlineLinks,
        .showMemberList,
        .showActivityDetails,
        .messageActionVisibility,
        .showRoleColors,
        .interfacePreview,
        .exportInterfaceSettings,
        .resetInterfaceSettings,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .interface
    }
    #expect(Set(controls.map(\.id)) == expected)
    #expect(controls.allSatisfy { $0.scope == .appWideLocal })

    let state = SettingsViewState()
    let searchCases: [(String, SettingsControlID)] = [
        ("clock", .timestampFormat),
        ("timestamp", .timestampFormat),
        ("roles", .showRoleColors),
        ("member list", .showMemberList),
    ]
    for (term, control) in searchCases {
        state.searchText = term
        #expect(
            state.searchResults.contains { $0.id == control },
            "Missing Interface search result for \(term)"
        )
    }
}
