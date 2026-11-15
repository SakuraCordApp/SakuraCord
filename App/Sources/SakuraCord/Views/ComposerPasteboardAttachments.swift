import AppKit

@MainActor
enum ComposerPasteboardAttachments {
    /// Files outrank image previews that accompany them, and images outrank
    /// the URL or HTML text that browsers add when copying an image.
    static let readableTypes: [NSPasteboard.PasteboardType] = {
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        return [.fileURL] + imageTypes + NSImage.imageTypes
            .map { NSPasteboard.PasteboardType($0) }
            .filter { !imageTypes.contains($0) }
    }()

    static func attachments(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> ComposerIncomingAttachments? {
        guard type != .fileURL else {
            let urls = fileURLs(from: pasteboard)
            return urls.isEmpty ? nil : .external(urls)
        }
        return pastedImage(from: pasteboard, type: type).map { .owned($0) }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        var seen: Set<URL> = []
        return objects.compactMap { object -> URL? in
            guard let url = (object as? NSURL)?.absoluteURL,
                  url.isFileURL,
                  seen.insert(url.standardizedFileURL).inserted
            else { return nil }
            return url
        }
    }

    /// Writes clipboard image data as a PNG in app-owned storage, which the
    /// model adopts and removes once no composer or upload retains it.
    private static func pastedImage(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> ComposerPromisedFileBatch? {
        guard let data = pasteboard.data(forType: type),
              let png = type == .png ? data : NSImage(data: data)?.tiffRepresentation
                  .flatMap(NSBitmapImageRep.init(data:))?
                  .representation(using: .png, properties: [:])
        else { return nil }
        let filename = pastedImageFilename(html: pasteboard.string(forType: .html))
        return ComposerPromisedFileStorage.makeBatch(writing: png, named: filename)
    }

    /// Names a pasted image as Discord does: after the first `<img>` source in
    /// accompanying HTML, which browsers include when copying an image.
    nonisolated static func pastedImageFilename(html: String?) -> String {
        let pattern = /<img\b[^>]*?\ssrc\s*=\s*["']([^"']+)["']/.ignoresCase()
        guard let html,
              let source = html.firstMatch(of: pattern).map({ String($0.1) }),
              let url = URL(string: source),
              url.scheme.map({ ["http", "https", "file"].contains($0.lowercased()) }) ?? true
        else { return "image.png" }
        // `lastPathComponent` percent-decodes, so the name can contain
        // separators, control characters, or traversal components.
        let stem = safeFilenameStem((url.lastPathComponent as NSString).deletingPathExtension)
        return (stem ?? "image") + ".png"
    }

    /// Reduces untrusted text to one file name component of at most 200
    /// UTF-8 bytes, or nil when nothing usable remains.
    nonisolated static func safeFilenameStem(_ raw: String) -> String? {
        var stem = ""
        for character in raw {
            let isUnsafe = character.unicodeScalars.contains {
                $0 == "/" || $0 == ":" || $0.properties.generalCategory == .control
            }
            let safe = isUnsafe ? "_" : String(character)
            guard stem.utf8.count + safe.utf8.count <= 200 else { break }
            stem += safe
        }
        guard !stem.isEmpty, stem != ".", stem != "..", stem != "_" else { return nil }
        return stem
    }

    /// Writes pasted text too long for a message as `message.txt`, as Discord does.
    static func longTextAttachment(_ text: String) -> ComposerPromisedFileBatch? {
        guard ChatCharacterLimitPolicy.pastedTextBecomesAttachment(text) else { return nil }
        return ComposerPromisedFileStorage.makeBatch(writing: Data(text.utf8), named: "message.txt")
    }
}
