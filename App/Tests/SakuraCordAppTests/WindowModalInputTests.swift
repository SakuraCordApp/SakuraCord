import AppKit
@testable import SakuraCord
import SwiftUI
import Testing

@MainActor
@Test func `modal ownership follows presentation order and excludes retained hidden hosts`() {
    let window = modalTestWindow()
    let otherWindow = modalTestWindow()
    let background = window.contentView!
    let first = modalTestHost(in: window)
    let second = modalTestHost(in: window)
    let retained = modalTestHost(in: window, behavior: .instantKeyboardOwned)
    let coordinator = WindowModalCoordinator.coordinator(for: window)
    defer {
        for host in [first, second, retained] { host.unregisterInput(); host.removeFromSuperview() }
    }

    retained.hideImmediately()
    #expect(!WindowModalCoordinator.allowsInput(for: retained))
    first.present()
    #expect(coordinator.topmost === first)
    #expect(!WindowModalCoordinator.allowsInput(for: background))
    #expect(WindowModalCoordinator.allowsInput(for: otherWindow.contentView!))
    second.present()
    #expect(!WindowModalCoordinator.allowsInput(for: first))
    #expect(WindowModalCoordinator.allowsInput(for: second))
    #expect(first.hitTest(.zero) == nil)
    #expect(second.hitTest(.zero) != nil)
    retained.present()
    #expect(coordinator.topmost === retained)
    retained.hideImmediately()
    #expect(coordinator.topmost === second)
    #expect(!WindowModalCoordinator.allowsInput(for: retained))
}

@MainActor
@Test func `removing a covered modal preserves top focus and repairs restoration`() {
    let window = modalTestWindow()
    let original = ModalTestResponder(frame: .zero)
    window.contentView!.addSubview(original)
    window.makeFirstResponder(original)
    let first = modalTestHost(in: window)
    let second = modalTestHost(in: window)
    first.present()
    second.present()
    first.unregisterInput()
    first.removeFromSuperview()
    #expect(window.firstResponder === second)
    second.unregisterInput()
    second.removeFromSuperview()
    #expect(window.firstResponder === original)
}

@MainActor
@Test func `modal rejects momentum from covered and subsequently revealed surfaces`() {
    let window = modalTestWindow()
    let host = modalTestHost(in: window)
    let coordinator = WindowModalCoordinator.coordinator(for: window)
    host.present()
    defer { host.unregisterInput(); host.removeFromSuperview() }

    #expect(!coordinator.allowsScroll(phase: [], momentumPhase: .changed))
    #expect(coordinator.allowsScroll(phase: .began, momentumPhase: []))
    #expect(coordinator.allowsScroll(phase: [], momentumPhase: .changed))
    let child = modalTestHost(in: window)
    child.present()
    #expect(!coordinator.allowsScroll(phase: [], momentumPhase: .changed))
    child.unregisterInput()
    child.removeFromSuperview()
    #expect(!coordinator.allowsScroll(phase: [], momentumPhase: .changed))
    #expect(coordinator.allowsScroll(phase: .began, momentumPhase: []))
    #expect(coordinator.allowsScroll(phase: [], momentumPhase: .changed))
}

@MainActor
@Test func `escape belongs to the top modal and does not affect another window`() throws {
    let window = modalTestWindow()
    let unrelatedWindow = modalTestWindow()
    let coordinator = WindowModalCoordinator.coordinator(for: window)
    let parent = modalTestHost(in: window)
    let child = modalTestHost(in: window)
    var parentEscapes = 0
    var childEscapes = 0
    parent.animationState.escapeAction = { parentEscapes += 1 }
    child.animationState.escapeAction = { childEscapes += 1 }
    parent.present()
    child.present()
    defer {
        child.unregisterInput(); child.removeFromSuperview()
        parent.unregisterInput(); parent.removeFromSuperview()
    }
    let unrelatedEscape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: unrelatedWindow.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
    #expect(coordinator.filter(unrelatedEscape) != nil)
    #expect(parentEscapes == 0 && childEscapes == 0)
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
    #expect(coordinator.filter(escape) == nil)
    #expect(parentEscapes == 0 && childEscapes == 1)
}

