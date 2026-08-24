import AppKit
import SwiftUI

struct KeyboardShortcutRecorder: NSViewRepresentable {
    let actionTitle: String
    let shortcut: KeyboardShortcutChord?
    let capture: (KeyboardShortcutChord) -> Void
    let clear: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> KeyboardShortcutRecorderButton {
        let button = KeyboardShortcutRecorderButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.beginRecording)
        context.coordinator.button = button
        context.coordinator.update(parent: self)
        return button
    }

    func updateNSView(
        _ button: KeyboardShortcutRecorderButton,
        context: Context
    ) {
        context.coordinator.button = button
        context.coordinator.update(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: KeyboardShortcutRecorder
        weak var button: KeyboardShortcutRecorderButton?

        init(parent: KeyboardShortcutRecorder) {
            self.parent = parent
        }

        func update(parent: KeyboardShortcutRecorder) {
            self.parent = parent
            button?.configure(
                actionTitle: parent.actionTitle,
                shortcut: parent.shortcut,
                capture: parent.capture,
                clear: parent.clear,
                cancel: parent.cancel
            )
        }

        @objc func beginRecording() {
            button?.beginRecording()
        }
    }
}

@MainActor
final class KeyboardShortcutRecorderButton: NSButton {
    private var actionTitle = "Shortcut"
    private var shortcut: KeyboardShortcutChord?
    private var capture: (KeyboardShortcutChord) -> Void = { _ in }
    private var clearShortcut: () -> Void = {}
    private var cancelRecording: () -> Void = {}
    private(set) var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        controlSize = .regular
        focusRingType = .default
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func configure(
        actionTitle: String,
        shortcut: KeyboardShortcutChord?,
        capture: @escaping (KeyboardShortcutChord) -> Void,
        clear: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.actionTitle = actionTitle
        self.shortcut = shortcut
        self.capture = capture
        clearShortcut = clear
        cancelRecording = cancel
        refreshPresentation()
    }

    func beginRecording() {
        isRecording = true
        refreshPresentation()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53:
            finishRecording()
            cancelRecording()
        case 51, 117:
            finishRecording()
            clearShortcut()
        default:
            guard let shortcut = KeyboardShortcutChord(event: event) else {
                NSSound.beep()
                return
            }
            finishRecording()
            capture(shortcut)
        }
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, isRecording {
            isRecording = false
            refreshPresentation()
            cancelRecording()
        }
        return result
    }

    private func finishRecording() {
        isRecording = false
        refreshPresentation()
        window?.makeFirstResponder(nil)
    }

    private func refreshPresentation() {
        title = if isRecording {
            "Type Shortcut…"
        } else {
            shortcut?.displayName ?? "Record Shortcut"
        }
        toolTip = isRecording
            ? "Press a modified key. Escape cancels; Delete clears."
            : "Record a shortcut for \(actionTitle)"
        setAccessibilityLabel("Shortcut for \(actionTitle)")
        setAccessibilityValue(
            isRecording
                ? "Recording"
                : (shortcut?.displayName ?? "Unassigned")
        )
        setAccessibilityHelp(toolTip)
    }
}
