import SwiftUI

/// Presents Forward as a 32-point window modal panel.
struct ForwardMessageWindowOverlay: View {
    let model: AppModel

    var body: some View {
        Color.clear
            .windowModal(
                item: Binding(
                    get: { model.forwardingMessage },
                    set: { if $0 == nil { model.dismissForwarding() } }
                ),
                cornerRadius: InterfaceScale.metric(32),
                cornerStyle: .circular
            ) { message in
                ForwardMessageOverlay(model: model, message: message)
            }
            // Destination discovery depends only on already-loaded local stores.
            // Warm its revisioned index after workspace changes settle so the first
            // explicit Forward action normally attaches an immediately populated
            // picker instead of starting permission and fuzzy-index work on open.
            .task(id: model.forwardSearchSourceRevision) {
                guard model.snapshot != nil else { return }
                ForwardDestinationSearchIndexCache.shared.schedulePrewarm(
                    for: model
                )
            }
    }
}
