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
    let label = NativeTimelineSpoilerAppearance.labelFrame(
        in: CGRect(
            origin: .zero,
            size: pill.size
        ),
        measuredLabelHeight: 13.2
    )
    #expect(label.midX == pill.width / 2)
    #expect(label.midY == pill.height / 2)
    #expect(label.height == 14)
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
    #expect(overlay.pillView.frame.midX == overlay.bounds.midX)
    #expect(overlay.pillView.frame.midY == overlay.bounds.midY)
    #expect(overlay.pillLabel.frame.midX == overlay.pillView.bounds.midX)
    #expect(overlay.pillLabel.frame.midY == overlay.pillView.bounds.midY)
    #expect(overlay.pillLabel.frame.height < overlay.pillView.bounds.height)
    let paragraphStyle = try #require(
        overlay.pillLabel.attributedStringValue.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
    )
    #expect(paragraphStyle.alignment == .center)

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
        TimelineTextAccessibility.text(
            value,
            revealedLocations: []
        ) == "before Spoiler after"
    )
    #expect(
        TimelineTextAccessibility
            .hiddenSpoilerRanges(
                in: value,
                revealedLocations: []
            ) == [NSRange(location: 7, length: 6)]
    )
    #expect(
        TimelineTextAccessibility.text(
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
        TimelineTextAccessibility.text(
            value,
            revealedLocations: []
        ) == "before Spoiler after"
    )
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
    #expect(
        NativeTimelineShortContentRedrawPolicy.redrawsSynchronously(
            conversationChanged: false,
            appendedAtTail: true
        )
    )
    #expect(
        !NativeTimelineShortContentRedrawPolicy.redrawsSynchronously(
            conversationChanged: true,
            appendedAtTail: true
        )
    )
    #expect(
        !NativeTimelineShortContentRedrawPolicy.redrawsSynchronously(
            conversationChanged: false,
            appendedAtTail: false
        )
    )
    #expect(
        TimelineAccessibilityWorkPolicy.reconcilesEagerly(
            isVoiceOverEnabled: true,
            isSwitchControlEnabled: false
        )
    )
    #expect(
        TimelineAccessibilityWorkPolicy.reconcilesEagerly(
            isVoiceOverEnabled: false,
            isSwitchControlEnabled: true
        )
    )
    #expect(
        !TimelineAccessibilityWorkPolicy.reconcilesEagerly(
            isVoiceOverEnabled: false,
            isSwitchControlEnabled: false
        )
    )
    #expect(
        HoverActionPillMetrics.size(controlCount: 1)
            == CGSize(width: 36, height: 36)
    )
    #expect(
        HoverActionPillMetrics.size(controlCount: 5)
            == CGSize(width: 152, height: 36)
    )
}

@Test
@MainActor
func `cross surface scroll work gate stays active until every surface ends`() {
    let timelineScrollView = NSScrollView()
    let serverListScrollView = NSScrollView()
    let timelineProbe = ScrollInputPerformanceProbe(surface: .timeline)
    let serverListProbe = ScrollInputPerformanceProbe(surface: .serverList)
    var ownsBenchmarkActivity = true
    AppScrollWorkGate.beginActivity()
    timelineProbe.install(on: timelineScrollView)
    serverListProbe.install(on: serverListScrollView)
    defer {
        if ownsBenchmarkActivity {
            AppScrollWorkGate.endActivity()
        }
        timelineProbe.invalidate()
        serverListProbe.invalidate()
    }

    NotificationCenter.default.post(
        name: NSScrollView.willStartLiveScrollNotification,
        object: timelineScrollView
    )
    #expect(AppScrollActivity.isActive)
    #expect(AppScrollWorkGate.isActive)

    NotificationCenter.default.post(
        name: NSScrollView.willStartLiveScrollNotification,
        object: serverListScrollView
    )
    NotificationCenter.default.post(
        name: NSScrollView.didEndLiveScrollNotification,
        object: timelineScrollView
    )
    #expect(AppScrollActivity.isActive)
    #expect(AppScrollWorkGate.isActive)

    NotificationCenter.default.post(
        name: NSScrollView.didEndLiveScrollNotification,
        object: serverListScrollView
    )
    #expect(!AppScrollActivity.isActive)
    #expect(AppScrollWorkGate.isActive)

    AppScrollWorkGate.endActivity()
    ownsBenchmarkActivity = false
    #expect(!AppScrollWorkGate.isActive)
}

