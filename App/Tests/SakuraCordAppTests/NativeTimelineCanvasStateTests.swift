import AppKit
@testable import SakuraCord
import SakuraCordModels
import SwiftUI
import Testing

@MainActor @Test
func `pointer state clears every hover and press target as one invariant`() {
    let state = NativeTimelinePointerState()
    let messageID = MessageID(rawValue: 71)
    let component = NativeTimelineComponentButtonTarget(
        messageID: messageID,
        componentID: "confirm"
    )
    state.hoveredRow = 4
    state.hoveredCompactTimestampRow = 3
    state.hoveredComponentButton = component
    state.hoveredForwardedSourceMessageID = messageID
    state.visualPressedComponentButton = component
    state.componentButtonPressProgress = 0.75
    state.componentButtonPressAnimationDestination = 1
    state.componentButtonPressAnimationTask = Task {}
    state.pressedActivationTarget = .componentSelect(
        messageID,
        "select"
    )
    let cleared = state.clearHoverAndPressTargets()

    #expect(cleared.row == 4)
    #expect(cleared.compactTimestampRow == 3)
    #expect(cleared.componentButton == component)
    #expect(cleared.forwardedSourceMessageID == messageID)
    #expect(!state.hasHoverOrPressTargets)
}

@MainActor @Test
func `forward overlay interaction block clears native hover and tracking state`() {
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 560, height: 400)
    )
    canvas.hoveredRow = 4
    canvas.hoveredForwardedSourceMessageID = MessageID(rawValue: 72)

    canvas.setOverlayInteractionBlocked(true)

    #expect(canvas.overlayBlocksInteractions)
    #expect(!canvas.pointer.hasHoverOrPressTargets)
    #expect(canvas.rowTrackingAreas.isEmpty)
}

@Test
func `message jump highlight holds then fades to transparent`() {
    let hold = NativeTimelineMessageJumpHighlightPolicy.holdDuration
    let fade = NativeTimelineMessageJumpHighlightPolicy.fadeDuration

    #expect(
        NativeTimelineMessageJumpHighlightPolicy.opacity(elapsed: 0) == 1
    )
    #expect(
        NativeTimelineMessageJumpHighlightPolicy.opacity(elapsed: hold) == 1
    )
    let midpointOpacity =
        NativeTimelineMessageJumpHighlightPolicy.opacity(
            elapsed: hold + fade / 2
        )
    #expect(abs(midpointOpacity - 0.5) < 0.000_001)
    #expect(
        NativeTimelineMessageJumpHighlightPolicy.opacity(
            elapsed: hold + fade
        ) == 0
    )
    #expect(
        NativeTimelineMessageJumpHighlightPolicy.opacity(
            elapsed: hold + fade / 2,
            reducesMotion: true
        ) == 1
    )
}

@MainActor @Test
func `message jump highlight uses the canonical message highlight frame`() throws {
    let message = Message(
        id: MessageID(rawValue: 73),
        channelID: ChannelID(rawValue: 74),
        author: User(
            id: UserID(rawValue: 75),
            username: "highlight",
            displayName: "Highlight"
        ),
        content: "Jump highlighting must not include the day separator."
    )
    let item = NativeMessageTimelineItem.message(
        MessageRowPresentation(
            message: message,
            startsGroup: true,
            startsDay: true,
            replyPreview: nil,
            isReplyAvailable: false
        ),
        isUnreadBoundary: false,
        isHighlighted: true
    )
    let layout = NativeTimelineRowLayout.make(item: item, width: 560)
    let storage = NativeTimelineCanvasStorage()
    storage.items = [item]
    storage.layouts = [layout]
    storage.rowOrigins = [0]
    storage.contentHeight = layout.height
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 560, height: layout.height + 24)
    )
    canvas.storage = storage
    canvas.baseContentOriginY = 24
    canvas.contentOriginY = 24
    let startedAt: TimeInterval = 100
    canvas.messageJumpHighlight = .init(
        messageID: message.id,
        startedAt: startedAt
    )

    let presentation = try #require(
        canvas.messageJumpHighlightPresentation(
            at: 0,
            uptime: startedAt
        )
    )
    let highlightFrame = try #require(layout.highlightFrame)

    #expect(
        presentation.frame
            == highlightFrame.offsetBy(dx: 0, dy: 24)
    )
    #expect(presentation.frame != canvas.rowFrame(at: 0))
    #expect(presentation.opacity == 1)
}

