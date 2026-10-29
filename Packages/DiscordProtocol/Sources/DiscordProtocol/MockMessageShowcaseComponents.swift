import Foundation
import SakuraCordModels

extension MockMessageFixtureBuilder {
    func showcaseComponents() -> [Message] {
        var result = [showcaseMessage(400, content: "# Buttons, selects, and Components V2")]
        result += [
            showcaseMessage(401, author: verifiedApp, content: "Legacy action rows: button styles, disabled, and icon-only buttons.") {
                $0.applicationID = ApplicationID(rawValue: 900_000_000_000_000_101)
                $0.components = showcaseButtons()
            },
            showcaseMessage(402, author: verifiedApp) {
                $0.flags = [.isComponentsV2]
                $0.components = [
                    .container(id: "showcase-container", accentColor: 0xD9578B, spoiler: false, children: [
                        .textDisplay(id: "showcase-heading", content: "## A complete component card\nFormatted **text**, <@1>, and ||a spoiler||."),
                        .separator(id: "showcase-divider", divider: true, spacing: 1),
                        .section(id: "showcase-section", children: [
                            .textDisplay(id: "showcase-section-text", content: "A section with a thumbnail accessory."),
                        ], accessory: .thumbnail(id: "showcase-thumbnail", media: showcaseComponentImage)),
                        .section(id: "showcase-button-section", children: [
                            .textDisplay(id: "showcase-button-text", content: "A section with a button accessory."),
                        ], accessory: showcaseButton("section", style: .primary, label: "Inspect")),
                        .mediaGallery(id: "showcase-gallery", items: [
                            ComponentGalleryItem(id: "showcase-gallery-image", media: showcaseComponentImage),
                            ComponentGalleryItem(id: "showcase-gallery-gif", media: .init(
                                url: MockChatFixture.animatedDemoAsset(), width: 32, height: 32, contentType: "image/gif", description: "Animated gallery tile"
                            )),
                            ComponentGalleryItem(id: "showcase-gallery-video", media: .init(
                                url: videoFixture, width: 320, height: 180, contentType: "video/mp4", description: "Video gallery tile"
                            )),
                        ]),
                        .separator(id: "showcase-spacer", divider: false, spacing: 2),
                        .file(id: "showcase-file", media: showcaseComponentFile),
                    ]),
                ]
                $0.mentionedUsers = [nova]
                $0.attachments = showcaseComponentAttachments
            },
            showcaseMessage(403, author: nova) {
                $0.flags = [.isComponentsV2]
                $0.attachments = showcaseComponentAttachments
                $0.components = [
                    .textDisplay(id: "showcase-top-text", content: "## Top-level components\nText outside a container."),
                    .thumbnail(id: "showcase-top-thumbnail", media: showcaseComponentImage),
                    .mediaGallery(id: "showcase-top-gallery", items: [ComponentGalleryItem(id: "showcase-top-image", media: showcaseComponentImage)]),
                    .file(id: "showcase-top-file", media: showcaseComponentFile),
                ]
            },
            showcaseMessage(404, author: verifiedApp) {
                $0.flags = [.isComponentsV2]
                $0.components = [
                    .container(id: "showcase-spoiler-container", accentColor: 0x7C3AED, spoiler: true, children: [
                        .textDisplay(id: "showcase-hidden-text", content: "## A concealed container\nText and media reveal together."),
                        .mediaGallery(id: "showcase-hidden-gallery", items: [ComponentGalleryItem(id: "showcase-hidden-image", media: showcaseComponentImage)]),
                    ]),
                ]
            },
            showcaseMessage(405, author: verifiedApp) {
                $0.flags = [.isComponentsV2]
                var hiddenImage = showcaseComponentImage
                hiddenImage.isSpoiler = true
                var hiddenFile = showcaseComponentFile
                hiddenFile.isSpoiler = true
                $0.attachments = showcaseComponentAttachments
                $0.components = [
                    .textDisplay(id: "showcase-media-spoilers", content: "Individual component media spoilers"),
                    .mediaGallery(id: "showcase-mixed-gallery", items: [
                        ComponentGalleryItem(id: "showcase-visible-tile", media: showcaseComponentImage),
                        ComponentGalleryItem(id: "showcase-hidden-tile", media: hiddenImage),
                    ]),
                    .file(id: "showcase-hidden-file", media: hiddenFile),
                ]
            },
            showcaseMessage(406, author: verifiedApp, content: "An unsupported component fallback.") {
                $0.components = [.unsupported(id: "showcase-unsupported", type: 999, label: "Unsupported demonstration component")]
            },
        ]
        result += selectionFieldFixtureMessages().enumerated().map { index, original in
            showcaseMessage(UInt64(420 + index), author: original.author, content: original.content) {
                $0.flags = original.flags
                $0.applicationID = original.applicationID
                $0.components = original.components
                $0.mentionedUsers = original.mentionedUsers
            }
        }
        result.append(showcaseMessage(425, author: verifiedApp, content: "A disabled selection field.") {
            $0.components = [.actionRow(id: "showcase-disabled-select-row", children: [
                .select(id: "showcase-disabled-select", kind: .string, customID: "offline-showcase-disabled", placeholder: "Unavailable",
                        minValues: 0, maxValues: 1, disabled: true, options: [.init(label: "Read only", value: "readonly")], channelTypes: []),
            ])]
        })
        return result
    }

    private var showcaseComponentImage: ComponentMedia {
        ComponentMedia(url: layoutAttachment?.url, width: 720, height: 420, contentType: "image/png", description: "Offline layout study")
    }

    /// Discord delivers a file component's attachment with its message.
    private var showcaseComponentAttachments: [Attachment] {
        MockChatFixture.demoResource("demo-notes", extension: "txt").map {
            [Attachment(id: "showcase-component-file", filename: "demo-notes.txt", url: $0, mediaType: "text/plain", size: 218)]
        } ?? []
    }

    private var showcaseComponentFile: ComponentMedia {
        ComponentMedia(url: MockChatFixture.demoResource("demo-notes", extension: "txt"), attachmentName: "demo-notes.txt", contentType: "text/plain")
    }

    private func showcaseButtons() -> [MessageComponent] {
        [
            .actionRow(id: "showcase-button-styles", children: [
                showcaseButton("primary", style: .primary, label: "Primary"),
                showcaseButton("secondary", style: .secondary, label: "Secondary"),
                showcaseButton("success", style: .success, label: "Success"),
                showcaseButton("destructive", style: .destructive, label: "Destructive"),
                showcaseButton("link", style: .link, label: "Link"),
            ]),
            .actionRow(id: "showcase-button-states", children: [
                showcaseButton("disabled", style: .primary, label: "Disabled", disabled: true),
                showcaseButton("emoji", style: .secondary, label: nil),
                showcaseButton("premium", style: .premium, label: "Premium", disabled: true),
            ]),
        ]
    }

    private func showcaseButton(_ id: String, style: ComponentButtonStyle, label: String?, disabled: Bool = false) -> MessageComponent {
        .button(id: "showcase-button-\(id)", style: style, label: label, emoji: label == nil ? EmojiReference(name: "🌸") : nil,
                customID: style == .link || style == .premium ? nil : "offline-showcase-\(id)",
                url: style == .link ? URL(string: "https://example.com") : nil, skuID: style == .premium ? "offline-sku" : nil, disabled: disabled)
    }
}
