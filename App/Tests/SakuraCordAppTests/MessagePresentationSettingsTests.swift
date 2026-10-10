@testable import SakuraCord
import AppKit
import Foundation
import SakuraCordModels
import Testing

@Test func `Chat character counter follows Discord effective limits`() {
    #expect(ChatCharacterLimitPolicy.limit(premiumType: nil) == 2_000)
    #expect(ChatCharacterLimitPolicy.limit(premiumType: 0) == 2_000)
    #expect(ChatCharacterLimitPolicy.limit(premiumType: 2) == 4_000)
    #expect(!ChatCharacterLimitPolicy.shouldShowCounter(characterCount: 1_799, limit: 2_000))
    #expect(ChatCharacterLimitPolicy.shouldShowCounter(characterCount: 1_800, limit: 2_000))
    #expect(!ChatCharacterLimitPolicy.isWithinLimit(characterCount: 2_001, premiumType: 0))
}

@MainActor
@Test func `SakuraCord update links replace Discord previews with native actions`() throws {
    let url = try #require(
        URL(string: "https://sakuracord.app/settings/update")
    )
    let message = Message(
        id: MessageID(rawValue: 64),
        channelID: ChannelID(rawValue: 65),
        author: User(
            id: UserID(rawValue: 66),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Try [the updater](\(url.absoluteString)).",
        embeds: [
            MessageEmbed(
                title: "Check for Updates in SakuraCord",
                type: "rich",
                description: "This is a SakuraCord settings deeplink.",
                url: url
            ),
        ]
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    #expect(row.sakuraCordDeepLinks.map(\.action) == [.checkForUpdates])
    #expect(MessageEmbedPresentation.visibleEmbeds(for: message).isEmpty)

    let item = NativeMessageTimelineItem.message(
        row,
        isUnreadBoundary: false,
        isHighlighted: false
    )
    let model = AppModel(launchMode: .offlineTesting)
    let layout = NativeTimelineRowLayout.make(
        item: item,
        width: 900,
        model: model
    )
    #expect(layout.sakuraCordDeepLinkRegions.first?.action == .checkForUpdates)
    #expect(layout.sakuraCordDeepLinkRegions.first?.action.title == "Update SakuraCord")
    #expect(layout.sakuraCordDeepLinkRegions.first?.action.buttonTitle == "Check for Updates")
    #expect(layout.embedRegions.isEmpty)

    #expect(
        SakuraCordDeepLinkPresentation.all(
            in: "https://sakuracord.app.evil/settings/update"
        ).isEmpty
    )
    #expect(
        SakuraCordDeepLinkPresentation.all(
            in: "http://sakuracord.app/settings/update"
        ).isEmpty
    )
}

