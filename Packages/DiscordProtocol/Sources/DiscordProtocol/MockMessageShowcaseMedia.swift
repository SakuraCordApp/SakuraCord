import Foundation
import SakuraCordModels

extension MockMessageFixtureBuilder {
    func showcaseMedia() -> [Message] {
        var result = [showcaseMessage(200, content: "# Attachments, voice, and stickers")]
        let image = layoutAttachment
        let animation = MockChatFixture.animatedDemoAsset().map {
            Attachment(id: "showcase-gif", filename: "animation.gif", url: $0, mediaType: "image/gif", width: 32, height: 32)
        }
        let video = videoFixture.map {
            Attachment(id: "showcase-video", filename: "color-loop.mp4", url: $0, mediaType: "video/mp4", width: 320, height: 180)
        }
        let audio = MockChatFixture.voiceMessageAttachment(id: "showcase-audio").map {
            Attachment(id: $0.id, filename: "audio-clip.ogg", url: $0.url, mediaType: "audio/ogg", size: $0.size, durationSeconds: $0.durationSeconds)
        }
        let file = MockChatFixture.demoResource("demo-notes", extension: "txt").map {
            Attachment(id: "showcase-file", filename: "demo-notes.txt", url: $0, mediaType: "text/plain", size: 218)
        }
        let attachments: [(String, Attachment?)] = [
            ("Image", image), ("Animated GIF", animation), ("Video", video), ("Audio file", audio), ("Text file", file),
        ]
        for (index, sample) in attachments.enumerated() {
            guard let attachment = sample.1 else { continue }
            result.append(showcaseMessage(UInt64(210 + index * 3), content: sample.0) { $0.attachments = [attachment] })
            result.append(showcaseMessage(UInt64(211 + index * 3), author: nova) { $0.attachments = [attachment] })
            result.append(showcaseMessage(UInt64(212 + index * 3), content: "Spoiler: \(sample.0.lowercased())") {
                var spoiler = attachment
                spoiler.isSpoiler = true
                spoiler.filename = "SPOILER_" + attachment.filename
                $0.attachments = [spoiler]
            })
        }
        result += [
            showcaseMessage(230, content: "A three-image gallery.") { $0.attachments = galleryAttachments },
            showcaseMessage(231, author: nova) {
                $0.attachments = (0 ..< 10).compactMap { index in
                    image.map {
                        Attachment(id: "showcase-gallery-\(index)", filename: "image-\(index + 1).png", url: $0.url,
                                   mediaType: "image/png", width: index.isMultiple(of: 2) ? 720 : 420, height: 420)
                    }
                }
            },
            showcaseMessage(232, content: "Mixed image, video, audio, and file attachments.") {
                $0.attachments = [image, video, audio, file].compactMap { $0 }
            },
            showcaseMessage(233, content: "An inline image link: \(image.map { "[Layout study](\($0.url.absoluteString))" } ?? "Layout study")"),
            showcaseMessage(234, author: nova, content: animatedFixtureLink),
            showcaseMessage(235, author: nova, content: "File types.") {
                $0.attachments = [
                    ("release-notes.pdf", 1_482_113), ("SakuraCord.zip", 48_211_456),
                    ("FileCard.swift", 7_340), ("budget.numbers", 220_416), ("payload.bin", 26),
                ].enumerated().compactMap { index, sample in
                    file.map {
                        Attachment(id: "showcase-file-type-\(index)", filename: sample.0, url: $0.url, size: sample.1)
                    }
                }
            },
            showcaseMessage(236, content: "A Markdown file and an audio file without a length.") {
                $0.attachments = [
                    MockChatFixture.demoResource("README", extension: "md").map {
                        Attachment(id: "showcase-markdown", filename: "README.md", url: $0, mediaType: "text/markdown", size: 796)
                    },
                    MockChatFixture.demoResource("demo-voice-message", extension: "ogg").map {
                        Attachment(id: "showcase-audio-file", filename: "field-recording.ogg", url: $0, mediaType: "audio/ogg", size: 18_723)
                    },
                ].compactMap { $0 }
            },
            showcaseMessage(237, author: nova) {
                $0.attachments = MockChatFixture.demoResource("benchmark-lottie", extension: "json").map {
                    [Attachment(id: "showcase-json", filename: "pulse.json", url: $0, mediaType: "application/json", size: 1_149)]
                } ?? []
            },
        ]
        let durations = [1.2, 6.2, 65.0]
        result += durations.enumerated().map { index, duration in
            showcaseMessage(UInt64(240 + index), author: index == 1 ? nova : theo) {
                $0.flags = [.voiceMessage]
                $0.attachments = MockChatFixture.voiceMessageAttachment(
                    id: "showcase-voice-\(index)", duration: duration,
                    waveform: MockChatFixture.syntheticVoiceWaveform(seed: index, duration: duration)
                ).map { [$0] } ?? []
            }
        }
        let stickers: [MessageSticker] = [
            demoSticker,
            MockChatFixture.demoResource("demo-sticker", extension: "apng").map {
                MessageSticker(id: "showcase-apng", name: "Animated PNG", format: .apng, assetURL: $0)
            },
            lottieSticker,
            MockChatFixture.animatedDemoAsset().map {
                MessageSticker(id: "showcase-gif-sticker", name: "GIF sticker", format: .gif, assetURL: $0)
            },
        ].compactMap { $0 }
        result += stickers.enumerated().map { index, sticker in
            showcaseMessage(UInt64(250 + index), author: index.isMultiple(of: 2) ? maya : nova) { $0.stickers = [sticker] }
        }
        result.append(showcaseMessage(254, content: "A caption with stickers.") { $0.stickers = stickers.prefix(3).map { $0 } })
        return result
    }