@MainActor
@Test func `conversation replacement defers live append short content redraw`() {
    let viewport = CGRect(x: 0, y: 0, width: 560, height: 400)
    let canvas = NativeTimelineCanvasView(frame: viewport)
    let scrollView = NSScrollView(frame: viewport)
    scrollView.documentView = canvas
    let window = NSWindow(
        contentRect: viewport,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    let storage = NativeTimelineCanvasStorage()
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
    let shortContentOrigin =
        ChatDetailLayoutPolicy.timelineTopPadding + 100

    canvas.apply(
        storage: storage,
        model: model,
        actions: actions,
        viewportWidth: viewport.width,
        minimumHeight: viewport.height,
        bottomSpacerHeight: 0,
        contentOriginY: shortContentOrigin,
        redrawsMovedShortContentSynchronously: false
    )
    #expect(canvas.synchronousShortContentRedrawCount == 0)

    canvas.apply(
        storage: storage,
        model: model,
        actions: actions,
        viewportWidth: viewport.width,
        minimumHeight: viewport.height,
        bottomSpacerHeight: 0,
        contentOriginY: shortContentOrigin + 20
    )
    #expect(canvas.synchronousShortContentRedrawCount == 1)
}

@MainActor
@Test func `timeline accessibility query materializes lazy row proxies`() {
    let viewport = CGRect(x: 0, y: 0, width: 560, height: 400)
    let channel = Channel(
        id: ChannelID(rawValue: 9_001),
        guildID: GuildID(rawValue: 9_002),
        name: "accessibility",
        kind: .text
    )
    let item = NativeMessageTimelineItem.beginning(
        .channel(channel, rulesChannelID: nil)
    )
    let layout = NativeTimelineRowLayout.make(
        item: item,
        width: viewport.width
    )
    let storage = NativeTimelineCanvasStorage()
    storage.items = [item]
    storage.layouts = [layout]
    storage.rowOrigins = [0]
    storage.contentHeight = layout.height
    let canvas = NativeTimelineCanvasView(frame: viewport)
    let scrollView = NSScrollView(frame: viewport)
    scrollView.documentView = canvas
    let window = NSWindow(
        contentRect: viewport,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
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
            openThread: { _ in },
            submitComponent: { _, _, _, _ in }
        ),
        viewportWidth: viewport.width,
        minimumHeight: viewport.height,
        bottomSpacerHeight: 0,
        contentOriginY: 0
    )
    canvas.removeAccessibilityProxies()
    #expect(canvas.accessibilityProxyRowsInTimelineOrder().isEmpty)

    #expect(canvas.accessibilityRows()?.count == 1)
    #expect(canvas.accessibilityProxyRowsInTimelineOrder().count == 1)
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
@Test func `attachment loading and painting share one stable media key`() throws {
    let source = try #require(URL(string: "https://cdn.example/image.png"))
    let proxy = try #require(URL(string: "https://media.example/image.png"))
    let image = Attachment(
        id: "image",
        filename: "image.png",
        url: source,
        proxyURL: proxy,
        mediaType: "image/png",
        width: 1_600,
        height: 900
    )
    let video = Attachment(
        id: "video",
        filename: "video.mov",
        url: source,
        proxyURL: proxy,
        mediaType: "video/quicktime",
        width: 1_600,
        height: 900
    )

    #expect(
        NativeTimelineMediaKey.attachment(image)
            == .media(proxy, fallbackURL: source)
    )
    #expect(
        NativeTimelineMediaKey.attachment(image)?.loadURLs
            == [proxy, source]
    )
    #expect(NativeTimelineMediaKey.attachment(video) == nil)
}

