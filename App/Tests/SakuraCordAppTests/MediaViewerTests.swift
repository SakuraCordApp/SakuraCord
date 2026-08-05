import AppKit
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct MediaViewerTests {
    @Test func `top chrome uses equal padding above and below matching controls`() {
        #expect(
            MediaViewerTopChromeMetrics.actionDiameter
                + MediaViewerTopChromeMetrics.actionPadding * 2
                == MediaViewerTopChromeMetrics.height
        )
        #expect(
            MediaViewerTopChromeMetrics.mediaTopInset
                - MediaViewerTopChromeMetrics.height
                - MediaViewerTopChromeMetrics.outerPadding
                == MediaViewerTopChromeMetrics.outerPadding
        )
        #expect(
            MediaViewerTopChromeMetrics.avatarDiameter
                == MediaViewerTopChromeMetrics.height
        )
    }

    @Test func `more menu preserves Discord order details and visible icons`() throws {
        let mediaURL = try #require(URL(string: "https://cdn.example/image.png"))
        let item = RichMediaItem(
            Attachment(
                id: "image",
                filename: "image.png",
                url: mediaURL,
                mediaType: "image/png",
                width: 3_420,
                height: 2_224,
                size: 2_000_000
            )
        )
        let coordinator = MediaViewerMoreMenuButton(
            item: item,
            copyImage: {},
            copyLink: {},
            copyAttachmentID: {},
            save: {},
            open: {}
        )
        .makeCoordinator()
        let menu = coordinator.makeMenu()
        let items = menu.items.filter { !$0.isSeparatorItem }

        #expect(
            items.map(\.title) == [
                "Copy Image",
                "Copy Media Link",
                "Copy Attachment ID",
                "View Details",
                "Save Media...",
                "Open in Browser",
            ]
        )
        #expect(items[0].image != nil)
        #expect(items[1].image != nil)
        #expect(items[2].image != nil)
        #expect(items[3].image != nil)
        #expect(items[4].image != nil)
        #expect(items[5].image != nil)
        #expect(items[3].submenu?.items.map(\.title) == ["Filename", "Size"])
        #expect(items[3].submenu?.items[0].subtitle == "image.png")
        #expect(items[3].submenu?.items[1].subtitle == "3420x2224 (2 MB)")
        #expect(items[3].submenu?.items.allSatisfy { $0.action != nil } == true)

        let filenameItem = try #require(items[3].submenu?.items[0])
        let filenameAction = try #require(filenameItem.action)
        #expect(
            NSApplication.shared.sendAction(
                filenameAction,
                to: filenameItem.target,
                from: filenameItem
            )
        )
        #expect(NSPasteboard.general.string(forType: .string) == "image.png")

        let sizeItem = try #require(items[3].submenu?.items[1])
        let sizeAction = try #require(sizeItem.action)
        #expect(
            NSApplication.shared.sendAction(
                sizeAction,
                to: sizeItem.target,
                from: sizeItem
            )
        )
        #expect(
            NSPasteboard.general.string(forType: .string)
                == "3420x2224 (2 MB)"
        )
    }

    @Test func `more control hover surface is circular`() {
        let diameter = MediaViewerTopChromeMetrics.actionDiameter
        let control = MediaViewerMenuNSControl(
            frame: NSRect(x: 0, y: 0, width: diameter, height: diameter)
        )

        control.layout()

        #expect(control.layer?.cornerRadius == diameter / 2)
        #expect(control.layer?.masksToBounds == true)
    }

    @Test func `image context menu matches Discord grouping and preserves icons`() {
        let menu = MediaImageContextMenuBuilder.make(
            actions: MediaImageContextMenuActions(
                copyImage: {},
                saveImage: {},
                copyLink: {},
                openLink: {}
            )
        )

        #expect(
            menu.items.map { $0.isSeparatorItem ? "separator" : $0.title }
                == [
                    "Copy Image",
                    "Save Image",
                    "separator",
                    "Copy Image Link",
                    "Open Image Link",
                ]
        )
        #expect(
            menu.items.filter { !$0.isSeparatorItem }
                .allSatisfy { $0.image != nil }
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

    @Test func `thumbnail rail hugs short sets and only scrolls when needed`() {
        #expect(
            MediaViewerThumbnailMetrics.contentWidth(itemCount: 3)
                == 192
        )
        #expect(
            MediaViewerThumbnailMetrics.railWidth(
                itemCount: 3,
                maximumWidth: 760
            ) == 192
        )
        #expect(
            MediaViewerThumbnailMetrics.railWidth(
                itemCount: 20,
                maximumWidth: 760
            ) == 760
        )
    }

    @Test func `fit policy uses all available space without cropping`() {
        let landscape = MediaViewerLayoutPolicy.fittedSize(
            mediaWidth: 1_600,
            mediaHeight: 900,
            availableSize: CGSize(width: 1_000, height: 800)
        )
        let portrait = MediaViewerLayoutPolicy.fittedSize(
            mediaWidth: 900,
            mediaHeight: 1_600,
            availableSize: CGSize(width: 1_000, height: 800)
        )

        #expect(landscape.width == 1_000)
        #expect(abs(landscape.height - 562.5) < 0.001)
        #expect(portrait.height == 800)
        #expect(abs(portrait.width - 450) < 0.001)
    }

    @Test func `pan policy constrains blank space at every zoom level`() {
        let offset = MediaViewerLayoutPolicy.clampedOffset(
            CGSize(width: 900, height: -900),
            scale: 2,
            fittedSize: CGSize(width: 800, height: 600),
            availableSize: CGSize(width: 1_000, height: 700)
        )

        #expect(offset.width == 300)
        #expect(offset.height == -250)
        #expect(
            MediaViewerLayoutPolicy.clampedOffset(
                CGSize(width: 20, height: 20),
                scale: 1,
                fittedSize: CGSize(width: 800, height: 600),
                availableSize: CGSize(width: 1_000, height: 700)
            ) == .zero
        )
    }

    @Test func `zoom canvas preserves resting geometry and pans across the full window`() {
        let windowSize = CGSize(width: 1_400, height: 800)
        let restingFrame = MediaViewerLayoutPolicy.restingFrame(
            availableSize: windowSize,
            horizontalInset: 66,
            topInset: 72,
            bottomInset: 14
        )

        #expect(restingFrame == CGRect(x: 66, y: 72, width: 1_268, height: 714))

        let panned = MediaViewerLayoutPolicy.offsetByScrolling(
            .zero,
            scrollingDelta: CGSize(width: 80, height: -45),
            scale: 2,
            fittedSize: CGSize(width: 1_200, height: 700),
            availableSize: windowSize
        )
        #expect(panned == CGSize(width: 80, height: -45))
    }

    @Test func `zoomed interaction frame follows every visible image edge`() {
        let restingFrame = CGRect(x: 100, y: 70, width: 1_200, height: 700)
        let transformed = MediaViewerLayoutPolicy.transformedImageFrame(
            restingFrame: restingFrame,
            fittedSize: CGSize(width: 1_000, height: 600),
            scale: 2,
            offset: CGSize(width: 40, height: -20)
        )

        #expect(transformed == CGRect(x: -260, y: -200, width: 2_000, height: 1_200))
        #expect(transformed.contains(CGPoint(x: 30, y: 400)))
    }

    @Test func `zoom cannot shrink below the resting size`() {
        let model = MediaViewerInteractionModel(itemCount: 1, selection: 0)
        model.commitScale(0.25)
        model.commitOffset(CGSize(width: 100, height: 100))

        #expect(model.scale == MediaViewerInteractionModel.minimumScale)
        #expect(model.offset == .zero)
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

    @Test func `presentation carries Discord style author context`() throws {
        let mediaURL = try #require(URL(string: "https://cdn.example/image.png"))
        let avatarURL = try #require(URL(string: "https://cdn.example/avatar.png"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let message = Message(
            id: MessageID(rawValue: 50),
            channelID: ChannelID(rawValue: 51),
            author: User(
                id: UserID(rawValue: 52),
                username: "author",
                displayName: "Author",
                avatarURL: avatarURL
            ),
            guildMember: MessageGuildMember(nickname: "Guild Name"),
            content: "",
            timestamp: timestamp,
            attachments: [
                Attachment(
                    id: "image",
                    filename: "image.png",
                    url: mediaURL,
                    mediaType: "image/png"
                )
            ]
        )

        let presentation = try #require(
            NativeTimelineMediaViewerPlan.attachments(
                in: message,
                selectedAttachmentID: "image"
            )
        )
        #expect(presentation.authorName == "Guild Name")
        #expect(presentation.authorAvatarURL == avatarURL)
        #expect(presentation.timestamp == timestamp)
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
