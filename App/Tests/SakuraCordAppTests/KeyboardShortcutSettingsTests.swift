@testable import SakuraCord
import AppKit
import SwiftUI
import Testing

@MainActor
private final class ShortcutRecorderTestState {
    var captured: [KeyboardShortcutChord] = []
    var clearCount = 0
    var cancelCount = 0
}

@MainActor
@Test func `Keyboard shortcuts persist clear and reset individually or together`() throws {
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
    #expect(store.shortcut(for: .toggleMute) == KeyboardShortcutAction.toggleMute.defaultShortcut)

    store.set(custom, for: .quickSwitch)
    store.set(nil, for: .messageSearch)
    let displacedDefault = try #require(KeyboardShortcutAction.quickSwitch.defaultShortcut)
    store.set(displacedDefault, for: .toggleMute)

    let restored = KeyboardShortcutSettingsStore(preferences: preferences)
    #expect(restored.shortcut(for: .quickSwitch) == custom)
    #expect(restored.shortcut(for: .messageSearch) == nil)
    #expect(restored.shortcut(for: .toggleMute) == displacedDefault)

    #expect(restored.set(displacedDefault, for: .quickSwitch) == .conflict(.toggleMute))
    #expect(restored.reset(.quickSwitch) == .conflict(.toggleMute))
    #expect(restored.shortcut(for: .quickSwitch) == custom)
    #expect(restored.shortcut(for: .toggleMute) == displacedDefault)
    restored.reload()
    #expect(restored.shortcut(for: .quickSwitch) == custom)

    restored.set(nil, for: .toggleMute)

    restored.reset(.quickSwitch)
    #expect(restored.shortcut(for: .quickSwitch) == KeyboardShortcutAction.quickSwitch.defaultShortcut)
    #expect(restored.shortcut(for: .messageSearch) == nil)
    #expect(restored.shortcut(for: .toggleMute) == nil)

    restored.reset(.toggleMute)
    #expect(restored.shortcut(for: .toggleMute) == KeyboardShortcutAction.toggleMute.defaultShortcut)

    restored.set(custom, for: .leaveCall)
    restored.resetAll()
    for action in KeyboardShortcutAction.allCases {
        #expect(restored.shortcut(for: action) == action.defaultShortcut)
    }
}

@MainActor
@Test func `Saved shortcuts take precedence over new defaults without restoring conflicts`() throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let custom = try #require(KeyboardShortcutAction.toggleMute.defaultShortcut)
    preferences.set(.string(custom.storageValue), for: KeyboardShortcutAction.quickSwitch.controlID)
    preferences.set(.string(custom.storageValue), for: KeyboardShortcutAction.toggleCamera.controlID)
    let formatting = try #require(KeyboardShortcutChord(key: "b", modifiers: .command))
    preferences.set(.string(formatting.storageValue), for: KeyboardShortcutAction.leaveCall.controlID)
    preferences.set(.string(""), for: KeyboardShortcutAction.toggleDeafen.controlID)

    let shortcuts = KeyboardShortcutSettingsStore(preferences: preferences)
    #expect(shortcuts.shortcut(for: .quickSwitch) == custom)
    #expect(shortcuts.shortcut(for: .toggleMute) == nil)
    #expect(shortcuts.shortcut(for: .toggleCamera) == nil)
    #expect(shortcuts.shortcut(for: .leaveCall) == nil)
    #expect(shortcuts.shortcut(for: .toggleDeafen) == nil)
    let assignments = shortcuts.shortcuts
    shortcuts.reload()
    #expect(shortcuts.shortcuts == assignments)
    // Migration resolves effective assignments without overwriting user choices.
    #expect(preferences.value(for: KeyboardShortcutAction.quickSwitch.controlID) == .string(custom.storageValue))
}

