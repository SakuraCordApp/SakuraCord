import AppKit
import Foundation
import Observation
import SakuraCordModels
import SwiftUI

nonisolated struct KeyboardShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var value: Self = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.shift) { value.insert(.shift) }
        self = value
    }

    var eventModifiers: EventModifiers {
        var value: EventModifiers = []
        if contains(.command) { value.insert(.command) }
        if contains(.option) { value.insert(.option) }
        if contains(.control) { value.insert(.control) }
        if contains(.shift) { value.insert(.shift) }
        return value
    }
}

nonisolated struct KeyboardShortcutChord: Codable, Hashable, Sendable {
    let key: String
    let modifiers: KeyboardShortcutModifiers

    init?(key: String, modifiers: KeyboardShortcutModifiers) {
        guard let character = key.first else { return nil }
        // AppKit matches a "+" key equivalent to the unshifted "=" key where
        // the two share a key, so both record and compare as one binding.
        let source = character == "=" && !modifiers.contains(.shift) ? "+" : String(character)
        let lowered = source.lowercased(with: Locale(identifier: "en_US_POSIX"))
        self.key = lowered.count == 1 ? lowered : source
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let key: String
        if let specialKey = event.specialKey {
            key = String(Character(specialKey.unicodeScalar))
        } else if let character = event.charactersIgnoringModifiers?.first {
            key = String(character)
        } else {
            return nil
        }
        self.init(
            key: key,
            modifiers: KeyboardShortcutModifiers(event.modifierFlags)
        )
    }

    init?(storageValue: String) {
        guard !storageValue.isEmpty else { return nil }
        let components = storageValue.split(separator: "|", maxSplits: 1)
        guard components.count == 2,
              let rawModifiers = UInt8(components[0]),
              let scalarValue = UInt32(components[1]),
              let scalar = Unicode.Scalar(scalarValue)
        else { return nil }
        self.init(
            key: String(Character(scalar)),
            modifiers: KeyboardShortcutModifiers(rawValue: rawModifiers)
        )
    }

    var storageValue: String {
        guard let scalar = key.unicodeScalars.first else { return "" }
        return "\(modifiers.rawValue)|\(scalar.value)"
    }

    var swiftUIShortcut: KeyboardShortcut? {
        guard let character = key.first else { return nil }
        return KeyboardShortcut(
            KeyEquivalent(character),
            modifiers: modifiers.eventModifiers,
            localization: .custom
        )
    }

    var displayName: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + Self.keyDisplayName(key)
    }

    private static func keyDisplayName(_ key: String) -> String {
        guard let character = key.first,
              let scalar = character.unicodeScalars.first
        else { return key.uppercased() }
        switch scalar.value {
        case NSEvent.SpecialKey.upArrow.unicodeScalar.value: return "↑"
        case NSEvent.SpecialKey.downArrow.unicodeScalar.value: return "↓"
        case NSEvent.SpecialKey.leftArrow.unicodeScalar.value: return "←"
        case NSEvent.SpecialKey.rightArrow.unicodeScalar.value: return "→"
        case NSEvent.SpecialKey.home.unicodeScalar.value: return "Home"
        case NSEvent.SpecialKey.end.unicodeScalar.value: return "End"
        case NSEvent.SpecialKey.pageUp.unicodeScalar.value: return "Page Up"
        case NSEvent.SpecialKey.pageDown.unicodeScalar.value: return "Page Down"
        case NSEvent.SpecialKey.deleteForward.unicodeScalar.value: return "⌦"
        case 27: return "Esc"
        case 9: return "Tab"
        case 13, NSEvent.SpecialKey.enter.unicodeScalar.value: return "Return"
        case 32: return "Space"
        default:
            return functionKeyDisplayName(key, scalarValue: scalar.value)
        }
    }

    private static func functionKeyDisplayName(_ key: String, scalarValue: UInt32) -> String {
        for number in 1 ... 35 where functionKey(number).unicodeScalar.value == scalarValue {
            return "F\(number)"
        }
        return key.uppercased()
    }

    private static func functionKey(_ number: Int) -> NSEvent.SpecialKey {
        let keys: [NSEvent.SpecialKey] = [
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
            .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
            .f21, .f22, .f23, .f24, .f25, .f26, .f27, .f28, .f29, .f30,
            .f31, .f32, .f33, .f34, .f35,
        ]
        return keys[number - 1]
    }
}

@MainActor
@Observable
final class KeyboardShortcutSettingsStore {
    static let shared = KeyboardShortcutSettingsStore()

    private(set) var shortcuts: [KeyboardShortcutAction: KeyboardShortcutChord] = [:]
    @ObservationIgnored private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
        reload()
    }

    func shortcut(for action: KeyboardShortcutAction) -> KeyboardShortcutChord? {
        shortcuts[action]
    }

    @discardableResult
    func set(_ shortcut: KeyboardShortcutChord?, for action: KeyboardShortcutAction) -> KeyboardShortcutValidation {
        if let shortcut {
            let result = KeyboardShortcutPolicy.validate(shortcut, for: action, shortcuts: shortcuts)
            guard result == .valid else { return result }
            shortcuts[action] = shortcut
        } else {
            shortcuts[action] = nil
        }
        preferences.set(
            .string(shortcut?.storageValue ?? ""),
            for: action.controlID
        )
        return .valid
    }

    @discardableResult
    func reset(_ action: KeyboardShortcutAction) -> KeyboardShortcutValidation {
        set(action.defaultShortcut, for: action)
    }

    func resetAll() {
        preferences.reset(page: .keyboardShortcuts)
        reload()
    }

    func reload() {
        var loaded: [KeyboardShortcutAction: KeyboardShortcutChord] = [:]
        let actions = KeyboardShortcutAction.allCases
        // User assignments win over defaults added by a newer app version.
        let explicitActions = actions.filter { preferences.containsStoredValue(for: $0.controlID) }
        let defaultActions = actions.filter { !preferences.containsStoredValue(for: $0.controlID) }
        for action in explicitActions + defaultActions {
            guard let value = preferences.string(action.controlID),
                  !value.isEmpty else { continue }
            let shortcut = KeyboardShortcutChord(storageValue: value) ?? action.defaultShortcut
            guard let shortcut,
                  KeyboardShortcutPolicy.validate(shortcut, for: action, shortcuts: loaded) == .valid
            else { continue }
            loaded[action] = shortcut
        }
        shortcuts = loaded
    }
}
