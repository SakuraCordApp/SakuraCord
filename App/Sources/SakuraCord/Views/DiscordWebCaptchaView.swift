import AppKit
import DiscordProtocol
import SwiftUI
import WebKit

/// reCAPTCHA, reCAPTCHA Enterprise and Turnstile challenges, rendered by
/// their vendors' explicit-render scripts on a transparent discord.com-origin
/// page. hCaptcha uses its SDK in `DiscordCaptchaView`. The page never
/// receives Discord credentials; only the human-completed token leaves it.
struct DiscordWebCaptchaView: NSViewRepresentable {
    let challenge: DiscordCaptchaChallenge
    let onInteractionRequired: () -> Void
    let onToken: (String?) -> Void
    let onCancel: () -> Void
    let onWidgetBoundsChanged: (CGRect) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // AppKit exposes no public content-background toggle for WKWebView.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        context.coordinator.webView = webView
        if let page = Self.page(for: challenge) {
            webView.loadHTMLString(page, baseURL: URL(string: "https://discord.com"))
        } else {
            Task { @MainActor in context.coordinator.finish(token: nil) }
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageName = "sakuracordCaptcha"
        let parent: DiscordWebCaptchaView
        weak var webView: WKWebView?
        private var finished = false
        private var loadedPage = false

        init(parent: DiscordWebCaptchaView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, message.frameInfo.isMainFrame, message.name == Self.messageName,
                  let payload = message.body as? [String: Any] else { return }
            switch payload["action"] as? String {
            case "interactive":
                parent.onInteractionRequired()
            case "token":
                finish(token: payload["token"] as? String)
            case "cancel":
                stop()
                parent.onCancel()
            case "bounds":
                guard let values = payload["bounds"] as? [Double], values.count == 4,
                      values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0,
                      values[2] <= 4096, values[3] <= 4096 else { return }
                parent.onWidgetBoundsChanged(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // Vendor frames may navigate; the challenge page itself never leaves.
            guard navigationAction.targetFrame?.isMainFrame == true else {
                decisionHandler(navigationAction.targetFrame == nil ? .cancel : .allow)
                return
            }
            decisionHandler(loadedPage ? .cancel : .allow)
            loadedPage = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            finish(token: nil)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            finish(token: nil)
        }

        func finish(token: String?) {
            guard !finished else { return }
            stop()
            parent.onToken(token)
        }

        func stop() {
            finished = true
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
            webView?.stopLoading()
            webView = nil
        }
    }

    // Official stable633029 module645320, module955205 and module700525
    // render options; Turnstile's three delayed widget resets are bounded.
    private static func page(for challenge: DiscordCaptchaChallenge) -> String? {
        var config: [String: Any] = [
            "service": challenge.service.rawValue,
            "sitekey": challenge.siteKey,
            "invisible": challenge.shouldServeInvisible,
        ]
        if let action = challenge.userFlow { config["action"] = action }
        guard challenge.service != .hcaptcha,
              let data = try? JSONSerialization.data(withJSONObject: config),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent}body{display:flex;align-items:center;justify-content:center}</style>
        </head><body><div id="captcha"></div><script>
        const config = \(literal);
        const send = value => window.webkit.messageHandlers.\(Coordinator.messageName).postMessage(value);
        const container = document.getElementById('captcha');
        let finished = false;
        const finish = token => { if (finished) return; finished = true; send({action: 'token', token: token || null}); };
        const report = () => {
            const rect = container.getBoundingClientRect();
            if (rect.width > 0 && rect.height > 0) send({action: 'bounds', bounds: [rect.x, rect.y, rect.width, rect.height]});
        };
        const interactive = () => { send({action: 'interactive'}); report(); };
        new ResizeObserver(report).observe(container);
        document.addEventListener('click', event => {
            if (event.target === document.body || event.target === document.documentElement) {
                event.stopImmediatePropagation();
                send({action: 'cancel'});
            }
        }, true);
        const load = (source, onload) => {
            const script = document.createElement('script');
            script.src = source;
            script.async = true;
            script.defer = true;
            script.onerror = () => finish(null);
            if (onload) script.onload = onload;
            document.head.appendChild(script);
        };
        if (config.service === 'recaptcha') {
            window.recaptchaOnLoad = () => {
                const id = grecaptcha.render(container, {
                    sitekey: config.sitekey, theme: 'dark', size: config.invisible ? 'invisible' : 'normal',
                    callback: token => finish(token),
                    'expired-callback': () => grecaptcha.reset(id),
                    'error-callback': () => finish(null)
                });
                interactive();
                if (config.invisible) grecaptcha.execute(id);
            };
            load('https://recaptcha.net/recaptcha/api.js?render=explicit&onload=recaptchaOnLoad');
        } else if (config.service === 'recaptcha_enterprise') {
            load('https://www.google.com/recaptcha/enterprise.js?render=' + encodeURIComponent(config.sitekey), () => {
                grecaptcha.enterprise.ready(async () => {
                    try {
                        finish(await grecaptcha.enterprise.execute(config.sitekey, config.action ? {action: config.action} : undefined));
                    } catch (error) {
                        finish(null);
                    }
                });
            });
        } else if (config.service === 'turnstile') {
            let resets = 0;
            window.turnstileOnLoad = () => {
                const id = turnstile.render(container, {
                    sitekey: config.sitekey, theme: 'auto', size: 'normal', retry: 'never',
                    callback: token => finish(token),
                    'error-callback': () => {
                        if (resets >= 3) { finish(null); return true; }
                        resets += 1;
                        setTimeout(() => { if (!finished) turnstile.reset(id); }, 3000);
                        return true;
                    },
                    'expired-callback': () => turnstile.reset(id)
                });
                interactive();
            };
            load('https://challenges.cloudflare.com/turnstile/v0/api.js?onload=turnstileOnLoad&render=explicit');
        }
        </script></body></html>
        """
    }
}
