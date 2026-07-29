import AppKit
import CoreText
import Foundation
import ImageIO
import MessageRendering
@testable import SakuraCord
import SakuraCordModels
import SwiftUI
import Testing
import UniformTypeIdentifiers

@MainActor @Test
func `spoiler reveal state follows stable message and content identity`() {
    let store = NativeTimelineSpoilerRevealStore()
    let messageID = MessageID(rawValue: 8_001)
    let attachment = NativeTimelineComponentRevealKey.attachment(
        messageID: messageID,
        attachmentID: "stable-attachment"
    )
    var notifications: [MessageID] = []
    let observer = store.observe { notifications.append($0) }
    defer { store.removeObserver(observer) }

    #expect(!store.isMediaRevealed(attachment))
    #expect(store.revealMedia(attachment))
    #expect(!store.revealMedia(attachment))
    #expect(store.isMediaRevealed(attachment))
    #expect(
        !store.isMediaRevealed(
            .attachment(
                messageID: messageID,
                attachmentID: "different-attachment"
            )
        )
    )
    #expect(
        !store.isMediaRevealed(
            .attachment(
                messageID: MessageID(rawValue: 8_002),
                attachmentID: "stable-attachment"
            )
        )
    )

    let text = NativeTimelineTextSpoilerRevealKey(
        messageID: messageID,
        contentID: "message-content",
        contentHash: 91,
        rangeLocation: 7
    )
    #expect(store.revealText(text))
    #expect(!store.revealText(text))
    #expect(
        store.revealedTextLocations(
            messageID: messageID,
            contentID: "message-content",
            contentHash: 91
        ) == [7]
    )
    #expect(
        store.revealedTextLocations(
            messageID: messageID,
            contentID: "message-content",
            contentHash: 92
        ).isEmpty
    )
    #expect(notifications == [messageID, messageID])
}

@MainActor @Test
func `concealed spoiler policy gates loading animation and nested containers until reveal`() throws {
    let store = NativeTimelineSpoilerRevealStore()
    let messageID = MessageID(rawValue: 8_003)
    let contentID = "attachment:animated"

    #expect(
        NativeTimelineSpoilerConcealmentPolicy.isConcealed(
            messageID: messageID,
            contentID: contentID,
            isSpoiler: true,
            store: store
        )
    )
    #expect(
        !NativeTimelineSpoilerConcealmentPolicy.shouldLoadOrAnimate(
            messageID: messageID,
            contentID: contentID,
            isSpoiler: true,
            store: store
        )
    )
    #expect(
        NativeTimelineSpoilerConcealmentPolicy.shouldLoadOrAnimate(
            messageID: messageID,
            contentID: "ordinary-media",
            isSpoiler: false,
            store: store
        )
    )

    store.revealMedia(
        NativeTimelineComponentRevealKey(
            messageID: messageID,
            componentID: contentID
        )
    )
    #expect(
        NativeTimelineSpoilerConcealmentPolicy.shouldLoadOrAnimate(
            messageID: messageID,
            contentID: contentID,
            isSpoiler: true,
            store: store
        )
    )

    let nestedMessage = Message(
        id: MessageID(rawValue: 8_004),
        channelID: ChannelID(rawValue: 8_005),
        author: User(
            id: UserID(rawValue: 8_006),
            username: "nested.fixture",
            displayName: "Nested Fixture"
        ),
        content: "",
        flags: [.isComponentsV2],
        components: [
            .container(
                id: "outer",
                accentColor: nil,
                spoiler: true,
                children: [
                    .container(
                        id: "inner",
                        accentColor: nil,
                        spoiler: true,
                        children: [
                            .textDisplay(
                                id: "nested-text",
                                content: "Nested concealed content"
                            )
                        ]
                    )
                ]
            )
        ]
    )
    let nestedLayout = try #require(
        NativeTimelineComponentLayout.make(
            message: nestedMessage,
            model: nil,
            origin: .zero,
            maximumWidth: 480
        )
    )
    let outerFrame = try #require(
        nestedLayout.containers.first {
            $0.componentID == "outer"
        }?.frame
    )
    let innerFrame = try #require(
        nestedLayout.containers.first {
            $0.componentID == "inner"
        }?.frame
    )
    #expect(
        NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(
            in: nestedLayout,
            messageID: nestedMessage.id,
            store: store
        ) == [outerFrame]
    )
    store.revealMedia(
        NativeTimelineComponentRevealKey(
            messageID: nestedMessage.id,
            componentID: "outer"
        )
    )
    #expect(
        NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(
            in: nestedLayout,
            messageID: nestedMessage.id,
            store: store
        ) == [innerFrame]
    )
}

@MainActor @Test
func `spoiler cover centers its pill and owns pointer keyboard and accessibility activation`() throws {
    let bounds = CGRect(x: 0, y: 0, width: 280, height: 160)
    let pill = NativeTimelineSpoilerAppearance.pillFrame(
        in: bounds,
        measuredLabelWidth: 47.2
    )
    #expect(pill.midX == bounds.midX)
    #expect(pill.midY == bounds.midY)
    #expect(pill.height == NativeTimelineSpoilerAppearance.pillHeight)
    #expect(
        pill.width
            == ceil(47.2)
                + NativeTimelineSpoilerAppearance.pillHorizontalPadding * 2
    )
    #expect(NativeTimelineSpoilerAppearance.textCornerRadius == 4)
    #expect(
        NativeTimelineSpoilerAppearance.textBackgroundAlpha(
            isHovered: true
        )
            > NativeTimelineSpoilerAppearance.textBackgroundAlpha(
                isHovered: false
            )
    )

    var activationCount = 0
    let overlay = NativeTimelineSpoilerOverlayHost(
        frame: bounds,
        cornerRadius: 8
    ) {
        activationCount += 1
    }
    let window = NSWindow(
        contentRect: bounds,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = overlay
    overlay.layoutSubtreeIfNeeded()
    #expect(overlay.hasPersistentPillForTesting)

    func mouseEvent(
        _ type: NSEvent.EventType,
        point: CGPoint,
        number: Int
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: overlay.convert(point, to: nil),
                modifierFlags: [],
                timestamp: TimeInterval(number),
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
        )
    }

    let inside = CGPoint(x: 120, y: 80)
    let outside = CGPoint(x: 320, y: 80)
    #expect(overlay.hitTest(inside) === overlay)
    #expect(overlay.hitTest(outside) == nil)
    overlay.mouseEntered(
        with: try mouseEvent(.mouseMoved, point: inside, number: 1)
    )
    #expect(overlay.isHovered)
    overlay.mouseExited(
        with: try mouseEvent(.mouseMoved, point: outside, number: 2)
    )
    #expect(!overlay.isHovered)

    overlay.mouseDown(
        with: try mouseEvent(.leftMouseDown, point: inside, number: 3)
    )
    overlay.mouseDragged(
        with: try mouseEvent(.leftMouseDragged, point: outside, number: 4)
    )
    overlay.mouseUp(
        with: try mouseEvent(.leftMouseUp, point: outside, number: 5)
    )
    #expect(activationCount == 0)
    overlay.rightMouseDown(
        with: try mouseEvent(
            .rightMouseDown,
            point: inside,
            number: 6
        )
    )
    #expect(activationCount == 0)
    overlay.mouseDown(
        with: try mouseEvent(.leftMouseDown, point: inside, number: 7)
    )
    overlay.mouseUp(
        with: try mouseEvent(.leftMouseUp, point: inside, number: 8)
    )
    #expect(activationCount == 1)
    overlay.mouseDown(
        with: try mouseEvent(.leftMouseDown, point: inside, number: 9)
    )
    overlay.mouseUp(
        with: try mouseEvent(.leftMouseUp, point: inside, number: 10)
    )
    #expect(activationCount == 1)
    #expect(overlay.accessibilityRole() == .button)
    #expect(overlay.accessibilityLabel() == "Reveal spoiler")
    #expect(
        overlay.accessibilityHelp()
            == "Reveals this media without opening it"
    )
    #expect(overlay.accessibilityActionNames() == [.press])

    func keyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    #expect(
        NativeTimelineSpoilerAppearance.isActivationKey(
            try keyEvent(characters: "\r", keyCode: 36)
        )
    )
    #expect(
        NativeTimelineSpoilerAppearance.isActivationKey(
            try keyEvent(characters: " ", keyCode: 49)
        )
    )
    #expect(
        !NativeTimelineSpoilerAppearance.isActivationKey(
            try keyEvent(
                characters: " ",
                keyCode: 49,
                modifiers: .command
            )
        )
    )

    var keyboardActivations = 0
    let keyboardOverlay = NativeTimelineSpoilerOverlayHost(
        frame: bounds,
        cornerRadius: 8
    ) {
        keyboardActivations += 1
    }
    keyboardOverlay.keyDown(
        with: try keyEvent(characters: " ", keyCode: 49)
    )
    #expect(keyboardActivations == 1)

    var accessibilityActivations = 0
    let accessibilityOverlay = NativeTimelineSpoilerOverlayHost(
        frame: bounds,
        cornerRadius: 8
    ) {
        accessibilityActivations += 1
    }
    #expect(accessibilityOverlay.accessibilityPerformPress())
    #expect(accessibilityActivations == 1)
}

@MainActor
@Test func `timeline accessibility proxy rejects unsupported row presses without crashing`() {
    let source = NSAccessibilityElement()
    source.setAccessibilityRole(.row)
    source.setAccessibilityLabel("Message row")
    let proxy = NativeTimelineAccessibilityProxyView(source: source)

    #expect(proxy.accessibilityActionNames().isEmpty)
    #expect(!proxy.accessibilityPerformPress())
}

@MainActor
@Test func `timeline accessibility proxy routes supported presses through its native action`() {
    var activationCount = 0
    let source = NativeTimelineAccessibilityElement {
        activationCount += 1
        return true
    }
    source.setAccessibilityRole(.button)
    source.setAccessibilityLabel("Open reply")
    let proxy = NativeTimelineAccessibilityProxyView(source: source)

    #expect(proxy.accessibilityActionNames() == [.press])
    #expect(proxy.accessibilityPerformPress())
    #expect(activationCount == 1)
}

@MainActor @Test
func `concealed spoiler covers survive repeated far offscreen recycling and pagination`() throws {
    let width: CGFloat = 560
    let viewportHeight: CGFloat = 320
    let mediaURL = try #require(
        URL(string: "file:///tmp/sakuracord-spoiler-fixture.png")
    )
    let author = User(
        id: UserID(rawValue: 8_100),
        username: "spoiler.fixture",
        displayName: "Spoiler Fixture"
    )

    func makeStorage(
        messageRange: Range<Int>
    ) -> (
        storage: NativeTimelineCanvasStorage,
        rows: [MessageRowPresentation]
    ) {
        let storage = NativeTimelineCanvasStorage()
        var rows: [MessageRowPresentation] = []
        var origin: CGFloat = 0
        for index in messageRange {
            let message = Message(
                id: MessageID(rawValue: UInt64(8_200 + index)),
                channelID: ChannelID(rawValue: 8_101),
                author: author,
                content: "Concealed fixture \(index)",
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(1_700_000_000 + index)
                ),
                attachments: [
                    Attachment(
                        id: "spoiler-\(index)",
                        filename: "SPOILER-fixture-\(index).png",
                        url: mediaURL,
                        mediaType: "image/png",
                        width: 720,
                        height: 420,
                        isSpoiler: true
                    )
                ]
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
            let layout = NativeTimelineRowLayout.make(
                item: item,
                width: width
            )
            storage.items.append(item)
            storage.layouts.append(layout)
            storage.rowOrigins.append(origin)
            rows.append(row)
            origin += layout.height
        }
        storage.contentHeight = origin
        return (storage, rows)
    }

    let initial = makeStorage(messageRange: 0 ..< 48)
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: initial.storage.contentHeight
        )
    )
    let scrollView = NSScrollView(
        frame: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: viewportHeight
        )
    )
    scrollView.documentView = canvas
    let window = NSWindow(
        contentRect: scrollView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    let model = AppModel(launchMode: .offlineTesting)
    let actions = NativeTimelineRowActions(
        loadEarlier: {},
        openReply: { _ in },
        reply: nil,
        retry: { _ in },
        edit: { _, _ in },
        markUnread: { _ in },
        delete: { _ in },
        react: { _, _ in },
        openThread: { _ in },
        submitComponent: { _, _, _, _ in }
    )
    canvas.apply(
        storage: initial.storage,
        model: model,
        actions: actions,
        viewportWidth: width,
        minimumHeight: viewportHeight,
        bottomSpacerHeight: 0,
        contentOriginY: 0
    )
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()

    func scroll(to y: CGFloat) {
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.reconcileSpoilerOverlaysForTesting()
    }

    scroll(to: 0)
    let initialOverlayFrames =
        canvas.spoilerOverlayFramesForTesting
    let firstVisible = Set(initialOverlayFrames.keys)
    #expect(!firstVisible.isEmpty)
    #expect(canvas.spoilerOverlayPillKeysForTesting == firstVisible)
    let firstKey = NativeTimelineComponentRevealKey.attachment(
        messageID: initial.rows[0].message.id,
        attachmentID: "spoiler-0"
    )
    #expect(
        initialOverlayFrames[firstKey]
            == initial.storage.layouts[0].attachmentRegions[0].frame
    )
    #expect(
        firstVisible.allSatisfy {
            !model.timelineSpoilerRevealStore.isMediaRevealed($0)
        }
    )

    let farY = max(
        0,
        initial.storage.contentHeight - viewportHeight
    )
    for _ in 0 ..< 6 {
        scroll(to: farY)
        let farVisible = Set(
            canvas.spoilerOverlayFramesForTesting.keys
        )
        #expect(!farVisible.isEmpty)
        #expect(canvas.spoilerOverlayPillKeysForTesting == farVisible)
        #expect(firstVisible.isDisjoint(with: farVisible))
        #expect(
            farVisible.allSatisfy {
                !model.timelineSpoilerRevealStore.isMediaRevealed($0)
            }
        )

        scroll(to: 0)
        #expect(
            Set(canvas.spoilerOverlayFramesForTesting.keys)
                == firstVisible
        )
        #expect(canvas.spoilerOverlayPillKeysForTesting == firstVisible)
    }

    let paginated = makeStorage(messageRange: -8 ..< 48)
    canvas.apply(
        storage: paginated.storage,
        model: model,
        actions: actions,
        viewportWidth: width,
        minimumHeight: viewportHeight,
        bottomSpacerHeight: 0,
        contentOriginY: 0
    )
    scroll(to: 0)
    let prependedVisible = Set(
        canvas.spoilerOverlayFramesForTesting.keys
    )
    #expect(!prependedVisible.isEmpty)
    #expect(canvas.spoilerOverlayPillKeysForTesting == prependedVisible)
    #expect(
        prependedVisible.allSatisfy {
            !model.timelineSpoilerRevealStore.isMediaRevealed($0)
        }
    )
}

@MainActor @Test
func `animated attachment and component spoilers start only after their own reveal`() throws {
    let hiddenURL = try #require(
        URL(string: "file:///tmp/sakuracord-hidden.gif")
    )
    let ordinaryURL = try #require(
        URL(string: "file:///tmp/sakuracord-ordinary.gif")
    )
    let componentURL = try #require(
        URL(string: "file:///tmp/sakuracord-component.gif")
    )
    let messageID = MessageID(rawValue: 8_400)
    let message = Message(
        id: messageID,
        channelID: ChannelID(rawValue: 8_401),
        author: User(
            id: UserID(rawValue: 8_402),
            username: "animation.fixture",
            displayName: "Animation Fixture"
        ),
        content: "",
        attachments: [
            Attachment(
                id: "hidden-animation",
                filename: "SPOILER-hidden.gif",
                url: hiddenURL,
                mediaType: "image/gif",
                width: 32,
                height: 32,
                isSpoiler: true,
                isAnimated: true
            ),
            Attachment(
                id: "ordinary-animation",
                filename: "ordinary.gif",
                url: ordinaryURL,
                mediaType: "image/gif",
                width: 32,
                height: 32,
                isAnimated: true
            ),
        ],
        flags: [.isComponentsV2],
        components: [
            .container(
                id: "hidden-container",
                accentColor: nil,
                spoiler: true,
                children: [
                    .mediaGallery(
                        id: "hidden-gallery",
                        items: [
                            ComponentGalleryItem(
                                id: "hidden-gallery-item",
                                media: ComponentMedia(
                                    url: componentURL,
                                    width: 32,
                                    height: 32,
                                    contentType: "image/gif",
                                    description:
                                        "Concealed component animation"
                                )
                            )
                        ]
                    )
                ]
            )
        ]
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
    let layout = NativeTimelineRowLayout.make(
        item: item,
        width: 560
    )
    let storage = NativeTimelineCanvasStorage()
    storage.items = [item]
    storage.layouts = [layout]
    storage.rowOrigins = [0]
    storage.contentHeight = layout.height
    let model = AppModel(launchMode: .offlineTesting)
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 560, height: layout.height)
    )
    canvas.apply(
        storage: storage,
        model: model,
        actions: NativeTimelineRowActions(
            loadEarlier: {},
            openReply: { _ in },
            reply: nil,
            retry: { _ in },
            edit: { _, _ in },
            markUnread: { _ in },
            delete: { _ in },
            react: { _, _ in },
            openThread: { _ in },
            submitComponent: { _, _, _, _ in }
        ),
        viewportWidth: 560,
        minimumHeight: layout.height,
        bottomSpacerHeight: 0,
        contentOriginY: 0
    )

    let ordinaryKey = NativeTimelineMediaKey.media(ordinaryURL)
    let hiddenKey = NativeTimelineMediaKey.media(hiddenURL)
    let componentKey = NativeTimelineMediaKey.media(componentURL)
    var animated = canvas.animatedMediaKeysForTesting(
        row: row,
        layout: layout
    )
    #expect(animated.contains(ordinaryKey))
    #expect(!animated.contains(hiddenKey))
    #expect(!animated.contains(componentKey))

    model.timelineSpoilerRevealStore.revealMedia(
        .attachment(
            messageID: messageID,
            attachmentID: "hidden-animation"
        )
    )
    animated = canvas.animatedMediaKeysForTesting(
        row: row,
        layout: layout
    )
    #expect(animated.contains(hiddenKey))
    #expect(!animated.contains(componentKey))

    model.timelineSpoilerRevealStore.revealMedia(
        NativeTimelineComponentRevealKey(
            messageID: messageID,
            componentID: "hidden-container"
        )
    )
    animated = canvas.animatedMediaKeysForTesting(
        row: row,
        layout: layout
    )
    #expect(animated.contains(componentKey))
}

