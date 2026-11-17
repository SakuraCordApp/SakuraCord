import DiscordProtocol
import Foundation
import ImageIO
import SakuraCordModels
import UniformTypeIdentifiers

enum MockChatMediaFixtures {
    static func gifs(query: String) throws -> [GIFSearchResult] {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "SakuraCordDemoMedia",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "demo.gif")
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = Data(
                base64Encoded: "R0lGODlhAQABAPAAAP///wAAACH5BAAAAAAALAAAAAABAAEAAAICRAEAOw=="
            )!
            try data.write(to: url, options: .atomic)
        }
        let sizes = [(640, 640), (498, 210), (374, 352), (498, 498), (200, 150), (640, 492)]
        return (0 ..< 50).map { index in
            let size = sizes[index % sizes.count]
            return GIFSearchResult(
                id: "demo-gif-\(index)",
                title: "\(query) demo \(index + 1)",
                url: URL(string: "https://example.invalid/mock-gif/\(index)")!,
                previewURL: url,
                width: size.0,
                height: size.1,
                thumbnailURL: url,
                mediaURL: url
            )
        }
    }

    static func stageAttachment(
        _ sourceURL: URL,
        messageID: UInt64,
        index: Int
    ) throws -> Attachment {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SakuraCordDemoAttachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension
        let filename = sourceURL.lastPathComponent.isEmpty
            ? "attachment-\(index)"
            : sourceURL.lastPathComponent
        let destination = directory.appending(
            path: "\(messageID)-\(index)\(fileExtension.isEmpty ? "" : ".\(fileExtension)")"
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        let mediaType = UTType(filenameExtension: fileExtension)?.preferredMIMEType
        // Discord reports an uploaded image's size, which lays out its frame.
        let properties = CGImageSourceCreateWithURL(destination as CFURL, nil).flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // The decoder rotates these orientations by a quarter turn.
        let swapsDimensions = (5 ... 8).contains(orientation)
        return Attachment(
            id: "\(messageID)-\(index)",
            filename: filename,
            url: destination,
            mediaType: mediaType,
            width: swapsDimensions ? height : width,
            height: swapsDimensions ? width : height,
            size: values.fileSize ?? 0
        )
    }
}
