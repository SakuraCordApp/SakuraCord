import SwiftUI
import WebKit

/// Created only by an explicit media activation, never by timeline layout or scrolling.
struct YouTubePlayerView: NSViewRepresentable {
    let playback: YouTubeEmbedPlayback
    let openInBrowser: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(playback: playback, openInBrowser: openInBrowser)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(context.coordinator, name: "playback")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        let position = YouTubePlaybackSession.shared.position(for: playback)
        let request = playback.playerRequest(
            appIdentifier: Bundle.main.bundleIdentifier ?? "dev.sakuracord.SakuraCord",
            resumeAt: position
        )
        // YouTube documents loadHTMLString's base URL as the WKWebView Referer source.
        view.loadHTMLString(
            playerHTML(request: request, position: position),
            baseURL: request.value(forHTTPHeaderField: "Referer").flatMap(URL.init(string:))
        )
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.openInBrowser = openInBrowser
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "playback")
        nsView.pauseAllMediaPlayback(completionHandler: nil)
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.loadHTMLString("", baseURL: nil)
    }

    private func playerHTML(request: URLRequest, position: Double) -> String {
        // Only the validated video ID, generated URL and finite session position enter this document.
        let source = request.url!.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        return """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body,iframe{margin:0;width:100%;height:100%;border:0;background:black;overflow:hidden}</style>
        </head><body>
        <iframe id="player" src="\(source)" allow="autoplay; encrypted-media; fullscreen; picture-in-picture" allowfullscreen></iframe>
        <script>
        let player, hasPlayed = false;
        function reportProgress() {
            if (!player || !hasPlayed) return;
            const state = player.getPlayerState();
            if (![0, 1, 2].includes(state)) return;
            const videoID = new URL(player.getVideoUrl()).searchParams.get('v');
            if (videoID !== '\(playback.videoID)') return;
            window.webkit.messageHandlers.playback.postMessage({
                videoID, seconds: player.getCurrentTime(), duration: player.getDuration(), ended: state === 0
            });
        }
        function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', { events: {
                onReady: event => {
                    if (\(position) > 0) event.target.seekTo(\(position), true);
                    event.target.playVideo();
                },
                onStateChange: event => {
                    if (event.data === 1) hasPlayed = true;
                    reportProgress();
                }
            }});
        }
        setInterval(reportProgress, 1000);
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let playback: YouTubeEmbedPlayback
        var openInBrowser: (URL) -> Void

        init(playback: YouTubeEmbedPlayback, openInBrowser: @escaping (URL) -> Void) {
            self.playback = playback
            self.openInBrowser = openInBrowser
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  body["videoID"] as? String == playback.videoID,
                  let seconds = body["seconds"] as? Double,
                  let duration = body["duration"] as? Double,
                  let ended = body["ended"] as? Bool else { return }
            YouTubePlaybackSession.shared.record(seconds, duration: duration, ended: ended, for: playback)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame != false else { return .allow }
            // The app-owned wrapper is the only main-frame document. YouTube lives in its iframe.
            if navigationAction.navigationType == .other,
               navigationAction.request.url == webView.url || webView.url == nil { return .allow }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url, url.scheme == "https" { openInBrowser(url) }
            return .cancel
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url, url.scheme == "https" { openInBrowser(url) }
            return nil
        }
    }
}