@MainActor @Test
func `shared timeline canvases synchronize spoiler reveal across channel switching`() throws {
    let mediaURL = try #require(
        URL(string: "file:///tmp/sakuracord-shared-spoiler.png")
    )
    let message = Message(
        id: MessageID(rawValue: 8_500),
        channelID: ChannelID(rawValue: 8_501),
        author: User(
            id: UserID(rawValue: 8_502),
            username: "shared.fixture",
            displayName: "Shared Fixture"
        ),
        content: "",
        attachments: [
            Attachment(
                id: "shared-spoiler",
                filename: "SPOILER-shared.png",
                url: mediaURL,
                mediaType: "image/png",
                width: 720,
                height: 420,
                isSpoiler: true
            )
        ]
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
    let layout = NativeTimelineRowLayout.make(item: item, width: 560)
    let storage = NativeTimelineCanvasStorage()
    storage.items = [item]
    storage.layouts = [layout]
    storage.rowOrigins = [0]
    storage.contentHeight = layout.height
    let model = AppModel(launchMode: .offlineTesting)
    let actions = NativeTimelineRowActions(
        loadEarlier: {},
        openReply: { _ in },
        reply: nil,
        retry: { _ in },
        edit: { _, _ in },
        markUnread: { _ in },
        delete: { _ in },
        react: { _, _ in },
        openThread: { _ in },
        submitComponent: { _, _, _, _ in }
    )

    func makeCanvas() -> NativeTimelineCanvasView {
        let canvas = NativeTimelineCanvasView(
            frame: CGRect(x: 0, y: 0, width: 560, height: layout.height)
        )
        canvas.apply(
            storage: storage,
            model: model,
            actions: actions,
            viewportWidth: 560,
            minimumHeight: layout.height,
            bottomSpacerHeight: 0,
            contentOriginY: 0
        )
        canvas.reconcileSpoilerOverlaysForTesting()
        return canvas
    }

    let firstCanvas = makeCanvas()
    let secondCanvas = makeCanvas()
    let key = NativeTimelineComponentRevealKey.attachment(
        messageID: message.id,
        attachmentID: "shared-spoiler"
    )
    let coverFrame = try #require(
        firstCanvas.spoilerOverlayFramesForTesting[key]
    )
    #expect(
        firstCanvas.hitTest(
            CGPoint(x: coverFrame.midX, y: coverFrame.midY)
        ) is NativeTimelineSpoilerOverlayHost
    )
    #expect(secondCanvas.spoilerOverlayFramesForTesting[key] != nil)

    let compactLayout = NativeTimelineRowLayout.make(
        item: item,
        width: 420
    )
    let compactStorage = NativeTimelineCanvasStorage()
    compactStorage.items = [item]
    compactStorage.layouts = [compactLayout]
    compactStorage.rowOrigins = [0]
    compactStorage.contentHeight = compactLayout.height
    firstCanvas.apply(
        storage: compactStorage,
        model: model,
        actions: actions,
        viewportWidth: 420,
        minimumHeight: compactLayout.height,
        bottomSpacerHeight: 0,
        contentOriginY: 0
    )
    firstCanvas.reconcileSpoilerOverlaysForTesting()
    let compactCoverFrame = try #require(
        firstCanvas.spoilerOverlayFramesForTesting[key]
    )
    #expect(
        compactCoverFrame
            == compactLayout.attachmentRegions[0].frame
    )
    #expect(compactCoverFrame != coverFrame)

    model.timelineSpoilerRevealStore.revealMedia(key)

    #expect(firstCanvas.spoilerOverlayFramesForTesting.isEmpty)
    #expect(secondCanvas.spoilerOverlayFramesForTesting.isEmpty)
    let returningCanvas = makeCanvas()
    #expect(returningCanvas.spoilerOverlayFramesForTesting.isEmpty)
}

@Test func `benchmark startup waits for real quiet display frames`() {
    #expect(
        !NativeTimelineBenchmarkStartupPolicy.isReady(
            completedTicks: 0,
            uptime: 10,
            lastDelayedTickUptime: 0
        )
    )
    #expect(
        !NativeTimelineBenchmarkStartupPolicy.isReady(
            completedTicks: 1,
            uptime: 10,
            lastDelayedTickUptime: 0
        )
    )
    #expect(
        !NativeTimelineBenchmarkStartupPolicy.isReady(
            completedTicks: 2,
            uptime: 10.05,
            lastDelayedTickUptime: 10
        )
    )
    #expect(
        NativeTimelineBenchmarkStartupPolicy.isReady(
            completedTicks: 2,
            uptime: 10.10,
            lastDelayedTickUptime: 10
        )
    )
}

@Test
func `text spoiler reveal state stays scoped to its exact native text region`() {
    let embedRegion = NativeTimelineTextRegion.embed(
        embedID: "embed",
        textIndex: 1
    )
    let componentRegion = NativeTimelineTextRegion.component(
        layoutIndex: 2,
        textIndex: 3
    )
    var state = NativeTimelineTextSpoilerRevealState()

    state.reveal(region: .content, rangeLocation: 4)
    state.reveal(region: embedRegion, rangeLocation: 0)
    state.reveal(region: componentRegion, rangeLocation: 7)

    #expect(state.locations(in: .content) == [4])
    #expect(state.locations(in: embedRegion) == [0])
    #expect(state.locations(in: componentRegion) == [7])
    #expect(
        state.locations(
            in: .embed(embedID: "embed", textIndex: 0)
        ).isEmpty
    )
    #expect(
        state.locations(
            in: .component(layoutIndex: 1, textIndex: 3)
        ).isEmpty
    )
}

@Test
@MainActor
func `hidden text spoilers stay private to accessibility until revealed`() {
    let value = NSMutableAttributedString(
        string: "before secret after",
        attributes: [.font: NSFont.systemFont(ofSize: 15)]
    )
    value.addAttribute(
        .discordMarkdownSpoiler,
        value: NSNumber(value: true),
        range: NSRange(location: 7, length: 6)
    )

    #expect(
        NativeTimelineTextAccessibilityPresentation.text(
            value,
            revealedLocations: []
        ) == "before Spoiler after"
    )
    #expect(
        NativeTimelineTextAccessibilityPresentation
            .hiddenSpoilerRanges(
                in: value,
                revealedLocations: []
            ) == [NSRange(location: 7, length: 6)]
    )
    #expect(
        NativeTimelineTextAccessibilityPresentation.text(
            value,
            revealedLocations: [7]
        ) == "before secret after"
    )
    #expect(
        NativeTimelineTextHitTester.rangeFrame(
            value: value,
            framesetter: CTFramesetterCreateWithAttributedString(value),
            frame: CGRect(x: 0, y: 0, width: 240, height: 40),
            range: NSRange(location: 7, length: 6)
        ) != nil
    )
}

@Test
@MainActor
func `inline rich tokens inherit their enclosing spoiler`() {
    let source = "before ||<@&10> and <:glow:123>|| after"
    let prepared = RichMessageAttributedText.prepare(source: source)
    let value = NativeTimelineCoreText.make(
        prepared: prepared,
        emojiSize: 18,
        mentionPresentations: [:]
    )
    let fullRange = NSRange(location: 0, length: value.length)
    var spoilerRanges: [NSRange] = []
    value.enumerateAttribute(
        .discordMarkdownSpoiler,
        in: fullRange
    ) { rawValue, range, _ in
        guard (rawValue as? NSNumber)?.boolValue == true else {
            return
        }
        spoilerRanges.append(range)
    }

    #expect(spoilerRanges.count == 1)
    #expect(
        NativeTimelineTextAccessibilityPresentation.text(
            value,
            revealedLocations: []
        ) == "before Spoiler after"
    )
}

@Test func `native message menu preserves the pre CoreText presentation contract`() {
    #expect(
        NativeTimelineMessageMenuPolicy.entries(
            canEdit: true,
            canRetry: false,
            canReply: true
        ) == [
            .action(
                .addReaction,
                title: "Add Reaction",
                systemImage: "face.smiling.inverse"
            ),
            .action(
                .reply,
                title: "Reply",
                systemImage: "arrowshape.turn.up.left"
            ),
            .action(
                .markUnread,
                title: "Mark Unread",
                systemImage: "envelope.badge"
            ),
            .action(
                .editMessage,
                title: "Edit Message",
                systemImage: "pencil"
            ),
            .action(
                .copyText,
                title: "Copy Text",
                systemImage: "doc.on.doc"
            ),
            .separator,
            .action(
                .deleteMessage,
                title: "Delete Message",
                systemImage: "trash",
                isDestructive: true
            ),
        ]
    )

    #expect(
        NativeTimelineMessageMenuPolicy.entries(
            canEdit: false,
            canRetry: true,
            canReply: false
        ) == [
            .action(
                .retrySending,
                title: "Retry Sending",
                systemImage: "arrow.clockwise"
            ),
            .separator,
            .action(
                .addReaction,
                title: "Add Reaction",
                systemImage: "face.smiling.inverse"
            ),
            .action(
                .markUnread,
                title: "Mark Unread",
                systemImage: "envelope.badge"
            ),
            .action(
                .copyText,
                title: "Copy Text",
                systemImage: "doc.on.doc"
            ),
        ]
    )
}

@Test func `native author profile hitboxes do not cover message text`() {
    let avatar = CGRect(x: 14, y: 3, width: 38, height: 38)
    let author = CGRect(x: 64, y: 3, width: 86, height: 16)
    let frames = NativeTimelineAuthorProfileGeometry.hitFrames(
        avatarFrame: avatar,
        authorFrame: author
    )

    #expect(frames == [avatar, author])
    #expect(
        NativeTimelineAuthorProfileGeometry.hitFrame(
            at: CGPoint(x: 30, y: 24),
            avatarFrame: avatar,
            authorFrame: author
        ) == avatar
    )
    #expect(
        NativeTimelineAuthorProfileGeometry.hitFrame(
            at: CGPoint(x: 90, y: 10),
            avatarFrame: avatar,
            authorFrame: author
        ) == author
    )
    #expect(
        NativeTimelineAuthorProfileGeometry.hitFrame(
            at: CGPoint(x: 90, y: 27),
            avatarFrame: avatar,
            authorFrame: author
        ) == nil
    )
    #expect(avatar.union(author).contains(CGPoint(x: 90, y: 27)))
}

@Test func `native scrolling paints uncached rows without synchronous rasterization`() {
    #expect(
        NativeTimelineScrollingRenderPolicy.usesDirectPainter(
            isScrolling: true,
            hasCachedBitmap: false
        )
    )
    #expect(
        !NativeTimelineScrollingRenderPolicy.usesDirectPainter(
            isScrolling: true,
            hasCachedBitmap: true
        )
    )
    #expect(
        !NativeTimelineScrollingRenderPolicy.usesDirectPainter(
            isScrolling: false,
            hasCachedBitmap: false
        )
    )
}

@MainActor
@Test func `retained row media survives volatile cache eviction`() throws {
    let key = NativeTimelineMediaKey.media(try #require(URL(
        string: "https://cdn.discordapp.com/attachments/1/2/pinned.png"
    )))
    let image = NSImage(size: NSSize(width: 32, height: 32))
    let owner = UUID()
    let store = NativeTimelineMediaStore.shared
    store.cacheImageForTesting(image, for: key)
    store.pinLoadedImages(for: [key], owner: owner)
    store.evictVolatileImageForTesting(for: key)

    #expect((store.image(for: key) as AnyObject?) === image)

    store.releasePinnedImages(owner: owner)
    #expect(store.image(for: key) == nil)
}

@MainActor
@Test func `native reply media dependencies include the replied-to author avatar`() throws {
    let avatarURL = try #require(
        URL(string: "https://cdn.discordapp.com/avatars/2/reply.webp")
    )
    let preview = MessageReplyPreview(
        messageID: MessageID(rawValue: 22),
        author: User(
            id: UserID(rawValue: 2),
            username: "reply-author",
            displayName: "Reply Author",
            avatarURL: avatarURL
        ),
        content: "original message"
    )

    #expect(
        NativeTimelineReplyMediaPolicy.avatarKey(for: preview)
            == .avatar(avatarURL)
    )
    #expect(NativeTimelineReplyMediaPolicy.avatarKey(for: nil) == nil)
}

@MainActor @Test
func `timeline presentation invalidation clears cached render state`() {
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 720, height: 480)
    )
    canvas.needsDisplay = false

    canvas.invalidatePresentationCaches()

    #expect(canvas.presentationCacheInvalidationCount == 1)
}

@MainActor @Test
func `native scrolling removes installed pointer tracking immediately`() {
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 720, height: 480)
    )
    let window = NSWindow(
        contentRect: canvas.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = canvas
    canvas.updateTrackingAreas()
    #expect(!canvas.trackingAreas.isEmpty)

    canvas.dismissHoverPresentationForScroll()

    #expect(canvas.trackingAreas.isEmpty)
}

@Test func `short native timeline fills above its rows and footer`() {
    let top = NativeMessageTimelineLayoutPolicy.shortContentTopInset(
        viewportHeight: 700,
        contentHeight: 180,
        bottomInset: 76,
        verticalPadding: 8
    )
    #expect(top == 444)
    let documentHeight = NativeMessageTimelineLayoutPolicy.documentHeight(
        contentOriginY: top,
        contentHeight: 180,
        bottomInset: 76,
        viewportHeight: 700
    )
    #expect(documentHeight == 700)
    #expect(
        NativeMessageTimelineLayoutPolicy.clampedDocumentY(
            proposedY: .greatestFiniteMagnitude,
            contentHeight: documentHeight,
            viewportHeight: 700,
            bottomInset: 0
        ) == 0
    )
    #expect(
        !NativeMessageTimelineLayoutPolicy.showsVerticalScroller(
            contentHeight: 180,
            viewportHeight: 700,
            bottomInset: 76,
            verticalPadding: 8
        )
    )
    #expect(
        !NativeMessageTimelineLayoutPolicy.showsVerticalScroller(
            contentHeight: 616,
            viewportHeight: 700,
            bottomInset: 76,
            verticalPadding: 8
        )
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.showsVerticalScroller(
            contentHeight: 617,
            viewportHeight: 700,
            bottomInset: 76,
            verticalPadding: 8
        )
    )

    let preservedEmptyChannelTop =
        NativeMessageTimelineLayoutPolicy.shortContentTopInset(
            viewportHeight: 740,
            contentHeight: 179,
            bottomInset:
                ChatDetailLayoutPolicy.defaultFloatingFooterHeight
                + ChatDetailLayoutPolicy.timelineBottomPadding,
            verticalPadding: ChatDetailLayoutPolicy.timelineTopPadding
        )
    #expect(preservedEmptyChannelTop == 471)
}

@Test func `native timeline bottom scroll includes the floating footer inset`() {
    let documentHeight = NativeMessageTimelineLayoutPolicy.documentHeight(
        contentOriginY: 8,
        contentHeight: 2_000,
        bottomInset: 76,
        viewportHeight: 700
    )
    let y = NativeMessageTimelineLayoutPolicy.clampedDocumentY(
        proposedY: .greatestFiniteMagnitude,
        contentHeight: documentHeight,
        viewportHeight: 700,
        bottomInset: 0
    )
    #expect(documentHeight == 2_084)
    #expect(y == 1_384)
}

@Test func `native timeline distinguishes the true bottom from a nearby viewport`() {
    #expect(
        NativeMessageTimelineLayoutPolicy.isAtTrueBottom(
            documentHeight: 2_084,
            visibleMaximumY: 2_084
        )
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.isAtTrueBottom(
            documentHeight: 2_084,
            visibleMaximumY: 2_083
        )
    )
    #expect(
        !NativeMessageTimelineLayoutPolicy.isAtTrueBottom(
            documentHeight: 2_084,
            visibleMaximumY: 2_080
        )
    )
}

@Test func `native timeline prepends consume reserved document coordinates`() {
    let absorbed =
        NativeMessageTimelineLayoutPolicy.consumingLeadingHistoryReserve(
            65_536,
            prependedHeight: 3_200,
            chunk: 65_536
        )
    #expect(absorbed.reserve == 62_336)
    #expect(!absorbed.grew)

    let replenished =
        NativeMessageTimelineLayoutPolicy.consumingLeadingHistoryReserve(
            1_000,
            prependedHeight: 3_200,
            chunk: 65_536
        )
    #expect(replenished.reserve == 63_336)
    #expect(replenished.grew)
}

