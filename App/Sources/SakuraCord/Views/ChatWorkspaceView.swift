import SwiftUI

struct ChatWorkspaceView: View {
    let model: AppModel
    @Binding var presentsForumComposer: Bool

    var body: some View {
        let presentation = ChatWorkspacePresentation(
            isVoiceChannel: model.selectedChannel?.kind == .voice,
            isForumChannel: model.selectedChannel?.kind == .forum,
            hasOpenThread: model.openThread != nil,
            hasOpenVoiceChat: model.isVoiceChatOpen,
            showsInspector: model.showInspector
        )

        HStack(spacing: 0) {
            ChatWorkspacePrimaryContent(
                model: model,
                content: presentation.primaryContent,
                presentsForumComposer: $presentsForumComposer
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let supplementaryContent = presentation.supplementaryContent {
                Divider()
                ChatWorkspaceSupplementaryContent(model: model, content: supplementaryContent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(
            item: Binding(
                get: { model.presentedInteractionModal },
                set: {
                    if $0 == nil {
                        model.dismissInteractionModal()
                    }
                }
            )
        ) { modal in
            InteractionModalSheet(model: model, modal: modal)
        }
    }
}

struct ChatWorkspacePresentation: Equatable {
    enum PrimaryContent: Equatable {
        case chat
        case forum
        case voice
    }

    enum SupplementaryContent: Equatable {
        case thread
        case voiceChat
        case memberInspector
    }

    let primaryContent: PrimaryContent
    let supplementaryContent: SupplementaryContent?

    init(
        isVoiceChannel: Bool,
        isForumChannel: Bool = false,
        hasOpenThread: Bool,
        hasOpenVoiceChat: Bool,
        showsInspector: Bool
    ) {
        primaryContent = isVoiceChannel ? .voice : (isForumChannel ? .forum : .chat)

        if hasOpenThread, !isVoiceChannel || hasOpenVoiceChat {
            supplementaryContent = .thread
        } else if isVoiceChannel {
            supplementaryContent = hasOpenVoiceChat ? .voiceChat : nil
        } else {
            supplementaryContent = showsInspector ? .memberInspector : nil
        }
    }
}

private struct ChatWorkspacePrimaryContent: View {
    let model: AppModel
    let content: ChatWorkspacePresentation.PrimaryContent
    @Binding var presentsForumComposer: Bool

    var body: some View {
        switch content {
        case .chat:
            ChatDetailView(model: model)
        case .forum:
            ForumChannelView(model: model, presentsComposer: $presentsForumComposer)
        case .voice:
            VoiceChannelView(model: model)
        }
    }
}

private struct ChatWorkspaceSupplementaryContent: View {
    let model: AppModel
    let content: ChatWorkspacePresentation.SupplementaryContent

    var body: some View {
        switch content {
        case .thread:
            ThreadConversationView(model: model)
        case .voiceChat:
            VoiceChannelChatView(model: model)
        case .memberInspector:
            MemberInspectorView(
                sections: model.memberSections,
                selectedMemberID: model.selectedMember?.id,
                isProfilePresented: model.isInspectorProfilePresented,
                profile: model.selectedProfile,
                isLoadingProfile: model.isLoadingProfile,
                profileErrorMessage: model.profileErrorMessage,
                selectMember: model.selectMember,
                dismissProfile: model.dismissProfile
            )
            .frame(width: ChatChromeMetrics.memberListWidth)
            .frame(maxHeight: .infinity)
        }
    }
}

private struct VoiceChannelChatView: View {
    let model: AppModel

    var body: some View {
        SupplementaryConversationPane {
            ChatDetailView(model: model)
        }
    }
}
