import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum MediaViewerActionService {
    static func copyText(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    static func copyImage(from url: URL) async throws {
        let data = try await SharedMediaDataLoader.shared.data(for: url)
        guard let image = NSImage(data: data) else {
            throw MediaViewerActionError.invalidImage
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else {
            throw MediaViewerActionError.pasteboardWriteFailed
        }
    }

    static func save(_ item: RichMediaItem) async throws -> URL? {
        let settings = StorageDownloadsSettingsStore.shared.load()
        var accessedFolder: URL?
        defer { accessedFolder?.stopAccessingSecurityScopedResource() }
        let destination: URL?
        switch settings.downloadLocationMode {
        case .askEveryTime:
            destination = await savePanelDestination(for: item)
        case .defaultFolder:
            guard let folder = try StorageDownloadsSettingsStore.shared
                .resolvedDefaultFolder()
            else {
                throw MediaViewerActionError.defaultDownloadFolderUnavailable
            }
            guard folder.startAccessingSecurityScopedResource() else {
                throw MediaViewerActionError.defaultDownloadFolderUnavailable
            }
            accessedFolder = folder
            let proposed = folder.appendingPathComponent(
                MediaViewerFilePolicy.suggestedFilename(
                    title: item.title,
                    sourceURL: item.url
                )
            )
            if let automaticDestination = settings.filenameCollisionPolicy
                .destination(for: proposed)
            {
                destination = automaticDestination
            } else if settings.filenameCollisionPolicy == .ask {
                destination = await savePanelDestination(
                    for: item,
                    directory: folder
                )
            } else {
                throw MediaViewerActionError.couldNotChooseUniqueFilename
            }
        }

        guard let destination else { return nil }
        try await copyMedia(from: item.url, to: destination)
        if settings.revealsCompletedDownloads {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
        return destination
    }

    private static func savePanelDestination(
        for item: RichMediaItem,
        directory: URL? = nil
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Media"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = MediaViewerFilePolicy.suggestedFilename(
            title: item.title,
            sourceURL: item.url
        )
        panel.directoryURL = directory
        if let type = MediaViewerFilePolicy.contentType(
            title: item.title,
            sourceURL: item.url
        ) {
            panel.allowedContentTypes = [type]
        }

        // A frame-level media viewer sits above the window's sheet anchor.
        // Run a standalone native panel after menu tracking has unwound. The
        // modal AppKit run loop keeps the app responsive and guarantees that
        // the panel is ordered above the frame-level viewer.
        await Task.yield()
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    static func copyMedia(
        from source: URL,
        to destination: URL,
        dataLoader: SharedMediaDataLoader = .shared
    ) async throws {
        try await ExactDestinationFileWriter.write(to: destination) { stagedDestination in
            if source.isFileURL {
                let accessed = source.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        source.stopAccessingSecurityScopedResource()
                    }
                }
                try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(
                        at: source,
                        to: stagedDestination
                    )
                }.value
            } else {
                try await dataLoader.copyRemoteMedia(
                    from: source,
                    to: stagedDestination
                )
            }
        }
    }

    static func openInBrowser(_ url: URL) {
        let workspace = NSWorkspace.shared
        let browserProbe = URL(string: "https://example.com")!
        guard let browserURL = workspace.urlForApplication(toOpen: browserProbe)
            ?? workspace.urlForApplication(
                withBundleIdentifier: "com.apple.Safari"
            )
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open(
            [url],
            withApplicationAt: browserURL,
            configuration: configuration
        )
    }

}
nonisolated enum MediaViewerFilePolicy {
    static func suggestedFilename(title: String, sourceURL: URL) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = sourceURL.lastPathComponent.isEmpty
            ? "Media"
            : sourceURL.lastPathComponent
        var filename = trimmedTitle.isEmpty ? fallback : trimmedTitle
        filename = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let sourceExtension = sourceURL.pathExtension
        if (filename as NSString).pathExtension.isEmpty,
           !sourceExtension.isEmpty
        {
            filename += ".\(sourceExtension)"
        }
        return String(filename.prefix(240))
    }

    static func contentType(title: String, sourceURL: URL) -> UTType? {
        let titleExtension = (title as NSString).pathExtension
        let pathExtension = titleExtension.isEmpty
            ? sourceURL.pathExtension
            : titleExtension
        guard !pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: pathExtension)
    }

}

nonisolated enum MediaViewerDetails {
    static func dimensions(_ item: RichMediaItem) -> String? {
        guard let width = item.width,
              let height = item.height,
              width > 0,
              height > 0
        else { return nil }
        return "\(width) × \(height) pixels"
    }

    static func fileSize(_ item: RichMediaItem) -> String? {
        guard item.size > 0 else { return nil }
        return item.size.formatted(.byteCount(style: .file))
    }

    static func kind(_ item: RichMediaItem) -> String {
        switch item.kind {
        case let .image(animated):
            animated ? "Animated image" : "Image"
        case .video:
            "Video"
        case .audio:
            "Audio"
        case .file:
            "File"
        }
    }
}

enum MediaViewerActionError: LocalizedError {
    case invalidImage
    case pasteboardWriteFailed
    case defaultDownloadFolderUnavailable
    case couldNotChooseUniqueFilename

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "The media could not be decoded as an image."
        case .pasteboardWriteFailed:
            "The image could not be copied to the clipboard."
        case .defaultDownloadFolderUnavailable:
            "The saved default download folder is unavailable. Choose it again in Storage & Downloads."
        case .couldNotChooseUniqueFilename:
            "SakuraCord could not choose an unused filename in the default download folder."
        }
    }
}