@MainActor
@Test func `updating a visible media lease keeps shared images pinned`() throws {
    let firstKey = NativeTimelineMediaKey.media(try #require(URL(
        string: "https://cdn.example/visible-first.png"
    )))
    let secondKey = NativeTimelineMediaKey.media(try #require(URL(
        string: "https://cdn.example/visible-second.png"
    )))
    let firstImage = NSImage(size: NSSize(width: 32, height: 32))
    let secondImage = NSImage(size: NSSize(width: 32, height: 32))
    let owner = UUID()
    let store = NativeTimelineMediaStore.shared

    store.cacheImageForTesting(firstImage, for: firstKey)
    store.pinLoadedImages(for: [firstKey], owner: owner)
    store.evictVolatileImageForTesting(for: firstKey)
    store.cacheImageForTesting(secondImage, for: secondKey)
    store.pinLoadedImages(for: [firstKey, secondKey], owner: owner)
    store.evictVolatileImageForTesting(for: secondKey)

    #expect((store.image(for: firstKey) as AnyObject?) === firstImage)
    #expect((store.image(for: secondKey) as AnyObject?) === secondImage)

    store.pinLoadedImages(for: [secondKey], owner: owner)
    #expect(store.image(for: firstKey) == nil)
    #expect((store.image(for: secondKey) as AnyObject?) === secondImage)
    store.releasePinnedImages(owner: owner)
    #expect(store.image(for: secondKey) == nil)
}

@MainActor
@Test func `retained row media has a hard decoded pixel budget`() throws {
    let store = NativeTimelineMediaStore.shared
    let image = NSImage(size: NSSize(width: 1_024, height: 1_024))
    let representation = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1_024,
            pixelsHigh: 1_024,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    )
    image.addRepresentation(representation)
    var owners: [UUID] = []

    for index in 0 ..< 10 {
        let key = NativeTimelineMediaKey.media(try #require(URL(
            string: "https://cdn.example/large-\(index).png"
        )))
        let owner = UUID()
        owners.append(owner)
        store.cacheImageForTesting(image, for: key)
        store.pinLoadedImages(for: [key], owner: owner)
    }

    #expect(
        store.pinnedImageCostForTesting
            <= store.pinnedImageCostLimitForTesting
    )
    for owner in owners {
        store.releasePinnedImages(owner: owner)
    }
    #expect(store.pinnedImageCostForTesting == 0)
}

