@testable import SakuraCord
import AppKit
import Testing

@MainActor
private final class ShortcutRecorderTestState {
    var captured: [KeyboardShortcutChord] = []
    var clearCount = 0
    var cancelCount = 0
}

@MainActor
@Test func `Keyboard shortcuts persist clear export and reset at each scope`() throws {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = KeyboardShortcutSettingsStore(preferences: preferences)
    let custom = try #require(
        KeyboardShortcutChord(
            key: "p",
            modifiers: [.command, .option]
        )
    )

    #expect(store.shortcut(for: .quickSwitch) == KeyboardShortcutAction.quickSwitch.defaultShortcut)
    #expect(store.shortcut(for: .toggleMute) == nil)

    store.set(custom, for: .quickSwitch)
    store.set(nil, for: .messageSearch)
    store.set(custom, for: .toggleMute)

    let restored = KeyboardShortcutSettingsStore(preferences: preferences)
    #expect(restored.shortcut(for: .quickSwitch) == custom)
    #expect(restored.shortcut(for: .messageSearch) == nil)
    #expect(restored.shortcut(for: .toggleMute) == custom)

    let export = preferences.export(scope: .appWide, page: .keyboardShortcuts)
    #expect(export.values.count == KeyboardShortcutAction.allCases.count)
    #expect(
        export.values[KeyboardShortcutAction.quickSwitch.controlID.rawValue]
            == .string(custom.storageValue)
    )
    #expect(
        export.values[KeyboardShortcutAction.messageSearch.controlID.rawValue]
            == .string("")
    )
    #expect(export.values[SettingsControlID.sendWithReturn.rawValue] == nil)

    restored.reset(.navigation)
    #expect(restored.shortcut(for: .quickSwitch) == KeyboardShortcutAction.quickSwitch.defaultShortcut)
    #expect(restored.shortcut(for: .messageSearch) == KeyboardShortcutAction.messageSearch.defaultShortcut)
    #expect(restored.shortcut(for: .toggleMute) == custom)

    restored.reset(.toggleMute)
    #expect(restored.shortcut(for: .toggleMute) == nil)

    restored.set(custom, for: .leaveCall)
    restored.resetAll()
    for action in KeyboardShortcutAction.allCases {
        #expect(restored.shortcut(for: action) == action.defaultShortcut)
    }
}

@Test func `Shortcut validation identifies conflicts and protects system text entry`() throws {
    let commandK = try #require(
        KeyboardShortcutChord(key: "k", modifiers: .command)
    )
    let existing = [KeyboardShortcutAction.quickSwitch: commandK]
    #expect(
        KeyboardShortcutValidator.validate(
            commandK,
            for: .toggleMute,
            shortcuts: existing
        ) == .conflict(.quickSwitch)
    )

    let commandQ = try #require(
        KeyboardShortcutChord(key: "q", modifiers: .command)
    )
    guard case .invalid = KeyboardShortcutValidator.validate(
        commandQ,
        for: .toggleMute,
        shortcuts: [:]
    ) else {
        Issue.record("Command-Q must remain reserved")
        return
    }

    let bareKey = try #require(
        KeyboardShortcutChord(key: "j", modifiers: [])
    )
    guard case .invalid = KeyboardShortcutValidator.validate(
        bareKey,
        for: .toggleMute,
        shortcuts: [:]
    ) else {
        Issue.record("Incomplete chords must be rejected")
        return
    }

    let shiftLetter = try #require(
        KeyboardShortcutChord(key: "j", modifiers: .shift)
    )
    guard case .invalid = KeyboardShortcutValidator.validate(
        shiftLetter,
        for: .toggleMute,
        shortcuts: [:]
    ) else {
        Issue.record("Printable Shift chords must not steal text entry")
        return
    }

    let shiftReturn = try #require(
        KeyboardShortcutChord(key: "\r", modifiers: .shift)
    )
    #expect(
        KeyboardShortcutValidator.validate(
            shiftReturn,
            for: .insertNewline,
            shortcuts: [:]
        ) == .valid
    )

    let voiceOverChord = try #require(
        KeyboardShortcutChord(key: "j", modifiers: [.control, .option])
    )
    guard case .invalid = KeyboardShortcutValidator.validate(
        voiceOverChord,
        for: .toggleMute,
        shortcuts: [:]
    ) else {
        Issue.record("Control-Option must remain available to VoiceOver")
        return
    }

    let screenshotChord = try #require(
        KeyboardShortcutChord(key: "4", modifiers: [.command, .shift])
    )
    guard case .invalid = KeyboardShortcutValidator.validate(
        screenshotChord,
        for: .toggleMute,
        shortcuts: [:]
    ) else {
        Issue.record("macOS screenshot shortcuts must remain reserved")
        return
    }
}

