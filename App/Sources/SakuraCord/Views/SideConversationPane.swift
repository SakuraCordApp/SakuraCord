import SakuraCordModels
import SwiftUI

/// The global frame of the workspace's trailing column. The window toolbar
/// aligns the side chat title to it and file drops split at its edge.
struct SupplementaryPaneFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let nextFrame = nextValue()
        if nextFrame != .zero {
            value = nextFrame
        }
    }
}

extension View {
    func reportsSupplementaryPaneFrame() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SupplementaryPaneFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        }
    }
}

/// The shell shared by every side chat in the trailing column: its divider,
/// width, scroll-edge treatment and frame report. Kinds supply only content.
struct SideConversationPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            Divider()
                .ignoresSafeArea(.container, edges: .top)
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .frame(
                    minWidth: InterfaceScale.metric(340),
                    idealWidth: InterfaceScale.metric(400),
                    maxWidth: InterfaceScale.metric(440),
                    maxHeight: .infinity
                )
                .reportsSupplementaryPaneFrame()
        }
    }
}

/// A side chat in its pane. This is the one place that maps a kind to its
/// content; voice chat and channel previews reuse the primary conversation.
struct SideConversationView: View {
    let model: AppModel
    let conversation: SideConversation

    var body: some View {
        SideConversationPane {
            switch conversation {
            case .thread, .threadCreation:
                ThreadConversationView(model: model)
            case .voiceChat, .channelPreview:
                ChatDetailView(model: model)
            case .guideResource(let guildID, _):
                if let resource = model.presentedGuideResource {
                    GuildResourceConversationView(model: model, guildID: guildID, resource: resource)
                }
            }
        }
    }
}
