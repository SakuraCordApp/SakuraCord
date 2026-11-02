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

    let sameDay = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 24, hour: 23, minute: 59
    )))
    let nextDay = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 25, hour: 0, minute: 1
    )))
    let followingDay = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 26, hour: 0, minute: 1
    )))
    func messageText(now: Date) -> String {
        InterfaceTimestampFormatter.messageText(
            for: date,
            now: now,
            format: .twelveHour,
            includesSeconds: false,
            locale: locale,
            timeZone: timeZone,
            calendar: calendar
        )
    }
    #expect(messageText(now: sameDay) == "1:05 PM")
    #expect(messageText(now: nextDay) == "Yesterday at 1:05 PM")
    #expect(messageText(now: followingDay) == "08/24/2026, 1:05 PM")
}

@MainActor
@Test func `Timestamp preferences persist by page`() {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = InterfaceSettingsStore(preferences: preferences)

    var loaded = store.load()

    loaded.timestampFormat = .twentyFourHour
    loaded.alwaysShowsTimestamps = true
    loaded.includesTimestampSeconds = true
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
@Test func `Always underlined links share hover styling without changing timeline geometry`() throws {
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

    let original = NativeTimelineRowLayout.make(item: item, width: 620, source: model)
    var settings = AccessibilitySettingsSnapshot.defaults
    settings.underlinesLinks = true
    model.applyAccessibilitySettings(settings, persists: false)
    let layout = NativeTimelineRowLayout.make(item: item, width: 620, source: model)
    #expect(layout.height == original.height)
    #expect(layout.contentFrame == original.contentFrame)
    let content = try #require(layout.attributedContent)
    #expect(content == original.attributedContent)
    let hovered = NSMutableAttributedString(attributedString: content)
    NativeTimelineLinkAppearance.applyHover(to: hovered, characterIndex: 0)
    let always = NSMutableAttributedString(attributedString: content)
    NativeTimelineLinkAppearance.applyHover(to: always, characterIndex: nil, underlinesAllLinks: true)
    #expect(always == hovered)
}

@MainActor
@Test func `Interface catalog exposes every control and required search synonym`() {
    let expected: Set<SettingsControlID> = [
        .interfaceSize,
        .messageAppearance,
        .directMessageAppearance,
        .groupMessageAppearance,
        .messageDensity,
        .composerBarAppearance,
        .resetMessageAppearance,
        .timestampFormat,
        .timestampSeconds,
        .alwaysShowTimestamps,
        .composerIcons,
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
        ("roles", .roleColorDisplay),
        ("bubbles", .messageAppearance),
        ("density", .messageDensity),
        ("zoom", .interfaceSize),
        ("text size", .interfaceSize),
        ("input bar", .composerBarAppearance),
        ("defaults", .resetMessageAppearance),
    ]
    for (term, control) in searchCases {
        state.searchText = term
        #expect(
            state.searchResults.contains { $0.id == control },
            "Missing Interface search result for \(term)"
        )
    }
}

@MainActor
@Test func `Composer icon order persists and repairs duplicate or missing icons`() {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let store = AppearanceSettingsStore(preferences: preferences)
    var settings = store.load()
    settings.composerIcons.move([.emoji], before: .gif)
    store.save(settings)
    #expect(store.load().composerIcons.order == [.emoji, .gif, .sticker])
    settings = store.load()
    settings.composerIcons.move([.emoji, .gif], before: nil)
    store.save(settings)
    #expect(store.load().composerIcons.order == [.sticker, .emoji, .gif])
    let repaired = ComposerIconLayout(storageValue: "{\"order\":[\"emoji\",\"emoji\"]}")
    #expect(repaired.order == [.emoji, .gif, .sticker])
}

@MainActor
@Test func `Retired appearance preferences are removed and role colour choice migrates`() {
    let defaults = InMemoryPreferences()
    defaults.set(false, forKey: "settings.interface.showRoleColors")
    defaults.set(22, forKey: "settings.interface.groupingIntervalMinutes")
    defaults.set(false, forKey: "settings.interface.showActivityDetails")
    defaults.set("always", forKey: "settings.interface.messageActionVisibility")
    defaults.set(true, forKey: "settings.interface.underlineLinks")
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = AccessibilitySettingsStore(preferences: preferences)
    #expect(store.load().roleColorDisplay == .hidden)
    #expect(store.load().underlinesLinks)
    for key in ["settings.interface.showRoleColors", "settings.interface.groupingIntervalMinutes",
                "settings.interface.showActivityDetails", "settings.interface.messageActionVisibility"] {
        #expect(defaults.object(forKey: key) == nil)
    }
    var settings = store.load()
    settings.roleColorDisplay = .nextToNames
    store.save(settings)
    #expect(store.load() == settings)
}