@Test func `native timeline exposes a bounded provisional history page`() {
    #expect(
        NativeMessageTimelineLayoutPolicy.provisionalHistoryDepth(
            reserve: 65_536,
            viewportHeight: 800
        ) == 8_000
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.provisionalHistoryMinimumY(
            reserve: 65_536,
            viewportHeight: 800,
            allowsProvisionalHistory: true
        ) == 57_536
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.provisionalHistoryMinimumY(
            reserve: 65_536,
            viewportHeight: 800,
            allowsProvisionalHistory: false
        ) == 65_536
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.provisionalHistoryMinimumY(
            reserve: 1_200,
            viewportHeight: 800,
            allowsProvisionalHistory: true
        ) == 0
    )
}

@Test func `native timeline only presents history skeletons while provisional history is active`() {
    #expect(
        !NativeMessageTimelineLayoutPolicy.showsHistorySkeleton(
            hasMoreMessages: true,
            isLoadingEarlier: false,
            followsMaterializedHistoryBoundary: false
        )
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.showsHistorySkeleton(
            hasMoreMessages: true,
            isLoadingEarlier: true,
            followsMaterializedHistoryBoundary: false
        )
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.showsHistorySkeleton(
            hasMoreMessages: true,
            isLoadingEarlier: false,
            followsMaterializedHistoryBoundary: true
        )
    )
    #expect(
        !NativeMessageTimelineLayoutPolicy.showsHistorySkeleton(
            hasMoreMessages: false,
            isLoadingEarlier: true,
            followsMaterializedHistoryBoundary: true
        )
    )
}

@MainActor @Test
func `native earlier loader is hidden until automatic pagination starts`() {
    let width: CGFloat = 620
    let idle = NativeTimelineLoaderLayout.make(
        isLoading: false,
        kind: .messages,
        width: width
    )
    let loading = NativeTimelineLoaderLayout.make(
        isLoading: true,
        kind: .messages,
        width: width
    )
    let reference = NSHostingController(
        rootView: NativeTimelineEarlierLoaderReference()
    ).sizeThatFits(in: CGSize(width: width, height: 1_000))

    #expect(idle.height == 0)
    #expect(idle.controlFrame == .zero)
    #expect(idle.labelFrame == .zero)
    #expect(idle.spinnerFrame == nil)
    #expect(loading.height == reference.height)
    #expect(loading.controlFrame.midX == width / 2)
    #expect(loading.controlFrame.minY == 10)
    #expect(loading.height == 36)
    #expect(loading.controlFrame.size == CGSize(width: 155, height: 16))
    #expect(loading.spinnerFrame?.size == CGSize(width: 16, height: 16))
}

@MainActor @Test
func `native unread boundary preserves the pre CoreText separator height`() {
    let width: CGFloat = 620
    let reference = NSHostingController(
        rootView: NewMessagesSeparator()
    ).sizeThatFits(in: CGSize(width: width, height: 1_000))
    let author = User(
        id: UserID(rawValue: 1),
        username: "fixture",
        displayName: "Fixture"
    )
    let row = MessageRowPresentation(
        message: Message(
            id: MessageID(rawValue: 2),
            channelID: ChannelID(rawValue: 3),
            author: author,
            content: "Unread message"
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let ordinary = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: width
    )
    let unread = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: true,
            isHighlighted: false
        ),
        width: width
    )

    #expect(
        reference.height
            == NativeTimelineUnreadSeparatorMetrics.rowHeight
    )
    #expect(unread.unreadSeparatorFrame?.height == reference.height)
    #expect(
        unread.highlightFrame?.minY
            == NativeTimelineUnreadSeparatorMetrics.rowHeight
    )
    #expect(
        unread.avatarFrame?.minY
            == NativeTimelineUnreadSeparatorMetrics.rowHeight
                + MessageRowLayoutMetrics.visibleHighlightInset
    )
    let lineY =
        NativeTimelineUnreadSeparatorMetrics.rowHeight / 2
    let precedingVisibleGap =
        MessageRowLayoutMetrics.visibleHighlightInset + lineY
    let followingVisibleGap =
        (unread.avatarFrame?.minY ?? 0) - lineY
    #expect(precedingVisibleGap == followingVisibleGap)
    #expect(
        unread.height - ordinary.height
            == NativeTimelineUnreadSeparatorMetrics.rowHeight
                - MessageRowLayoutMetrics.separation(
                    startsGroup: true,
                    highlightTopInset:
                        MessageRowLayoutMetrics.visibleHighlightInset
                )
    )
}

@MainActor @Test
func `native day separator preserves the pre CoreText label metrics`() {
    let date = Date(timeIntervalSince1970: 1_774_896_000)
    let label = date.formatted(
        .dateTime.day().month(.wide).year()
    )
    let referenceLabel = NSHostingController(
        rootView: Text(
            date,
            format: .dateTime.day().month(.wide).year()
        )
        .font(.caption2.weight(.semibold))
        .fixedSize()
    ).sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
    let referenceSeparator = NSHostingController(
        rootView: DateSeparator(date: date)
    ).sizeThatFits(in: CGSize(width: 620, height: 1_000))
    let frame = CGRect(
        x: 14,
        y: 0,
        width: 592,
        height: NativeTimelineDateSeparatorMetrics.rowHeight
    )
    let labelFrame = NativeTimelineDateSeparatorMetrics.labelFrame(
        for: label,
        in: frame
    )

    #expect(referenceLabel.height == 13)
    #expect(NativeTimelineDateSeparatorMetrics.font.pointSize == 10)
    #expect(
        labelFrame.size
            == CGSize(
                width: referenceLabel.width,
                height: referenceLabel.height
            )
    )
    #expect(referenceSeparator.height == 37)
    #expect(
        NativeTimelineDateSeparatorMetrics.rowHeight
            == referenceSeparator.height
    )
    #expect(
        labelFrame.minY
            == NativeTimelineDateSeparatorMetrics.verticalPadding
    )

    let author = User(
        id: UserID(rawValue: 4),
        username: "fixture",
        displayName: "Fixture"
    )
    let row = MessageRowPresentation(
        message: Message(
            id: MessageID(rawValue: 5),
            channelID: ChannelID(rawValue: 6),
            author: author,
            content: "First message of the day",
            timestamp: date
        ),
        startsGroup: true,
        startsDay: true,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )
    #expect(
        layout.highlightFrame?.minY
            == NativeTimelineDateSeparatorMetrics.rowHeight
    )
    #expect(
        layout.avatarFrame?.minY
            == NativeTimelineDateSeparatorMetrics.rowHeight
                + MessageRowLayoutMetrics.visibleHighlightInset
    )
    let separatorLineY =
        NativeTimelineDateSeparatorMetrics.rowHeight / 2
    let precedingVisibleGap =
        MessageRowLayoutMetrics.visibleHighlightInset
            + separatorLineY
    let followingVisibleGap =
        (layout.avatarFrame?.minY ?? 0) - separatorLineY
    #expect(precedingVisibleGap == followingVisibleGap)
}

@MainActor @Test
func `native reply preview preserves the pre CoreText caption metrics`() {
    let author = "Juniper Reed"
    let summary = "A compact reply preview"
    let referenceAuthor = NSHostingController(
        rootView: Text(author)
            .font(.caption2.weight(.semibold))
            .fixedSize()
    ).sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
    let referenceSummary = NSHostingController(
        rootView: Text(summary)
            .font(.caption)
            .fixedSize()
    ).sizeThatFits(in: CGSize(width: 1_000, height: 1_000))

    #expect(NativeTimelineReplyMetrics.authorFont.pointSize == 10)
    #expect(NativeTimelineReplyMetrics.summaryFont.pointSize == 10)
    #expect(
        NativeTimelineReplyMetrics.textWidth(
            author,
            font: NativeTimelineReplyMetrics.authorFont
        ) == referenceAuthor.width
    )
    #expect(
        NativeTimelineReplyMetrics.textWidth(
            summary,
            font: NativeTimelineReplyMetrics.summaryFont
        ) == referenceSummary.width
    )
}

@MainActor @Test
func `native generated messages preserve the pre CoreText body font`() throws {
    let author = User(
        id: UserID(rawValue: 41),
        username: "nova",
        displayName: "Nova Chen"
    )
    let generated = Message(
        id: MessageID(rawValue: 42),
        channelID: ChannelID(rawValue: 43),
        author: author,
        content: "",
        type: .channelPinnedMessage
    )
    let ordinary = Message(
        id: MessageID(rawValue: 44),
        channelID: generated.channelID,
        author: author,
        content: "Ordinary rich message text"
    )
    let generatedPlan = NativeTimelineTextPlan.make(for: generated)
    let ordinaryPlan = NativeTimelineTextPlan.make(for: ordinary)
    let generatedText = try #require(generatedPlan.attributedText?.value)
    let generatedFont = try #require(
        generatedText.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont
    )
    let label = SystemMessagePresentation.label(for: generated)
    let reference = NSHostingController(
        rootView: Text(label)
            .font(.body)
            .fixedSize()
    ).sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
    let attributedWidth = ceil(generatedText.size().width)

    #expect(generatedPlan.baseFontSize == 13)
    #expect(generatedFont.pointSize == 13)
    #expect(attributedWidth == reference.width)
    #expect(ordinaryPlan.baseFontSize == 15)
}

@MainActor @Test
func `native compact timestamp preserves the pre CoreText hover column`() {
    let author = User(
        id: UserID(rawValue: 51),
        username: "rowan",
        displayName: "Rowan Vale"
    )
    let message = Message(
        id: MessageID(rawValue: 52),
        channelID: ChannelID(rawValue: 53),
        author: author,
        content: "A compact continuation"
    )
    let compact = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: false,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )
    let first = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )
    let frame = compact.compactTimestampFrame

    #expect(
        frame?.size
            == CGSize(
                width: MessageRowLayoutMetrics.avatarDiameter,
                height: MessageRowLayoutMetrics.compactContentHeight
            )
    )
    #expect(frame?.minX == 14)
    #expect(first.compactTimestampFrame == nil)
    #expect(NativeTimelineCompactTimestampMetrics.font.pointSize == 10)
    #expect(
        NativeTimelineCompactTimestampHitTesting.contains(
            CGPoint(x: 15, y: 107),
            rowOrigin: 100,
            frame: frame
        )
    )
    #expect(
        !NativeTimelineCompactTimestampHitTesting.contains(
            CGPoint(x: 64, y: 107),
            rowOrigin: 100,
            frame: frame
        )
    )
}

@Test func `native timeline width reflow top pins an intersecting legacy row`() {
    #expect(
        NativeMessageTimelineLayoutPolicy.widthChangeAnchorOffset(from: -371)
            == ChatDetailLayoutPolicy.timelineWidthReflowTopInset
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.widthChangeAnchorOffset(from: 28)
            == 28
    )
    #expect(
        !NativeMessageTimelineLayoutPolicy.prefersVisibleMessageBeginning(
            from: 861,
            to: 701
        )
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.prefersVisibleMessageBeginning(
            from: 701,
            to: 861
        )
    )
}

@Test func `native timeline identifies prepended rows without replacing existing rows`() {
    let insertions = NativeMessageTimelineLayoutPolicy.insertionIndexes(
        preserving: ["loader", "101", "102", "103"],
        in: ["loader", "51", "52", "101", "102", "103"]
    )

    #expect(insertions == IndexSet(integersIn: 1 ..< 3))
}

@Test func `native timeline rejects incremental insertion when existing order changes`() {
    let insertions = NativeMessageTimelineLayoutPolicy.insertionIndexes(
        preserving: ["loader", "101", "102"],
        in: ["loader", "102", "101"]
    )

    #expect(insertions == nil)
}

@Test func `native timeline identifies removed rows without replacing survivors`() {
    let removals = NativeMessageTimelineLayoutPolicy.removalIndexes(
        preserving: ["101", "103", "105"],
        in: ["101", "102", "103", "104", "105"]
    )

    #expect(removals == IndexSet([1, 3]))
}

@Test func `native timeline rejects incremental removal when survivors reorder`() {
    let removals = NativeMessageTimelineLayoutPolicy.removalIndexes(
        preserving: ["103", "101"],
        in: ["101", "102", "103"]
    )

    #expect(removals == nil)
}

@Test func `native timeline only consumes rows at a published snapshot boundary`() {
    #expect(
        !NativeMessageTimelineLayoutPolicy.acceptsRowSnapshot(
            itemsAreEmpty: false,
            conversationChanged: false,
            publishedRevision: 41,
            appliedRevision: 41
        )
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.acceptsRowSnapshot(
            itemsAreEmpty: false,
            conversationChanged: false,
            publishedRevision: 42,
            appliedRevision: 41
        )
    )
    #expect(
        NativeMessageTimelineLayoutPolicy.acceptsRowSnapshot(
            itemsAreEmpty: false,
            conversationChanged: true,
            publishedRevision: 41,
            appliedRevision: 41
        )
    )
}

@Test func `thread beginning transition rebuilds the first message boundary`() {
    #expect(
        NativeMessageTimelineLayoutPolicy
            .requiresFirstMessageBoundaryRebuild(
                from: nil,
                to: false
            )
    )
    #expect(
        NativeMessageTimelineLayoutPolicy
            .requiresFirstMessageBoundaryRebuild(
                from: false,
                to: nil
            )
    )
    #expect(
        !NativeMessageTimelineLayoutPolicy
            .requiresFirstMessageBoundaryRebuild(
                from: false,
                to: false
            )
    )
}

@Test func `native timeline chains successful earlier history pages`() {
    #expect(
        NativeTimelineAutomaticHistoryPolicy.shouldReevaluateAfterUpdate(
            wasLoadingEarlier: true,
            isLoadingEarlier: false,
            previousRowCount: 100,
            currentRowCount: 150
        )
    )
    #expect(
        !NativeTimelineAutomaticHistoryPolicy.shouldReevaluateAfterUpdate(
            wasLoadingEarlier: true,
            isLoadingEarlier: false,
            previousRowCount: 100,
            currentRowCount: 100
        )
    )
    #expect(
        !NativeTimelineAutomaticHistoryPolicy.shouldReevaluateAfterUpdate(
            wasLoadingEarlier: false,
            isLoadingEarlier: false,
            previousRowCount: 100,
            currentRowCount: 150
        )
    )
}

@Test func `native timeline keeps a visible loader for an unresolved page`() {
    #expect(
        NativeTimelineEarlierLoaderPolicy.includesLoader(
            hasMoreMessages: false,
            isLoadingEarlier: true
        )
    )
    #expect(
        NativeTimelineEarlierLoaderPolicy.includesLoader(
            hasMoreMessages: true,
            isLoadingEarlier: false
        )
    )
    #expect(
        !NativeTimelineEarlierLoaderPolicy.includesLoader(
            hasMoreMessages: false,
            isLoadingEarlier: false
        )
    )
}

@MainActor @Test
func `native channel beginning preserves the pre CoreText intrinsic height`() {
    let channel = Channel(
        id: ChannelID(rawValue: 41),
        guildID: GuildID(rawValue: 42),
        name: "announcements",
        topic: "Product updates and community news.",
        kind: .announcement
    )
    let beginning = NativeTimelineBeginning.channel(
        channel,
        rulesChannelID: channel.id
    )
    let width: CGFloat = 420
    let layout = NativeTimelineBeginningLayout.make(
        beginning: beginning,
        width: width
    )
    let reference = NSHostingController(
        rootView: ChannelBeginningView(
            channel: channel,
            rulesChannelID: channel.id
        )
    ).sizeThatFits(in: CGSize(width: width, height: 10_000))

    #expect(beginning.symbolName == "newspaper.fill")
    #expect(beginning.title == "Welcome to #announcements!")
    #expect(beginning.description == "Product updates and community news.")
    #expect(abs(layout.height - reference.height) <= 1)
}

@MainActor @Test
func `native channel and thread beginnings expose selectable Core Text regions`() {
    let beginning = NativeTimelineBeginning.thread(
        id: ChannelID(rawValue: 49),
        title: "Rich message feedback",
        starterName: "Nova Chen",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let layout = NativeTimelineBeginningLayout.make(
        beginning: beginning,
        width: 428
    )
    let title = NativeTimelineBeginningText.title(beginning)
    let description = NativeTimelineBeginningText.description(beginning)

    #expect(title.value.string == "Rich message feedback")
    #expect(description.value.string == "Started by Nova Chen")
    #expect(beginning.isDescriptionSelectable)
    #expect(
        !NativeTimelineBeginning.thread(
            id: ChannelID(rawValue: 50),
            title: "Unattributed thread",
            starterName: nil,
            startedAt: nil
        ).isDescriptionSelectable
    )

    func selectionRects(
        box: NativeTimelineAttributedTextBox,
        frame: CGRect
    ) -> [CGRect] {
        let textFrame = CTFramesetterCreateFrame(
            box.framesetter,
            CFRange(location: 0, length: box.value.length),
            CGPath(
                rect: CGRect(origin: .zero, size: frame.size),
                transform: nil
            ),
            nil
        )
        return NativeTimelineTextSelectionGeometry.rects(
            in: textFrame,
            outerFrame: frame,
            range: NSRange(location: 0, length: box.value.length)
        )
    }

    let titleRects = selectionRects(
        box: title,
        frame: layout.titleFrame
    )
    let descriptionRects = selectionRects(
        box: description,
        frame: layout.descriptionFrame
    )
    #expect(!titleRects.isEmpty)
    #expect(!descriptionRects.isEmpty)
    #expect(titleRects.allSatisfy { layout.titleFrame.intersects($0) })
    #expect(
        descriptionRects.allSatisfy {
            layout.descriptionFrame.intersects($0)
        }
    )
}

