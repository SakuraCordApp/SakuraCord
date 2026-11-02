import SakuraCordModels
import SwiftUI

/// The frame of the workspace's trailing column, in its column's own space
/// (`WorkspaceColumnsHost.columnSpace`). The window toolbar aligns the side
/// chat title to it and file drops split at its edge.
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
    /// - Parameter isEnabled: Whether this view is in the trailing column.
    ///   A full-width side chat is not, but keeps the modifier so its
    ///   identity survives moving there.
    func reportsSupplementaryPaneFrame(isEnabled: Bool = true) -> some View {
        modifier(SupplementaryPaneFrameReporter(isEnabled: isEnabled))
    }
}

private struct SupplementaryPaneFrameReporter: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SupplementaryPaneFramePreferenceKey.self,
                    value: isEnabled
                        ? proxy.frame(in: .named(WorkspaceColumnsHost.columnSpace))
                        : .zero
                )
            }
        }
    }
}

/// The shell shared by every side chat in the trailing column: its divider,
/// width, scroll-edge treatment and frame report. Kinds supply only content.
/// A full-width thread keeps this shell, without the divider and width
/// limits, so moving between the pane and full width keeps its timeline.
struct SideConversationPane<Content: View>: View {
    var isFullWidth = false
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 0) {
            if !isFullWidth {
                Divider()
                    .ignoresSafeArea(.container, edges: .top)
            }
            content
                .scrollEdgeEffectStyle(isFullWidth ? .automatic : .soft, for: .top)
            .frame(
                minWidth: isFullWidth ? nil : ChatChromeMetrics.sideConversationMinimumWidth,
                idealWidth: isFullWidth ? nil : InterfaceScale.metric(400),
                maxWidth: isFullWidth ? .infinity : InterfaceScale.metric(440),
                maxHeight: .infinity
            )
        }
    }
}

/// A side chat in its pane. This is the one place that maps a kind to its
/// content; voice chat and channel previews reuse the primary conversation.
struct SideConversationView: View {
    let model: AppModel
    let conversation: SideConversation

    var body: some View {
        SideConversationPane(isFullWidth: conversation.isFullWidth) {
            switch conversation {
            case .thread(let thread, _):
                ThreadConversationView(model: model, leavingThread: thread)
            case .threadCreation:
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