@Test func `Shortcut validation protects app commands and leaves system shortcuts to macOS`() throws {
    let commandK = try #require(
        KeyboardShortcutChord(key: "k", modifiers: .command)
    )
    let existing = [KeyboardShortcutAction.quickSwitch: commandK]
    #expect(
        KeyboardShortcutPolicy.validate(
            commandK,
            for: .toggleMute,
            shortcuts: existing
        ) == .conflict(.quickSwitch)
    )

    let commandQ = try #require(
        KeyboardShortcutChord(key: "q", modifiers: .command)
    )
    guard case .invalid = KeyboardShortcutPolicy.validate(
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
    guard case .invalid = KeyboardShortcutPolicy.validate(
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
    guard case .invalid = KeyboardShortcutPolicy.validate(
        shiftLetter,
        for: .toggleMute,
        shortcuts: [:]
    ) else {
        Issue.record("Printable Shift chords must not steal text entry")
        return
    }

    for key in ["b", "i", "u"] {
        let formatting = try #require(KeyboardShortcutChord(key: key, modifiers: .command))
        guard case .invalid = KeyboardShortcutPolicy.validate(formatting, for: .toggleMute, shortcuts: [:]) else {
            Issue.record("Composer formatting must not be assigned to another command")
            return
        }
    }
    let underline = try #require(KeyboardShortcutChord(key: "u", modifiers: .command))
    #expect(KeyboardShortcutPolicy.validate(underline, for: .toggleMemberList, shortcuts: [:]) == .valid)
    let underlineEvent = try keyEvent(keyCode: 32, characters: "u", modifiers: .command)
    #expect(KeyboardShortcutPolicy.markdownMarker(for: underlineEvent, hasSelection: false) == nil)
    #expect(KeyboardShortcutPolicy.markdownMarker(for: underlineEvent, hasSelection: true) == "__")

    let shiftReturn = try #require(
        KeyboardShortcutChord(key: "\r", modifiers: .shift)
    )
    guard case .invalid = KeyboardShortcutPolicy.validate(shiftReturn, for: .toggleMute, shortcuts: [:]) else {
        Issue.record("Shift-Return belongs to the native composer")
        return
    }

    let voiceOverChord = try #require(
        KeyboardShortcutChord(key: "j", modifiers: [.control, .option])
    )
    #expect(KeyboardShortcutPolicy.validate(
        voiceOverChord,
        for: .toggleMute,
        shortcuts: [:]
    ) == .valid)

    let screenshotChord = try #require(
        KeyboardShortcutChord(key: "4", modifiers: [.command, .shift])
    )
    #expect(KeyboardShortcutPolicy.validate(
        screenshotChord,
        for: .toggleMute,
        shortcuts: [:]
    ) == .valid)
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
    button.flagsChanged(with: try keyEvent(
        keyCode: 55, characters: "", modifiers: .command, type: .flagsChanged
    ))
    #expect(button.recordingModifiers == .command)
    #expect(button.isRecording && state.captured.isEmpty)
    button.flagsChanged(with: try keyEvent(
        keyCode: 55, characters: "", modifiers: [], type: .flagsChanged
    ))
    #expect(button.recordingModifiers.isEmpty)
    button.flagsChanged(with: try keyEvent(
        keyCode: 58, characters: "", modifiers: .option, type: .flagsChanged
    ))
    #expect(button.recordingModifiers == .option)
    button.keyDown(with: try keyEvent(
        keyCode: 38,
        characters: "j",
        modifiers: .option
    ))
    #expect(state.captured.first?.displayName == "⌥J")
    #expect(!button.isRecording)
    #expect(button.recordingModifiers.isEmpty)

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

@Test func `Every shortcut action is registered and searchable`() {
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .keyboardShortcuts
    }
    let actionIDs = Set(KeyboardShortcutAction.allCases.map(\.controlID))
    let registeredActionIDs = Set(controls.map(\.id)).intersection(actionIDs)
    #expect(registeredActionIDs == actionIDs)
    #expect(
        SettingsPreferenceRegistry.foundation.registrations(
            page: .keyboardShortcuts,
            storageScope: .appWide
        ).count == KeyboardShortcutAction.allCases.count
    )
}

@Test func `Default shortcuts are unique and valid`() {
    var assigned: [KeyboardShortcutAction: KeyboardShortcutChord] = [:]
    for action in KeyboardShortcutAction.allCases {
        guard let shortcut = action.defaultShortcut else { continue }
        #expect(
            KeyboardShortcutPolicy.validate(
                shortcut,
                for: action,
                shortcuts: assigned
            ) == .valid
        )
        assigned[action] = shortcut
    }
}

