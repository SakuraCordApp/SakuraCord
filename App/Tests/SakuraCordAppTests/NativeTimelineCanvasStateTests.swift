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
    #expect(!state.hasHoverOrPressTargets)
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