@MainActor
@Test func `visible gallery survives deterministic decoded cache trimming`() throws {
    let store = NativeTimelineMediaStore.shared
    let image = NSImage(size: NSSize(width: 1_024, height: 1_024))
    let representation = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1_024,
            pixelsHigh: 1_024,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    )
    image.addRepresentation(representation)
    let keys = try (0 ..< 20).map { index in
        NativeTimelineMediaKey.media(try #require(URL(
            string: "https://cdn.example/cache-pressure-\(index).png"
        )))
    }
    let visibleKey = keys[0]
    let owner = UUID()
    defer {
        store.releaseVisibleImages(owner: owner)
        for key in keys {
            store.evictVolatileImageForTesting(for: key)
        }
    }

    store.cacheImageForTesting(image, for: visibleKey)
    store.retainVisibleImages(for: [visibleKey], owner: owner)
    for key in keys.dropFirst() {
        store.cacheImageForTesting(image, for: key)
    }

    #expect((store.image(for: visibleKey) as AnyObject?) === image)
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
            wasLoading: true,
            isLoading: false,
            previousRowCount: 100,
            currentRowCount: 150
        )
    )
    #expect(
        !NativeTimelineAutomaticHistoryPolicy.shouldReevaluateAfterUpdate(
            wasLoading: true,
            isLoading: false,
            previousRowCount: 100,
            currentRowCount: 100
        )
    )
    #expect(
        !NativeTimelineAutomaticHistoryPolicy.shouldReevaluateAfterUpdate(
            wasLoading: false,
            isLoading: false,
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
func `fitting exact unread run opens at true bottom and reports newest boundary`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    model.navigate(to: ChannelID(rawValue: 210))
    let deadline = ContinuousClock.now + .seconds(1)
    while model.messages.count < 9,
          ContinuousClock.now < deadline
    {
        try await Task.sleep(for: .milliseconds(2))
    }
    let conversationID = try #require(model.selectedChannelID)
    let unreadMessage = try #require(
        model.messages.dropLast(2).last
    )
    let newestMessage = try #require(model.messages.last)
    var initialStates: [TimelineScrollState] = []
    let timeline = NativeMessageTimelineView(
        model: model,
        conversation: .channel(conversationID),
        beginning: nil,
        firstMessageStartsDayOverride: nil,
        hasMoreMessages: false,
        isLoadingEarlier: false,
        bottomContentInset: 76,
        unreadMessageID: unreadMessage.id,
        highlightedMessageID: nil,
        initialScrollTarget: .message(
            unreadMessage.id,
            anchor: TimelineInitialPositionPolicy.unreadViewportAnchor
        ),
        scrollRequest: nil,
        runsPerformanceAutoScroll: false,
        loadEarlier: {},
        openReply: { _ in },
        onScrollActivityChange: { _ in },
        onScrollStateChange: { _ in },
        onInitialPositionEstablished: { initialStates.append($0) },
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
    for _ in 0 ..< 4 {
        await Task.yield()
    }

    let unreadOffset = try #require(
        coordinator.messageOffsetFromViewportTopForTesting(unreadMessage.id)
    )
    let newestOffset = try #require(
        coordinator.messageOffsetFromViewportTopForTesting(newestMessage.id)
    )
    let newestHeight = try #require(
        coordinator.messageHeightForTesting(newestMessage.id)
    )
    #expect(
        newestOffset + newestHeight - unreadOffset + 76
            <= scrollView.contentView.bounds.height + 0.5
    )
    #expect(
        coordinator.contentHeightForTesting + 76
            > scrollView.contentView.bounds.height
    )
    #expect(coordinator.scrollStateForTesting.isNearBottom)
    #expect(
        coordinator.scrollStateForTesting
            .hasReachedNewestMessageBoundary
    )
    #expect(initialStates.last?.isNearBottom == true)
    #expect(
        initialStates.last?.hasReachedNewestMessageBoundary
            == true
    )
    coordinator.stopObserving()
}

@MainActor @Test
func `scrolling a tall unread timeline to bottom publishes the read boundary`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    model.navigate(to: ChannelID(rawValue: 210))
    let deadline = ContinuousClock.now + .seconds(1)
    while model.messages.count < 9,
          ContinuousClock.now < deadline
    {
        try await Task.sleep(for: .milliseconds(2))
    }
    let conversationID = try #require(model.selectedChannelID)
    let unreadMessage = try #require(
        model.messages.dropFirst(4).dropLast(4).first
    )
    var reportedStates: [TimelineScrollState] = []
    func timeline(
        scrollRequest: MessageTimelineScrollRequest?
    ) -> NativeMessageTimelineView {
        NativeMessageTimelineView(
            model: model,
            conversation: .channel(conversationID),
            beginning: nil,
            firstMessageStartsDayOverride: nil,
            hasMoreMessages: false,
            isLoadingEarlier: false,
            bottomContentInset: 76,
            unreadMessageID: unreadMessage.id,
            highlightedMessageID: nil,
            initialScrollTarget: .message(
                unreadMessage.id,
                anchor: TimelineInitialPositionPolicy.unreadViewportAnchor
            ),
            scrollRequest: scrollRequest,
            runsPerformanceAutoScroll: false,
            loadEarlier: {},
            openReply: { _ in },
            onScrollActivityChange: { _ in },
            onScrollStateChange: { reportedStates.append($0) },
            onUserScrollBegan: {},
            onUserScrollEnded: { _ in }
        )
    }
    let initialTimeline = timeline(scrollRequest: nil)
    let coordinator = initialTimeline.makeCoordinator()
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = CGRect(x: 0, y: 0, width: 820, height: 500)
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.update(parent: initialTimeline, scrollView: scrollView)
    coordinator.reconcileViewportGeometryForTesting()
    #expect(
        !coordinator.scrollStateForTesting
            .hasReachedNewestMessageBoundary
    )

    coordinator.update(
        parent: timeline(
            scrollRequest: MessageTimelineScrollRequest(target: .bottom)
        ),
        scrollView: scrollView
    )
    for _ in 0 ..< 4 {
        await Task.yield()
    }

    #expect(coordinator.scrollStateForTesting.isNearBottom)
    #expect(
        coordinator.scrollStateForTesting
            .hasReachedNewestMessageBoundary
    )
    #expect(reportedStates.last?.isNearBottom == true)
    #expect(
        reportedStates.last?.hasReachedNewestMessageBoundary
            == true
    )
    coordinator.stopObserving()
}