@MainActor @Test
func `native channel beginning configuration covers every unified conversation kind`() {
    let directMessage = NativeTimelineBeginning.channel(
        Channel(
            id: ChannelID(rawValue: 51),
            guildID: nil,
            name: "Maya",
            kind: .directMessage
        ),
        rulesChannelID: nil
    )
    let groupDirectMessage = NativeTimelineBeginning.channel(
        Channel(
            id: ChannelID(rawValue: 52),
            guildID: nil,
            name: "Design crew",
            kind: .groupDirectMessage
        ),
        rulesChannelID: nil
    )
    let announcement = NativeTimelineBeginning.channel(
        Channel(
            id: ChannelID(rawValue: 53),
            guildID: GuildID(rawValue: 42),
            name: "release-notes",
            kind: .announcement
        ),
        rulesChannelID: nil
    )
    let voice = NativeTimelineBeginning.channel(
        Channel(
            id: ChannelID(rawValue: 54),
            guildID: GuildID(rawValue: 42),
            name: "Studio Lounge",
            kind: .voice
        ),
        rulesChannelID: nil
    )

    #expect(directMessage.title == "Beginning of your conversation with Maya")
    #expect(
        directMessage.description
            == "This is the beginning of your direct message history."
    )
    #expect(directMessage.symbolName == "person.fill")
    #expect(
        groupDirectMessage.title
            == "Beginning of your conversation with Design crew"
    )
    #expect(groupDirectMessage.symbolName == "person.2.fill")
    #expect(announcement.title == "Welcome to #release-notes!")
    #expect(announcement.symbolName == "megaphone.fill")
    #expect(voice.title == "Welcome to Studio Lounge!")
    #expect(
        voice.description
            == "This is the start of the Studio Lounge voice channel chat."
    )
    #expect(voice.symbolName == "bubble.left.fill")
}

@MainActor @Test
func `channel and thread configurations instantiate the same native canvas engine`() {
    let model = AppModel(launchMode: .offlineTesting)

    for conversation in [
        NativeTimelineConversation.channel(ChannelID(rawValue: 210)),
        .thread(ChannelID(rawValue: 43)),
    ] {
        let timeline = NativeMessageTimelineView(
            model: model,
            conversation: conversation,
            beginning: nil,
            firstMessageStartsDayOverride: nil,
            hasMoreMessages: false,
            isLoadingEarlier: false,
            bottomContentInset: 0,
            unreadMessageID: nil,
            highlightedMessageID: nil,
            scrollRequest: nil,
            runsPerformanceAutoScroll: false,
            loadEarlier: {},
            openReply: { _ in },
            onScrollActivityChange: { _ in },
            onScrollStateChange: { _ in },
            onUserScrollBegan: {},
            onUserScrollEnded: { _ in }
        )
        let coordinator = timeline.makeCoordinator()
        let scrollView = coordinator.makeScrollView()

        let documentView =
            scrollView.documentView as? NativeTimelineDocumentView
        #expect(
            documentView?.subviews.contains {
                $0 is NativeTimelineCanvasView
            } == true
        )

        coordinator.stopObserving()
    }
}

@MainActor @Test
func `first viewport layout keeps bounded canvas frame and bounds synchronized`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let timeline = NativeMessageTimelineView(
        model: model,
        conversation: .channel(ChannelID(rawValue: 210)),
        beginning: nil,
        firstMessageStartsDayOverride: nil,
        hasMoreMessages: false,
        isLoadingEarlier: false,
        bottomContentInset: 0,
        unreadMessageID: nil,
        highlightedMessageID: nil,
        scrollRequest: nil,
        runsPerformanceAutoScroll: false,
        loadEarlier: {},
        openReply: { _ in },
        onScrollActivityChange: { _ in },
        onScrollStateChange: { _ in },
        onUserScrollBegan: {},
        onUserScrollEnded: { _ in }
    )
    let coordinator = timeline.makeCoordinator()
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = CGRect(x: 0, y: 0, width: 820, height: 700)
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.update(parent: timeline, scrollView: scrollView)

    let documentView = try #require(
        scrollView.documentView as? NativeTimelineDocumentView
    )
    let canvas = try #require(
        documentView.subviews.first {
            $0 is NativeTimelineCanvasView
        } as? NativeTimelineCanvasView
    )

    #expect(abs(canvas.frame.width - scrollView.contentView.bounds.width) < 0.5)
    #expect(abs(canvas.frame.origin.y - canvas.bounds.origin.y) < 0.5)
    #expect(abs(canvas.frame.height - canvas.bounds.height) < 0.5)

    coordinator.stopObserving()
}

@MainActor @Test
func `short timeline is bottom aligned on its first frame and stays there while resizing`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 91_001)
    let timeline = NativeMessageTimelineView(
        model: model,
        conversation: .channel(channelID),
        beginning: .channel(
            Channel(
                id: channelID,
                guildID: GuildID(rawValue: 91_000),
                name: "short-history",
                kind: .text
            ),
            rulesChannelID: nil
        ),
        firstMessageStartsDayOverride: nil,
        hasMoreMessages: false,
        isLoadingEarlier: false,
        bottomContentInset: 76,
        unreadMessageID: nil,
        highlightedMessageID: nil,
        initialScrollTarget: .bottom,
        scrollRequest: nil,
        runsPerformanceAutoScroll: false,
        loadEarlier: {},
        openReply: { _ in },
        onScrollActivityChange: { _ in },
        onScrollStateChange: { _ in },
        onUserScrollBegan: {},
        onUserScrollEnded: { _ in }
    )
    let coordinator = timeline.makeCoordinator()
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = CGRect(x: 0, y: 0, width: 820, height: 700)
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.update(parent: timeline, scrollView: scrollView)
    coordinator.reconcileViewportGeometryForTesting()

    let firstOrigin = coordinator.contentOriginYForTesting
    #expect(coordinator.hasAppliedInitialPositionForTesting)
    #expect(coordinator.scrollStateForTesting.isNearBottom)
    #expect(!scrollView.hasVerticalScroller)
    #expect(
        abs(
            (scrollView.documentView?.frame.height ?? 0)
                - scrollView.contentView.bounds.height
        ) < 0.5
    )

    scrollView.frame.size.height = 900
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.reconcileViewportGeometryForTesting()

    #expect(coordinator.scrollStateForTesting.isNearBottom)
    #expect(!scrollView.hasVerticalScroller)
    #expect(
        abs(
            coordinator.contentOriginYForTesting
                - firstOrigin
                - 200
        ) < 0.5
    )
    coordinator.updateDocumentHeightForTesting(
        (scrollView.documentView?.frame.height ?? 0) + 240
    )
    #expect(coordinator.scrollStateForTesting.isNearBottom)
    #expect(scrollView.hasVerticalScroller)

    let threadID = ChannelID(rawValue: 91_002)
    let threadTimeline = NativeMessageTimelineView(
        model: model,
        conversation: .thread(threadID),
        beginning: .thread(
            id: threadID,
            title: "Short thread",
            starterName: "Fixture",
            startedAt: .now
        ),
        firstMessageStartsDayOverride: nil,
        hasMoreMessages: false,
        isLoadingEarlier: false,
        bottomContentInset: 76,
        unreadMessageID: nil,
        highlightedMessageID: nil,
        initialScrollTarget: .bottom,
        scrollRequest: nil,
        runsPerformanceAutoScroll: false,
        loadEarlier: {},
        openReply: { _ in },
        onScrollActivityChange: { _ in },
        onScrollStateChange: { _ in },
        onUserScrollBegan: {},
        onUserScrollEnded: { _ in }
    )
    coordinator.update(
        parent: threadTimeline,
        scrollView: scrollView
    )

    #expect(
        coordinator.initialPositionConversationForTesting
            == .thread(threadID)
    )
    #expect(coordinator.scrollStateForTesting.isNearBottom)
    coordinator.stopObserving()
}

@MainActor @Test
func `media rich timeline establishes unread context before display and preserves it while resizing`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let deadline = ContinuousClock.now + .seconds(1)
    while model.messages.count < 9,
          ContinuousClock.now < deadline
    {
        try await Task.sleep(for: .milliseconds(2))
    }
    let conversationID = try #require(model.selectedChannelID)
    let targetMessage = try #require(
        model.messages.dropFirst(4).dropLast(4).first
    )
    let timeline = NativeMessageTimelineView(
        model: model,
        conversation: .channel(conversationID),
        beginning: nil,
        firstMessageStartsDayOverride: nil,
        hasMoreMessages: false,
        isLoadingEarlier: false,
        bottomContentInset: 76,
        unreadMessageID: targetMessage.id,
        highlightedMessageID: nil,
        initialScrollTarget: .message(
            targetMessage.id,
            anchor: TimelineInitialPositionPolicy.unreadViewportAnchor
        ),
        scrollRequest: nil,
        runsPerformanceAutoScroll: false,
        loadEarlier: {},
        openReply: { _ in },
        onScrollActivityChange: { _ in },
        onScrollStateChange: { _ in },
        onUserScrollBegan: {},
        onUserScrollEnded: { _ in }
    )
    let coordinator = timeline.makeCoordinator()
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = CGRect(x: 0, y: 0, width: 820, height: 500)
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.update(parent: timeline, scrollView: scrollView)
    coordinator.reconcileViewportGeometryForTesting()

    let firstOffset = try #require(
        coordinator.messageOffsetFromViewportTopForTesting(
            targetMessage.id
        )
    )
    let rowHeight = try #require(
        coordinator.messageHeightForTesting(targetMessage.id)
    )
    let expectedOffset =
        (scrollView.contentView.bounds.height - rowHeight)
        * TimelineInitialPositionPolicy.unreadViewportAnchor.y
    #expect(coordinator.hasAppliedInitialPositionForTesting)
    #expect(abs(firstOffset - expectedOffset) < 1)
    #expect(!coordinator.scrollStateForTesting.isNearBottom)

    scrollView.frame.size.height = 650
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.reconcileViewportGeometryForTesting()

    let resizedOffset = try #require(
        coordinator.messageOffsetFromViewportTopForTesting(
            targetMessage.id
        )
    )
    #expect(abs(resizedOffset - firstOffset) < 1)
    #expect(!coordinator.scrollStateForTesting.isNearBottom)
    coordinator.updateDocumentHeightForTesting(
        (scrollView.documentView?.frame.height ?? 0) + 240
    )
    let settledOffset = try #require(
        coordinator.messageOffsetFromViewportTopForTesting(
            targetMessage.id
        )
    )
    #expect(abs(settledOffset - resizedOffset) < 1)
    #expect(!coordinator.scrollStateForTesting.isNearBottom)
    coordinator.stopObserving()
}

@MainActor @Test
func `reentrant first width layout preserves the newer canvas bounds`() {
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 1, height: 1)
    )
    let correctedBounds = CGRect(x: 0, y: 640, width: 820, height: 700)
    canvas.onWidthChange = { _ in
        // Model the synchronous coordinator relayout performed by the real
        // first width update.
        canvas.bounds = correctedBounds
    }

    canvas.installViewportGeometry(
        frame: CGRect(x: 0, y: 0, width: 820, height: 700),
        bounds: CGRect(x: 0, y: 0, width: 820, height: 700)
    )

    #expect(canvas.bounds == correctedBounds)
}

@MainActor @Test
func `native thread beginning and loader preserve thread surface configuration`() {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let title = "Media viewer should use a native presentation"
    let beginning = NativeTimelineBeginning.thread(
        id: ChannelID(rawValue: 43),
        title: title,
        starterName: "Maya",
        startedAt: startedAt
    )
    let width: CGFloat = 428
    let layout = NativeTimelineBeginningLayout.make(
        beginning: beginning,
        width: width
    )
    let reference = NSHostingController(
        rootView: NativeTimelineThreadBeginningReference(
            title: title,
            starterName: "Maya"
        )
    ).sizeThatFits(
        in: CGSize(
            width: width,
            height: 10_000
        )
    )

    #expect(beginning.symbolName == "bubble.left.and.bubble.right.fill")
    #expect(beginning.description == "Started by Maya")
    #expect(layout.titleFrame.width == width - 32)
    #expect(layout.dateSeparatorFrame?.height == 37)
    #expect(layout.height == reference.height + 37)
    #expect(
        NativeTimelineLoaderKind.replies.loadingLabel
            == "Loading earlier replies…"
    )
    #expect(!NativeTimelineConversation.thread(ChannelID(rawValue: 43)).supportsReply)
    #expect(NativeTimelineConversation.channel(nil).supportsReply)
}

@MainActor @Test
func `single line native thread beginning preserves the pre CoreText height`() {
    let width: CGFloat = 427
    let beginning = NativeTimelineBeginning.thread(
        id: ChannelID(rawValue: 45),
        title: "Rich message feedback",
        starterName: "Nova Chen",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let layout = NativeTimelineBeginningLayout.make(
        beginning: beginning,
        width: width
    )
    let reference = NSHostingController(
        rootView: NativeTimelineThreadBeginningReference(
            title: beginning.title,
            starterName: "Nova Chen"
        )
    ).sizeThatFits(
        in: CGSize(width: width, height: 10_000)
    )

    #expect(layout.height == reference.height + 37)
}

@Test
func `native timeline accessibility preserves media sticker and thread labels`() throws {
    let attachment = Attachment(
        id: "spoiler",
        filename: "SPOILER-layout.png",
        url: try #require(URL(string: "https://cdn.example/layout.png")),
        mediaType: "image/png",
        description: "Zoomed layout comparison",
        isSpoiler: true
    )
    let sticker = MessageSticker(
        id: "sticker",
        name: "Aurora wave",
        description: "Animated Aurora greeting"
    )
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 44),
        name: "Visual parity",
        messageCount: 3
    )

    #expect(
        NativeTimelineAccessibilityPresentation.attachmentLabel(attachment)
            == "Spoiler attachment, Zoomed layout comparison"
    )
    #expect(
        NativeTimelineAccessibilityPresentation.stickerLabel(sticker)
            == "Animated Aurora greeting"
    )
    #expect(
        NativeTimelineAccessibilityPresentation.threadLabel(thread)
            == "Visual parity, 3 replies"
    )
}

@Test
func `native timeline accessibility proxies stay within one viewport of visible content`() {
    let middle = NativeTimelineAccessibilityPolicy.bufferedViewport(
        around: CGRect(x: 0, y: 1_000, width: 620, height: 500),
        contentHeight: 10_000
    )
    let beginning = NativeTimelineAccessibilityPolicy.bufferedViewport(
        around: CGRect(x: 0, y: 0, width: 620, height: 500),
        contentHeight: 10_000
    )
    let ending = NativeTimelineAccessibilityPolicy.bufferedViewport(
        around: CGRect(x: 0, y: 9_700, width: 620, height: 500),
        contentHeight: 10_000
    )

    #expect(middle == CGRect(x: 0, y: 500, width: 620, height: 1_500))
    #expect(beginning == CGRect(x: 0, y: 0, width: 620, height: 1_000))
    #expect(ending == CGRect(x: 0, y: 9_200, width: 620, height: 800))
}

@Test
func `native timeline accessibility replaces an editing message body in timeline order`() {
    let editingMessageID = MessageID(rawValue: 42)
    let identifiers: [NativeMessageTimelineItem.Identifier] = [
        .beginning(ChannelID(rawValue: 1)),
        .message(MessageID(rawValue: 41)),
        .message(editingMessageID),
        .message(MessageID(rawValue: 43))
    ]

    #expect(
        !NativeTimelineAccessibilityPolicy.showsMessageBody(
            messageID: editingMessageID,
            editingMessageID: editingMessageID
        )
    )
    #expect(
        NativeTimelineAccessibilityPolicy.showsMessageBody(
            messageID: MessageID(rawValue: 43),
            editingMessageID: editingMessageID
        )
    )
    #expect(
        NativeTimelineAccessibilityPolicy.editingOverlayInsertionIndex(
            in: identifiers,
            editingMessageID: editingMessageID
        ) == 3
    )
    #expect(
        NativeTimelineAccessibilityPolicy.editingOverlayInsertionIndex(
            in: identifiers,
            editingMessageID: MessageID(rawValue: 99)
        ) == nil
    )
}

