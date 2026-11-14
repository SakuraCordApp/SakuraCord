import AppKit
import MessageRendering
import Observation
import SakuraCordModels
import SwiftUI
import WebKit

@MainActor
final class ComposerUnfocusedTypingMonitor {
    private weak var textView: NSTextView?
    private var eventMonitor: Any?
    private var onUnfocusedReturn: ((NSEvent) -> Bool)?
    private var onEditLatestMessage: (() -> Bool)?
    private var onNavigateReplySelection:
        ((MessageReplyNavigationDirection) -> Bool)?
    private var onEscape: (() -> Void)?
    private var onPasteAttachments: (() -> Bool)?

    isolated deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func synchronize(
        with textView: NSTextView,
        enabled: Bool,
        onUnfocusedReturn: ((NSEvent) -> Bool)? = nil,
        onEditLatestMessage: (() -> Bool)? = nil,
        onNavigateReplySelection:
            ((MessageReplyNavigationDirection) -> Bool)? = nil,
        onEscape: (() -> Void)? = nil,
        onPasteAttachments: (() -> Bool)? = nil
    ) {
        self.textView = textView
        self.onUnfocusedReturn = onUnfocusedReturn
        self.onEditLatestMessage = onEditLatestMessage
        self.onNavigateReplySelection = onNavigateReplySelection
        self.onEscape = onEscape
        self.onPasteAttachments = onPasteAttachments
        guard enabled, textView.window != nil
        else {
            removeMonitor()
            return
        }
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let textView = self.textView,
                  WindowModalCoordinator.allowsInput(for: textView),
                  let window = textView.window,
                  event.window === window,
                  window.isKeyWindow,
                  window.firstResponder !== textView,
                  !Self.handlesOwnTyping(window.firstResponder)
            else { return event }

            if let timeline = window.firstResponder as? NativeTimelineCanvasView,
               timeline.messageInteractionContext == .inboxResult || timeline.messageInteractionContext == .inboxMention
            {
                return event
            }

            // Popovers can leave the main window key. Its composer monitor may
            // receive Escape first, so honor popover dismissal before composer actions.
            if KeyboardShortcutPolicy.isPlainEscape(keyCode: event.keyCode, modifierFlags: event.modifierFlags),
               PopoverEscapeKeyCoordinator.shared.dismissTopmostPopover(in: window)
            {
                return nil
            }

            if Self.handlePaste(
                characters: event.characters,
                modifierFlags: event.modifierFlags,
                onPasteAttachments: self.onPasteAttachments
            ) {
                return nil
            }
            if Self.shouldOfferReturn(event.keyCode) {
                return self.onUnfocusedReturn?(event) == true ? nil : event
            }
            if Self.handleEditLatestMessage(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                composerIsEmpty: textView.string.isEmpty,
                onEditLatestMessage: self.onEditLatestMessage
            ) {
                return nil
            }
            if let direction = ComposerNSTextView.replyNavigationDirection(for: event),
               self.onNavigateReplySelection?(direction) == true
            {
                return nil
            }
            if Self.handleEscape(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                onEscape: self.onEscape
            ) {
                return nil
            }
            guard Self.shouldRedirect(event) else { return event }
            window.makeFirstResponder(textView)
            return event
        }
    }

    private func removeMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    /// Text editors and web content, such as a running Activity, take their
    /// own keys, Return and Escape included, as page content does in Discord.
    private static func handlesOwnTyping(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }
        guard let view = responder as? NSView else { return false }
        return sequence(first: view, next: \.superview).contains { $0 is WKWebView }
    }

    nonisolated static func shouldRedirect(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .function]
        guard modifierFlags.isDisjoint(with: disallowed),
              let characters,
              !characters.isEmpty
        else { return false }
        return characters.unicodeScalars.contains {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    static func handleEscape(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        onEscape: (() -> Void)?
    ) -> Bool {
        guard KeyboardShortcutPolicy.isPlainEscape(keyCode: keyCode, modifierFlags: modifierFlags) else { return false }
        onEscape?()
        return true
    }

    static func handleEditLatestMessage(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        composerIsEmpty: Bool,
        onEditLatestMessage: (() -> Bool)?
    ) -> Bool {
        guard ComposerLatestMessageEditingPolicy.shouldRequest(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            composerIsEmpty: composerIsEmpty
        )
        else { return false }
        _ = onEditLatestMessage?()
        return true
    }

    nonisolated static func shouldOfferReturn(_ keyCode: UInt16) -> Bool {
        keyCode == 36 || keyCode == 76
    }

    /// Matches Command-V as the Edit menu's Paste item does, using the
    /// characters the layout produces with Command held. Layouts such as
    /// Russian or "Dvorak – QWERTY ⌘" map Command combinations to Latin keys,
    /// so `charactersIgnoringModifiers` would report "м" or "k" instead.
    nonisolated static func shouldOfferPaste(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let relevant = modifierFlags.intersection([.command, .option, .control, .shift])
        // Caps Lock can uppercase the characters without Shift.
        return characters?.lowercased() == "v" && relevant == .command
    }

    nonisolated static func handlePaste(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags,
        onPasteAttachments: (() -> Bool)?
    ) -> Bool {
        guard shouldOfferPaste(
            characters: characters,
            modifierFlags: modifierFlags
        ) else {
            return false
        }
        return onPasteAttachments?() == true
    }

    private static func shouldRedirect(_ event: NSEvent) -> Bool {
        shouldRedirect(characters: event.characters, modifierFlags: event.modifierFlags)
    }
}

struct ComposerFocusSurface: NSViewRepresentable {
    let focus: () -> Void

    func makeNSView(context: Context) -> ComposerFocusSurfaceView {
        ComposerFocusSurfaceView(focus: focus)
    }

    func updateNSView(_ view: ComposerFocusSurfaceView, context: Context) {
        view.focus = focus
    }
}

final class ComposerFocusSurfaceView: NSView {
    var focus: () -> Void

    init(focus: @escaping () -> Void) {
        self.focus = focus
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with _: NSEvent) {
        focus()
    }
}
