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
        let source = String(character)
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
        case 9: return "Tab"
        case 13, NSEvent.SpecialKey.enter.unicodeScalar.value: return "Return"
        case 32: return "Space"
        default:
            for number in 1 ... 35 where functionKey(number).unicodeScalar.value == scalar.value {
                return "F\(number)"
            }
            return key.uppercased()
        }
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

nonisolated enum KeyboardShortcutGroup: String, CaseIterable, Identifiable, Sendable {
    case navigation
    case messaging
    case voiceVideo

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .navigation: LocalizedStringResource("Navigation", bundle: #bundle)
        case .messaging: LocalizedStringResource("Messaging", bundle: #bundle)
        case .voiceVideo: LocalizedStringResource("Voice & Video", bundle: #bundle)
        }
    }

    var settingsSection: SettingsSectionID {
        switch self {
        case .navigation: .shortcutNavigation
        case .messaging: .shortcutMessaging
        case .voiceVideo: .shortcutVoiceVideo
        }
    }
}

nonisolated enum KeyboardShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case quickSwitch
    case messageSearch
    case previousConversation
    case nextConversation
    case previousUnread
    case nextUnread
    case currentCall
    case toggleChannelSidebar
    case toggleMemberList
    case openSettings
    case focusComposer
    case editLastMessage
    case reply
    case upload
    case searchCurrentConversation
    case markRead
    case sendMessage
    case insertNewline
    case toggleMute
    case toggleDeafen
    case toggleCamera
    case toggleScreenShare
    case leaveCall

    var id: String { rawValue }
    var controlID: SettingsControlID {
        SettingsControlID(rawValue: "keyboard-shortcuts.\(rawValue)")
    }

    var group: KeyboardShortcutGroup {
        switch self {
        case .quickSwitch, .messageSearch, .previousConversation,
             .nextConversation, .previousUnread, .nextUnread, .currentCall,
             .toggleChannelSidebar, .toggleMemberList, .openSettings:
            .navigation
        case .focusComposer, .editLastMessage, .reply, .upload,
             .searchCurrentConversation, .markRead, .sendMessage, .insertNewline:
            .messaging
        case .toggleMute, .toggleDeafen, .toggleCamera, .toggleScreenShare,
             .leaveCall:
            .voiceVideo
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .quickSwitch: LocalizedStringResource("Quick Switch…", bundle: #bundle)
        case .messageSearch: LocalizedStringResource("Message Search…", bundle: #bundle)
        case .previousConversation: LocalizedStringResource("Previous Conversation", bundle: #bundle)
        case .nextConversation: LocalizedStringResource("Next Conversation", bundle: #bundle)
        case .previousUnread: LocalizedStringResource("Previous Unread Conversation", bundle: #bundle)
        case .nextUnread: LocalizedStringResource("Next Unread Conversation", bundle: #bundle)
        case .currentCall: LocalizedStringResource("Go to Current Call", bundle: #bundle)
        case .toggleChannelSidebar: LocalizedStringResource("Toggle Channel Sidebar", bundle: #bundle)
        case .toggleMemberList: LocalizedStringResource("Toggle Member List", bundle: #bundle)
        case .openSettings: LocalizedStringResource("Settings…", bundle: #bundle)
        case .focusComposer: LocalizedStringResource("Focus Composer", bundle: #bundle)
        case .editLastMessage: LocalizedStringResource("Edit Last Message", bundle: #bundle)
        case .reply: LocalizedStringResource("Reply to Latest Message", bundle: #bundle)
        case .upload: LocalizedStringResource("Upload File…", bundle: #bundle)
        case .searchCurrentConversation: LocalizedStringResource("Search Current Conversation…", bundle: #bundle)
        case .markRead: LocalizedStringResource("Mark Conversation Read", bundle: #bundle)
        case .sendMessage: LocalizedStringResource("Send Message", bundle: #bundle)
        case .insertNewline: LocalizedStringResource("Insert Newline", bundle: #bundle)
        case .toggleMute: LocalizedStringResource("Mute or Unmute", bundle: #bundle)
        case .toggleDeafen: LocalizedStringResource("Deafen or Undeafen", bundle: #bundle)
        case .toggleCamera: LocalizedStringResource("Start or Stop Camera", bundle: #bundle)
        case .toggleScreenShare: LocalizedStringResource("Start or Stop Screen Share", bundle: #bundle)
        case .leaveCall: LocalizedStringResource("Leave Call", bundle: #bundle)
        }
    }

    var localizedTitle: String {
        String(localized: title)
    }

    var help: LocalizedStringResource {
        switch self {
        case .sendMessage, .insertNewline:
            LocalizedStringResource(
                "Adds a composer-only shortcut. The Return behavior selected in Chat remains available.",
                bundle: #bundle
            )
        case .reply:
            LocalizedStringResource(
                "Replies to the newest message in the active channel or thread using the existing composer reply path.",
                bundle: #bundle
            )
        case .toggleScreenShare:
            LocalizedStringResource(
                "Opens the existing screen-share preview, or stops the current local share.",
                bundle: #bundle
            )
        default:
            LocalizedStringResource(
                "Runs the same action as SakuraCord's corresponding menu or visible control.",
                bundle: #bundle
            )
        }
    }

    var keywords: [LocalizedStringResource] {
        switch self {
        case .quickSwitch: ["switcher", "navigate", "command k"]
        case .messageSearch, .searchCurrentConversation: ["find", "messages", "search"]
        case .previousConversation, .nextConversation: ["channel", "direct message", "navigate"]
        case .previousUnread, .nextUnread: ["unread", "mention", "navigate"]
        case .currentCall: ["voice channel", "call", "navigate"]
        case .toggleChannelSidebar: ["sidebar", "channels", "show hide"]
        case .toggleMemberList: ["members", "inspector", "show hide"]
        case .openSettings: ["preferences", "command comma"]
        case .focusComposer: ["message field", "type", "focus"]
        case .editLastMessage: ["edit", "own message", "arrow up"]
        case .reply: ["reply", "latest message", "composer"]
        case .upload: ["attachment", "file", "add"]
        case .markRead: ["acknowledge", "unread", "conversation"]
        case .sendMessage: ["send", "return", "composer"]
        case .insertNewline: ["new line", "line break", "return"]
        case .toggleMute: ["microphone", "mute", "voice"]
        case .toggleDeafen: ["headphones", "deafen", "voice"]
        case .toggleCamera: ["video", "camera", "call"]
        case .toggleScreenShare: ["screen", "stream", "share"]
        case .leaveCall: ["disconnect", "hang up", "voice"]
        }
    }

    var defaultShortcut: KeyboardShortcutChord? {
        let command = KeyboardShortcutModifiers.command
        return switch self {
        case .quickSwitch:
            KeyboardShortcutChord(key: "k", modifiers: command)
        case .messageSearch:
            KeyboardShortcutChord(key: "f", modifiers: command)
        case .toggleChannelSidebar:
            KeyboardShortcutChord(key: "s", modifiers: [command, .control])
        case .toggleMemberList:
            KeyboardShortcutChord(key: "i", modifiers: [command, .option])
        case .openSettings:
            KeyboardShortcutChord(key: ",", modifiers: command)
        case .focusComposer:
            KeyboardShortcutChord(key: "l", modifiers: [command, .shift])
        case .searchCurrentConversation:
            KeyboardShortcutChord(key: "f", modifiers: [command, .shift])
        case .sendMessage:
            KeyboardShortcutChord(key: "\r", modifiers: command)
        case .insertNewline:
            KeyboardShortcutChord(key: "\r", modifiers: .shift)
        default:
            nil
        }
    }

    var registersMenuShortcut: Bool {
        self != .sendMessage && self != .insertNewline
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

    func action(matching event: NSEvent) -> KeyboardShortcutAction? {
        guard let chord = KeyboardShortcutChord(event: event) else { return nil }
        return KeyboardShortcutAction.allCases.first { shortcuts[$0] == chord }
    }

    func set(_ shortcut: KeyboardShortcutChord?, for action: KeyboardShortcutAction) {
        if let shortcut {
            shortcuts[action] = shortcut
        } else {
            shortcuts[action] = nil
        }
        preferences.set(
            .string(shortcut?.storageValue ?? ""),
            for: action.controlID
        )
    }

    func reset(_ action: KeyboardShortcutAction) {
        set(action.defaultShortcut, for: action)
    }

    func reset(_ group: KeyboardShortcutGroup) {
        for action in KeyboardShortcutAction.allCases where action.group == group {
            reset(action)
        }
    }

    func resetAll() {
        preferences.reset(scope: .appWide, page: .keyboardShortcuts)
        reload()
    }

    func reload() {
        var loaded: [KeyboardShortcutAction: KeyboardShortcutChord] = [:]
        for action in KeyboardShortcutAction.allCases {
            guard case let .string(value) = preferences.value(for: action.controlID) else {
                if let fallback = action.defaultShortcut {
                    loaded[action] = fallback
                }
                continue
            }
            if let shortcut = KeyboardShortcutChord(storageValue: value) {
                loaded[action] = shortcut
            } else if !value.isEmpty, let fallback = action.defaultShortcut {
                loaded[action] = fallback
            }
        }
        shortcuts = loaded
    }
}

nonisolated enum KeyboardShortcutValidation: Equatable, Sendable {
    case valid
    case conflict(KeyboardShortcutAction)
    case invalid(String)
}

nonisolated enum KeyboardShortcutValidator {
    static func validate(
        _ chord: KeyboardShortcutChord,
        for action: KeyboardShortcutAction,
        shortcuts: [KeyboardShortcutAction: KeyboardShortcutChord]
    ) -> KeyboardShortcutValidation {
        if let conflict = shortcuts.first(where: {
            $0.key != action && $0.value == chord
        })?.key {
            return .conflict(conflict)
        }
        guard !chord.modifiers.isEmpty else {
            return .invalid("Include Command, Option, Control, or Shift with the key.")
        }
        if chord.modifiers == .shift, isPrintable(chord.key), chord.key != "\r" {
            return .invalid("Shift with a printable key is reserved for text entry.")
        }
        if let reason = reservedReason(for: chord, action: action) {
            return .invalid(reason)
        }
        return .valid
    }

    private static func reservedReason(
        for chord: KeyboardShortcutChord,
        action: KeyboardShortcutAction
    ) -> String? {
        let command = KeyboardShortcutModifiers.command
        if chord.modifiers.contains(.control), chord.modifiers.contains(.option) {
            return "Control–Option combinations are reserved for VoiceOver commands."
        }
        if chord.modifiers == command {
            if ["q", "h", "m", "w"].contains(chord.key) {
                return "That shortcut is reserved by the macOS application menu."
            }
            if ["a", "c", "v", "x", "z"].contains(chord.key) {
                return "That shortcut is reserved for standard text editing."
            }
            if ["g", "n", "o", "p", "s", "t"].contains(chord.key)
                || (chord.key == "f" && action != .messageSearch)
            {
                return "That shortcut is reserved for a standard macOS application command."
            }
            if ("1" ... "9").contains(chord.key) {
                return "Command–1 through Command–9 are reserved for server navigation."
            }
            if chord.key == ",", action != .openSettings {
                return "Command–Comma is reserved for Settings."
            }
            if chord.key == "\t" || chord.key == " " {
                return "That combination is reserved by macOS application switching or Spotlight."
            }
            if chord.key == "`" {
                return "Command–Grave Accent is reserved for cycling application windows."
            }
        }
        if chord.modifiers == [command, .option], ["h", "m", "w"].contains(chord.key) {
            return "That shortcut is reserved for macOS window management."
        }
        if chord.modifiers == [command, .option], chord.key.first?.unicodeScalars.first?.value == 27 {
            return "That shortcut is reserved for Force Quit Applications."
        }
        if chord.modifiers == [.control], chord.key == " " {
            return "That shortcut is reserved for switching keyboard input sources."
        }
        if chord.modifiers == [command, .control], ["f", "q"].contains(chord.key) {
            return "That shortcut is reserved for full screen or locking the Mac."
        }
        if chord.modifiers == [command, .shift], ["3", "4", "5", "q"].contains(chord.key)
            || chord.modifiers == [command, .option, .shift] && chord.key == "q"
        {
            return "That shortcut is reserved for screenshots or logging out of macOS."
        }
        if usesTextNavigationKey(chord.key),
           chord.modifiers.contains(.command) || chord.modifiers.contains(.option)
        {
            return "That combination is reserved for text navigation or selection."
        }
        return nil
    }

    private static func isPrintable(_ key: String) -> Bool {
        key.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) }
            && !usesTextNavigationKey(key)
    }

    private static func usesTextNavigationKey(_ key: String) -> Bool {
        guard let value = key.first?.unicodeScalars.first?.value else { return false }
        return [
            NSEvent.SpecialKey.upArrow.unicodeScalar.value,
            NSEvent.SpecialKey.downArrow.unicodeScalar.value,
            NSEvent.SpecialKey.leftArrow.unicodeScalar.value,
            NSEvent.SpecialKey.rightArrow.unicodeScalar.value,
            NSEvent.SpecialKey.home.unicodeScalar.value,
            NSEvent.SpecialKey.end.unicodeScalar.value,
            NSEvent.SpecialKey.pageUp.unicodeScalar.value,
            NSEvent.SpecialKey.pageDown.unicodeScalar.value,
        ].contains(value)
    }
}

@MainActor
extension AppModel {
    func performKeyboardShortcutAction(_ action: KeyboardShortcutAction) {
        switch action.group {
        case .navigation:
            performNavigationShortcutAction(action)
        case .messaging:
            performMessagingShortcutAction(action)
        case .voiceVideo:
            performVoiceShortcutAction(action)
        }
    }

    private func performNavigationShortcutAction(
        _ action: KeyboardShortcutAction
    ) {
        switch action {
        case .quickSwitch:
            presentQuickSwitcher()
        case .messageSearch:
            presentMessageSearch()
        case .previousConversation:
            navigateShortcutConversation(direction: -1, unreadOnly: false)
        case .nextConversation:
            navigateShortcutConversation(direction: 1, unreadOnly: false)
        case .previousUnread:
            navigateShortcutConversation(direction: -1, unreadOnly: true)
        case .nextUnread:
            navigateShortcutConversation(direction: 1, unreadOnly: true)
        case .currentCall:
            if let channelID = activeVoiceChannel?.id { navigate(to: channelID) }
        case .toggleChannelSidebar:
            NotificationCenter.default.post(name: .sakuracordToggleChannelSidebar, object: nil)
        case .toggleMemberList:
            showInspector.toggle()
        case .openSettings:
            break
        default:
            preconditionFailure("Non-navigation shortcut routed as navigation")
        }
    }

    private func performMessagingShortcutAction(
        _ action: KeyboardShortcutAction
    ) {
        switch action {
        case .focusComposer:
            NotificationCenter.default.post(
                name: .sakuracordFocusComposer,
                object: activeComposerDestination
            )
        case .editLastMessage:
            NotificationCenter.default.post(
                name: .sakuracordEditLastMessage,
                object: activeComposerDestination
            )
        case .reply:
            _ = navigateReplySelection(in: activeComposerDestination, direction: .older)
        case .upload:
            NotificationCenter.default.post(
                name: .sakuracordChooseComposerAttachment,
                object: activeComposerDestination
            )
        case .searchCurrentConversation:
            presentMessageSearchFromCommand()
        case .markRead:
            if let channelID = openThread?.id ?? selectedChannelID {
                markConversationRead(channelID: channelID)
            }
        case .sendMessage, .insertNewline:
            break
        default:
            preconditionFailure("Non-messaging shortcut routed as messaging")
        }
    }

    private func performVoiceShortcutAction(
        _ action: KeyboardShortcutAction
    ) {
        switch action {
        case .toggleMute:
            Task { await toggleVoiceMute() }
        case .toggleDeafen:
            Task { await toggleVoiceDeafen() }
        case .toggleCamera:
            Task { await toggleCamera() }
        case .toggleScreenShare:
            Task {
                if localApplicationStreamKey == nil {
                    await presentScreenSharePreview()
                } else {
                    await stopScreenSharing()
                }
            }
        case .leaveCall:
            Task { await leaveVoice() }
        default:
            preconditionFailure("Non-voice shortcut routed as voice")
        }
    }

    func keyboardShortcutActionIsEnabled(_ action: KeyboardShortcutAction) -> Bool {
        guard sessionState == .workspace else {
            return action == .openSettings
        }
        return switch action {
        case .quickSwitch, .toggleChannelSidebar, .toggleMemberList, .openSettings:
            true
        case .messageSearch, .searchCurrentConversation:
            MessageSearchSurfacePolicy.showsToolbar(
                channelKind: selectedChannel?.kind,
                hasOpenThread: openThread != nil
            )
        case .previousConversation, .nextConversation:
            shortcutConversationChannels(unreadOnly: false).count > 1
        case .previousUnread, .nextUnread:
            !shortcutConversationChannels(unreadOnly: true).isEmpty
        case .currentCall, .toggleMute, .toggleDeafen, .leaveCall:
            activeVoiceChannel != nil
        case .toggleCamera:
            activeVoiceChannel != nil
                && (voiceSessionState == .connected || isCameraEnabled)
        case .toggleScreenShare:
            activeVoiceChannel != nil
                && (voiceSessionState == .connected || localApplicationStreamKey != nil)
        case .focusComposer, .sendMessage, .insertNewline:
            selectedChannelID != nil
        case .editLastMessage:
            commandComposer.activeCommand == nil
                && ComposerLatestMessageEditingPolicy.messageID(
                    in: activeShortcutMessages,
                    currentUserID: snapshot?.currentUser.id
                ) != nil
        case .reply:
            commandComposer.activeCommand == nil && !activeShortcutMessages.isEmpty
        case .upload:
            commandComposer.activeCommand == nil
                && selectedChannelID != nil
                && selectedConversationAccess.canSend
        case .markRead:
            (openThread?.id ?? selectedChannelID).map {
                readState.unread(channelID: $0)
            } == true
        }
    }

    private var activeComposerDestination: MessageComposerDestination {
        openThread == nil ? .channel : .thread
    }

    private var activeShortcutMessages: [Message] {
        openThread == nil ? messages : threadMessages
    }

    private func navigateShortcutConversation(direction: Int, unreadOnly: Bool) {
        let channels = shortcutConversationChannels(unreadOnly: unreadOnly)
        guard !channels.isEmpty else { return }
        let currentIndex = channels.firstIndex { $0.id == selectedChannelID }
        let destinationIndex: Int
        if let currentIndex {
            destinationIndex = (currentIndex + direction + channels.count) % channels.count
        } else {
            destinationIndex = direction < 0 ? channels.index(before: channels.endIndex) : 0
        }
        navigate(to: channels[destinationIndex].id)
    }

    private func shortcutConversationChannels(unreadOnly: Bool) -> [Channel] {
        visibleChannelGroups
            .flatMap(\.channels)
            .filter { channel in
                !hiddenChannelIDs.contains(channel.id)
                    && !checkingChannelIDs.contains(channel.id)
                    && (!unreadOnly || readState.unread(channelID: channel.id))
                    && (!unreadOnly || channel.id != selectedChannelID)
            }
    }
}