@MainActor @Test
func `ten thousand message timeline keeps stable identities across incremental update`() {
    let author = User(id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture")
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    var messages = (0 ..< 10000).map { index in
        Message(
            id: MessageID(rawValue: UInt64(index + 1)), channelID: ChannelID(rawValue: 1), author: author,
            content: "Message \(index)", timestamp: base.addingTimeInterval(Double(index))
        )
    }
    let original = MessageGrouping.rows(for: messages)
    messages[5000].content = "Changed"
    let updated = MessageGrouping.updating(
        existing: original, oldMessages: original.map(\.message), newMessages: messages
    )

    #expect(updated.count == 10000)
    #expect(updated.map(\.id) == original.map(\.id))
    #expect(updated[4999] == original[4999])
    #expect(updated[5000].message.content == "Changed")
    #expect(updated[5002] == original[5002])
}

@MainActor @Test func `timeline prepend preserves prior rows beyond boundary`() {
    let author = User(id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture")
    let channel = ChannelID(rawValue: 1)
    let old = (10 ..< 20).map {
        Message(
            id: MessageID(rawValue: UInt64($0)), channelID: channel, author: author, content: "\($0)",
            timestamp: Date(timeIntervalSince1970: Double($0 * 600))
        )
    }
    let earlier = (0 ..< 10).map {
        Message(
            id: MessageID(rawValue: UInt64($0 + 100)), channelID: channel, author: author,
            content: "earlier \($0)", timestamp: Date(timeIntervalSince1970: Double($0 * 600))
        )
    }
    let original = MessageGrouping.rows(for: old)
    let updated = MessageGrouping.updating(
        existing: original, oldMessages: old, newMessages: earlier + old
    )
    #expect(updated.count == 20)
    #expect(updated[11] == original[1])
}

@MainActor @Test
func `native timeline render plan preserves markdown inline emoji mentions and linked images`() throws {
    let author = User(
        id: UserID(rawValue: 1),
        username: "fixture",
        displayName: "Fixture"
    )
    let message = Message(
        id: MessageID(rawValue: 2),
        channelID: ChannelID(rawValue: 3),
        author: author,
        content:
            "# Heading\n**bold** <@4> <:wave:900000000000000101> [preview](https://example.com/image.png)"
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: 620
    )
    let attributed = try #require(layout.attributedContent)

    #expect(attributed.string.contains("Heading"))
    #expect(!attributed.string.contains("# Heading"))
    #expect(!attributed.string.contains("**bold**"))
    #expect(attributed.string.contains("\u{FFFC}"))
    #expect(layout.linkedImageRegions.count == 1)
    #expect(layout.linkedImageRegions[0].reference.label == "preview")
    #expect(layout.contentFrame?.height ?? 0 > 22)
}

@MainActor @Test
func `native timeline mention popover anchor follows the exact Core Text run after reflow`() throws {
    let author = User(
        id: UserID(rawValue: 5),
        username: "fixture",
        displayName: "Fixture"
    )
    let mentioned = User(
        id: UserID(rawValue: 6),
        username: "maya",
        displayName: "Maya Ortiz"
    )
    let message = Message(
        id: MessageID(rawValue: 7),
        channelID: ChannelID(rawValue: 8),
        author: author,
        content:
            "A deliberately long prefix keeps wrapping deterministic before <@6> and the suffix.",
        mentionedUsers: [mentioned]
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )

    func anchor(width: CGFloat) throws -> CGRect {
        let layout = NativeTimelineRowLayout.make(
            item: .message(
                row,
                isUnreadBoundary: false,
                isHighlighted: false
            ),
            width: width
        )
        let value = try #require(layout.attributedContent)
        let framesetter = try #require(layout.contentFramesetter)
        let frame = try #require(layout.contentFrame)
        var mentionIndex: Int?
        value.enumerateAttribute(
            .nativeTimelineMention,
            in: NSRange(location: 0, length: value.length)
        ) { attribute, range, stop in
            guard attribute != nil else { return }
            mentionIndex = range.location
            stop.pointee = true
        }
        let resolvedMentionIndex = try #require(mentionIndex)
        let drawingFrame = NativeTimelineTextGeometry
            .messageContentDrawingFrame(frame)
        let mentionFrame = try #require(
            NativeTimelineTextHitTester.mentionAnchorFrame(
                value: value,
                framesetter: framesetter,
                frame: drawingFrame,
                characterIndex: resolvedMentionIndex,
                rawToken: "<@6>"
            )
        )
        for point in [
            CGPoint(x: mentionFrame.minX + 1, y: mentionFrame.minY + 1),
            CGPoint(x: mentionFrame.maxX - 1, y: mentionFrame.minY + 1),
            CGPoint(x: mentionFrame.midX, y: mentionFrame.midY),
            CGPoint(x: mentionFrame.midX, y: mentionFrame.maxY - 1),
        ] {
            #expect(
                NativeTimelineTextHitTester.mention(
                    value: value,
                    framesetter: framesetter,
                    frame: drawingFrame,
                    point: point
                )?.rawToken == "<@6>"
            )
        }
        return mentionFrame
    }

    let wide = try anchor(width: 620)
    let narrow = try anchor(width: 260)

    #expect(wide.width > 40)
    #expect(wide.height >= 18)
    #expect(narrow.width == wide.width)
    #expect(narrow.minY > wide.minY)
}

@MainActor @Test
func `native mention hover preserves the legacy artwork and exact glyph hit regions`() throws {
    let author = User(
        id: UserID(rawValue: 31),
        username: "author",
        displayName: "Author"
    )
    let mentioned = User(
        id: UserID(rawValue: 32),
        username: "mentioned",
        displayName: "Mentioned"
    )
    let message = Message(
        id: MessageID(rawValue: 33),
        channelID: ChannelID(rawValue: 34),
        author: author,
        content: "Body <@32>",
        embeds: [
            MessageEmbed(
                id: "mention-embed",
                description: "Embed <@32>"
            )
        ],
        components: [
            .textDisplay(
                id: "mention-component",
                content: "Component <@32>"
            )
        ],
        mentionedUsers: [mentioned]
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )

    func verify(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect
    ) throws {
        let region = try #require(
            NativeTimelineTextHitTester.mentionRegions(
                value: value,
                framesetter: framesetter,
                frame: frame
            ).first
        )
        #expect(region.presentation.rawToken == "<@32>")
        #expect(
            NativeTimelineTextHitTester.mentionAnchorFrame(
                value: value,
                framesetter: framesetter,
                frame: frame,
                characterIndex: region.characterIndex,
                rawToken: region.presentation.rawToken
            ) == region.frame
        )
        #expect(
            NativeTimelineTextHitTester.mention(
                value: value,
                framesetter: framesetter,
                frame: frame,
                point: CGPoint(
                    x: region.frame.maxX - 0.5,
                    y: region.frame.maxY - 0.5
                )
            )?.rawToken == "<@32>"
        )
    }

    let content = try #require(layout.attributedContent)
    let contentFramesetter = try #require(layout.contentFramesetter)
    let contentFrame = NativeTimelineTextGeometry
        .messageContentDrawingFrame(try #require(layout.contentFrame))
    try verify(
        value: content,
        framesetter: contentFramesetter,
        frame: contentFrame
    )

    let embedText = try #require(
        layout.embedRegions
            .flatMap(\.textRegions)
            .first(where: {
                $0.text.value.string.contains("\u{FFFC}")
            })
    )
    var embedFrame = embedText.frame
    embedFrame.size.height += embedText.text.layoutHeightAdjustment
    try verify(
        value: embedText.text.value,
        framesetter: embedText.text.framesetter,
        frame: embedFrame
    )

    let componentText = try #require(
        layout.componentLayouts
            .flatMap(\.textRegions)
            .first
    )
    var componentFrame = componentText.frame
    componentFrame.size.height +=
        componentText.text.layoutHeightAdjustment
    try verify(
        value: componentText.text.value,
        framesetter: componentText.text.framesetter,
        frame: componentFrame
    )

    #expect(
        NativeTimelineMentionAppearance.backgroundAlpha(
            isHovered: false
        ) == 0.18
    )
    #expect(
        NativeTimelineMentionAppearance.backgroundAlpha(
            isHovered: true
        ) == 0.34
    )
}

@MainActor @Test
func `native timeline ordinary rows preserve compact geometry and center the avatar`() throws {
    let author = User(
        id: UserID(rawValue: 41),
        username: "nova",
        displayName: "Nova Chen"
    )
    let first = Message(
        id: MessageID(rawValue: 42),
        channelID: ChannelID(rawValue: 43),
        author: author,
        content: "hm",
        timestamp: Date(timeIntervalSince1970: 1_000)
    )
    let grouped = Message(
        id: MessageID(rawValue: 44),
        channelID: first.channelID,
        author: author,
        content: "hmm",
        timestamp: first.timestamp.addingTimeInterval(1)
    )
    let firstLayout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: first,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )
    let groupedLayout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: grouped,
                startsGroup: false,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )

    #expect(firstLayout.height == 53)
    #expect(firstLayout.highlightFrame == CGRect(x: 0, y: 9, width: 620, height: 44))
    #expect(!NativeTimelineHoverHitTesting.contains(
        CGPoint(x: 100, y: 9),
        in: firstLayout.highlightFrame
    ))
    #expect(NativeTimelineHoverHitTesting.contains(
        CGPoint(x: 100, y: 10),
        in: firstLayout.highlightFrame
    ))
    #expect(NativeTimelineHoverHitTesting.pointerFrame(
        for: firstLayout.highlightFrame
    ) == CGRect(x: 0, y: 10, width: 620, height: 44))
    #expect(firstLayout.avatarFrame?.minY == 12)
    #expect(firstLayout.contentFrame?.minY == 32)
    #expect(firstLayout.contentFrame?.height == 18)
    #expect(firstLayout.timestampFrame?.minX == (firstLayout.authorFrame?.maxX ?? 0) + 7)
    #expect(groupedLayout.height == 24)
    #expect(groupedLayout.highlightFrame == CGRect(x: 0, y: 0, width: 620, height: 24))
    #expect(groupedLayout.contentFrame?.minY == 3)
    #expect(groupedLayout.contentFrame?.height == 18)
}

@MainActor @Test
func `native multiline grouped row preserves the pre CoreText intrinsic height`() {
    let author = User(
        id: UserID(rawValue: 45),
        username: "maya",
        displayName: "Maya • Orbit"
    )
    let message = Message(
        id: MessageID(rawValue: 46),
        channelID: ChannelID(rawValue: 47),
        author: author,
        content:
            "The parent timeline stays anchored while this pane is open.",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let width: CGFloat = 427
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: width
    )
    let reference = NSHostingController(
        rootView: NativeTimelineLegacyPlainMessageReference(message: message)
    ).sizeThatFits(in: CGSize(width: width, height: 10_000))

    #expect(layout.height == reference.height)
    #expect(layout.avatarFrame?.minY == 12)
}

@MainActor @Test
func `native single line grouped row preserves the pre CoreText intrinsic height`() {
    let author = User(
        id: UserID(rawValue: 48),
        username: "juniper",
        displayName: "Juniper Reed"
    )
    let message = Message(
        id: MessageID(rawValue: 49),
        channelID: ChannelID(rawValue: 50),
        author: author,
        content: "And closing it restores the member inspector.",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let width: CGFloat = 427
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: width
    )
    let reference = NSHostingController(
        rootView: NativeTimelineLegacyPlainMessageReference(message: message)
    ).sizeThatFits(in: CGSize(width: width, height: 10_000))

    #expect(layout.height == reference.height)
    #expect(layout.avatarFrame?.minY == 12)
}

@Test func `chat timeline preserves the legacy vertical stack padding`() {
    #expect(ChatDetailLayoutPolicy.timelineTopPadding == 12)
    #expect(ChatDetailLayoutPolicy.timelineBottomPadding == 12)
}

@Test func `native timeline animation overlays preserve compositor frame timing`() {
    let durations = [0.10, 0.20, 0.05]
    let keyTimes = AnimatedImageKeyframeSchedule.keyTimes(
        for: durations
    ).map(\.doubleValue)
    #expect(
        abs(AnimatedImageKeyframeSchedule.duration(for: durations) - 0.35)
            < 0.000_001
    )
    #expect(keyTimes.count == 3)
    #expect(abs(keyTimes[0] - 0) < 0.000_001)
    #expect(abs(keyTimes[1] - (0.10 / 0.35)) < 0.000_001)
    #expect(abs(keyTimes[2] - (0.30 / 0.35)) < 0.000_001)
    #expect(
        AnimatedImageKeyframeSchedule.duration(for: []) == 0.05
    )
}

@Test func `native timeline animated decoder preserves multiple GIF frames`() throws {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.gif.identifier as CFString,
        2,
        nil
    ))
    CGImageDestinationSetProperties(
        destination,
        [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ] as CFDictionary
    )
    for color in [NSColor.systemPink, NSColor.systemTeal] {
        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: 0.10,
                ],
            ] as CFDictionary
        )
    }
    #expect(CGImageDestinationFinalize(destination))

    let decoded = try DecodedAnimatedImage(
        data: data as Data,
        maximumPixelDimension: 64
    )
    #expect(decoded.frames.count == 2)
    #expect(decoded.frameDurations.count == 2)
    #expect(decoded.frameDurations.allSatisfy { $0 >= 0.09 })
}

@MainActor @Test
func `native timeline render plan preserves generated system message content`() {
    let author = User(
        id: UserID(rawValue: 91),
        username: "nova",
        displayName: "Nova Chen"
    )
    let message = Message(
        id: MessageID(rawValue: 92),
        channelID: ChannelID(rawValue: 93),
        author: author,
        content: "",
        timestamp: Date(timeIntervalSince1970: 1_000),
        type: .userJoin
    )

    let plan = NativeTimelineTextPlan.make(for: message)
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )

    #expect(plan.attributedText?.value.string == "Yay you made it, Nova Chen!")
    #expect(layout.height == 33)
    #expect(layout.avatarFrame == nil)
    #expect(layout.authorFrame == nil)
    #expect(
        layout.systemIconFrame
            == CGRect(x: 50, y: 12, width: 16, height: 18)
    )
    #expect(layout.contentFrame?.minX == 72)
    #expect(layout.contentFrame?.minY == 12)
    #expect(layout.contentFrame?.height == 18)
}

@MainActor @Test
func `native command invocation and ephemeral footer preserve legacy row geometry`() {
    let invokingUser = User(
        id: UserID(rawValue: 94),
        username: "nova",
        displayName: "Nova Chen"
    )
    let application = User(
        id: UserID(rawValue: 95),
        username: "verified",
        displayName: "Verified",
        isBot: true
    )
    let message = Message(
        id: MessageID(rawValue: 96),
        channelID: ChannelID(rawValue: 97),
        author: application,
        content: "Only the invoking user can see this response.",
        timestamp: Date(timeIntervalSince1970: 1_000),
        type: .chatInputCommand,
        flags: [.ephemeral],
        interactionMetadata: MessageInteractionMetadata(
            id: "98",
            type: 2,
            name: "inspect",
            user: invokingUser,
            applicationID: "95"
        )
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )
    let invocation = layout.commandInvocationRegion
    let ephemeral = layout.ephemeralRegion
    let reference = NSHostingController(
        rootView: NativeTimelineLegacyCommandEphemeralReference(
            message: message
        )
    ).sizeThatFits(in: CGSize(width: 620, height: 10_000))

    #expect(layout.height == 90)
    #expect(abs(layout.height - reference.height) <= 1)
    #expect(invocation?.frame == CGRect(x: 14, y: 12, width: 592, height: 20))
    #expect(invocation?.connectorFrame == CGRect(x: 14, y: 12, width: 30, height: 20))
    #expect(invocation?.avatarFrame == CGRect(x: 49, y: 15, width: 14, height: 14))
    #expect(invocation?.pillFrame.minY == 14)
    #expect(invocation?.commandSymbolFrame.minY == 17)
    #expect(invocation?.commandSymbolFrame.height == 10)
    #expect(invocation?.commandFrame.minY == 14)
    #expect(invocation?.commandFrame.height == 16)
    #expect(layout.avatarFrame == CGRect(x: 14, y: 32, width: 38, height: 38))
    #expect(layout.authorFrame?.minY == 32)
    #expect(layout.botBadgeFrame?.minY == 33)
    #expect(layout.botBadgeFrame?.height == 14)
    #expect(layout.contentFrame?.minY == 50)
    #expect(ephemeral?.frame == CGRect(x: 64, y: 72, width: 542, height: 15))
    #expect(ephemeral?.dismissFrame.width ?? 0 > 80)
}

@MainActor @Test
func `native deferred command keeps the legacy loading indicator in its author line`() {
    let application = User(
        id: UserID(rawValue: 99),
        username: "bot",
        displayName: "Bot",
        isBot: true
    )
    let base = Message(
        id: MessageID(rawValue: 100),
        channelID: ChannelID(rawValue: 101),
        author: application,
        content: "Working…",
        timestamp: Date(timeIntervalSince1970: 1_000),
        type: .chatInputCommand
    )
    var loading = base
    loading.flags.insert(.loading)
    var sending = base
    sending.outboxState = .sending

    func layout(_ message: Message) -> NativeTimelineRowLayout {
        NativeTimelineRowLayout.make(
            item: .message(
                MessageRowPresentation(
                    message: message,
                    startsGroup: true,
                    startsDay: false,
                    replyPreview: nil,
                    isReplyAvailable: false
                ),
                isUnreadBoundary: false,
                isHighlighted: false
            ),
            width: 620
        )
    }

    let confirmedLayout = layout(base)
    let loadingLayout = layout(loading)
    let sendingLayout = layout(sending)

    #expect(
        loadingLayout.loadingIndicatorFrame
            == CGRect(
                x: loadingLayout.loadingIndicatorFrame?.minX ?? 0,
                y: 34,
                width: 12,
                height: 12
            )
    )
    #expect(loadingLayout.height == confirmedLayout.height)
    #expect(loadingLayout.failedFrame == nil)
    #expect(sendingLayout.failedFrame == nil)
    #expect(sendingLayout.height == confirmedLayout.height)
}

@MainActor @Test
func `native failed outbox footer is the only legacy outbox state that changes row geometry`() {
    let author = User(
        id: UserID(rawValue: 102),
        username: "nova",
        displayName: "Nova"
    )
    let base = Message(
        id: MessageID(rawValue: 103),
        channelID: ChannelID(rawValue: 104),
        author: author,
        content: "This message could not be sent.",
        timestamp: Date(timeIntervalSince1970: 1_000)
    )
    var failed = base
    failed.outboxState = .failed
    var queued = base
    queued.outboxState = .queued

    func layout(_ message: Message) -> NativeTimelineRowLayout {
        NativeTimelineRowLayout.make(
            item: .message(
                MessageRowPresentation(
                    message: message,
                    startsGroup: true,
                    startsDay: false,
                    replyPreview: nil,
                    isReplyAvailable: false
                ),
                isUnreadBoundary: false,
                isHighlighted: false
            ),
            width: 620
        )
    }

    let confirmedLayout = layout(base)
    let failedLayout = layout(failed)
    let queuedLayout = layout(queued)

    #expect(failedLayout.failedFrame?.height == 14)
    #expect(
        failedLayout.failedFrame?.minY
            == (confirmedLayout.contentFrame?.maxY ?? 0) + 4
    )
    #expect(failedLayout.height == confirmedLayout.height + 18)
    #expect(queuedLayout.failedFrame == nil)
    #expect(queuedLayout.height == confirmedLayout.height)
}