@MainActor @Test
func `editing session clear removes its overlay and all geometry`() {
    let parent = NSView()
    let host = NativeTimelineEditingHost(rootView: AnyView(EmptyView()))
    let textView = ComposerNSTextView()
    parent.addSubview(host)
    let session = NativeTimelineEditingSession()
    session.host = host
    session.textView = textView
    session.messageID = MessageID(rawValue: 72)
    session.rowIndex = 5
    session.rowHeight = 120
    session.overlayLocalFrame = CGRect(x: 1, y: 2, width: 3, height: 4)
    session.scrollSnapshot = NSImage(size: NSSize(width: 2, height: 2))

    session.clear()

    #expect(host.superview == nil)
    #expect(!session.isActive)
    #expect(session.host == nil)
    #expect(session.textView == nil)
    #expect(session.rowIndex == nil)
    #expect(session.rowHeight == nil)
    #expect(session.overlayLocalFrame == nil)
    #expect(session.scrollSnapshot == nil)
}

@MainActor @Test
func `active message picker keeps its originating action capsule`() throws {
    let author = User(
        id: UserID(rawValue: 700),
        username: "fixture",
        displayName: "Fixture"
    )
    let messages = [701, 702].map { rawID in
        Message(
            id: MessageID(rawValue: UInt64(rawID)),
            channelID: ChannelID(rawValue: 703),
            author: author,
            content: "Message \(rawID)"
        )
    }
    let items = messages.map { message in
        NativeMessageTimelineItem.message(
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
    }
    let layouts = items.map {
        NativeTimelineRowLayout.make(item: $0, width: 560)
    }
    let storage = NativeTimelineCanvasStorage()
    storage.items = items
    storage.layouts = layouts
    storage.rowOrigins = [0, layouts[0].height]
    storage.contentHeight = layouts.reduce(0) { $0 + $1.height }
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(x: 0, y: 0, width: 560, height: storage.contentHeight)
    )
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
        viewportWidth: 560,
        minimumHeight: storage.contentHeight,
        bottomSpacerHeight: 0,
        contentOriginY: 0
    )
    let host = NativeTimelineActionCapsuleHost(rootView: AnyView(EmptyView()))
    canvas.addSubview(host)
    let state = NativeTimelineActionCapsuleState()
    state.isReactionPickerPresented = true
    canvas.actionCapsuleHost = host
    canvas.actionCapsuleState = state
    canvas.actionCapsuleMessageID = messages[0].id
    canvas.actionCapsuleSize = NSSize(width: 100, height: 40)
    canvas.hoveredRow = 0

    canvas.reconcileActionCapsule()
    let secondHighlight = try #require(layouts[1].highlightFrame)
    let secondPoint = CGPoint(
        x: secondHighlight.midX,
        y: canvas.displayedRowOrigin(at: 1) + secondHighlight.midY
    )
    #expect(!canvas.actionCapsuleContains(secondPoint))
    canvas.synchronizeHoveredRow(at: secondPoint)

    #expect(canvas.hoveredRow == 1)
    #expect(canvas.actionCapsuleMessageID == messages[0].id)
    #expect(canvas.actionCapsuleHost === host)
    #expect(host.superview === canvas)
    canvas.removeActionCapsule()
}

@MainActor @Test
func `accessibility proxy store keeps rows items and order synchronized`() {
    let parent = NSView()
    let store = NativeTimelineAccessibilityProxyStore<Int, String>()
    let first = NativeTimelineAccessibilityProxyView(
        source: NSAccessibilityElement()
    )
    let second = NativeTimelineAccessibilityProxyView(
        source: NSAccessibilityElement()
    )
    parent.addSubview(first)
    parent.addSubview(second)
    store.install(first, item: "first", for: 1)
    store.install(second, item: "second", for: 2)
    store.setOrder([2, 99, 1, 2])

    #expect(store.order == [2, 1])
    #expect(store.orderedRows().map(ObjectIdentifier.init) == [
        ObjectIdentifier(second),
        ObjectIdentifier(first),
    ])
    #expect(store.isConsistent)

    let replacement = NativeTimelineAccessibilityProxyView(
        source: NSAccessibilityElement()
    )
    parent.addSubview(replacement)
    store.install(replacement, item: "replacement", for: 1)
    #expect(first.superview == nil)
    #expect(store.item(for: 1) == "replacement")
    #expect(store.isConsistent)

    store.removeAll()
    #expect(second.superview == nil)
    #expect(replacement.superview == nil)
    #expect(store.order.isEmpty)
    #expect(store.isConsistent)
}
