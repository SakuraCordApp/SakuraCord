import HCaptcha
import SwiftUI

struct DiscordCaptchaView: NSViewControllerRepresentable {
    let challenge: DiscordCaptchaChallenge
    let onInteractionRequired: () -> Void
    let onToken: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            challenge: challenge,
            onInteractionRequired: onInteractionRequired,
            onToken: onToken
        )
    }

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        host.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            host.topAnchor.constraint(equalTo: controller.view.topAnchor),
            host.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        ])
        context.coordinator.start(on: host)
        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}

    static func dismantleNSViewController(
        _ nsViewController: NSViewController,
        coordinator: Coordinator
    ) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        let challenge: DiscordCaptchaChallenge
        let onInteractionRequired: () -> Void
        let onToken: (String?) -> Void
        var hcaptcha: HCaptcha?

        init(
            challenge: DiscordCaptchaChallenge,
            onInteractionRequired: @escaping () -> Void,
            onToken: @escaping (String?) -> Void
        ) {
            self.challenge = challenge
            self.onInteractionRequired = onInteractionRequired
            self.onToken = onToken
        }

        func start(on host: NSView) {
            hcaptcha = try? HCaptcha(
                apiKey: challenge.siteKey,
                baseURL: URL(string: "https://discord.com"),
                rqdata: challenge.rqdata,
                theme: "dark",
                diagnosticLog: false
            )
            hcaptcha?.configureWebView { webView in
                webView.frame = host.bounds
                webView.autoresizingMask = [.width, .height]
                host.addSubview(webView)
            }
            hcaptcha?.onEvent { [weak self] event, _ in
                guard event == .open else { return }
                Task { @MainActor in self?.onInteractionRequired() }
            }
            hcaptcha?.validate(on: host) { [weak self] result in
                guard let self else { return }
                let token = try? result.dematerialize()
                Task { @MainActor in self.onToken(token) }
                hcaptcha?.reset()
            }
        }

        func stop() {
            hcaptcha?.stop()
            hcaptcha = nil
        }
    }
}

struct DiscordCaptchaPresentation: View {
    let challenge: DiscordCaptchaChallenge
    @Binding var isVisible: Bool
    let cancel: () -> Void
    let interactionRequired: () -> Void
    let onToken: (String?) -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(isVisible ? 0.58 : 0)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    Text("Discord verification")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                }

                DiscordCaptchaView(
                    challenge: challenge,
                    onInteractionRequired: interactionRequired,
                    onToken: onToken
                )
                .frame(width: 520, height: 590)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(18)
            .background(
                Color(hex: 0x211824),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(hex: 0xFF79AA).opacity(0.24), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
        }
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.16), value: isVisible)
        .zIndex(10)
    }
}