@MainActor
@Test func `Shortcut recorder captures modified Escape without cancelling`() throws {
    let state = ShortcutRecorderTestState()
    let button = KeyboardShortcutRecorderButton()
    button.configure(actionTitle: "Mark Server Read", shortcut: nil,
                     capture: { state.captured.append($0) }, clear: {}, cancel: { state.cancelCount += 1 })
    button.beginRecording()
    button.keyDown(with: try keyEvent(keyCode: 53, characters: "\u{1b}", modifiers: .shift))
    #expect(state.captured.first == KeyboardShortcutAction.markServerRead.defaultShortcut)
    #expect(state.cancelCount == 0)
}

@MainActor
@Test func `Composer markdown wraps unicode selections without sending or losing text`() {
    let textView = ComposerNSTextView()
    textView.string = "hello 🌸 world"
    textView.setSelectedRange(NSRange(location: 6, length: 2))
    textView.wrapSelectionInMarkdown("**")
    #expect(textView.string == "hello **🌸** world")
    #expect(textView.selectedRange() == NSRange(location: 8, length: 2))
    textView.wrapSelectionInMarkdown("**")
    #expect(textView.string == "hello 🌸 world")
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    for source in ["hello 🌸 world", "**hello world**", "*hello*", "__hello__", "****"] {
        textView.string = source
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        for marker in ["**", "*", "__"] {
            textView.wrapSelectionInMarkdown(marker)
            #expect(textView.string == source)
            #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
        }
        textView.underline(nil)
        #expect(textView.string == source)
    }
}

private func keyEvent(
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags,
    type: NSEvent.EventType = .keyDown
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: type,
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

@MainActor
@Test func `composer native formatting edits Markdown and preserves attachments through undo`() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = ComposerNSTextView(frame: window.contentView!.bounds)
    view.isRichText = true
    view.allowsUndo = true
    view.usesFontPanel = true
    view.plainTextStyle = .composer(.systemFont(ofSize: 15))
    window.contentView = view
    window.makeFirstResponder(view)
    view.textStorage?.setAttributedString(ComposerEmojiAttributedText.make("hello <@123>"))
    view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
    let fontManager = NSFontManager()
    fontManager.target = view
    let nativeTraitItem = NSMenuItem(title: "", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "")
    nativeTraitItem.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
    fontManager.addFontTrait(nativeTraitItem)
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == "**hello <@123>**")
    let font = try #require(view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
    #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    view.selectAll(nil)
    nativeTraitItem.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
    fontManager.addFontTrait(nativeTraitItem)
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == "***hello <@123>***")
    view.wrapSelectionInMarkdown("*")
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == "**hello <@123>**")
    view.undoManager?.undo()
    view.undoManager?.undo()
    view.undoManager?.undo()
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == "hello <@123>")
    view.setSelectedRange(NSRange(location: 0, length: 5))
    view.underline(nil)
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == "__hello__ <@123>")
    view.underline(nil)
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == "hello <@123>")
    #expect(!view.shouldChangeText(in: NSRange(location: 0, length: 5), replacementString: nil))
    let vertical = NSMenuItem(title: "Vertical", action: #selector(NSTextView.changeLayoutOrientation(_:)), keyEquivalent: "")
    vertical.tag = 1
    view.changeLayoutOrientation(vertical)
    #expect(view.layoutOrientation == .horizontal)
    view.setSelectedRange(NSRange(location: 2, length: 0))
    for trait in [NSFontTraitMask.boldFontMask, .italicFontMask] {
        nativeTraitItem.tag = Int(trait.rawValue)
        fontManager.addFontTrait(nativeTraitItem)
        #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == "hello <@123>")
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
    }
}

private let composerFormattingOrders = [
    ["*", "__"], ["__", "*"],
    ["**", "*", "__"], ["**", "__", "*"],
    ["*", "**", "__"], ["*", "__", "**"],
    ["__", "**", "*"], ["__", "*", "**"]
]

