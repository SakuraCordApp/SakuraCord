import AppKit
import Foundation

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
    case previousServer
    case nextServer
    case currentCall
    case toggleChannelSidebar
    case toggleMemberList
    case upload
    case copyChannelLink
    case searchCurrentConversation
    case toggleMute
    case toggleDeafen
    case toggleCamera
    case toggleScreenShare
    case leaveCall
    case previousMention
    case nextMention
    case navigateBack
    case navigateForward
    case previousTextChannel
    case toggleDirectMessages
    case togglePins
    case toggleEmojiPicker
    case toggleGIFPicker
    case toggleStickerPicker
    case markServerRead
    case startCall
    case answerCall
    case toggleSoundboard
    case translateDraft

    var id: String { rawValue }
    var controlID: SettingsControlID {
        SettingsControlID(rawValue: "keyboard-shortcuts.\(rawValue)")
    }

    var group: KeyboardShortcutGroup {
        switch self {
        case .previousMention: .navigation
        case .nextMention: .navigation
        case .navigateBack: .navigation
        case .navigateForward: .navigation
        case .previousTextChannel: .navigation
        case .toggleDirectMessages: .navigation
        case .togglePins: .messaging
        case .toggleEmojiPicker: .messaging
        case .toggleGIFPicker: .messaging
        case .toggleStickerPicker: .messaging
        case .markServerRead: .messaging
        case .startCall: .voiceVideo
        case .answerCall: .voiceVideo
        case .toggleSoundboard: .voiceVideo
        case .translateDraft: .messaging
        case .quickSwitch, .messageSearch, .previousConversation,
             .nextConversation, .previousUnread, .nextUnread, .currentCall,
             .previousServer, .nextServer, .toggleChannelSidebar, .toggleMemberList:
            .navigation
        case .upload, .copyChannelLink, .searchCurrentConversation:
            .messaging
        case .toggleMute, .toggleDeafen, .toggleCamera, .toggleScreenShare,
             .leaveCall:
            .voiceVideo
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .previousMention: LocalizedStringResource("Previous Mention", bundle: #bundle)
        case .nextMention: LocalizedStringResource("Next Mention", bundle: #bundle)
        case .navigateBack: LocalizedStringResource("Navigate Back", bundle: #bundle)
        case .navigateForward: LocalizedStringResource("Navigate Forward", bundle: #bundle)
        case .previousTextChannel: LocalizedStringResource("Return to Previous Text Channel", bundle: #bundle)
        case .toggleDirectMessages: LocalizedStringResource("Switch Between Server and Direct Messages", bundle: #bundle)
        case .togglePins: LocalizedStringResource("Toggle Pinned Messages", bundle: #bundle)
        case .toggleEmojiPicker: LocalizedStringResource("Toggle Emoji Picker", bundle: #bundle)
        case .toggleGIFPicker: LocalizedStringResource("Toggle GIF Picker", bundle: #bundle)
        case .toggleStickerPicker: LocalizedStringResource("Toggle Sticker Picker", bundle: #bundle)
        case .markServerRead: LocalizedStringResource("Mark Server Read", bundle: #bundle)
        case .startCall: LocalizedStringResource("Start Private Call", bundle: #bundle)
        case .answerCall: LocalizedStringResource("Answer Incoming Call", bundle: #bundle)
        case .toggleSoundboard: LocalizedStringResource("Toggle Soundboard", bundle: #bundle)
        case .translateDraft: LocalizedStringResource("Translate Draft", bundle: #bundle)
        case .quickSwitch: LocalizedStringResource("Quick Switch…", bundle: #bundle)
        case .messageSearch: LocalizedStringResource("Message Search…", bundle: #bundle)
        case .previousConversation: LocalizedStringResource("Previous Conversation", bundle: #bundle)
        case .nextConversation: LocalizedStringResource("Next Conversation", bundle: #bundle)
        case .previousUnread: LocalizedStringResource("Previous Unread Conversation", bundle: #bundle)
        case .nextUnread: LocalizedStringResource("Next Unread Conversation", bundle: #bundle)
        case .previousServer: LocalizedStringResource("Previous Server", bundle: #bundle)
        case .nextServer: LocalizedStringResource("Next Server", bundle: #bundle)
        case .currentCall: LocalizedStringResource("Go to Current Call", bundle: #bundle)
        case .toggleChannelSidebar: LocalizedStringResource("Toggle Channel Sidebar", bundle: #bundle)
        case .toggleMemberList: LocalizedStringResource("Toggle Member List or Voice Text Chat", bundle: #bundle)
        case .copyChannelLink: LocalizedStringResource("Copy Channel Link", bundle: #bundle)
        case .upload: LocalizedStringResource("Upload File…", bundle: #bundle)
        case .searchCurrentConversation: LocalizedStringResource("Search Current Conversation…", bundle: #bundle)
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
        case .previousMention: LocalizedStringResource("Mentions across servers and direct messages.", bundle: #bundle)
        case .nextMention: LocalizedStringResource("Mentions across servers and direct messages.", bundle: #bundle)
        case .navigateBack: LocalizedStringResource("Return to the previous conversation in your history.", bundle: #bundle)
        case .navigateForward: LocalizedStringResource("Move forward through your conversation history.", bundle: #bundle)
        case .previousTextChannel: LocalizedStringResource("Return to the last text conversation you visited.", bundle: #bundle)
        case .toggleDirectMessages: LocalizedStringResource("Switch between direct messages and your last server.", bundle: #bundle)
        case .togglePins: LocalizedStringResource("Show or hide pinned messages in the active conversation.", bundle: #bundle)
        case .toggleEmojiPicker: LocalizedStringResource("Choose an emoji for the active composer.", bundle: #bundle)
        case .toggleGIFPicker: LocalizedStringResource("Choose a GIF for the active composer.", bundle: #bundle)
        case .toggleStickerPicker: LocalizedStringResource("Choose a sticker for the active composer.", bundle: #bundle)
        case .markServerRead: LocalizedStringResource("Mark all conversations in the current server as read.", bundle: #bundle)
        case .startCall: LocalizedStringResource("Start a call in the current direct message or group.", bundle: #bundle)
        case .answerCall: LocalizedStringResource("Answer the first incoming private call.", bundle: #bundle)
        case .toggleSoundboard: LocalizedStringResource("Show or hide the soundboard while connected to a call.", bundle: #bundle)
        case .translateDraft:
            LocalizedStringResource(
                "Translate the active draft, or switch between the original and its translation.",
                bundle: #bundle
            )
        case .previousConversation, .nextConversation:
            LocalizedStringResource("Cycles through channels in the current server, wrapping at either end.", bundle: #bundle)
        case .previousUnread, .nextUnread:
            LocalizedStringResource("Cycles through unread conversations across servers and direct messages.", bundle: #bundle)
        case .previousServer, .nextServer:
            LocalizedStringResource("Cycles through servers in sidebar order, including servers inside folders.", bundle: #bundle)
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
        case .previousMention, .nextMention, .navigateBack, .navigateForward, .previousTextChannel,
             .toggleDirectMessages, .togglePins, .toggleEmojiPicker,
             .toggleGIFPicker, .toggleStickerPicker, .markServerRead,
             .startCall, .answerCall, .toggleSoundboard: [title, help]
        case .translateDraft: ["translate", "translation", "language", "on-device", "Apple"]
        case .quickSwitch: ["switcher", "navigate", "command k"]
        case .messageSearch, .searchCurrentConversation: ["find", "messages", "search"]
        case .previousConversation, .nextConversation: ["channel", "direct message", "navigate"]
        case .previousUnread, .nextUnread: ["unread", "mention", "navigate"]
        case .previousServer, .nextServer: ["server", "guild", "navigate", "cycle"]
        case .currentCall: ["voice channel", "call", "navigate"]
        case .toggleChannelSidebar: ["sidebar", "channels", "show hide"]
        case .toggleMemberList: ["members", "inspector", "show hide"]
        case .upload: ["attachment", "file", "add"]
        case .copyChannelLink: ["copy", "channel", "link", "url", "thread"]
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
        case .togglePins:
            KeyboardShortcutChord(key: "p", modifiers: .command)
        case .toggleEmojiPicker:
            KeyboardShortcutChord(key: "e", modifiers: .command)
        case .toggleGIFPicker:
            KeyboardShortcutChord(key: "g", modifiers: .command)
        case .toggleStickerPicker:
            KeyboardShortcutChord(key: "s", modifiers: .command)
        case .copyChannelLink:
            KeyboardShortcutChord(key: "l", modifiers: [.command, .shift])
        case .upload:
            KeyboardShortcutChord(key: "u", modifiers: [.command, .shift])
        case .toggleMute:
            KeyboardShortcutChord(key: "m", modifiers: [.command, .shift])
        case .toggleDeafen:
            KeyboardShortcutChord(key: "d", modifiers: [.command, .shift])
        case .currentCall:
            KeyboardShortcutChord(key: "v", modifiers: [.command, .option, .shift])
        case .previousTextChannel:
            KeyboardShortcutChord(key: "b", modifiers: .control)
        case .startCall:
            KeyboardShortcutChord(key: "'", modifiers: .control)
        case .answerCall:
            KeyboardShortcutChord(key: "\r", modifiers: .command)
        case .navigateBack:
            KeyboardShortcutChord(key: "[", modifiers: .command)
        case .navigateForward:
            KeyboardShortcutChord(key: "]", modifiers: .command)
        case .toggleDirectMessages:
            KeyboardShortcutChord(key: String(Character(NSEvent.SpecialKey.rightArrow.unicodeScalar)), modifiers: [.command, .option])
        case .markServerRead:
            KeyboardShortcutChord(key: "\u{1b}", modifiers: .shift)
        case .toggleSoundboard:
            KeyboardShortcutChord(key: "b", modifiers: [.command, .shift])
        case .translateDraft:
            KeyboardShortcutChord(key: "t", modifiers: [.command, .shift])
        case .quickSwitch:
            KeyboardShortcutChord(key: "k", modifiers: command)
        case .messageSearch:
            KeyboardShortcutChord(key: "f", modifiers: [command, .shift])
        case .previousConversation, .nextConversation, .previousUnread, .nextUnread,
             .previousServer, .nextServer, .previousMention, .nextMention:
            navigationShortcut
        case .toggleChannelSidebar:
            KeyboardShortcutChord(key: "s", modifiers: [command, .control])
        case .toggleMemberList:
            KeyboardShortcutChord(key: "u", modifiers: command)
        case .searchCurrentConversation:
            KeyboardShortcutChord(key: "f", modifiers: command)
        default:
            nil
        }
    }

    private var navigationShortcut: KeyboardShortcutChord? {
        let key: NSEvent.SpecialKey = switch self {
        case .previousConversation, .previousUnread, .previousServer, .previousMention: .upArrow
        default: .downArrow
        }
        let modifiers: KeyboardShortcutModifiers = switch self {
        case .previousUnread, .nextUnread: [.option, .shift]
        case .previousMention, .nextMention: [.command, .option, .shift]
        case .previousServer, .nextServer: [.command, .option]
        default: .option
        }
        return KeyboardShortcutChord(key: String(Character(key.unicodeScalar)), modifiers: modifiers)
    }

}