    func showcaseEmbeds() -> [Message] {
        let image = MessageEmbedMedia(url: layoutAttachment?.url, width: 720, height: 420, description: "Offline layout study", contentType: "image/png")
        let animation = MessageEmbedMedia(url: MockChatFixture.animatedDemoAsset(), width: 32, height: 32, contentType: "image/gif")
        let video = MessageEmbedMedia(url: videoFixture, width: 320, height: 180, contentType: "video/mp4")
        let rich = MessageEmbed(
            id: "showcase-rich", title: "A complete rich embed", type: "rich",
            description: "**Formatted text**, [a link](https://example.com), <@1>, and ||a spoiler||.",
            url: URL(string: "https://example.com/showcase"), timestamp: base, color: 0xD9578B,
            footer: MessageEmbedFooter(text: "Offline showcase", iconURL: MockChatFixture.demoAsset("avatar-juniper")),
            image: image,
            thumbnail: MessageEmbedMedia(url: MockChatFixture.demoAsset("guild-aurora"), width: 64, height: 64),
            provider: MessageEmbedProvider(name: "Aurora Studio", url: URL(string: "https://example.com")),
            author: MessageEmbedAuthor(name: "Maya Ortiz", url: URL(string: "https://example.com/maya"), iconURL: maya.avatarURL),
            fields: [
                MessageEmbedField(id: 1, name: "Inline field", value: "First column", isInline: true),
                MessageEmbedField(id: 2, name: "Inline field", value: "Second column", isInline: true),
                MessageEmbedField(id: 3, name: "Inline field", value: "Third column", isInline: true),
                MessageEmbedField(id: 4, name: "Full-width field", value: "A longer field with `inline code` and a line break.\nSecond line."),
            ]
        )
        let samples = [
            rich,
            MessageEmbed(id: "showcase-link", title: "Article preview", type: "link", description: "A link card with a thumbnail.", url: URL(string: "https://example.com/article"), thumbnail: image),
            MessageEmbed(id: "showcase-image", type: "image", image: image),
            MessageEmbed(id: "showcase-gif", type: "image", image: animation),
            MessageEmbed(id: "showcase-gifv", type: "gifv", video: video),
            MessageEmbed(id: "showcase-video", title: "Bundled video", type: "video", thumbnail: image, video: video),
            MessageEmbed(id: "showcase-article", title: "Article with a large image", type: "article", description: "A longer description under an article title.", image: image),
            MessageEmbed(id: "showcase-description", type: "rich", description: "An embed with **only a description**."),
            MessageEmbed(id: "showcase-fields", type: "rich", color: 0x57F287, fields: rich.fields),
        ]
        var result = [showcaseMessage(300, content: "# Embeds and link cards")]
        result += samples.enumerated().map { index, embed in
            showcaseMessage(UInt64(301 + index), author: index.isMultiple(of: 2) ? verifiedApp : nova) { $0.embeds = [embed] }
        }
        result += [
            showcaseMessage(315, content: "Text above multiple embeds.") { $0.embeds = [rich, samples[1]] },
            showcaseMessage(316, content: "https://example.com/suppressed-preview") {
                $0.flags = [.suppressEmbeds]
                $0.embeds = [rich]
            },
            showcaseMessage(317, content: "https://sakuracord.app/settings/appearance/messages"),
            showcaseMessage(318, author: nova, content: "https://sakuracord.app/update"),
            showcaseMessage(319, content: "https://discord.gg/offline-showcase"),
            showcaseMessage(320, content: "https://discord.com/channels/100/216/600101"),
            showcaseMessage(321, content: "https://discord.gg/offline-expired"),
            showcaseMessage(322, content: "https://sakuracord.app/report?type=bug"),
            showcaseMessage(323, content: "https://sakuracord.app/settings/themes/AQJKz_VpjwzNszNAALhRczO9cP__yjw"),
            showcaseMessage(324, content: "https://sakuracord.app/settings/diagnostics/send"),
            showcaseMessage(325, author: nova, content: "A link in a spoiler hides its card: ||https://example.com/article||") {
                $0.embeds = [samples[1]]
            },
        ]
        return result
    }
}