@MainActor @Test
func `media rich timeline establishes unread context before display and preserves it while resizing`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    model.navigate(to: ChannelID(rawValue: 210))
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
    #expect(
        coordinator.scrollStateForTesting
            .hasEstablishedInitialPosition
    )
    #expect(
        !coordinator.scrollStateForTesting
            .hasReachedNewestMessageBoundary
    )

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
func `completed initial ten message page exposes history reserve before first upward delta`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 99_221)
    let author = User(
        id: UserID(rawValue: 99_222),
        username: "initial-page",
        displayName: "Initial Page"
    )
    let messages = (0 ..< 10).map { index in
        Message(
            id: MessageID(rawValue: UInt64(99_230 + index)),
            channelID: channelID,
            author: author,
            content: "Initial page message \(index)"
        )
    }
    model.replaceSelectedMessages(with: messages)
    var loadEarlierCount = 0
    var userScrollBeganCount = 0
    func timeline(
        hasMoreMessages: Bool,
        isLoadingEarlier: Bool
    ) -> NativeMessageTimelineView {
        NativeMessageTimelineView(
            model: model,
            conversation: .channel(channelID),
            beginning: nil,
            firstMessageStartsDayOverride: nil,
            hasMoreMessages: hasMoreMessages,
            isLoadingEarlier: isLoadingEarlier,
            bottomContentInset: 0,
            unreadMessageID: nil,
            highlightedMessageID: nil,
            initialScrollTarget: .bottom,
            scrollRequest: nil,
            runsPerformanceAutoScroll: false,
            loadEarlier: { loadEarlierCount += 1 },
            openReply: { _ in },
            onScrollActivityChange: { _ in },
            onScrollStateChange: { _ in },
            onUserScrollBegan: { userScrollBeganCount += 1 },
            onUserScrollEnded: { _ in }
        )
    }
    // The model publishes the ten messages before it publishes the page's
    // has-more boundary. That intermediate update already contains the
    // leading loader and all ten rows, which was the transition the previous
    // regression test failed to represent.
    let loadingTimeline = timeline(
        hasMoreMessages: false,
        isLoadingEarlier: true
    )
    let coordinator = loadingTimeline.makeCoordinator()
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = CGRect(x: 0, y: 0, width: 820, height: 700)
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.update(parent: loadingTimeline, scrollView: scrollView)
    coordinator.reconcileViewportGeometryForTesting()
    let canvas = try #require(coordinator.canvas)

    #expect(coordinator.rowCount == 10)
    #expect(coordinator.leadingHistoryReserve == 0)

    let completedTimeline = timeline(
        hasMoreMessages: true,
        isLoadingEarlier: false
    )
    coordinator.update(parent: completedTimeline, scrollView: scrollView)

    #expect(
        coordinator.leadingHistoryReserve
            == NativeMessageTimelineCoordinator.leadingHistoryReserveChunk
    )
    #expect(!coordinator.followsMaterializedHistoryBoundary)
    #expect(canvas.historySkeleton == nil)

    coordinator.liveScrollTrackingWillBegin()

    #expect(coordinator.followsMaterializedHistoryBoundary)
    #expect(canvas.historySkeleton != nil)
    #expect(
        coordinator.provisionalHistoryMinimumY(
            viewportHeight: scrollView.contentView.bounds.height
        ) == 0
    )
    #expect(loadEarlierCount == 1)
    #expect(userScrollBeganCount == 1)

    coordinator.liveScrollTrackingDidEnd()
    #expect(!coordinator.followsMaterializedHistoryBoundary)
    #expect(canvas.historySkeleton == nil)
    coordinator.stopObserving()
}