@MainActor @Test
func `native timeline embed layout renders rich text mentions and media`() throws {
    let author = User(
        id: UserID(rawValue: 101),
        username: "fixture",
        displayName: "Fixture"
    )
    let mediaURL = try #require(URL(string: "https://example.com/embed.png"))
    let thumbnailURL = try #require(URL(string: "https://example.com/thumb.png"))
    let embed = MessageEmbed(
        id: "rich-embed",
        title: "Release notes",
        description: "Hello <@&10> — **everything is native**.",
        color: 0x5865F2,
        footer: MessageEmbedFooter(text: "SakuraCord"),
        image: MessageEmbedMedia(
            url: mediaURL,
            width: 640,
            height: 360
        ),
        thumbnail: MessageEmbedMedia(
            url: thumbnailURL,
            width: 128,
            height: 128
        ),
        author: MessageEmbedAuthor(name: "Build bot"),
        fields: [
            MessageEmbedField(
                id: 1,
                name: "Status",
                value: "`ready`",
                isInline: true
            )
        ]
    )
    let message = Message(
        id: MessageID(rawValue: 102),
        channelID: ChannelID(rawValue: 103),
        author: author,
        content: "",
        embeds: [embed],
        mentionedRoleIDs: [RoleID(rawValue: 10)]
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )

    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: 620
    )
    let region = try #require(layout.embedRegions.first)
    let richText = NSMutableAttributedString()
    for textRegion in region.textRegions {
        richText.append(textRegion.text.value)
        richText.append(NSAttributedString(string: "\n"))
    }
    let selectableText = region.textRegions
        .filter(\.isSelectable)
        .map(\.text.value.string)
        .joined(separator: "\n")

    #expect(region.kind == .card)
    #expect(richText.string.contains("Release notes"))
    #expect(richText.string.contains("everything is native"))
    #expect(!richText.string.contains("**"))
    #expect(!richText.string.contains("<@&10>"))
    #expect(richText.string.contains("\u{FFFC}"))
    #expect(selectableText.contains("everything is native"))
    #expect(selectableText.contains("ready"))
    #expect(!selectableText.contains("Release notes"))
    #expect(!selectableText.contains("Status"))
    #expect(!selectableText.contains("SakuraCord"))
    #expect(region.imageRegions.contains { $0.url == thumbnailURL })
    #expect(region.mediaURL == mediaURL)
    #expect(region.imageRegions.contains {
        $0.url == thumbnailURL && $0.frame.size == CGSize(width: 80, height: 80)
    })
    #expect(region.mediaFrame != nil)
    #expect(region.frame.height > 200)
}

@MainActor @Test
func `native media viewer preserves attachment gallery order and selected item`() throws {
    let firstURL = try #require(URL(string: "https://cdn.example/first.png"))
    let secondURL = try #require(URL(string: "https://cdn.example/second.mp4"))
    let message = Message(
        id: MessageID(rawValue: 104),
        channelID: ChannelID(rawValue: 105),
        author: User(
            id: UserID(rawValue: 106),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        attachments: [
            Attachment(
                id: "first",
                filename: "first.png",
                url: firstURL,
                mediaType: "image/png"
            ),
            Attachment(
                id: "second",
                filename: "second.mp4",
                url: secondURL,
                mediaType: "video/mp4"
            ),
        ]
    )

    let presentation = try #require(
        NativeTimelineMediaViewerPlan.attachments(
            in: message,
            selectedAttachmentID: "second"
        )
    )

    #expect(presentation.items.map(\.url) == [firstURL, secondURL])
    #expect(presentation.items.map(\.id) == ["first", "second"])
    #expect(presentation.selection == 1)
    #expect(presentation.items[1].kind == .video)
}

@MainActor @Test
func `native media viewer resolves attachment backed embed by stable embed id`() throws {
    let attachmentURL = try #require(
        URL(string: "https://cdn.example/attachment-backed.png")
    )
    let attachmentReference = try #require(
        URL(string: "attachment://attachment-backed.png")
    )
    let hidden = MessageEmbed(id: "hidden", type: "rich")
    let visible = MessageEmbed(
        id: "visible",
        type: "image",
        image: MessageEmbedMedia(
            url: attachmentReference,
            width: 640,
            height: 360
        )
    )
    let message = Message(
        id: MessageID(rawValue: 107),
        channelID: ChannelID(rawValue: 108),
        author: User(
            id: UserID(rawValue: 109),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        attachments: [
            Attachment(
                id: "attachment",
                filename: "attachment-backed.png",
                url: attachmentURL,
                mediaType: "image/png",
                width: 640,
                height: 360
            )
        ],
        embeds: [hidden, visible]
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )
    let visibleRegion = try #require(layout.embedRegions.first)
    let presentation = try #require(
        NativeTimelineMediaViewerPlan.embed(
            in: message,
            id: visibleRegion.embedID
        )
    )

    #expect(layout.embedRegions.count == 1)
    #expect(visibleRegion.embedID == "visible")
    #expect(presentation.items.count == 1)
    #expect(presentation.items[0].url == attachmentURL)
    #expect(presentation.items[0].kind == .image(animated: false))
    #expect(presentation.selection == 0)
}

@MainActor @Test
func `native media viewer preserves remote embed video playback kind`() throws {
    let videoURL = try #require(
        URL(string: "https://cdn.example/embed-video.mp4")
    )
    let message = Message(
        id: MessageID(rawValue: 110),
        channelID: ChannelID(rawValue: 111),
        author: User(
            id: UserID(rawValue: 112),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        embeds: [
            MessageEmbed(
                id: "video",
                type: "video",
                video: MessageEmbedMedia(
                    url: videoURL,
                    width: 1280,
                    height: 720
                )
            )
        ]
    )

    let presentation = try #require(
        NativeTimelineMediaViewerPlan.embed(in: message, id: "video")
    )

    #expect(presentation.items.count == 1)
    #expect(presentation.items[0].url == videoURL)
    #expect(presentation.items[0].kind == .video)
    #expect(presentation.selection == 0)
}

@MainActor @Test
func `native timeline rich embed preserves previous card geometry`() throws {
    let iconURL = try #require(URL(string: "https://example.com/icon.png"))
    let thumbnailURL = try #require(URL(string: "https://example.com/thumbnail.png"))
    let embed = MessageEmbed(
        title: "Server-provided link preview",
        type: "rich",
        description:
            "This preview uses decoded embed data and performs no speculative unfurl request.",
        url: URL(string: "https://example.com"),
        color: 0x7C3AED,
        footer: MessageEmbedFooter(
            text: "Offline fixture",
            iconURL: iconURL
        ),
        thumbnail: MessageEmbedMedia(url: thumbnailURL),
        author: MessageEmbedAuthor(
            name: "Aurora Studio",
            iconURL: iconURL
        ),
        fields: [
            MessageEmbedField(
                id: 1,
                name: "Layout",
                value: "Hero plus stack",
                isInline: true
            ),
            MessageEmbedField(
                id: 2,
                name: "Accessibility",
                value: "Alt text included",
                isInline: true
            ),
        ]
    )
    let message = Message(
        id: MessageID(rawValue: 111),
        channelID: ChannelID(rawValue: 112),
        author: User(
            id: UserID(rawValue: 113),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        embeds: [embed]
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 620
    )

    let region = try #require(layout.embedRegions.first)
    let previousRenderer = NSHostingController(
        rootView: MessageEmbedCard(
            model: AppModel(launchMode: .offlineTesting),
            message: message,
            embed: embed,
            mediaItem: nil
        )
    )
    let previousSize = previousRenderer.sizeThatFits(
        in: CGSize(width: 520, height: 10_000)
    )
    let author = try #require(
        region.textRegions.first(where: {
            $0.text.value.string == "Aurora Studio"
        })
    )
    let description = try #require(
        region.textRegions.first(where: {
            $0.text.value.string
                == "This preview uses decoded embed data and performs no speculative unfurl request."
        })
    )
    let firstField = try #require(
        region.textRegions.first(where: {
            $0.text.value.string == "Layout"
        })
    )
    let secondField = try #require(
        region.textRegions.first(where: {
            $0.text.value.string == "Accessibility"
        })
    )

    #expect(abs(region.frame.width - previousSize.width) <= 1)
    #expect(abs(region.frame.height - previousSize.height) <= 1)
    #expect(author.frame.minX - region.frame.minX == 42)
    #expect(
        description.frame.width
            == region.frame.width - 4 - 24 - 80 - 24
    )
    #expect(
        abs(
            secondField.frame.minX - firstField.frame.minX
                - (description.frame.width + 14) / 2
        ) < 0.001
    )
}

@MainActor @Test
func `native timeline embed semantic colors preserve SwiftUI opacity`() throws {
    let appearance = try #require(NSAppearance(named: .darkAqua))
    var capturedColors: (NSColor?, NSColor?, NSColor, NSColor, NSColor)?
    appearance.performAsCurrentDrawingAppearance {
        capturedColors = (
            NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB),
            NSColor.labelColor.usingColorSpace(.deviceRGB),
            NativeTimelineSemanticColor.opacity(.secondaryLabelColor, 0.08),
            NativeTimelineSemanticColor.opacity(.secondaryLabelColor, 0.5),
            NativeTimelineSemanticColor.opacity(.labelColor, 0.08)
        )
    }
    let colors = try #require(capturedColors)
    let secondary = try #require(colors.0)
    let primary = try #require(colors.1)

    #expect(
        abs(colors.2.alphaComponent - secondary.alphaComponent * 0.08)
            < 0.0001
    )
    #expect(
        abs(colors.3.alphaComponent - secondary.alphaComponent * 0.5)
            < 0.0001
    )
    #expect(
        abs(colors.4.alphaComponent - primary.alphaComponent * 0.08)
            < 0.0001
    )
}

@MainActor @Test
func `native timeline bare embeds preserve previous media gallery geometry`() throws {
    let mediaURL = try #require(URL(string: "https://example.com/media.png"))
    let media = MessageEmbedMedia(
        url: mediaURL,
        width: 1_200,
        height: 800
    )
    let message = Message(
        id: MessageID(rawValue: 114),
        channelID: ChannelID(rawValue: 115),
        author: User(
            id: UserID(rawValue: 116),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        embeds: [
            MessageEmbed(type: "image", image: media)
        ]
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 720
    )
    let region = try #require(layout.embedRegions.first)
    let previousFrame = try #require(
        MediaGalleryPlan.frames(
            count: 1,
            width: 500,
            aspectRatios: [1.5],
            intrinsicSizes: [CGSize(width: 1_200, height: 800)],
            spacing: 4
        ).first
    )

    #expect(region.kind == .bareMedia)
    #expect(abs(region.frame.width - previousFrame.width) <= 0.001)
    #expect(abs(region.frame.height - previousFrame.height) <= 0.001)
}

@MainActor @Test
func `native timeline suppressed embeds restore link text without preview geometry`() throws {
    let sourceURL = try #require(URL(string: "https://example.com/media"))
    let mediaURL = try #require(URL(string: "https://cdn.example.com/media.mp4"))
    let message = Message(
        id: MessageID(rawValue: 117),
        channelID: ChannelID(rawValue: 118),
        author: User(
            id: UserID(rawValue: 119),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: sourceURL.absoluteString,
        flags: [.suppressEmbeds],
        embeds: [
            MessageEmbed(
                id: "suppressed",
                type: "gifv",
                url: sourceURL,
                video: MessageEmbedMedia(
                    url: mediaURL,
                    width: 320,
                    height: 180
                )
            )
        ]
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 720
    )
    let prepared = try #require(row.textPlan.preparedText)
    let attributed = DiscordMarkdown.appKitAttributed(
        prepared.markdownPlan,
        baseFontSize: row.textPlan.baseFontSize
    )

    #expect(attributed.string == sourceURL.absoluteString)
    #expect(layout.contentFrame != nil)
    #expect(layout.embedRegions.isEmpty)
}

@MainActor @Test
func `native timeline component layout preserves the complete V2 hierarchy`() throws {
    let author = User(
        id: UserID(rawValue: 201),
        username: "fixture",
        displayName: "Fixture"
    )
    let thumbnailURL = try #require(
        URL(string: "https://example.com/component-thumb.png")
    )
    let galleryURL = try #require(
        URL(string: "https://example.com/component-gallery.png")
    )
    let fileURL = try #require(
        URL(string: "https://example.com/component.pdf")
    )
    let message = Message(
        id: MessageID(rawValue: 202),
        channelID: ChannelID(rawValue: 203),
        author: author,
        content: "Legacy content must not render beside Components V2.",
        attachments: [
            Attachment(
                id: "legacy-attachment",
                filename: "legacy.png",
                url: thumbnailURL,
                mediaType: "image/png",
                width: 80,
                height: 80
            )
        ],
        flags: [.isComponentsV2],
        embeds: [
            MessageEmbed(
                title: "Legacy embed",
                image: MessageEmbedMedia(url: galleryURL)
            )
        ],
        components: [
            .container(
                id: "container",
                accentColor: 0x5865F2,
                spoiler: false,
                children: [
                    .textDisplay(
                        id: "heading",
                        content: "## Components V2\nHello <@&10>"
                    ),
                    .separator(
                        id: "separator",
                        divider: true,
                        spacing: 1
                    ),
                    .actionRow(
                        id: "actions",
                        children: [
                            .button(
                                id: "primary",
                                style: .primary,
                                label: "Continue",
                                emoji: nil,
                                customID: "continue",
                                url: nil,
                                skuID: nil,
                                disabled: false
                            ),
                            .button(
                                id: "link",
                                style: .link,
                                label: "Learn more",
                                emoji: nil,
                                customID: nil,
                                url: URL(string: "https://example.com"),
                                skuID: nil,
                                disabled: false
                            ),
                        ]
                    ),
                    .select(
                        id: "select",
                        kind: .string,
                        customID: "choice",
                        placeholder: "Choose one…",
                        minValues: 1,
                        maxValues: 1,
                        disabled: false,
                        options: [
                            ComponentSelectOption(
                                label: "First",
                                value: "first"
                            )
                        ],
                        channelTypes: []
                    ),
                    .section(
                        id: "section",
                        children: [
                            .textDisplay(
                                id: "section-text",
                                content: "**Section copy**"
                            )
                        ],
                        accessory: .thumbnail(
                            id: "thumbnail",
                            media: ComponentMedia(
                                url: thumbnailURL,
                                width: 80,
                                height: 80,
                                description: "Thumbnail"
                            )
                        )
                    ),
                    .mediaGallery(
                        id: "gallery",
                        items: [
                            ComponentGalleryItem(
                                id: "gallery-item",
                                media: ComponentMedia(
                                    url: galleryURL,
                                    width: 640,
                                    height: 360,
                                    description: "Gallery image"
                                )
                            )
                        ]
                    ),
                    .file(
                        id: "file",
                        media: ComponentMedia(
                            url: fileURL,
                            contentType: "application/pdf",
                            description: "Fixture document"
                        )
                    ),
                ]
            )
        ],
        mentionedRoleIDs: [RoleID(rawValue: 10)]
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )

    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: 720
    )
    let components = try #require(layout.componentLayouts.first)
    let container = try #require(components.containers.first)
    let renderedText = components.textRegions
        .map(\.text.value.string)
        .joined(separator: "\n")

    #expect(container.accentColor == 0x5865F2)
    #expect(container.frame.width <= DiscordRichMessageMetrics.maximumWidth)
    #expect(components.buttons.count == 2)
    #expect(components.buttons.allSatisfy { $0.frame.height == 32 })
    #expect(components.selects.count == 1)
    #expect(components.images.contains { $0.displayURL == thumbnailURL })
    #expect(components.media.contains { $0.displayURL == galleryURL })
    #expect(components.files.contains { $0.openURL == fileURL })
    #expect(components.separators.count == 1)
    #expect(renderedText.contains("Components V2"))
    #expect(!renderedText.contains("##"))
    #expect(renderedText.contains("\u{FFFC}"))
    #expect(components.textRegions.allSatisfy { $0.isSelectable })
    #expect(components.frame.height > 400)
    #expect(layout.attributedContent == nil)
    #expect(layout.linkedImageRegions.isEmpty)
    #expect(layout.attachmentRegions.isEmpty)
    #expect(layout.embedRegions.isEmpty)
}

@MainActor @Test
func `native component section pins its button accessory to the trailing edge`() throws {
    let message = Message(
        id: MessageID(rawValue: 310),
        channelID: ChannelID(rawValue: 311),
        author: User(
            id: UserID(rawValue: 312),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        flags: [.isComponentsV2],
        components: [
            .section(
                id: "candidate",
                children: [
                    .textDisplay(
                        id: "candidate-copy",
                        content: "<@313>"
                    )
                ],
                accessory: .button(
                    id: "vote",
                    style: .success,
                    label: "Vote",
                    emoji: nil,
                    customID: "vote",
                    url: nil,
                    skuID: nil,
                    disabled: false
                )
            )
        ]
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 720
    )
    let components = try #require(layout.componentLayouts.first)
    let button = try #require(components.buttons.first)

    #expect(button.frame.maxX == components.frame.maxX)
    #expect(
        components.textRegions.allSatisfy {
            $0.frame.maxX <= button.frame.minX - 8
        }
    )
}