@Test func `Shortcut storage and labels preserve normalized special keys`() throws {
    let commandUppercase = try #require(
        KeyboardShortcutChord(key: "K", modifiers: .command)
    )
    #expect(commandUppercase.key == "k")
    #expect(commandUppercase.displayName == "⌘K")
    #expect(
        KeyboardShortcutChord(storageValue: commandUppercase.storageValue)
            == commandUppercase
    )

    let arrow = try #require(
        KeyboardShortcutChord(
            key: String(Character(NSEvent.SpecialKey.upArrow.unicodeScalar)),
            modifiers: [.control, .shift]
        )
    )
    #expect(arrow.displayName == "⌃⇧↑")
    #expect(KeyboardShortcutChord(storageValue: arrow.storageValue) == arrow)
}

@MainActor
@Test func `Recorder captures cancel and clear with keyboard controls`() throws {
    let state = ShortcutRecorderTestState()
    let button = KeyboardShortcutRecorderButton()
    button.configure(
        actionTitle: "Quick Switch",
        shortcut: nil,
        capture: { state.captured.append($0) },
        clear: { state.clearCount += 1 },
        cancel: { state.cancelCount += 1 }
    )

    button.beginRecording()
    button.keyDown(with: try keyEvent(
        keyCode: 38,
        characters: "j",
        modifiers: .command
    ))
    #expect(state.captured.first?.displayName == "⌘J")
    #expect(!button.isRecording)

    button.beginRecording()
    button.keyDown(with: try keyEvent(
        keyCode: 53,
        characters: "\u{1b}",
        modifiers: []
    ))
    #expect(state.cancelCount == 1)

    button.beginRecording()
    button.keyDown(with: try keyEvent(
        keyCode: 51,
        characters: "\u{7f}",
        modifiers: []
    ))
    #expect(state.clearCount == 1)
}

@MainActor
@Test func `Composer shortcuts reuse submit and native newline paths`() throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let shortcuts = KeyboardShortcutSettingsStore(preferences: preferences)
    let textView = ComposerNSTextView()
    textView.shortcutSettings = shortcuts
    var submitCount = 0
    textView.onSubmit = { submitCount += 1 }

    textView.keyDown(with: try keyEvent(
        keyCode: 36,
        characters: "\r",
        modifiers: .command
    ))
    #expect(submitCount == 1)

    textView.string = "first"
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    textView.keyDown(with: try keyEvent(
        keyCode: 36,
        characters: "\r",
        modifiers: .shift
    ))
    #expect(textView.string == "first\n")
    #expect(submitCount == 1)
}

@Test func `Every shortcut action is registered and searchable`() {
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .keyboardShortcuts
    }
    let actionIDs = Set(KeyboardShortcutAction.allCases.map(\.controlID))
    let registeredActionIDs = Set(controls.map(\.id)).intersection(actionIDs)
    #expect(registeredActionIDs == actionIDs)
    #expect(Set(KeyboardShortcutAction.allCases.map(\.rawValue)).count == 23)
    #expect(
        SettingsPreferenceRegistry.foundation.registrations(
            page: .keyboardShortcuts,
            storageScope: .appWide
        ).count == 23
    )
}

@Test func `Default shortcuts are unique valid and text sensitive only in composer`() {
    var assigned: [KeyboardShortcutAction: KeyboardShortcutChord] = [:]
    for action in KeyboardShortcutAction.allCases {
        guard let shortcut = action.defaultShortcut else { continue }
        #expect(
            KeyboardShortcutValidator.validate(
                shortcut,
                for: action,
                shortcuts: assigned
            ) == .valid
        )
        assigned[action] = shortcut
    }
    #expect(!KeyboardShortcutAction.sendMessage.registersMenuShortcut)
    #expect(!KeyboardShortcutAction.insertNewline.registersMenuShortcut)
    #expect(KeyboardShortcutAction.focusComposer.registersMenuShortcut)
}

private func keyEvent(
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ))
}
