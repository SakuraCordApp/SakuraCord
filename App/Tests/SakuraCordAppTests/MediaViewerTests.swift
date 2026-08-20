import AppKit
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct MediaViewerTests {
    @Test func `media save copies local files without loading them into the media cache`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sakuracord-media-save-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let destination = directory.appendingPathComponent("destination.bin")
        let bytes = Data((0 ..< 4_096).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        try Data("old".utf8).write(to: destination)

        try await MediaViewerActionService.copyMedia(
            from: source,
            to: destination
        )

        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .allSatisfy { !$0.hasPrefix(".sakuracord-save-") }
        )
    }

    @Test func `remote media save uses the shared streamed download path`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sakuracord-remote-media-save-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloadedFile = directory.appendingPathComponent("downloaded.bin")
        let destination = directory.appendingPathComponent("saved.bin")
        let bytes = Data((0 ..< 8_192).map { UInt8($0 % 239) })
        try bytes.write(to: downloadedFile)
        let probe = MediaViewerRemoteDownloadProbe(fileURL: downloadedFile)
        let loader = SharedMediaDataLoader(
            remoteFetch: { url in
                try await probe.fetch(url)
            },
            remoteDownload: { url in
                await probe.download(url)
            }
        )
        let source = try #require(URL(
            string: "https://cdn.example/large-video.mp4"
        ))

        try await MediaViewerActionService.copyMedia(
            from: source,
            to: destination,
            dataLoader: loader
        )

        #expect(try Data(contentsOf: destination) == bytes)
        #expect(await probe.downloadedURLs == [source])
        #expect(await probe.dataFetchCount == 0)
        #expect(
            await loader.remoteLoadSnapshot()
                == .init(pendingCount: 0, activeCount: 0, waiterCount: 0)
        )
    }

    @Test func `interaction loops navigation and resets zoom between media`() {
        let model = MediaViewerInteractionModel(itemCount: 3, selection: 1)
        model.commitScale(4)
        model.commitOffset(CGSize(width: 90, height: -40))

        #expect(model.move(1))
        #expect(model.selection == 2)
        #expect(model.scale == 1)
        #expect(model.offset == .zero)
        #expect(model.move(1))
        #expect(model.selection == 0)
        #expect(model.move(-1))
        #expect(model.selection == 2)
    }

    @Test func `pinch dismissal only commits from minimum zoom`() {
        let model = MediaViewerInteractionModel(itemCount: 1, selection: 0)

        model.commitScale(2)
        model.updatePinchDismissal(magnification: 0.7)
        #expect(model.pinchDismissalProgress == 0)
        #expect(
            !model.shouldCommitPinchDismissal(
                magnification: 0.7,
                velocity: -2
            )
        )

        model.commitScale(1)
        model.updatePinchDismissal(magnification: 0.72)
        #expect(model.pinchDismissalProgress == 1)
        #expect(
            model.shouldCommitPinchDismissal(
                magnification: 0.8,
                velocity: 0
            )
        )
        #expect(
            !model.shouldCommitPinchDismissal(
                magnification: 0.9,
                velocity: 0
            )
        )
    }

    @Test func `save filename keeps the media extension and removes path separators`() throws {
        let source = try #require(URL(string: "https://cdn.example/image.png?token=1"))

        #expect(
            MediaViewerFilePolicy.suggestedFilename(
                title: "summer/night",
                sourceURL: source
            ) == "summer-night.png"
        )
        #expect(
            MediaViewerFilePolicy.suggestedFilename(
                title: "already.webp",
                sourceURL: source
            ) == "already.webp"
        )
    }

    @Test func `linked images open as one in app viewer gallery`() throws {
        let firstURL = try #require(URL(
            string: "https://cdn.discordapp.com/attachments/1/2/first.png"
        ))
        let secondURL = try #require(URL(
            string: "https://media.discordapp.net/attachments/1/2/second.webp"
        ))
        let content = "[First](\(firstURL.absoluteString)) [Second](\(secondURL.absoluteString))"
        let references = LinkedImagePresentation(content: content).images
        let second = try #require(references.last)
        let message = Message(
            id: MessageID(rawValue: 55),
            channelID: ChannelID(rawValue: 56),
            author: User(
                id: UserID(rawValue: 57),
                username: "author",
                displayName: "Author"
            ),
            content: content,
            timestamp: .now
        )

        let presentation = try #require(
            NativeTimelineMediaViewerPlan.linkedImages(
                in: message,
                selectedReferenceID: second.id
            )
        )

        #expect(presentation.items.map(\.url) == [firstURL, secondURL])
        #expect(presentation.selection == 1)
    }

    @Test func `component images use the viewer while ordinary files stay external`() throws {
        let visibleURL = try #require(URL(
            string: "https://cdn.example/visible.png"
        ))
        let hiddenURL = try #require(URL(
            string: "https://cdn.example/hidden.png"
        ))
        let fileImageURL = try #require(URL(
            string: "https://cdn.example/file-image.webp"
        ))
        let documentURL = try #require(URL(
            string: "https://cdn.example/disguised-document.png"
        ))
        let message = Message(
            id: MessageID(rawValue: 58),
            channelID: ChannelID(rawValue: 59),
            author: User(
                id: UserID(rawValue: 60),
                username: "author",
                displayName: "Author"
            ),
            content: "",
            timestamp: .now,
            attachments: [
                Attachment(
                    id: "document-attachment",
                    filename: "document.txt",
                    url: documentURL,
                    mediaType: "text/plain"
                )
            ],
            flags: [.isComponentsV2],
            components: [
                .mediaGallery(
                    id: "gallery",
                    items: [
                        ComponentGalleryItem(
                            id: "visible",
                            media: ComponentMedia(
                                url: visibleURL,
                                contentType: "image/png"
                            )
                        ),
                        ComponentGalleryItem(
                            id: "hidden",
                            media: ComponentMedia(
                                url: hiddenURL,
                                contentType: "image/png",
                                isSpoiler: true
                            )
                        ),
                    ]
                ),
                .file(
                    id: "image-file",
                    media: ComponentMedia(url: fileImageURL)
                ),
                .file(
                    id: "document",
                    media: ComponentMedia(
                        url: documentURL,
                        attachmentName: "document.txt"
                    )
                ),
            ]
        )
        let layout = NativeTimelineRowLayout.make(
            item: .message(
                MessageRowPresentation(
                    message: message,
                    startsGroup: true,
                    startsDay: false,
                    replyPreview: nil,
                    isReplyAvailable: false
                ),
                isUnreadBoundary: false,
                isHighlighted: false
            ),
            width: 700
        )

        let presentation = try #require(
            NativeTimelineMediaViewerPlan.components(
                in: message,
                layouts: layout.componentLayouts,
                selectedComponentID: "image-file",
                isRevealed: { _ in false }
            )
        )

        #expect(presentation.items.map(\.id) == ["visible", "image-file"])
        #expect(presentation.selection == 1)
        #expect(
            NativeTimelineMediaViewerPlan.components(
                in: message,
                layouts: layout.componentLayouts,
                selectedComponentID: "hidden",
                isRevealed: { _ in false }
            ) == nil
        )
        #expect(
            NativeTimelineMediaViewerPlan.components(
                in: message,
                layouts: layout.componentLayouts,
                selectedComponentID: "document",
                isRevealed: { _ in true }
            ) == nil
        )
    }

    @Test func `timeline image right click resolves the image instead of its message`() throws {
        let mediaURL = try #require(URL(string: "https://cdn.example/image.png"))
        let attachment = Attachment(
            id: "image",
            filename: "image.png",
            url: mediaURL,
            mediaType: "image/png",
            width: 800,
            height: 600
        )
        let message = Message(
            id: MessageID(rawValue: 60),
            channelID: ChannelID(rawValue: 61),
            author: User(
                id: UserID(rawValue: 62),
                username: "author",
                displayName: "Author"
            ),
            content: "",
            timestamp: .now,
            attachments: [attachment]
        )
        let layout = NativeTimelineRowLayout.make(
            item: .message(
                MessageRowPresentation(
                    message: message,
                    startsGroup: true,
                    startsDay: false,
                    replyPreview: nil,
                    isReplyAvailable: false
                ),
                isUnreadBoundary: false,
                isHighlighted: false
            ),
            width: 700
        )
        let frame = try #require(layout.attachmentRegions.first?.frame)
        let item = try #require(
            NativeTimelineImageContextMenuPlan.item(
                in: message,
                layout: layout,
                at: CGPoint(x: frame.midX, y: frame.midY),
                isRevealed: { _ in true }
            )
        )

        #expect(item.id == attachment.id)
        #expect(item.url == mediaURL)
        #expect(item.kind == .image(animated: false))
    }

    @Test func `escape prioritizer dismisses media before reaching the timeline`() throws {
        let model = AppModel(launchMode: .offlineTesting)
        let mediaURL = try #require(URL(string: "https://cdn.example/image.png"))
        model.mediaViewerPresentation = NativeTimelineMediaViewerPresentation(
            items: [
                RichMediaItem(
                    Attachment(
                        id: "image",
                        filename: "image.png",
                        url: mediaURL,
                        mediaType: "image/png"
                    )
                )
            ],
            selection: 0,
            authorName: "Author",
            authorAvatarURL: nil,
            timestamp: .now
        )

        #expect(model.consumeEscapeForMediaViewer())
        #expect(model.mediaViewerPresentation == nil)
        #expect(!model.consumeEscapeForMediaViewer())
    }

}

private actor MediaViewerRemoteDownloadProbe {
    let fileURL: URL
    private(set) var downloadedURLs: [URL] = []
    private(set) var dataFetchCount = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func fetch(_ url: URL) throws -> Data {
        dataFetchCount += 1
        return try Data(contentsOf: fileURL)
    }

    func download(_ url: URL) -> SharedMediaDownloadedFile {
        downloadedURLs.append(url)
        return SharedMediaDownloadedFile(
            url: fileURL,
            cleanupDirectory: nil
        )
    }
}