@MainActor
@Test func `closing modal releases input as its transition begins and dismisses once`() async {
    let window = modalTestWindow()
    var dismissals = 0
    var removalsBeforeDismissal = 0
    await withCheckedContinuation { continuation in
        var host: WindowModalHostingView!
        host = WindowModalHostingView(presentationID: UUID(), dismiss: { dismissals += 1 }, didFinishDismissal: {
            host.unregisterInput()
            host.removeFromSuperview()
            host = nil
            continuation.resume()
        }, behavior: .contentAnimated, content: { _ in AnyView(Color.clear) })
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        host.present()
        host.animationState.dismissalTransition = { _ in 0 }
        host.animationState.willRemove = { if dismissals == 0 { removalsBeforeDismissal += 1 } }
        host.requestDismissal()
        host.requestDismissal()
        // What the modal covered scrolls and hovers while it animates away,
        // while the modal still swallows clicks.
        #expect(WindowModalCoordinator.allowsInput(for: window.contentView!))
        #expect(host.hitTest(.zero) === host)
    }
    #expect(dismissals == 1)
    #expect(removalsBeforeDismissal == 1)
}

@MainActor
@Test func `one escape closes only the top of stacked modals and its clicks stay with it`() throws {
    let window = modalTestWindow()
    let coordinator = WindowModalCoordinator.coordinator(for: window)
    let parent = modalTestHost(in: window)
    let child = modalTestHost(in: window)
    var parentEscapes = 0
    parent.animationState.escapeAction = { parentEscapes += 1 }
    parent.present()
    child.present()
    child.animationState.dismissalTransition = { _ in 60 }
    defer {
        for host in [child, parent] { host.cancelPendingDismissal(); host.unregisterInput(); host.removeFromSuperview() }
    }
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
    #expect(coordinator.filter(escape) == nil)
    #expect(child.isDismissing && parentEscapes == 0)
    #expect(coordinator.topmost === parent)
    #expect(child.hitTest(.zero) === child)
    // Removing the closing modal from input leaves it above the parent.
    #expect(window.contentView!.subviews.last === child)
    // A repeated press while the child animates away acts on nothing,
    // including through other key monitors that see it first.
    #expect(coordinator.filter(escape) == nil)
    #expect(parentEscapes == 0)
    #expect(WindowModalCoordinator.closingModalOwnsEscape(in: window))
    #expect(WindowModalCoordinator.closingModalOwnsClicks(in: window))
    child.cancelPendingDismissal()
    child.unregisterInput()
    child.removeFromSuperview()
    #expect(!WindowModalCoordinator.closingModalOwnsEscape(in: window))
    #expect(!WindowModalCoordinator.closingModalOwnsClicks(in: window))
    #expect(coordinator.filter(escape) == nil)
    #expect(parentEscapes == 1)
}

@MainActor
private final class ModalTestResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private func modalTestWindow() -> NSWindow {
    NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
}

@MainActor
private func modalTestHost(in window: NSWindow, behavior: WindowModalBehavior = .contentAnimated) -> WindowModalHostingView {
    let host = WindowModalHostingView(presentationID: UUID(), dismiss: {}, didFinishDismissal: {}, behavior: behavior) { _ in AnyView(Color.clear) }
    host.frame = window.contentView!.bounds
    window.contentView!.addSubview(host)
    return host
}

@MainActor
@Test func `presenting a modal clears background native hover and blocks coordinate refresh`() {
    let window = modalTestWindow()
    let row = ChannelNativeRowInteractionView(frame: CGRect(x: 0, y: 0, width: 120, height: 30))
    var hovered = false
    row.hoverChanged = { hovered = $0 }
    window.contentView!.addSubview(row)
    let location = row.convert(CGPoint(x: 10, y: 10), to: nil)
    row.pointerLocationInWindowProvider = { location }
    row.synchronizeHover(atWindowPoint: location)
    #expect(hovered)
    let host = modalTestHost(in: window)
    host.present()
    #expect(!hovered)
    row.synchronizeHover(atWindowPoint: location)
    #expect(!hovered)
    host.unregisterInput()
    host.removeFromSuperview()
    #expect(hovered)
}