@MainActor @Test
func `rapid gesture boundary does not restore timeline presentation between swipes`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 99_260)
    let timeline = NativeMessageTimelineView(
        model: model,
        conversation: .channel(channelID),
        beginning: nil,
        firstMessageStartsDayOverride: nil,
        hasMoreMessages: false,
        isLoadingEarlier: false,
        bottomContentInset: 0,
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
    coordinator.update(parent: timeline, scrollView: scrollView)
    let canvas = try #require(coordinator.canvas)

    coordinator.liveScrollTrackingWillBegin()
    #expect(canvas.suppressesHoverPresentation)

    coordinator.liveScrollTrackingDidEnd()
    #expect(canvas.suppressesHoverPresentation)
    #expect(coordinator.scrollIdleTask != nil)

    coordinator.liveScrollTrackingWillBegin()
    #expect(canvas.suppressesHoverPresentation)
    coordinator.stopObserving()
}

@MainActor @Test
func `completed anchored page exposes the same history reserve below its loaded window`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 99_241)
    let author = User(
        id: UserID(rawValue: 99_242),
        username: "anchored-page",
        displayName: "Anchored Page"
    )
    let messages = (0 ..< 10).map { index in
        Message(
            id: MessageID(rawValue: UInt64(99_250 + index)),
            channelID: channelID,
            author: author,
            content: "Anchored page message \(index)"
        )
    }
    model.replaceSelectedMessages(with: messages)
    var loadLaterCount = 0
    var userScrollBeganCount = 0
    func timeline(
        hasMoreLaterMessages: Bool,
        isLoadingLater: Bool
    ) -> NativeMessageTimelineView {
        NativeMessageTimelineView(
            model: model,
            conversation: .channel(channelID),
            beginning: nil,
            firstMessageStartsDayOverride: nil,
            hasMoreMessages: false,
            hasMoreLaterMessages: hasMoreLaterMessages,
            isLoadingEarlier: false,
            isLoadingLater: isLoadingLater,
            bottomContentInset: 0,
            unreadMessageID: nil,
            highlightedMessageID: nil,
            initialScrollTarget: .bottom,
            scrollRequest: nil,
            runsPerformanceAutoScroll: false,
            loadEarlier: {},
            loadLater: { loadLaterCount += 1 },
            openReply: { _ in },
            onScrollActivityChange: { _ in },
            onScrollStateChange: { _ in },
            onUserScrollBegan: { userScrollBeganCount += 1 },
            onUserScrollEnded: { _ in }
        )
    }

    let loadingTimeline = timeline(
        hasMoreLaterMessages: false,
        isLoadingLater: true
    )
    let coordinator = loadingTimeline.makeCoordinator()
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = CGRect(x: 0, y: 0, width: 820, height: 700)
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.update(parent: loadingTimeline, scrollView: scrollView)
    coordinator.reconcileViewportGeometryForTesting()
    let canvas = try #require(coordinator.canvas)

    #expect(coordinator.rowCount == 10)
    #expect(coordinator.trailingHistoryReserve == 0)

    let completedTimeline = timeline(
        hasMoreLaterMessages: true,
        isLoadingLater: false
    )
    coordinator.update(parent: completedTimeline, scrollView: scrollView)

    #expect(
        coordinator.trailingHistoryReserve
            == NativeMessageTimelineCoordinator.historyReserveChunk
    )
    #expect(!coordinator.followsMaterializedLaterHistoryBoundary)
    #expect(canvas.historySkeleton == nil)

    coordinator.liveScrollTrackingWillBegin()

    #expect(coordinator.followsMaterializedLaterHistoryBoundary)
    #expect(canvas.historySkeleton != nil)
    #expect(
        coordinator.provisionalHistoryBoundaryY(
            .later,
            viewportHeight: scrollView.contentView.bounds.height
        )
            > coordinator.materializedHistoryScrollBoundaryY(
                .later,
                viewportHeight: scrollView.contentView.bounds.height
            )
    )
    #expect(loadLaterCount == 1)
    #expect(userScrollBeganCount == 1)

    coordinator.liveScrollTrackingDidEnd()
    #expect(!coordinator.followsMaterializedLaterHistoryBoundary)
    #expect(canvas.historySkeleton == nil)
    coordinator.stopObserving()
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
func `native timeline does not auto load third party linked images`() throws {
    let content = "[invoice](https://tracking.example/view.png?recipient=unique)"
    let presentation = LinkedImagePresentation(content: content)
    let message = Message(
        id: MessageID(rawValue: 12),
        channelID: ChannelID(rawValue: 13),
        author: User(
            id: UserID(rawValue: 14),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: content
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

    #expect(presentation.images.isEmpty)
    #expect(presentation.visibleText == content)
    #expect(layout.linkedImageRegions.isEmpty)
    #expect(layout.attributedContent?.string.contains("invoice") == true)
}

@MainActor @Test
func `timeline mention text prewarms off main without changing its resolved presentation`() async throws {
    let message = Message(
        id: MessageID(rawValue: 98_001),
        channelID: ChannelID(rawValue: 98_002),
        author: User(
            id: UserID(rawValue: 98_003),
            username: "prewarm.fixture",
            displayName: "Prewarm Fixture"
        ),
        content: "Hello <@98004>"
    )
    let plan = NativeTimelineTextPlan.make(for: message)
    let preparation = try #require(
        NativeTimelineTextPresentation.preparation(
            message: message,
            plan: plan,
            model: nil
        )
    )

    let prewarmed = await Task.detached(priority: .utility) {
        NativeTimelineTextPresentation.prewarm(preparation)
    }.value
    let presentation = NativeTimelineTextPresentation.make(
        message: message,
        plan: plan,
        model: nil
    )

    #expect(presentation.attributedContent === prewarmed.value)
    let mention = try #require(
        presentation.attributedContent?.attribute(
            .nativeTimelineMention,
            at: 6,
            effectiveRange: nil
        ) as? NativeTimelineMentionBox
    )
    #expect(mention.presentation.label == "@unknown-user")
}

