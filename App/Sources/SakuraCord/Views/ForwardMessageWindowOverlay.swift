import SwiftUI

/// Presents Forward with the same window-level modal host as the media viewer.
/// The workspace remains geometrically stable while the full-window host owns
/// pointer, accessibility, keyboard, and closing-animation behavior.
struct ForwardMessageWindowOverlay: View {
    let model: AppModel

    var body: some View {
        WindowModalOverlay(
            presentation: model.forwardingMessage,
            zPosition: 100_100,
            dismiss: model.dismissForwarding
        ) { message, animationState in
            ForwardMessageOverlay(
                model: model,
                message: message,
                animationState: animationState,
                dismiss: {
                    animationState.dismiss(committingPresentation: true)
                }
            )
        }
    }
}
