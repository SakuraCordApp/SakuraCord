import Foundation
import MessageRendering

extension AppModel {
    /// Lets voice playback, file downloads, and the media viewer re-sign
    /// expiring attachment links.
    func configureAttachmentMedia() {
        let resolveRemoteURL: @MainActor (URL) async -> URL = { [weak self] url in
            // Only Discord's own attachment links go to Discord; a local file
            // or another host's link is used as it is.
            guard let self, DiscordAttachmentLink.matches(url), DiscordAttachmentLink.needsRefresh(url, now: .now)
            else { return url }
            let session = accountSession()
            return (try? await session.provider.refreshAttachmentURL(url)) ?? url
        }
        voiceMessagePlayback.resolveRemoteURL = resolveRemoteURL
        attachmentDownloads.resolveRemoteURL = resolveRemoteURL
        MediaViewerActionService.resolveRemoteURL = resolveRemoteURL
        voiceMessagePlayback.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }
}