@MainActor
@Test(arguments: composerFormattingOrders)
func `composer repeated mixed formatting toggles preserve the selected content`(_ order: [String]) {
    var draft = "test"
    var selection: NSRange? = NSRange(location: 0, length: 4)
    let parent = ComposerTextView(
        text: draft, placeholder: "", sendWithReturn: true,
        onTextChange: { draft = $0 }, onSubmit: {},
        selection: Binding(get: { selection }, set: { selection = $0 }),
        isFocused: .constant(true)
    )
    let coordinator = parent.makeCoordinator()
    let view = ComposerNSTextView()
    view.string = "test"
    view.delegate = coordinator
    view.selectAll(nil)
    for removalOrder in composerFormattingOrders where removalOrder.count == order.count {
        var active: [String] = []
        for marker in order + removalOrder {
            if let index = active.firstIndex(of: marker) {
                active.remove(at: index)
            } else {
                active.append(marker)
            }
            view.wrapSelectionInMarkdown(marker)
            #expect(view.string == active.joined() + "test" + active.reversed().joined())
            #expect((view.string as NSString).substring(with: view.selectedRange()) == "test")
            let font = view.textStorage?.attribute(.font, at: view.selectedRange().location, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == active.contains("**"))
            #expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == active.contains("*"))
            let underline = view.textStorage?.attribute(.underlineStyle, at: view.selectedRange().location, effectiveRange: nil) as? Int ?? 0
            #expect((underline != 0) == active.contains("__"))
            // No representable refresh between edits: returning to the old
            // snapshot must still publish the new draft and selection.
            #expect(draft == view.string)
            #expect(selection == view.selectedRange())
        }
        #expect(view.string == "test")
    }
    // Recognize existing equivalent syntax, not only the spelling we emit.
    for source in ["*__test__*", "__*test*__", "___test___"] {
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "test"))
        view.wrapSelectionInMarkdown("*")
        #expect(view.string == "__test__")
        view.wrapSelectionInMarkdown("__")
        #expect(view.string == "test")
    }
}

@MainActor
@Test func `composer rich paste imports characters and derives only Markdown formatting`() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let rich = NSAttributedString(string: "**hello**", attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.red])
    let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    pasteboard.setData(data, forType: .rtf)
    let view = ComposerNSTextView()
    view.plainTextStyle = .composer(.systemFont(ofSize: 15))
    #expect(view.readSelection(from: pasteboard, type: .rtf))
    #expect(view.string == "**hello**")
    let font = try #require(view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
    #expect(font.pointSize == 15)
    #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    view.insertText("", replacementRange: NSRange(location: 7, length: 2))
    let unformatted = try #require(view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
    #expect(!unformatted.fontDescriptor.symbolicTraits.contains(.bold))

    pasteboard.clearContents()
    pasteboard.setString("<b style='font-size:40px;color:red'>hello &amp; 🌸</b>", forType: .html)
    view.selectAll(nil)
    #expect(view.readSelection(from: pasteboard, type: .html))
    #expect(view.string == "hello & 🌸")
    let pastedFont = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(pastedFont.pointSize == 15)
    #expect(!pastedFont.fontDescriptor.symbolicTraits.contains(.bold))
    #expect(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor)
}

@MainActor
@Test func `Unshifted equals records as the interface size plus binding`() throws {
    let recorded = try #require(KeyboardShortcutChord(key: "=", modifiers: .command))
    #expect(recorded == KeyboardShortcutAction.increaseInterfaceSize.defaultShortcut)
    #expect(
        KeyboardShortcutPolicy.validate(
            recorded,
            for: .toggleMemberList,
            shortcuts: [.increaseInterfaceSize: recorded]
        ) == .conflict(.increaseInterfaceSize)
    )

    // A saved Command-= assignment from before this default existed keeps precedence.
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    preferences.set(.string(recorded.storageValue), for: KeyboardShortcutAction.toggleMemberList.controlID)
    let shortcuts = KeyboardShortcutSettingsStore(preferences: preferences)
    #expect(shortcuts.shortcut(for: .toggleMemberList) == recorded)
    #expect(shortcuts.shortcut(for: .increaseInterfaceSize) == nil)
}
