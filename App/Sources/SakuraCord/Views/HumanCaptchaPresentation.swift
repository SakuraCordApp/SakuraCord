import DiscordProtocol
import SwiftUI

struct HumanCaptchaPresentation: ViewModifier {
    let store: HumanCaptchaStore

    func body(content: Content) -> some View {
        content.background {
            WindowModalOverlay(presentation: store.challenge, dismiss: { store.cancel() }, content: { challenge, context in
                HumanCaptchaContent(challenge: challenge, context: context, cancel: { store.cancel(id: challenge.id) }, onToken: { token in
                    store.complete(id: challenge.id, token: token)
                })
                .id(challenge.id)
            })
        }
    }
}

private struct HumanCaptchaContent: View {
    let challenge: DiscordCaptchaChallenge
    let context: WindowModalContext
    let cancel: () -> Void
    let onToken: (String?) -> Void
    @State private var interactionRequired = false
    @State private var widgetBounds: CGRect?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Keep native and CSS coordinates aligned; only the backdrop extends under the titlebar.
                Color.black.opacity(WindowModalVisualStyle.standardBackdropOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: cancel)
                if let widgetBounds, interactionRequired {
                    RoundedRectangle(cornerRadius: InterfaceScale.metric(16))
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay { RoundedRectangle(cornerRadius: InterfaceScale.metric(16)).stroke(.separator, lineWidth: 1) }
                        .shadow(color: .black.opacity(0.28), radius: InterfaceScale.metric(24), y: 10)
                        .frame(width: widgetBounds.width + 24, height: widgetBounds.height + 24)
                        .position(x: widgetBounds.midX, y: widgetBounds.midY)
                        .allowsHitTesting(false)
                }
                // The backing fits the checkbox; the transparent canvas gives expanded challenges the whole window.
                widget
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(interactionRequired ? 1 : 0)
                    .allowsHitTesting(interactionRequired)
                if !interactionRequired {
                    ProgressView().accessibilityLabel("Loading Discord verification").allowsHitTesting(false)
                }
            }
        }
        .onAppear { context.escapeAction = cancel }
        .onDisappear { context.escapeAction = nil }
    }

    @ViewBuilder private var widget: some View {
        switch challenge.service {
        case .hcaptcha:
            DiscordCaptchaView(challenge: challenge, onInteractionRequired: { interactionRequired = true },
                               onToken: onToken, onCancel: cancel, onWidgetBoundsChanged: { widgetBounds = $0 })
        case .recaptcha, .recaptchaEnterprise, .turnstile:
            DiscordWebCaptchaView(challenge: challenge, onInteractionRequired: { interactionRequired = true },
                                  onToken: onToken, onCancel: cancel, onWidgetBoundsChanged: { widgetBounds = $0 })
        }
    }
}
