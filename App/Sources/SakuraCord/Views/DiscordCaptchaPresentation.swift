import DiscordProtocol
import HCaptcha
import SwiftUI
import WebKit

struct DiscordCaptchaView: NSViewRepresentable {
    let challenge: DiscordCaptchaChallenge
    let onInteractionRequired: () -> Void
    let onToken: (String?) -> Void
    var onCancel: (() -> Void)?
    var onWidgetBoundsChanged: ((CGRect) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            challenge: challenge,
            onInteractionRequired: onInteractionRequired,
            onToken: onToken,
            onCancel: onCancel,
            onWidgetBoundsChanged: onWidgetBoundsChanged
        )
    }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        context.coordinator.start(on: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let challenge: DiscordCaptchaChallenge
        let onInteractionRequired: () -> Void
        let onToken: (String?) -> Void
        let onCancel: (() -> Void)?
        let onWidgetBoundsChanged: ((CGRect) -> Void)?
        private weak var webView: WKWebView?
        private static let presentationMessage = "sakuracordCaptchaPresentation"
        var hcaptcha: HCaptcha?
        private var finished = false

        init(
            challenge: DiscordCaptchaChallenge,
            onInteractionRequired: @escaping () -> Void,
            onToken: @escaping (String?) -> Void,
            onCancel: (() -> Void)?,
            onWidgetBoundsChanged: ((CGRect) -> Void)?
        ) {
            self.challenge = challenge
            self.onInteractionRequired = onInteractionRequired
            self.onToken = onToken
            self.onCancel = onCancel
            self.onWidgetBoundsChanged = onWidgetBoundsChanged
        }

        func start(on host: NSView) {
            hcaptcha = try? HCaptcha(
                apiKey: challenge.siteKey,
                baseURL: URL(string: "https://discord.com"),
                size: challenge.shouldServeInvisible ? .invisible : .normal,
                rqdata: challenge.rqdata,
                theme: "dark",
                diagnosticLog: false
            )
            guard let hcaptcha else {
                Task { @MainActor [weak self] in self?.finish(token: nil) }
                return
            }
            hcaptcha.didFinishLoading { [weak self] in
                Task { @MainActor in
                    guard let self, !self.finished, !self.challenge.shouldServeInvisible else { return }
                    self.onInteractionRequired()
                }
            }
            hcaptcha.configureWebView { [weak self] webView in
                self?.configureCanvas(webView)

                webView.frame = host.bounds
                webView.autoresizingMask = [.width, .height]
                host.addSubview(webView)
            }
            hcaptcha.onEvent { [weak self] event, _ in
                guard event == .open else { return }
                Task { @MainActor in
                    guard let self, !self.finished else { return }
                    self.onInteractionRequired()
                }
            }
            hcaptcha.validate(on: host, resetOnError: false) { [weak self] result in
                guard let self else { return }
                let token = try? result.dematerialize()
                Task { @MainActor in self.finish(token: token) }
            }
        }

        private func configureCanvas(_ webView: WKWebView) {
            self.webView = webView
            // AppKit exposes no public content-background toggle for the SDK-owned WKWebView.
            // underPageBackgroundColor alone changes overscroll, leaving the page canvas opaque.
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
            // Style only the SDK's host document; the cross-origin hCaptcha frames keep their own UI.
            webView.evaluateJavaScript("""
            document.documentElement.style.background = 'transparent';
            document.body.style.background = 'transparent';
            """)
            guard onCancel != nil || onWidgetBoundsChanged != nil else { return }
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.presentationMessage)
            webView.configuration.userContentController.add(self, name: Self.presentationMessage)
            webView.evaluateJavaScript("""
            if (!window.sakuracordCaptchaPresentation) {
                const send = value => window.webkit.messageHandlers.\(Self.presentationMessage).postMessage(value);
                let previous = '';
                const report = () => {
                    const iframe = document.querySelector('#hcaptcha-container iframe');
                    if (!iframe) return;
                    const rect = iframe.getBoundingClientRect();
                    if (rect.width <= 0 || rect.height <= 0) return;
                    const bounds = [rect.x, rect.y, rect.width, rect.height];
                    const signature = JSON.stringify(bounds);
                    if (signature !== previous) { previous = signature; send({action: 'bounds', bounds}); }
                };
                window.sakuracordCaptchaPresentation = report;
                new ResizeObserver(report).observe(document.documentElement);
                new MutationObserver(report).observe(document.body, {subtree: true, childList: true, attributes: true});
                window.addEventListener('resize', report);
                document.addEventListener('click', function(event) {
                    if (event.target === document.body || event.target === document.documentElement || event.target.id === 'hcaptcha-container') {
                        event.stopImmediatePropagation();
                        send({action: 'cancel'});
                    }
                }, true);
            }
            window.sakuracordCaptchaPresentation();
            """)

        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, message.frameInfo.isMainFrame, message.name == Self.presentationMessage,
                  let payload = message.body as? [String: Any] else { return }
            if payload["action"] as? String == "cancel" {
                stop()
                onCancel?()
            } else if let values = payload["bounds"] as? [Double], values.count == 4,
                      values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0,
                      values[2] <= 4096, values[3] <= 4096 {
                onWidgetBoundsChanged?(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            }
        }

        private func finish(token: String?) {
            guard !finished else { return }
            stop()
            onToken(token)
        }

        func stop() {
            finished = true
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.presentationMessage)
            webView = nil
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
                        .foregroundStyle(.primary)
                    Spacer()
                    SakuraCordAuthenticationCloseButton(action: cancel)
                        .disabled(!isVisible)
                }

                DiscordCaptchaView(
                    challenge: challenge,
                    onInteractionRequired: interactionRequired,
                    onToken: onToken
                )
                .frame(width: 520, height: 590)
                .clipShape(ConcentricRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius))
            }
            .padding(18)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius + 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius + 18, style: .continuous)
                    .stroke(SakuraCordAccentColor.color.opacity(0.24), lineWidth: 1)
            }
            .containerShape(.rect(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius + 18))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
        }
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.16), value: isVisible)
        .zIndex(10)
    }
}