@Test
func `native component button preserves legacy hover press and activation behavior`() {
    #expect(
        NativeTimelineComponentButtonVisualState.pressAnimationDuration
            == 0.09
    )
    #expect(
        NativeTimelineComponentButtonVisualState.scale(
            pressProgress: 0
        ) == 1
    )
    #expect(
        NativeTimelineComponentButtonVisualState.scale(
            pressProgress: 1
        ) == 0.985
    )
    #expect(
        NativeTimelineComponentButtonVisualState.scale(
            pressProgress: -1
        ) == 1
    )
    #expect(
        NativeTimelineComponentButtonVisualState.scale(
            pressProgress: 2
        ) == 0.985
    )

    #expect(
        NativeTimelineComponentButtonVisualState.brightness(
            isHovered: false,
            pressProgress: 0
        ) == 0
    )
    #expect(
        NativeTimelineComponentButtonVisualState.brightness(
            isHovered: true,
            pressProgress: 0
        ) == 0.035
    )
    #expect(
        abs(
            NativeTimelineComponentButtonVisualState.brightness(
                isHovered: true,
                pressProgress: 0.5
            ) + 0.0175
        ) < 0.000_001
    )
    #expect(
        NativeTimelineComponentButtonVisualState.brightness(
            isHovered: true,
            pressProgress: 1
        ) == -0.07
    )
    #expect(
        NativeTimelineComponentButtonVisualState.borderAlpha(
            isHovered: true,
            isEnabled: true
        ) == 0.14
    )
    #expect(
        NativeTimelineComponentButtonVisualState.borderAlpha(
            isHovered: true,
            isEnabled: false
        ) == 0.07
    )
    #expect(
        NativeTimelineComponentButtonVisualState.borderAlpha(
            isHovered: false,
            isEnabled: true
        ) == 0.07
    )
    #expect(
        NativeTimelineComponentButtonVisualState.easeOut(0) == 0
    )
    #expect(
        NativeTimelineComponentButtonVisualState.easeOut(0.5)
            == 0.875
    )
    #expect(
        NativeTimelineComponentButtonVisualState.easeOut(1) == 1
    )

    let first = NativeTimelineComponentButtonTarget(
        messageID: MessageID(rawValue: 301),
        componentID: "first"
    )
    let second = NativeTimelineComponentButtonTarget(
        messageID: MessageID(rawValue: 301),
        componentID: "second"
    )
    #expect(
        NativeTimelineComponentButtonActivationPolicy.activates(
            pressed: first,
            released: first
        )
    )
    #expect(
        !NativeTimelineComponentButtonActivationPolicy.activates(
            pressed: first,
            released: second
        )
    )
    #expect(
        !NativeTimelineComponentButtonActivationPolicy.activates(
            pressed: first,
            released: nil
        )
    )
    #expect(
        !NativeTimelineComponentButtonActivationPolicy.activates(
            pressed: nil,
            released: first
        )
    )
}

@Test
func `native timeline activation requires the same stable press target`() {
    let message = MessageID(rawValue: 401)
    let otherMessage = MessageID(rawValue: 402)
    let firstAttachment = NativeTimelinePointerActivationTarget.attachment(
        message,
        "first"
    )
    let secondAttachment = NativeTimelinePointerActivationTarget.attachment(
        message,
        "second"
    )
    let sameAttachmentOnAnotherMessage =
        NativeTimelinePointerActivationTarget.attachment(
            otherMessage,
            "first"
        )

    #expect(
        NativeTimelinePointerActivationPolicy.activates(
            pressed: firstAttachment,
            released: firstAttachment
        )
    )
    #expect(
        !NativeTimelinePointerActivationPolicy.activates(
            pressed: firstAttachment,
            released: secondAttachment
        )
    )
    #expect(
        !NativeTimelinePointerActivationPolicy.activates(
            pressed: firstAttachment,
            released: sameAttachmentOnAnotherMessage
        )
    )
    #expect(
        !NativeTimelinePointerActivationPolicy.activates(
            pressed: firstAttachment,
            released: nil
        )
    )
    #expect(
        !NativeTimelinePointerActivationPolicy.activates(
            pressed: nil,
            released: firstAttachment
        )
    )

    let image = NativeTimelinePointerActivationTarget.componentImage(
        message,
        "shared-id"
    )
    let media = NativeTimelinePointerActivationTarget.componentMedia(
        message,
        "shared-id"
    )
    #expect(
        !NativeTimelinePointerActivationPolicy.activates(
            pressed: image,
            released: media
        )
    )

    let mention = NativeTimelinePointerActivationTarget.textMention(
        message,
        .content,
        characterIndex: 4,
        rawToken: "<@123>"
    )
    let movedMention = NativeTimelinePointerActivationTarget.textMention(
        message,
        .content,
        characterIndex: 5,
        rawToken: "<@123>"
    )
    #expect(mention.supportsTextSelection)
    #expect(!firstAttachment.supportsTextSelection)
    #expect(
        !NativeTimelinePointerActivationPolicy.activates(
            pressed: mention,
            released: movedMention
        )
    )
}

@MainActor @Test
func `native timeline thread activation owns its complete click gesture`() throws {
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 411),
        name: "Press ownership",
        messageCount: 3,
        memberCount: 2
    )
    let message = Message(
        id: MessageID(rawValue: 412),
        channelID: ChannelID(rawValue: 413),
        author: User(
            id: UserID(rawValue: 414),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Thread activation fixture",
        thread: thread
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
    let width: CGFloat = 720
    let layout = NativeTimelineRowLayout.make(
        item: item,
        width: width
    )
    let threadFrame = try #require(layout.threadFrame)
    let storage = NativeTimelineCanvasStorage()
    storage.items = [item]
    storage.layouts = [layout]
    storage.rowOrigins = [0]
    storage.contentHeight = layout.height

    var openedThreads: [ChannelID] = []
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: layout.height
        )
    )
    let window = NSWindow(
        contentRect: canvas.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = canvas
    canvas.apply(
        storage: storage,
        model: AppModel(launchMode: .offlineTesting),
        actions: NativeTimelineRowActions(
            loadEarlier: {},
            openReply: { _ in },
            reply: nil,
            retry: { _ in },
            edit: { _, _ in },
            markUnread: { _ in },
            delete: { _ in },
            react: { _, _ in },
            openThread: { openedThreads.append($0.id) },
            submitComponent: { _, _, _, _ in }
        ),
        viewportWidth: width,
        minimumHeight: layout.height,
        bottomSpacerHeight: 0,
        contentOriginY: 0
    )

    func event(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        number: Int
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(point, to: nil),
            modifierFlags: [],
            timestamp: TimeInterval(number),
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: number,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    let inside = CGPoint(
        x: threadFrame.midX,
        y: threadFrame.midY
    )
    let outside = CGPoint(
        x: min(width - 1, threadFrame.maxX + 12),
        y: threadFrame.midY
    )

    canvas.mouseDown(with: try event(.leftMouseDown, at: outside, number: 1))
    canvas.mouseUp(with: try event(.leftMouseUp, at: inside, number: 2))
    #expect(openedThreads.isEmpty)

    canvas.mouseDown(with: try event(.leftMouseDown, at: inside, number: 3))
    canvas.mouseDragged(
        with: try event(.leftMouseDragged, at: outside, number: 4)
    )
    canvas.mouseUp(with: try event(.leftMouseUp, at: outside, number: 5))
    #expect(openedThreads.isEmpty)

    canvas.mouseDown(with: try event(.leftMouseDown, at: inside, number: 6))
    canvas.mouseUp(with: try event(.leftMouseUp, at: inside, number: 7))
    #expect(openedThreads == [thread.id])
}

@MainActor @Test
func `short timeline origin changes invalidate all former row pixels`() {
    let width: CGFloat = 480
    let message = Message(
        id: MessageID(rawValue: 415),
        channelID: ChannelID(rawValue: 416),
        author: User(
            id: UserID(rawValue: 417),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Sparse thread reply"
    )
    let item = NativeMessageTimelineItem.message(
        MessageRowPresentation(
            message: message,
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        ),
        isUnreadBoundary: false,
        isHighlighted: false
    )
    let layout = NativeTimelineRowLayout.make(item: item, width: width)
    let storage = NativeTimelineCanvasStorage()
    storage.items = [item]
    storage.layouts = [layout]
    storage.rowOrigins = [0]
    storage.contentHeight = layout.height
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: width, height: 400)
    )
    let window = NSWindow(
        contentRect: canvas.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = canvas
    let actions = NativeTimelineRowActions(
        loadEarlier: {},
        openReply: { _ in },
        reply: nil,
        retry: { _ in },
        edit: { _, _ in },
        markUnread: { _ in },
        delete: { _ in },
        react: { _, _ in },
        openThread: { _ in },
        submitComponent: { _, _, _, _ in }
    )
    let model = AppModel(launchMode: .offlineTesting)
    canvas.apply(
        storage: storage,
        model: model,
        actions: actions,
        viewportWidth: width,
        minimumHeight: 400,
        bottomSpacerHeight: 0,
        contentOriginY: 260
    )
    let invalidationsBeforeMove = canvas.contentOriginInvalidationCount
    let synchronousRedrawsBeforeMove =
        canvas.synchronousShortContentRedrawCount

    canvas.apply(
        storage: storage,
        model: model,
        actions: actions,
        viewportWidth: width,
        minimumHeight: 400,
        bottomSpacerHeight: 0,
        contentOriginY: 220
    )

    #expect(
        canvas.contentOriginInvalidationCount
            == invalidationsBeforeMove + 1
    )
    #expect(
        canvas.synchronousShortContentRedrawCount
            == synchronousRedrawsBeforeMove + 1
    )
    let rowTrackingArea = canvas.trackingAreas.first {
        $0.userInfo?["nativeTimelineTrackingKind"] as? String == "row"
    }
    #expect(
        rowTrackingArea?.rect.minY
            == 220
                + (layout.highlightFrame?.minY ?? 0)
                + NativeTimelineHoverHitTesting.coreTextOpticalOffset
    )
}

@MainActor @Test
func `replacing an edited conversation with empty storage clears stale geometry`() {
    let width: CGFloat = 480
    let message = Message(
        id: MessageID(rawValue: 615),
        channelID: ChannelID(rawValue: 616),
        author: User(
            id: UserID(rawValue: 617),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Editing while the thread closes"
    )
    let item = NativeMessageTimelineItem.message(
        MessageRowPresentation(
            message: message,
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        ),
        isUnreadBoundary: false,
        isHighlighted: false
    )
    let layout = NativeTimelineRowLayout.make(item: item, width: width)
    let storage = NativeTimelineCanvasStorage()
    storage.items = [item]
    storage.layouts = [layout]
    storage.rowOrigins = [0]
    storage.contentHeight = layout.height

    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: width, height: 400)
    )
    let window = NSWindow(
        contentRect: canvas.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = canvas
    let actions = NativeTimelineRowActions(
        loadEarlier: {},
        openReply: { _ in },
        reply: nil,
        retry: { _ in },
        edit: { _, _ in },
        markUnread: { _ in },
        delete: { _ in },
        react: { _, _ in },
        openThread: { _ in },
        submitComponent: { _, _, _, _ in }
    )
    let model = AppModel(launchMode: .offlineTesting)
    canvas.apply(
        storage: storage,
        model: model,
        actions: actions,
        viewportWidth: width,
        minimumHeight: 400,
        bottomSpacerHeight: 0,
        contentOriginY: 260
    )
    canvas.installEditingGeometryForTesting(
        messageID: message.id,
        rowIndex: 0,
        rowHeight: layout.height + 40
    )

    canvas.apply(
        storage: NativeTimelineCanvasStorage(),
        model: model,
        actions: actions,
        viewportWidth: width,
        minimumHeight: 400,
        bottomSpacerHeight: 0,
        contentOriginY: 8
    )

    #expect(!canvas.hasEditingGeometryForTesting)
}

@MainActor @Test
func `native timeline attachments preserve the previous media mosaic geometry`() throws {
    let url = try #require(URL(string: "https://example.com/layout.png"))
    let attachments = (0 ..< 3).map { index in
        Attachment(
            id: "attachment-\(index)",
            filename: "layout-\(index).png",
            url: url,
            mediaType: "image/png",
            width: index == 0 ? 720 : 420,
            height: 420
        )
    }
    let message = Message(
        id: MessageID(rawValue: 204),
        channelID: ChannelID(rawValue: 205),
        author: User(
            id: UserID(rawValue: 206),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        attachments: attachments
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 720
    )
    let previous = MediaGalleryPlan.frames(
        count: 3,
        width: 500,
        aspectRatios: attachments.map {
            CGFloat($0.width!) / CGFloat($0.height!)
        },
        intrinsicSizes: attachments.map {
            CGSize(
                width: CGFloat($0.width!),
                height: CGFloat($0.height!)
            )
        },
        spacing: 4
    )

    #expect(layout.attachmentRegions.count == previous.count)
    let origin = try #require(layout.attachmentRegions.first?.frame.origin)
    for (region, expected) in zip(layout.attachmentRegions, previous) {
        #expect(
            region.frame.offsetBy(dx: -origin.x, dy: -origin.y)
                == expected
        )
    }
}

@MainActor @Test
func `native timeline component container preserves previous fitting geometry`() throws {
    func button(
        _ id: String,
        _ style: ComponentButtonStyle,
        _ label: String,
        _ emoji: String
    ) -> MessageComponent {
        .actionRow(
            id: "\(id)-row",
            children: [
                .button(
                    id: id,
                    style: style,
                    label: label,
                    emoji: EmojiReference(name: emoji),
                    customID: id,
                    url: nil,
                    skuID: nil,
                    disabled: false
                )
            ]
        )
    }

    let children: [MessageComponent] = [
        .textDisplay(
            id: "heading",
            content: "## How did you join the server?"
        ),
        .separator(id: "divider", divider: true, spacing: 1),
        button("reddit", .success, "Reddit", "🙂"),
        button("social", .secondary, "Other social media", "🌐"),
        button("friend", .primary, "A friend invited me", "🧑‍🤝‍🧑"),
        button("returning", .primary, "I was here before", "🏠"),
        button("other", .destructive, "Other", "❓"),
    ]
    let component = MessageComponent.container(
        id: "container",
        accentColor: 0x5865F2,
        spoiler: false,
        children: children
    )
    let message = Message(
        id: MessageID(rawValue: 221),
        channelID: ChannelID(rawValue: 222),
        author: User(
            id: UserID(rawValue: 223),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        flags: [.isComponentsV2],
        components: [component]
    )
    let model = AppModel(launchMode: .offlineTesting)
    let layout = try #require(
        NativeTimelineComponentLayout.make(
            message: message,
            model: model,
            origin: .zero,
            maximumWidth: 520
        )
    )
    let previousRenderer = NSHostingController(
        rootView: DiscordComponentContainerView(
            model: model,
            message: message,
            accent: 0x5865F2,
            spoiler: false,
            children: children
        )
    )
    let previousSize = previousRenderer.sizeThatFits(
        in: CGSize(width: 520, height: 10_000)
    )
    let buttonFixtures: [
        (ComponentButtonStyle, String, String)
    ] = [
        (.success, "Reddit", "🙂"),
        (.secondary, "Other social media", "🌐"),
        (.primary, "A friend invited me", "🧑‍🤝‍🧑"),
        (.primary, "I was here before", "🏠"),
        (.destructive, "Other", "❓"),
    ]
    let previousButtonSizes = buttonFixtures.map {
        style, label, emoji in
        NSHostingController(
            rootView: DiscordComponentButton(
                style: style,
                label: label,
                emoji: EmojiReference(name: emoji),
                showsExternalLink: false,
                action: {}
            )
        ).sizeThatFits(
            in: CGSize(width: 520, height: 1_000)
        )
    }

    #expect(abs(layout.frame.width - previousSize.width) <= 1)
    #expect(abs(layout.frame.height - previousSize.height) <= 1)
    #expect(layout.buttons.count == previousButtonSizes.count)
    for (button, previousButtonSize) in zip(
        layout.buttons,
        previousButtonSizes
    ) {
        #expect(abs(button.frame.width - previousButtonSize.width) <= 1)
        #expect(button.frame.height == previousButtonSize.height)
    }
    #expect(layout.buttons.map(\.emoji?.name) == [
        "🙂", "🌐", "🧑‍🤝‍🧑", "🏠", "❓",
    ])
}

