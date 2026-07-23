import Testing
@testable import SakuraCord

@MainActor
@Test
func forumUsesDedicatedBrowserAndExistingThreadPane() {
    let browsing = ChatWorkspacePresentation(
        isVoiceChannel: false,
        isForumChannel: true,
        hasOpenThread: false,
        hasOpenVoiceChat: false,
        showsInspector: true
    )
    #expect(browsing.primaryContent == .forum)
    #expect(browsing.supplementaryContent == .memberInspector)

    let opened = ChatWorkspacePresentation(
        isVoiceChannel: false,
        isForumChannel: true,
        hasOpenThread: true,
        hasOpenVoiceChat: false,
        showsInspector: true
    )
    #expect(opened.primaryContent == .forum)
    #expect(opened.supplementaryContent == .thread)
}

@MainActor
@Test
func closedVoiceChatKeepsTheVoiceSurfaceFullWidth() {
    let presentation = ChatWorkspacePresentation(
        isVoiceChannel: true,
        hasOpenThread: false,
        hasOpenVoiceChat: false,
        showsInspector: true
    )

    #expect(presentation.primaryContent == .voice)
    #expect(presentation.supplementaryContent == nil)
}

@MainActor
@Test
func voiceChannelKeepsFullWidthWithoutInspector() {
    let presentation = ChatWorkspacePresentation(
        isVoiceChannel: true,
        hasOpenThread: false,
        hasOpenVoiceChat: false,
        showsInspector: false
    )

    #expect(presentation.primaryContent == .voice)
    #expect(presentation.supplementaryContent == nil)
}

@MainActor
@Test
func staleTextThreadDoesNotReplaceAClosedVoiceChat() {
    let presentation = ChatWorkspacePresentation(
        isVoiceChannel: true,
        hasOpenThread: true,
        hasOpenVoiceChat: false,
        showsInspector: true
    )

    #expect(presentation.primaryContent == .voice)
    #expect(presentation.supplementaryContent == nil)
}

@MainActor
@Test
func textThreadRetainsPriorityOverMemberInspector() {
    let presentation = ChatWorkspacePresentation(
        isVoiceChannel: false,
        hasOpenThread: true,
        hasOpenVoiceChat: false,
        showsInspector: true
    )

    #expect(presentation.primaryContent == .chat)
    #expect(presentation.supplementaryContent == .thread)
}

@MainActor
@Test
func openVoiceChannelChatReplacesTheVoiceInspectorSlot() {
    let presentation = ChatWorkspacePresentation(
        isVoiceChannel: true,
        hasOpenThread: false,
        hasOpenVoiceChat: true,
        showsInspector: true
    )

    #expect(presentation.primaryContent == .voice)
    #expect(presentation.supplementaryContent == .voiceChat)
}

@MainActor
@Test
func threadOpenedFromVoiceChatRetainsPriorityAndCanRestoreVoiceChat() {
    let presentation = ChatWorkspacePresentation(
        isVoiceChannel: true,
        hasOpenThread: true,
        hasOpenVoiceChat: true,
        showsInspector: true
    )

    #expect(presentation.primaryContent == .voice)
    #expect(presentation.supplementaryContent == .thread)
}
