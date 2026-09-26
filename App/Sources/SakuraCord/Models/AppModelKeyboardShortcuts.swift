import AppKit
import SakuraCordModels
import SwiftUI

extension AppModel {
    func performKeyboardShortcutAction(_ action: KeyboardShortcutAction) {
        guard keyboardShortcutActionIsEnabled(action) else { return }
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
        case .previousTextChannel:
            if let channelID = conversationNavigationHistory.previousTextChannelID { navigate(to: channelID) }
        case .toggleDirectMessages:
            selectGuild(selectedGuildID == nil ? conversationNavigationHistory.lastGuildID ?? orderedNavigationGuildIDs.first : nil)
        case .quickSwitch:
            presentQuickSwitcher()
        case .messageSearch:
            presentMessageSearch()
        case .currentCall:
            if let channelID = activeVoiceChannel?.id { navigate(to: channelID) }
        case .toggleChannelSidebar:
            NotificationCenter.default.post(name: .sakuracordToggleChannelSidebar, object: nil)
        case .toggleMemberList:
            if let channel = selectedChannel, channel.kind == .voice {
                if isVoiceChatOpen { closeVoiceChat() } else { openVoiceChat(for: channel) }
            } else {
                prepareInspectorProfileForPresentation()
                withAnimation(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? nil : .smooth(duration: 0.24)
                ) {
                    showInspector.toggle()
                }
            }
        default:
            performConversationNavigationShortcut(action)
        }
    }

    private func performConversationNavigationShortcut(_ action: KeyboardShortcutAction) {
        switch action {
        case .previousMention:
            navigateShortcutConversation(direction: -1, unreadOnly: true, mentionsOnly: true)
        case .nextMention:
            navigateShortcutConversation(direction: 1, unreadOnly: true, mentionsOnly: true)
        case .navigateBack:
            navigateConversationHistory(direction: -1)
        case .navigateForward:
            navigateConversationHistory(direction: 1)
        case .previousConversation:
            navigateShortcutConversation(direction: -1, unreadOnly: false)
        case .nextConversation:
            navigateShortcutConversation(direction: 1, unreadOnly: false)
        case .previousUnread:
            navigateShortcutConversation(direction: -1, unreadOnly: true)
        case .nextUnread:
            navigateShortcutConversation(direction: 1, unreadOnly: true)
        case .previousServer:
            navigateShortcutServer(direction: -1)
        case .nextServer:
            navigateShortcutServer(direction: 1)
        default: preconditionFailure("Non-navigation shortcut routed as navigation")
        }
    }

    private func performMessagingShortcutAction(
        _ action: KeyboardShortcutAction
    ) {
        switch action {
        case .togglePins:
            if pinnedMessages.isPresented { dismissPinnedMessages() } else { presentPinnedMessages() }
        case .toggleEmojiPicker, .toggleGIFPicker, .toggleStickerPicker:
            NotificationCenter.default.post(name: .sakuracordComposerPicker, object: activeComposerDestination, userInfo: ["action": action])
        case .markServerRead:
            if let guildID = selectedGuildID { markGuildRead(guildID) }
        case .copyChannelLink:
            if let channelID = openThread?.id ?? selectedChannelID {
                ChannelContextMenuValue.copy(ChannelContextMenuValue.link(
                    guildID: openThread?.guildID ?? selectedChannel?.guildID,
                    channelID: channelID
                ))
            }
        case .upload:
            NotificationCenter.default.post(
                name: .sakuracordChooseComposerAttachment,
                object: activeComposerDestination
            )
        case .searchCurrentConversation:
            presentMessageSearchFromCommand()
        default:
            preconditionFailure("Non-messaging shortcut routed as messaging")
        }
    }

    private func performVoiceShortcutAction(
        _ action: KeyboardShortcutAction
    ) {
        switch action {
        case .startCall:
            if let channel = selectedChannel { Task { await startPrivateCall(in: channel) } }
        case .answerCall:
            if let call = incomingPrivateCalls.first { Task { await acceptPrivateCall(call) } }
        case .toggleSoundboard:
            NotificationCenter.default.post(name: .sakuracordToggleSoundboard, object: nil)
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
            return false
        }
        return switch action.group {
        case .navigation: navigationShortcutIsEnabled(action)
        case .messaging: messagingShortcutIsEnabled(action)
        case .voiceVideo: voiceShortcutIsEnabled(action)
        }
    }

    private func navigationShortcutIsEnabled(_ action: KeyboardShortcutAction) -> Bool {
        switch action {
        case .quickSwitch, .toggleChannelSidebar, .toggleMemberList:
            true
        case .messageSearch:
            MessageSearchSurfacePolicy.showsToolbar(
                channelKind: selectedChannel?.kind,
                hasOpenThread: openThread != nil
            )
        case .previousConversation, .nextConversation:
            hasKeyboardShortcutConversationDestination(unreadOnly: false)
        case .previousUnread, .nextUnread:
            hasKeyboardShortcutConversationDestination(unreadOnly: true)
        case .previousMention, .nextMention:
            hasKeyboardShortcutConversationDestination(unreadOnly: true, mentionsOnly: true)
        case .navigateBack:
            keyboardShortcutHistoryDestination(direction: -1) != nil
        case .navigateForward:
            keyboardShortcutHistoryDestination(direction: 1) != nil
        case .previousTextChannel:
            conversationNavigationHistory.previousTextChannelID != nil
        case .toggleDirectMessages:
            !orderedNavigationGuildIDs.isEmpty
        case .previousServer, .nextServer:
            keyboardShortcutServerDestination(direction: 1) != nil
        case .currentCall:
            activeVoiceChannel != nil
        default: false
        }
    }

    private func messagingShortcutIsEnabled(_ action: KeyboardShortcutAction) -> Bool {
        switch action {
        case .searchCurrentConversation:
            MessageSearchSurfacePolicy.showsToolbar(
                channelKind: selectedChannel?.kind,
                hasOpenThread: openThread != nil
            )
        case .copyChannelLink:
            openThread != nil || selectedChannelID != nil
        case .togglePins:
            activePinsChannelID != nil
        case .toggleEmojiPicker, .toggleGIFPicker, .toggleStickerPicker:
            commandComposer.activeCommand == nil && selectedChannelID != nil && selectedConversationAccess.canSend
        case .markServerRead:
            selectedGuildID != nil
        case .upload:
            commandComposer.activeCommand == nil
                && selectedChannelID != nil
                && selectedConversationAccess.canSend
        default: false
        }
    }

    private func voiceShortcutIsEnabled(_ action: KeyboardShortcutAction) -> Bool {
        switch action {
        case .startCall:
            selectedChannel?.guildID == nil && selectedChannelID != nil && activeVoiceChannel == nil
                && selectedChannel.map { !isPrivateCallActionInFlight(in: $0.id) } == true
        case .answerCall:
            incomingPrivateCalls.first.map { !isPrivateCallActionInFlight(in: $0.channelID) } == true
        case .toggleSoundboard:
            activeVoiceChannel != nil && voiceSessionState == .connected && !isVoiceDeafened
        case .toggleMute, .toggleDeafen, .leaveCall:
            activeVoiceChannel != nil
        case .toggleCamera:
            activeVoiceChannel != nil
                && (voiceSessionState == .connected || isCameraEnabled)
        case .toggleScreenShare:
            activeVoiceChannel != nil
                && (voiceSessionState == .connected || localApplicationStreamKey != nil)
        default: false
        }
    }

    private var activeComposerDestination: MessageComposerDestination {
        openThread == nil ? .channel : .thread
    }

}
