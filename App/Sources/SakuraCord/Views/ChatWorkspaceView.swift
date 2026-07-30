import SakuraCordModels
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
                if supplementaryContent != .memberInspector
                    || model.selectedChannel?.kind != .directMessage
                {
                    Divider()
                }
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
            if let channel = model.selectedChannel,
               channel.kind == .directMessage || channel.kind == .groupDirectMessage,
               model.privateCall(in: channel.id) != nil
                    || model.activeVoiceChannel?.id == channel.id
            {
                DirectMessageCallWorkspace(model: model, channel: channel)
            } else {
                ChatDetailView(model: model)
            }
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
            if let channel = model.selectedChannel,
               channel.kind == .directMessage,
               let recipient = channel.recipients.first
            {
                DirectMessageProfileInspector(
                    model: model,
                    recipient: recipient
                )
            } else {
                MemberInspectorView(
                    sections: model.directMessageInspectorSections,
                    profilePresentation:
                        model.inspectorProfilePresentation,
                    isProfilePresented: model.isInspectorProfilePresented,
                    selectMember: model.selectMember,
                    dismissProfile: model.dismissInspectorProfile
                )
                .frame(width: ChatChromeMetrics.memberListWidth)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct DirectMessageProfileInspector: View {
    let model: AppModel
    let recipient: User

    var body: some View {
        Group {
            if let presentation = model.inspectorProfilePresentation,
               presentation.member.id == recipient.id
            {
                ProfilePresentationContent(
                    presentation: presentation,
                    layout: .inspector
                )
            } else {
                ProgressView("Loading profile…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: ChatChromeMetrics.memberListWidth)
        .frame(maxHeight: .infinity)
        .clipShape(
            ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(
                        ChatChromeMetrics.composerMinimumCornerRadius
                    )
                ),
                isUniform: true
            )
        )
        .task(id: recipient.id) {
            model.showInspectorProfile(for: recipient)
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