@Test
func `linked image trust rejects lookalike insecure and credential URLs`() throws {
    let accepted = try #require(URL(
        string: "https://cdn.discordapp.com/attachments/1/2/image.webp"
    ))
    let rejected = try [
        #require(URL(string: "https://tracking.example/image.webp")),
        #require(URL(string: "https://cdn.discordapp.com.example/image.webp")),
        #require(URL(string: "http://cdn.discordapp.com/image.webp")),
        #require(URL(string: "https://user@cdn.discordapp.com/image.webp")),
        #require(URL(string: "https://cdn.discordapp.com:8443/image.webp"))
    ]

    #expect(LinkedImageReference.isSupported(accepted))
    #expect(rejected.allSatisfy {
        !LinkedImageReference.isSupported($0)
    })
}

@Test
func `timeline avatar animation policy avoids decoding ordinary static avatars`() throws {
    let staticAvatar = try #require(URL(
        string:
            "https://cdn.discordapp.com/avatars/1/static.webp?size=128&animated=false"
    ))
    let animatedAvatar = try #require(URL(
        string:
            "https://cdn.discordapp.com/avatars/1/a_hash.webp?size=128&animated=true"
    ))
    let gifAvatar = try #require(URL(
        string: "https://example.com/avatar.gif"
    ))

    #expect(
        !NativeTimelineAvatarPresentation
            .shouldDecodeAnimation(for: staticAvatar)
    )
    #expect(
        NativeTimelineAvatarPresentation
            .shouldDecodeAnimation(for: animatedAvatar)
    )
    #expect(
        NativeTimelineAvatarPresentation
            .shouldDecodeAnimation(for: gifAvatar)
    )
    let decorationFrame =
        NativeTimelineAvatarPresentation.decorationFrame(
            around: CGRect(x: 14, y: 3, width: 38, height: 38)
        )
    #expect(abs(decorationFrame.minX - 10.96) < 0.000_001)
    #expect(abs(decorationFrame.minY + 0.04) < 0.000_001)
    #expect(abs(decorationFrame.width - 44.08) < 0.000_001)
    #expect(abs(decorationFrame.height - 44.08) < 0.000_001)
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