@MainActor
@Test func `SakuraCord theme links replace Discord previews with native theme actions`() throws {
    let sharedTheme = SakuraCordSharedTheme(
        appearance: .dark,
        theme: SakuraCordGradientTheme(
            colors: [
                .init(hue: 0.02, saturation: 0.70),
                .init(hue: 0.34, saturation: 0.72),
                .init(hue: 0.67, saturation: 0.74),
            ],
            intensity: 0.84,
            brightness: 0.76
        )
    )
    let url = try SakuraCordThemeShareCodec.shareURL(for: sharedTheme)
    let message = Message(
        id: MessageID(rawValue: 67),
        channelID: ChannelID(rawValue: 68),
        author: User(
            id: UserID(rawValue: 69),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Try [this theme](\(url.absoluteString)).",
        embeds: [
            MessageEmbed(
                title: "SakuraCord Settings Deeplink",
                type: "rich",
                description: "Open it in SakuraCord to use the linked setting.",
                url: url
            ),
        ]
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    guard case let .applyTheme(decodedTheme)? = row.sakuraCordDeepLinks.first?.action else {
        Issue.record("Theme link did not produce an apply action")
        return
    }
    #expect(decodedTheme.appearance == .dark)
    #expect(decodedTheme.theme.activeColorCount == 3)
    #expect(MessageEmbedPresentation.visibleEmbeds(for: message).isEmpty)

    let item = NativeMessageTimelineItem.message(
        row,
        isUnreadBoundary: false,
        isHighlighted: false
    )
    let model = AppModel(launchMode: .offlineTesting)
    let layout = NativeTimelineRowLayout.make(
        item: item,
        width: 900,
        model: model
    )
    let region = try #require(layout.sakuraCordDeepLinkRegions.first)
    #expect(region.action == .applyTheme(decodedTheme))
    #expect(region.action.buttonTitle == "Apply Theme")
    #expect(region.paletteFrames.count == 3)
    #expect(region.buttonFrame.height == NativeTimelineComponentButtonMetrics.height)
    #expect(layout.embedRegions.isEmpty)
}

@MainActor
@Test func `Multiple SakuraCord links render ordered independent native cards`() throws {
    let firstThemeURL = try SakuraCordThemeShareCodec.shareURL(for: .init(
        appearance: .dark,
        theme: .defaultTheme
    ))
    let secondThemeURL = try SakuraCordThemeShareCodec.shareURL(for: .init(
        appearance: .light,
        theme: SakuraCordGradientTheme(
            colors: [
                .init(hue: 0.12, saturation: 0.75),
                .init(hue: 0.58, saturation: 0.82),
            ],
            intensity: 0.72,
            brightness: 0.88
        )
    ))
    let updateURL = try #require(
        URL(string: "https://sakuracord.app/settings/update")
    )
    let urls = [firstThemeURL, updateURL, secondThemeURL]
    let message = Message(
        id: MessageID(rawValue: 70),
        channelID: ChannelID(rawValue: 71),
        author: User(
            id: UserID(rawValue: 72),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: urls.map(\.absoluteString).joined(separator: "\n"),
        embeds: urls.map { url in
            MessageEmbed(
                title: "SakuraCord Settings Deeplink",
                type: "rich",
                description: "Open it in SakuraCord to use the linked setting.",
                url: url
            )
        }
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )

    #expect(row.sakuraCordDeepLinks.map(\.url) == urls)
    #expect(row.sakuraCordDeepLinks.count == 3)
    #expect(MessageEmbedPresentation.visibleEmbeds(for: message).isEmpty)

    let layout = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 900,
        model: AppModel(launchMode: .offlineTesting)
    )
    let regions = layout.sakuraCordDeepLinkRegions
    try #require(regions.count == 3)
    #expect(regions[0].action.title == "Apply Theme")
    #expect(regions[1].action == .checkForUpdates)
    #expect(regions[2].action.title == "Apply Theme")
    #expect(Set(regions.map(\.componentID)).count == 3)
    #expect(regions[0].frame.maxY < regions[1].frame.minY)
    #expect(regions[1].frame.maxY < regions[2].frame.minY)
    #expect(layout.embedRegions.isEmpty)

    for maximumWidth: CGFloat in [280, 360, 560] {
        for (index, deepLink) in row.sakuraCordDeepLinks.enumerated() {
            let region = NativeTimelineSakuraCordDeepLinkLayout.make(
                deepLink,
                componentIndex: index,
                origin: .zero,
                maximumWidth: maximumWidth
            )
            #expect(!region.titleFrame.intersects(region.buttonFrame))
            #expect(!region.symbolBackgroundFrame.intersects(region.buttonFrame))
            #expect(region.paletteFrames.allSatisfy {
                !$0.intersects(region.buttonFrame)
            })
            #expect(region.cardFrame.contains(region.buttonFrame))
        }
    }
}