@MainActor @Test
func `native timeline stickers thread and reactions preserve previous geometry`() throws {
    let assetURL = try #require(
        URL(string: "https://example.com/sticker.png")
    )
    let reaction = Reaction(
        emoji: "🔥",
        count: 7,
        didCurrentUserReact: true,
        reactors: [
            ReactionReactor(
                id: UserID(rawValue: 301),
                displayName: "Maya"
            ),
            ReactionReactor(
                id: UserID(rawValue: 302),
                displayName: "Nova"
            ),
        ]
    )
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 303),
        name: "Rich message feedback",
        messageCount: 2,
        memberCount: 3
    )
    let stickers = [
        MessageSticker(
            id: "one",
            name: "One",
            format: .png,
            assetURL: assetURL
        ),
        MessageSticker(
            id: "two",
            name: "Two",
            format: .png,
            assetURL: assetURL
        ),
    ]
    let message = Message(
        id: MessageID(rawValue: 304),
        channelID: ChannelID(rawValue: 305),
        author: User(
            id: UserID(rawValue: 306),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "",
        reactions: [reaction],
        stickers: stickers,
        thread: thread
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 720
    )

    let previousStickers = NSHostingController(
        rootView: MessageStickersView(stickers: stickers)
    ).sizeThatFits(in: CGSize(width: 520, height: 10_000))
    let threadView = NSHostingController(
        rootView: MessageThreadSummaryView(thread: thread, open: {})
    )
    let previousThread = threadView.sizeThatFits(
        in: CGSize(width: 500, height: 10_000)
    )
    let previousReaction = NSHostingController(
        rootView: MessageReactionPill(
            reaction: reaction,
            emojiURL: nil,
            react: {},
            loadReactors: {}
        )
    ).sizeThatFits(in: CGSize(width: 500, height: 10_000))

    #expect(layout.stickerFrames.count == 2)
    #expect(
        layout.stickerFrames[1].maxX
            - layout.stickerFrames[0].minX
            == previousStickers.width
    )
    #expect(layout.stickerFrames.allSatisfy {
        $0.height == previousStickers.height
    })
    let threadFrame = try #require(layout.threadFrame)
    #expect(abs(threadFrame.width - previousThread.width) <= 1)
    #expect(abs(threadFrame.height - previousThread.height) <= 1)
    let reactionRegion = try #require(layout.reactionRegions.first)
    #expect(abs(reactionRegion.frame.width - previousReaction.width) <= 1)
    #expect(abs(reactionRegion.frame.height - previousReaction.height) <= 1)
    #expect(layout.addReactionFrame?.size == CGSize(width: 30, height: 28))
}

@Test
func `first reaction mutation uses the pre-update canvas count as its animation baseline`() {
    #expect(
        NativeTimelineReactionCountBaseline.canAnimate(
            hasCapturedVisibleCounts: false,
            hasStoredSnapshot: true
        )
    )
    #expect(
        !NativeTimelineReactionCountBaseline.canAnimate(
            hasCapturedVisibleCounts: false,
            hasStoredSnapshot: false
        )
    )
    #expect(
        NativeTimelineReactionCountBaseline.previousCount(
            capturedCount: nil,
            storedCountBeforeUpdate: 4,
            messageExistedBeforeUpdate: true,
            messageWasPreviouslyVisible: false,
            currentCount: 5
        ) == 4
    )
    #expect(
        NativeTimelineReactionCountBaseline.previousCount(
            capturedCount: nil,
            storedCountBeforeUpdate: nil,
            messageExistedBeforeUpdate: true,
            messageWasPreviouslyVisible: false,
            currentCount: 1
        ) == 0
    )
    #expect(
        NativeTimelineReactionCountBaseline.previousCount(
            capturedCount: nil,
            storedCountBeforeUpdate: nil,
            messageExistedBeforeUpdate: false,
            messageWasPreviouslyVisible: false,
            currentCount: 4
        ) == 4
    )
    #expect(
        NativeTimelineReactionCountBaseline.previousCount(
            capturedCount: nil,
            storedCountBeforeUpdate: 9,
            messageExistedBeforeUpdate: true,
            messageWasPreviouslyVisible: false,
            currentCount: 10
        ) == 9
    )
}

@Test
func `native add reaction symbol preserves its aspect ratio and centers its box`() {
    let control = CGRect(x: 10, y: 20, width: 30, height: 28)
    let icon = NativeTimelineReactionAddControlGeometry.iconFrame(in: control)
    let fitted = NativeTimelineSymbolGeometry.opticallyFitted(
        sourceSize: CGSize(width: 20, height: 20),
        alignmentRect: CGRect(x: 0, y: 4, width: 19.5, height: 11.5),
        in: icon
    )

    #expect(icon.size == CGSize(width: 16, height: 16))
    #expect(icon.midX == control.midX)
    #expect(icon.midY == control.midY)
    #expect(fitted.midX > icon.midX)
    #expect(fitted.midY > icon.midY)
    #expect(fitted.width == icon.width)
    #expect(fitted.height == icon.height)
}

@MainActor @Test
func `native timeline selection geometry follows wrapped Core Text lines`() {
    let value = NSAttributedString(
        string: "alpha beta gamma delta epsilon zeta eta theta",
        attributes: [
            .font: NSFont.systemFont(ofSize: 15),
        ]
    )
    let framesetter = CTFramesetterCreateWithAttributedString(value)
    let outerFrame = CGRect(x: 13, y: 29, width: 92, height: 180)
    let path = CGPath(
        rect: CGRect(origin: .zero, size: outerFrame.size),
        transform: nil
    )
    let textFrame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: 0, length: value.length),
        path,
        nil
    )

    let rects = NativeTimelineTextSelectionGeometry.rects(
        in: textFrame,
        outerFrame: outerFrame,
        range: NSRange(location: 0, length: value.length)
    )

    #expect(rects.count > 1)
    #expect(rects.allSatisfy { outerFrame.intersects($0) })
    #expect(rects.allSatisfy { $0.width > 1 && $0.height > 1 })
}

@MainActor @Test
func `native fenced code chrome stays inside measured row height`() throws {
    let terminalSource = [
        "Multi-line Code Block:",
        "```",
        "Hello World",
        "Line 2",
        "```",
    ].joined(separator: "\n")
    let terminalCode = DiscordMarkdown.appKitAttributed(terminalSource)
    #expect(
        NativeTimelineMarkdownChromeMetrics.trailingVisualOverflow(
            in: terminalCode
        ) == 9.5
    )

    let followedCode = DiscordMarkdown.appKitAttributed(
        [
            "```",
            "Hello World",
            "```",
            "Ordinary text follows.",
        ].joined(separator: "\n")
    )
    #expect(
        NativeTimelineMarkdownChromeMetrics.trailingVisualOverflow(
            in: followedCode
        ) == 0
    )

    let message = Message(
        id: MessageID(rawValue: 91),
        channelID: ChannelID(rawValue: 92),
        author: User(
            id: UserID(rawValue: 93),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: terminalSource
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 836
    )
    let contentFrame = try #require(layout.contentFrame)
    let attributedContent = try #require(layout.attributedContent)
    let framesetter = try #require(layout.contentFramesetter)
    let highlightFrame = try #require(layout.highlightFrame)
    let terminalRegion = try #require(
        NativeTimelineCodeBlockGeometry.regions(
            value: attributedContent,
            framesetter: framesetter,
            frame: NativeTimelineTextGeometry
                .messageContentDrawingFrame(contentFrame)
        ).last
    )
    let bottomHighlightPadding =
        highlightFrame.maxY - terminalRegion.backgroundFrame.maxY
    #expect(
        bottomHighlightPadding
            >= MessageRowLayoutMetrics.visibleHighlightInset
    )
    #expect(
        bottomHighlightPadding
            < MessageRowLayoutMetrics.visibleHighlightInset + 1
    )
}

@MainActor @Test
func `native fenced code regions share paint hover copy and accessibility geometry`() throws {
    let value = DiscordMarkdown.appKitAttributed(
        [
            "Before",
            "```",
            "first",
            "second",
            "```",
            "Between",
            "```json",
            #"{"value": 1}"#,
            "```",
        ].joined(separator: "\n")
    )
    let frame = CGRect(x: 20, y: 10, width: 400, height: 500)
    let regions = NativeTimelineCodeBlockGeometry.regions(
        value: value,
        framesetter: CTFramesetterCreateWithAttributedString(value),
        frame: frame
    )

    #expect(regions.count == 2)
    let first = try #require(regions.first)
    let last = try #require(regions.last)
    #expect(first.content == "first\nsecond")
    #expect(last.content == #"{"value": 1}"#)
    for region in regions {
        #expect(region.backgroundFrame.minX == frame.minX)
        #expect(region.backgroundFrame.width == frame.width)
        #expect(region.backgroundFrame.contains(region.copyButtonFrame))
        #expect(
            region.copyButtonFrame.maxX
                == region.backgroundFrame.maxX - 4
        )
        #expect(
            region.copyButtonFrame.minY
                == region.backgroundFrame.minY + 4
        )
        #expect(region.copyButtonFrame.size == CGSize(width: 28, height: 28))
    }
}

@MainActor @Test
func `native timeline selection uses the full message text container`() {
    let frame = NativeTimelineTextSelectionGeometry.interactionFrame(
        contentFrame: CGRect(x: 128, y: 41, width: 520, height: 22),
        rowOrigin: 300,
        canvasWidth: 900
    )

    #expect(frame == CGRect(x: 128, y: 341, width: 772, height: 22))
    #expect(frame.contains(CGPoint(x: 899, y: 352)))
}

@MainActor @Test
func `native timeline selection recognizes selected inline attachment runs`() {
    #expect(
        NativeTimelineTextSelectionGeometry.intersects(
            characterRange: CFRange(location: 8, length: 1),
            selectionRange: NSRange(location: 3, length: 7)
        )
    )
    #expect(
        !NativeTimelineTextSelectionGeometry.intersects(
            characterRange: CFRange(location: 10, length: 1),
            selectionRange: NSRange(location: 3, length: 7)
        )
    )
}

@MainActor @Test
func `native timeline selection paints inline attachments exactly once`() throws {
    let value = NSMutableAttributedString(string: "a\u{FFFC}b")
    value.addAttribute(
        .font,
        value: NSFont.systemFont(ofSize: 15),
        range: NSRange(location: 0, length: value.length)
    )
    value.addAttribute(
        .discordEmojiToken,
        value: "<:fixture:123>",
        range: NSRange(location: 1, length: 1)
    )

    #expect(
        NativeTimelineTextSelectionGeometry.backgroundRanges(
            in: value,
            selectionRange: NSRange(location: 0, length: 3)
        ) == [
            NSRange(location: 0, length: 1),
            NSRange(location: 2, length: 1),
        ]
    )

    let framesetter = CTFramesetterCreateWithAttributedString(value)
    let outerFrame = CGRect(x: 20, y: 40, width: 240, height: 28)
    let textFrame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: 0, length: value.length),
        CGPath(
            rect: CGRect(origin: .zero, size: outerFrame.size),
            transform: nil
        ),
        nil
    )
    let lineSelection = try #require(
        NativeTimelineTextSelectionGeometry.rects(
        in: textFrame,
        outerFrame: outerFrame,
        range: NSRange(location: 0, length: value.length)
        ).first
    )
    let attachmentSelection = try #require(
        NativeTimelineTextSelectionGeometry.rects(
        in: textFrame,
        outerFrame: outerFrame,
        range: NSRange(location: 1, length: 1)
        ).first
    )
    #expect(attachmentSelection.minY == lineSelection.minY)
    #expect(attachmentSelection.height == lineSelection.height)
}

@MainActor @Test
func `native timeline copied custom emojis preserve exact Discord tokens`() {
    let first = "<:aurora_glow:900000000000000101>"
    let second = "<:native_mac:900000000000000102>"
    let value = NSMutableAttributedString(string: "\u{FFFC} \u{FFFC}")
    value.addAttribute(
        .discordEmojiToken,
        value: first,
        range: NSRange(location: 0, length: 1)
    )
    value.addAttribute(
        .discordEmojiToken,
        value: second,
        range: NSRange(location: 2, length: 1)
    )

    #expect(
        RichMessageCopySerializer.string(
            from: value,
            range: NSRange(location: 0, length: value.length)
        ) == "\(first) \(second)"
    )
}

@MainActor @Test
func `native timeline vertical selection clamps beyond text to line boundaries`() {
    let value = NSAttributedString(
        string: "alpha beta",
        attributes: [.font: NSFont.systemFont(ofSize: 15)]
    )
    let framesetter = CTFramesetterCreateWithAttributedString(value)
    let frame = CGRect(x: 100, y: 200, width: 300, height: 24)

    #expect(
        NativeTimelineTextHitTester.caretIndex(
            value: value,
            framesetter: framesetter,
            frame: frame,
            point: CGPoint(x: 160, y: frame.minY - 20),
            clampsToText: true
        ) == 0
    )
    #expect(
        NativeTimelineTextHitTester.caretIndex(
            value: value,
            framesetter: framesetter,
            frame: frame,
            point: CGPoint(x: 160, y: frame.maxY + 20),
            clampsToText: true
        ) == value.length
    )
}

@Test
func `native timeline transient editor replaces exactly one row geometry`() {
    let origins: [CGFloat] = [0, 40, 100, 180]
    let heights: [CGFloat] = [40, 60, 80, 50]
    let replacementIndex = 1
    let replacementHeight: CGFloat = 110

    let displayedOrigins = origins.indices.map { index in
        NativeTimelineTransientRowGeometry.rowOrigin(
            base: origins[index],
            rowIndex: index,
            replacementIndex: replacementIndex,
            replacementHeight: replacementHeight,
            baseRowHeight: heights[replacementIndex]
        )
    }
    let displayedHeights = heights.indices.map { index in
        NativeTimelineTransientRowGeometry.rowHeight(
            base: heights[index],
            rowIndex: index,
            replacementIndex: replacementIndex,
            replacementHeight: replacementHeight
        )
    }

    #expect(displayedOrigins == [0, 40, 150, 230])
    #expect(displayedHeights == [40, 110, 80, 50])
    #expect(
        NativeTimelineTransientRowGeometry.contentHeight(
            base: 230,
            replacementHeight: replacementHeight,
            baseRowHeight: heights[replacementIndex]
        ) == 280
    )
    #expect(
        NativeTimelineTransientRowGeometry.contentOriginY(
            base: 120,
            heightDelta: replacementHeight - heights[replacementIndex],
            minimum: 8
        ) == 70
    )
    #expect(
        NativeTimelineTransientRowGeometry.contentOriginY(
            base: 40,
            heightDelta: 50,
            minimum: 8
        ) == 8
    )
    #expect(
        NativeTimelineTransientRowGeometry.contentOriginY(
            base: 8,
            heightDelta: 50,
            minimum: 8
        ) == 8
    )
}

@Test
func `native timeline transient editor can shrink a media row without overlap`() {
    #expect(
        NativeTimelineTransientRowGeometry.rowOrigin(
            base: 620,
            rowIndex: 3,
            replacementIndex: 2,
            replacementHeight: 84,
            baseRowHeight: 420
        ) == 284
    )
    #expect(
        NativeTimelineTransientRowGeometry.contentHeight(
            base: 900,
            replacementHeight: 84,
            baseRowHeight: 420
        ) == 564
    )
    #expect(
        NativeTimelineTransientRowGeometry.contentOriginY(
            base: 120,
            heightDelta: 84 - 420,
            minimum: 8
        ) == 456
    )
}

@Test
func `native timeline multiline editor growth expands the replacement row`() {
    let oneLineHeight = NativeTimelineEditingGeometry.rowHeight(
        avatarMaxY: 44,
        contentOriginY: 20,
        contentHeight: 57
    )
    let twoLineHeight = NativeTimelineEditingGeometry.rowHeight(
        avatarMaxY: 44,
        contentOriginY: 20,
        contentHeight: 74
    )

    #expect(oneLineHeight == 80)
    #expect(twoLineHeight == 97)
    #expect(
        NativeTimelineTransientRowGeometry.rowOrigin(
            base: 240,
            rowIndex: 3,
            replacementIndex: 2,
            replacementHeight: twoLineHeight,
            baseRowHeight: oneLineHeight
        ) == 257
    )
}

private struct NativeTimelineEarlierLoaderReference: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading earlier messages…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

private struct NativeTimelineThreadBeginningReference: View {
    let title: String
    let starterName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 68, height: 68)
                .background(.quaternary, in: Circle())

            Text(title)
                .font(.largeTitle.weight(.bold))

            if let starterName {
                Text("Started by \(starterName)")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("This is the start of the thread.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeTimelineLegacyPlainMessageReference: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .frame(
                    width: MessageRowLayoutMetrics.avatarDiameter,
                    height: MessageRowLayoutMetrics.avatarDiameter
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(message.author.displayName)
                        .font(.headline)
                    Text(
                        message.timestamp,
                        format: .dateTime.hour().minute()
                    )
                    .font(.caption)
                }
                SelectableMessageTextView(
                    source: message.content,
                    emojiSize: 18,
                    mentionPresentations: [:]
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 9)
    }
}

private struct NativeTimelineLegacyCommandEphemeralReference: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Color.clear.frame(width: 30, height: 20)
                AvatarView(
                    name: message.interactionMetadata?.user?.displayName
                        ?? "Someone",
                    url: message.interactionMetadata?.user?.avatarURL,
                    size: 14
                )
                Text(
                    message.interactionMetadata?.user?.displayName
                        ?? "Someone"
                )
                .font(.caption2.weight(.semibold))
                Text("used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Image(
                        systemName:
                            "xmark.triangle.circle.square.fill"
                    )
                    .font(.system(size: 9, weight: .semibold))
                    Text(
                        message.interactionMetadata?.displayName
                            ?? "command"
                    )
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Color.accentColor.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 4)
                )
            }
            .padding(.trailing, 48)
            .frame(height: 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 12) {
                AvatarView(
                    name: message.author.displayName,
                    url: message.author.avatarURL,
                    size: MessageRowLayoutMetrics.avatarDiameter
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: 7
                    ) {
                        Text(message.author.displayName)
                            .font(.headline)
                        Text("APP")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                        Text(
                            message.timestamp,
                            format: .dateTime.hour().minute()
                        )
                        .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        SelectableMessageTextView(
                            source: message.content,
                            emojiSize: 18,
                            mentionPresentations: [:]
                        )
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                            Text("Only you can see this")
                            Text("•")
                            Text("Dismiss message")
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 9)
    }
}