@MainActor
@Test func `Settings cards resolve every category and control through search navigation`() throws {
    for page in SettingsPageID.allCases {
        let url = try #require(URL(string: "https://sakuracord.app/settings/\(page.deepLinkPath)"))
        #expect(SakuraCordDeepLinkPresentation.action(for: url) == .openSettings(.init(page: page)))
    }
    for (path, control) in [("composer", SettingsControlID.composerBarAppearance), ("messages", .messageAppearance)] {
        let url = try #require(URL(string: "https://sakuracord.app/settings/appearance/\(path)"))
        guard case let .openSettings(destination)? = SakuraCordDeepLinkPresentation.action(for: url) else {
            Issue.record("Expected a Settings destination")
            continue
        }
        let state = SettingsViewState()
        state.navigate(to: .init(page: destination.page, section: destination.section), controlID: try #require(destination.controlID))
        #expect(state.selectedPage == .interface)
        #expect(state.revealRequest?.controlID == control)
        #expect(state.highlightedControlID == control)
        #expect(state.revealRequest?.destination.section == (control == .composerBarAppearance ? .interfaceInputBar : .interfaceMessages))
    }
    var controlURLs = Set<URL>()
    for control in SettingsCatalog.foundation.controls {
        let expected = SettingsDeepLinkDestination(page: control.destination.page, controlID: control.id)
        #expect(controlURLs.insert(expected.url).inserted)
        let link = try #require(SakuraCordDeepLinkPresentation.all(in: "<\(expected.url.absoluteString)>.").first)
        #expect(link.action == .openSettings(expected))
        guard case let .openSettings(destination) = link.action else { continue }
        let state = SettingsViewState()
        state.navigate(to: .init(page: destination.page, section: destination.section), controlID: try #require(destination.controlID))
        #expect(state.selectedPage == control.destination.page)
        #expect(state.revealRequest?.destination == control.destination)
        #expect(state.highlightedControlID == control.id)
        #expect(!destination.title.isEmpty)
    }
    #expect(SakuraCordDeepLinkPresentation.all(in: "https://sakuracord.app/settings/diagnostics/send").map(\.action) == [.sendDiagnostics])
    for url in [
        "https://sakuracord.app.evil.test/settings/diagnostics/send",
        "https://user@sakuracord.app/settings/diagnostics/send",
        "http://sakuracord.app/settings/diagnostics/send",
        "https://sakuracord.app/settings/diagnostics/send?channel=12",
        "https://sakuracord.app/settings/diagnostics/send#12",
        "https://sakuracord.app/settings/appearance/unknown",
        "https://sakuracord.app/settings/general/input-device",
        "https://sakuracord.app/settings/voice-video/input-device/extra",
    ] {
        #expect(SakuraCordDeepLinkPresentation.all(in: url).isEmpty)
    }
}

@MainActor
@Test func `ephemeral messages expose no server message actions`() {
    let model = AppModel(launchMode: .offlineTesting)
    let canvas = NativeTimelineCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
    canvas.model = model
    for flags: MessageFlags in [.ephemeral, [.ephemeral, .loading]] {
        let message = Message(
            id: MessageID(rawValue: 70), channelID: ChannelID(rawValue: 71),
            author: User(id: UserID(rawValue: 72), username: "fixture", displayName: "Fixture"),
            content: "Private response", flags: flags
        )
        let row = MessageRowPresentation(message: message, startsGroup: true, startsDay: false,
                                         replyPreview: nil, isReplyAvailable: false)
        let mode = MessageOutboxPresentation.interactionMode(for: message)
        #expect(!mode.allowsHoverActions)
        #expect(!mode.allowsMessageContextMenu)
        #expect(!mode.allowsMediaContextMenu)
        #expect(!MessageReplyPresentationPolicy.allowsReplyAction(for: message))
        #expect(!model.canDeleteMessage(message))
        #expect(!model.canManagePins(for: message))
        #expect(!message.isForwardable)
        #expect(canvas.accessibilityMessageActions(row, rowIndex: 0).isEmpty)
    }
}
