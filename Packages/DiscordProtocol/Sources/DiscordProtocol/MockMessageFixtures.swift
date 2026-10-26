import Foundation
import SakuraCordModels

struct MockMessageFixtureBuilder {
    let auroraID: GuildID
    let nativeLabID: GuildID
    let base: Date
    let now: Date
    let nova: User
    let maya: User
    let theo: User
    let juniper: User
    let rowan: User
    let verifiedApp: User
    let layoutAttachment: Attachment?
    let galleryAttachments: [Attachment]
    let spoilerAttachment: Attachment?
    let spoilerAnimatedAttachment: Attachment?
    let spoilerVideoAttachment: Attachment?
    let spoilerFileAttachment: Attachment?
    let demoSticker: MessageSticker?
    let lottieSticker: MessageSticker
    let animatedFixtureLink: String
    let videoFixture: URL?
    let thread: MessageThreadSummary

    var messages: [ChannelID: [Message]] {
        [
            ChannelID(rawValue: 216): messageShowcase(),
            ChannelID(rawValue: 902): showcaseThreadMessages(),
            ChannelID(rawValue: 200): [
                message(
                    1001, 200, rowan,
                    "Welcome to **Aurora Studio** — a fictional community bundled with SakuraCord's offline demo.",
                    base
                ),
                message(
                    1002, 200, maya,
                    "Everything here is synthetic: people, profiles, conversations, and artwork. Feel free to click around.",
                    base.addingTimeInterval(90)
                )
            ],
            ChannelID(rawValue: 201): [
                message(
                    1101, 201, nova,
                    "**Demo build 0.4**\n• compact multiline composer\n• local attachment previews\n• richer profile fixtures",
                    base.addingTimeInterval(180)
                )
            ],
            ChannelID(rawValue: 202): [
                message(
                    1201, 202, rowan,
                    "Be curious, give specific feedback, and remember that every profile in this demo is fictional.",
                    base.addingTimeInterval(240)
                )
            ],
            ChannelID(rawValue: 210): [
                message(
                    2001, 210, maya,
                    "I tried the new sidebar at three window widths. The compact state finally feels intentional.",
                    base.addingTimeInterval(420)
                ),
                message(
                    2002, 210, juniper,
                    "Nice. I also checked keyboard navigation — focus stays put when the member list opens.",
                    base.addingTimeInterval(485),
                    reactions: [
                        Reaction(
                            emoji: "😭", count: 2, didCurrentUserReact: true,
                            reactors: [ReactionReactor(user: nova), ReactionReactor(user: maya)]
                        ),
                        Reaction(
                            emoji: "<:aurora_glow:900000000000000101>", count: 3,
                            didCurrentUserReact: true,
                            reactors: [
                                ReactionReactor(user: nova), ReactionReactor(user: maya),
                                ReactionReactor(user: theo)
                            ]
                        ),
                        Reaction(
                            emoji: "😂", count: 1,
                            reactors: [ReactionReactor(user: rowan)]
                        ),
                        Reaction(
                            emoji: "🤔", count: 4,
                            reactors: [
                                ReactionReactor(user: maya), ReactionReactor(user: theo),
                                ReactionReactor(user: juniper)
                            ]
                        ),
                        Reaction(
                            emoji: "<:bug_hunt:900000000000000103>", count: 2,
                            didCurrentUserReact: true,
                            reactors: [ReactionReactor(user: nova), ReactionReactor(user: juniper)]
                        ),
                        Reaction(
                            emoji: "🔥", count: 9,
                            reactors: [
                                ReactionReactor(user: nova), ReactionReactor(user: maya),
                                ReactionReactor(user: theo), ReactionReactor(user: juniper),
                                ReactionReactor(user: rowan)
                            ]
                        ),
                        Reaction(
                            emoji: "🎉", count: 1,
                            reactors: [ReactionReactor(user: maya)]
                        )
                    ]
                ),
                message(
                    2003, 210, theo,
                    "The little server artwork makes a surprisingly big difference. No more mystery squares.",
                    base.addingTimeInterval(610)
                ),
                message(
                    2004, 210, nova,
                    "Agreed. I kept the fallback neutral so unnamed test servers still look deliberate.",
                    base.addingTimeInterval(665)
                ),
                message(
                    2005, 210, maya,
                    "Next pass: make the empty channel state feel as polished as the busy one?",
                    base.addingTimeInterval(840)
                ),
                message(
                    2006, 210, juniper, "Already added it to the fictional backlog ✨",
                    base.addingTimeInterval(900), reactions: [Reaction(emoji: "✨", count: 4)]
                ),
                Message(
                    id: MessageID(rawValue: 2007), channelID: ChannelID(rawValue: 210), author: nova,
                    content: "", timestamp: base.addingTimeInterval(960), type: .userJoin,
                    guildID: auroraID
                ),
                Message(
                    id: MessageID(rawValue: 2008), channelID: ChannelID(rawValue: 210), author: nova,
                    content: "", timestamp: base.addingTimeInterval(990), guildID: auroraID,
                    stickers: [lottieSticker]
                ),
                Message(
                    id: MessageID(rawValue: 2009), channelID: ChannelID(rawValue: 210), author: rowan,
                    content: "Welcome <@2> — take a look in <#211>.", timestamp: base.addingTimeInterval(1_040),
                    guildID: auroraID,
                    embeds: [
                        MessageEmbed(
                            title: "Mention regression fixture", type: "rich",
                            description: "❓ You selected **Other**. <@&10> will be there shortly to assist you!",
                            color: 0xF0B232
                        )
                    ],
                    mentionedUsers: [maya]
                ),
                message(
                    2010, 210, theo,
                    animatedFixtureLink,
                    base.addingTimeInterval(1_100)
                ),
                Message(
                    id: MessageID(rawValue: 2011), channelID: ChannelID(rawValue: 210), author: juniper,
                    content: "https://klipy.com/gifs/cat-bouncing-LhA", timestamp: base.addingTimeInterval(1_160),
                    guildID: auroraID,
                    embeds: [
                        MessageEmbed(
                            title: "Autoplay regression fixture", type: "gifv",
                            url: URL(string: "https://klipy.com/gifs/cat-bouncing-LhA"),
                            video: MessageEmbedMedia(
                                url: videoFixture,
                                width: 320, height: 180, description: "A looping sample video.",
                                contentType: "video/mp4"
                            ),
                            provider: MessageEmbedProvider(name: "Offline fixture")
                        )
                    ]
                ),
            ] + selectionFieldFixtureMessages(),
            ChannelID(rawValue: 211): [
                message(
                    2101, 211, maya,
                    "Design note: toolbar identity should answer “where am I?” without competing with the channel title.",
                    Calendar.current.date(byAdding: .day, value: -3, to: now)!
                ),
                message(
                    2102, 211, nova,
                    "I’m using the server mark first, then the channel control. Both stay readable when the window narrows.",
                    Calendar.current.date(byAdding: .day, value: -1, to: now)!
                ),
                message(
                    2103, 211, rowan,
                    "The placeholder also needs a proper accessibility label for unnamed servers.",
                    now
                )
            ],
            ChannelID(rawValue: 212): [
                message(
                    2201, 212, juniper,
                    "Does anyone have a clean pattern for sizing an `NSTextView` inside `NSViewRepresentable`?",
                    base.addingTimeInterval(600)
                ),
                message(
                    2202, 212, nova,
                    "Measure the layout manager with the proposed width, but clamp the usable width before laying out. Zero-width proposals can explode the height.",
                    base.addingTimeInterval(720)
                ),
                message(
                    2203, 212, theo,
                    "That explains a composer I once saw become approximately one kilometre tall.",
                    base.addingTimeInterval(780), reactions: [Reaction(emoji: "😅", count: 2)]
                )
            ],
            ChannelID(rawValue: 220): [
                message(
                    2301, 220, maya,
                    "**Suggestion:** keep demo data isolated from account caches so screenshots are repeatable.",
                    base.addingTimeInterval(500)
                ),
                message(
                    2302, 220, nova,
                    "Implemented with an in-memory demo database. Nothing carries between launches.",
                    base.addingTimeInterval(760)
                )
            ],
            ChannelID(rawValue: 221): [
                message(
                    2401, 221, juniper,
                    "**Resolved:** empty composer opened at maximum height after an initial zero-width layout pass.",
                    base.addingTimeInterval(560)
                ),
                Message(
                    id: MessageID(rawValue: 2402), channelID: ChannelID(rawValue: 221), author: nova,
                    content: "Offline retry fixture — this message is intentionally marked failed.",
                    timestamp: base.addingTimeInterval(620), nonce: "offline-retry-fixture",
                    outboxState: .failed, guildID: auroraID
                ),
                Message(
                    id: MessageID(rawValue: 2403), channelID: ChannelID(rawValue: 221), author: juniper,
                    content: "# **Markdown reply target** with [DiscordKit](https://example.com)",
                    timestamp: base.addingTimeInterval(680), guildID: auroraID
                ),
                Message(
                    id: MessageID(rawValue: 2404), channelID: ChannelID(rawValue: 221), author: nova,
                    content: "Markdown replies stay compact.", timestamp: base.addingTimeInterval(740),
                    replyTo: MessageID(rawValue: 2403), guildID: auroraID
                ),
                Message(
                    id: MessageID(rawValue: 2405), channelID: ChannelID(rawValue: 221), author: maya,
                    content: String(repeating: "Long reply targets should never overlap the message below. ", count: 8),
                    timestamp: base.addingTimeInterval(800), guildID: auroraID
                ),
                Message(
                    id: MessageID(rawValue: 2406), channelID: ChannelID(rawValue: 221), author: nova,
                    content: "The preview is constrained to one line.", timestamp: base.addingTimeInterval(860),
                    replyTo: MessageID(rawValue: 2405), guildID: auroraID
                )
            ],
            ChannelID(rawValue: 300): [
                message(
                    3001, 300, theo,
                    "Instruments found a 14% drop in idle rendering work after splitting the animated status row.",
                    base.addingTimeInterval(300)
                ),
                message(
                    3002, 300, nova,
                    "That lines up with the observation scopes. Small leaf views are doing their job.",
                    base.addingTimeInterval(390)
                ),
                message(
                    3003, 300, maya,
                    "And it still reads like ordinary SwiftUI instead of a framework inside a framework.",
                    base.addingTimeInterval(470)
                )
            ],
            ChannelID(rawValue: 301): [
                Message(
                    id: MessageID(rawValue: 3101),
                    channelID: ChannelID(rawValue: 301),
                    author: maya,
                    content: "A quick fictional layout study for the demo gallery.",
                    timestamp: base.addingTimeInterval(620),
                    attachments: layoutAttachment.map { [$0] } ?? [],
                    reactions: [Reaction(emoji: "🎨", count: 5)]
                ),
                Message(
                    id: MessageID(rawValue: 3102), channelID: ChannelID(rawValue: 301), author: nova,
                    content:
                    "Here is a **fixture-backed** gallery, embed, sticker, reply target, and thread. ✨",
                    timestamp: base.addingTimeInterval(680), attachments: galleryAttachments,
                    embeds: [
                        MessageEmbed(
                            title: "Server-provided link preview", type: "rich",
                            description:
                            "This preview uses ||decoded embed data|| and performs no speculative unfurl request.",
                            url: URL(string: "https://example.com"), color: 0x7C3AED,
                            footer: MessageEmbedFooter(
                                text: "Offline fixture",
                                iconURL: demoAsset("avatar-juniper")
                            ),
                            thumbnail: MessageEmbedMedia(
                                url: demoAsset("guild-native-lab"),
                                description: "Mac Native Lab mark"
                            ),
                            author: MessageEmbedAuthor(
                                name: "Aurora Studio",
                                iconURL: demoAsset("avatar-nova")
                            ),
                            fields: [
                                MessageEmbedField(id: 1, name: "Layout", value: "Hero plus stack", isInline: true),
                                MessageEmbedField(
                                    id: 2, name: "Accessibility", value: "Alt text included", isInline: true
                                )
                            ]
                        )
                    ],
                    stickers: demoSticker.map { [$0] } ?? [], thread: thread
                ),
                Message(
                    id: MessageID(rawValue: 3103), channelID: ChannelID(rawValue: 301), author: maya,
                    content: "",
                    timestamp: base.addingTimeInterval(740), flags: [.isComponentsV2],
                    components: [
                        .container(
                            id: "fixture-container", accentColor: 0x5865F2, spoiler: false,
                            children: [
                                .textDisplay(
                                    id: "fixture-text",
                                    content: "## How did you join the server?"
                                ),
                                .separator(id: "fixture-divider", divider: true, spacing: 1),
                                .actionRow(
                                    id: "fixture-reddit",
                                    children: [
                                        .button(
                                            id: "fixture-reddit-button", style: .success, label: "Reddit",
                                            emoji: EmojiReference(name: "🙂"),
                                            customID: "offline-reddit", url: nil, skuID: nil, disabled: false
                                        )
                                    ]
                                ),
                                .actionRow(
                                    id: "fixture-social",
                                    children: [
                                        .button(
                                            id: "fixture-social-button", style: .secondary,
                                            label: "Other social media", emoji: EmojiReference(name: "🌐"),
                                            customID: "offline-social", url: nil, skuID: nil, disabled: false
                                        )
                                    ]
                                ),
                                .actionRow(
                                    id: "fixture-friend",
                                    children: [
                                        .button(
                                            id: "fixture-friend-button", style: .primary,
                                            label: "A friend invited me", emoji: EmojiReference(name: "🧑‍🤝‍🧑"),
                                            customID: "offline-friend", url: nil, skuID: nil, disabled: false
                                        )
                                    ]
                                ),
                                .actionRow(
                                    id: "fixture-house",
                                    children: [
                                        .button(
                                            id: "fixture-house-button", style: .primary,
                                            label: "I was here before", emoji: EmojiReference(name: "🏠"),
                                            customID: "offline-house", url: nil, skuID: nil, disabled: false
                                        )
                                    ]
                                ),
                                .actionRow(
                                    id: "fixture-other",
                                    children: [
                                        .button(
                                            id: "fixture-other-button", style: .destructive, label: "Other",
                                            emoji: EmojiReference(name: "❓"), customID: "offline-other", url: nil,
                                            skuID: nil, disabled: false
                                        )
                                    ]
                                )
                            ]
                        )
                    ]
                ),
                Message(
                    id: MessageID(rawValue: 3104), channelID: ChannelID(rawValue: 301), author: rowan,
                    content: "", timestamp: base.addingTimeInterval(800), flags: [.isComponentsV2],
                    components: [
                        .container(
                            id: "fixture-response-container", accentColor: 0xF0B232, spoiler: false,
                            children: [
                                .textDisplay(
                                    id: "fixture-response-text",
                                    content:
                                        "❓ You selected **Other**. ||<@&10> will be there shortly to assist you!||"
                                ),
                                .separator(id: "fixture-response-divider", divider: true, spacing: 1),
                                .actionRow(
                                    id: "fixture-response-actions",
                                    children: [
                                        .button(
                                            id: "fixture-misclick", style: .secondary, label: "WAIT I MISCLICKED",
                                            emoji: nil, customID: "offline-misclick", url: nil, skuID: nil,
                                            disabled: false
                                        )
                                    ]
                                )
                            ]
                        )
                    ]
                ),
                Message(
                    id: MessageID(rawValue: 3105),
                    channelID: ChannelID(rawValue: 301),
                    author: juniper,
                    content: "",
                    timestamp: base.addingTimeInterval(860),
                    attachments: spoilerAttachment.map { [$0] } ?? [],
                    flags: [.isComponentsV2],
                    components: [
                        .container(
                            id: "fixture-spoiler-container",
                            accentColor: 0x7C3AED,
                            spoiler: true,
                            children: [
                                .textDisplay(
                                    id: "fixture-spoiler-text",
                                    content: "## Hidden component details"
                                ),
                                .thumbnail(
                                    id: "fixture-spoiler-thumbnail",
                                    media: ComponentMedia(
                                        url: layoutAttachment?.url,
                                        width: 720,
                                        height: 420,
                                        contentType: "image/png",
                                        description:
                                            "Nested spoiler thumbnail",
                                        isSpoiler: true
                                    )
                                ),
                                .mediaGallery(
                                    id: "fixture-spoiler-gallery",
                                    items: [
                                        ComponentGalleryItem(
                                            id: "fixture-spoiler-gallery-image",
                                            media: ComponentMedia(
                                                url: layoutAttachment?.url,
                                                width: 720,
                                                height: 420,
                                                contentType: "image/png",
                                                description:
                                                    "Nested concealed gallery image",
                                                isSpoiler: true
                                            )
                                        ),
                                        ComponentGalleryItem(
                                            id: "fixture-spoiler-gallery-animation",
                                            media: ComponentMedia(
                                                url: animatedDemoAsset(),
                                                width: 32,
                                                height: 32,
                                                contentType: "image/gif",
                                                description:
                                                    "Nested concealed gallery animation",
                                                isSpoiler: true
                                            )
                                        ),
                                    ]
                                ),
                            ]
                        ),
                    ]
                ),
                Message(
                    id: MessageID(rawValue: 3106),
                    channelID: ChannelID(rawValue: 301),
                    author: nova,
                    content:
                        "Independent image, GIF, video, file, and component gallery spoilers.",
                    timestamp: base.addingTimeInterval(920),
                    attachments:
                        [
                            spoilerAttachment,
                            spoilerAnimatedAttachment,
                            spoilerVideoAttachment,
                            spoilerFileAttachment,
                        ].compactMap { $0 },
                    flags: [.isComponentsV2],
                    components: [
                        .mediaGallery(
                            id: "fixture-independent-spoiler-gallery",
                            items: [
                                ComponentGalleryItem(
                                    id: "fixture-independent-spoiler-image",
                                    media: ComponentMedia(
                                        url: layoutAttachment?.url,
                                        width: 720,
                                        height: 420,
                                        contentType: "image/png",
                                        description:
                                            "Independent concealed gallery image",
                                        isSpoiler: true
                                    )
                                ),
                                ComponentGalleryItem(
                                    id: "fixture-independent-spoiler-gif",
                                    media: ComponentMedia(
                                        url: animatedDemoAsset(),
                                        width: 32,
                                        height: 32,
                                        contentType: "image/gif",
                                        description:
                                            "Independent concealed gallery animation",
                                        isSpoiler: true
                                    )
                                ),
                            ]
                        ),
                        .file(
                            id: "fixture-independent-spoiler-file",
                            media: ComponentMedia(
                                url: layoutAttachment?.url,
                                attachmentName: "SPOILER-notes.txt",
                                contentType: "text/plain",
                                description:
                                    "Independent concealed component file",
                                isSpoiler: true
                            )
                        ),
                    ]
                ),
                Message(
                    id: MessageID(rawValue: 3107),
                    channelID: ChannelID(rawValue: 301),
                    author: rowan,
                    content:
                        "Animated custom emoji <a:animated_fixture:900000000000000203> stays on the Core Text baseline.",
                    timestamp: base.addingTimeInterval(980),
                    reactions: [
                        Reaction(
                            emoji:
                                "<a:animated_fixture:900000000000000203>",
                            count: 2
                        )
                    ]
                ),
                Message(
                    id: MessageID(rawValue: 3108),
                    channelID: ChannelID(rawValue: 301),
                    author: verifiedApp,
                    content: "Only the invoking user can see this response.",
                    timestamp: base.addingTimeInterval(1_040),
                    type: .chatInputCommand,
                    flags: [.ephemeral],
                    applicationID: ApplicationID(
                        rawValue: 900_000_000_000_000_101
                    ),
                    interactionMetadata: MessageInteractionMetadata(
                        id: "offline-showcase-command",
                        type: 2,
                        name: "inspect",
                        user: nova,
                        applicationID: "900000000000000101"
                    ),
                    guildID: nativeLabID
                ),
                Message(
                    id: MessageID(rawValue: 3109),
                    channelID: ChannelID(rawValue: 301),
                    author: nova,
                    content: "",
                    timestamp: base.addingTimeInterval(1_100),
                    type: .channelPinnedMessage,
                    guildID: nativeLabID
                ),
                Message(
                    id: MessageID(rawValue: 3110),
                    channelID: ChannelID(rawValue: 301),
                    author: verifiedApp,
                    content: "Preparing the detailed timeline comparison…",
                    timestamp: base.addingTimeInterval(1_160),
                    type: .chatInputCommand,
                    flags: [.loading],
                    applicationID: ApplicationID(
                        rawValue: 900_000_000_000_000_101
                    ),
                    interactionMetadata: MessageInteractionMetadata(
                        id: "offline-showcase-deferred-command",
                        type: 2,
                        name: "compare",
                        user: nova,
                        applicationID: "900000000000000101"
                    ),
                    guildID: nativeLabID
                ),
                Message(
                    id: MessageID(rawValue: 3111),
                    channelID: ChannelID(rawValue: 301),
                    author: nova,
                    content: "This local fixture demonstrates the failed-send state.",
                    timestamp: base.addingTimeInterval(1_220),
                    outboxState: .failed,
                    guildID: nativeLabID
                ),
                Message(
                    id: MessageID(rawValue: 3199), channelID: ChannelID(rawValue: 301), author: nova,
                    content: "Hello",
                    timestamp: base.addingTimeInterval(1_240),
                    outboxState: .failed,
                    sendFailure: .autoModeration(explanation: "From server moderators: Please revise this message."),
                    guildID: nativeLabID
                ),
                Message(
                    id: MessageID(rawValue: 3112),
                    channelID: ChannelID(rawValue: 301),
                    author: nova,
                    content: """
                    Bold:
                    **Hello World**

                    Italic (Asterisks):
                    *Hello World*

                    Italic (Underscores):
                    _Hello World_

                    Underline:
                    __Hello World__

                    Strikethrough:
                    ~~Hello World~~

                    Spoiler:
                    ||Hello World||

                    Bold Italic Asterisks:
                    ***Hello World***

                    Bold Italic Underscores:
                    ___Hello World___

                    Bold Underline:
                    __**Hello World**__

                    Italic Underline:
                    __*Hello World*__

                    Bold Italic Underline:
                    __***Hello World***__

                    Strikethrough Underline:
                    ~~__Hello World__~~

                    Bold Strikethrough Underline:
                    ~~__**Hello World**__~~

                    Spoiler Bold Italic Underline:
                    ||__***Hello World***__||

                    Large Header (H1):
                    # Hello World

                    Medium Header (H2):
                    ## Hello World

                    Small Header (H3):
                    ### Hello World

                    Subtext:
                    -# Hello World

                    Single-line Block Quote:
                    > Hello World

                    Multi-line Block Quote:
                    > Line 1
                    Line 2
                    Line 3

                    Unordered List (Dash):
                    - Item 1
                    - Item 2

                    Unordered List (Asterisk):
                    * Item 1
                    * Item 2

                    Ordered List:
                    1. Item 1
                    2. Item 2

                    Inline Code:
                    `Hello World`

                    Multi-line Code Block:
                    ```
                    Hello World
                    Line 2
                    ```

                    Multi-line Code Block with Syntax Highlighting (JSON):
                    ```json
                    {
                      "user_id": 1365151121735290932,
                      "server_id": 1528177363563581662
                    }
                    ```

                    Multi-line Code Block with ANSI Colors:
                    ```
                    \u{001B}[31mRed Text\u{001B}[0m
                    \u{001B}[32mGreen Text\u{001B}[0m
                    \u{001B}[33mYellow Text\u{001B}[0m
                    \u{001B}[34mBlue Text\u{001B}[0m
                    \u{001B}[35mMagenta Text\u{001B}[0m
                    \u{001B}[36mCyan Text\u{001B}[0m
                    \u{001B}[1;31mBold Red Text\u{001B}[0m
                    ```
                    """,
                    timestamp: base.addingTimeInterval(1_280),
                    guildID: nativeLabID
                ),
                Message(
                    id: MessageID(rawValue: 3113),
                    channelID: ChannelID(rawValue: 301),
                    author: rowan,
                    content: "This reply intentionally mentions <@1>.",
                    timestamp: base.addingTimeInterval(1_340),
                    replyTo: MessageID(rawValue: 3112),
                    replyPreview: MessageReplyPreview(
                        messageID: MessageID(rawValue: 3112),
                        author: nova,
                        content: "Markdown parity fixture"
                    ),
                    guildID: nativeLabID,
                    mentionedUsers: [nova]
                ),
                Message(
                    id: MessageID(rawValue: 3114),
                    channelID: ChannelID(rawValue: 301),
                    author: theo,
                    content: "https://example.com/suppressed-preview",
                    timestamp: base.addingTimeInterval(1_400),
                    flags: [.suppressEmbeds],
                    guildID: nativeLabID,
                    embeds: [
                        MessageEmbed(
                            id: "suppressed-preview",
                            title: "This preview must remain hidden",
                            type: "rich",
                            description:
                                "Only the original source link should render.",
                            url: URL(
                                string:
                                    "https://example.com/suppressed-preview"
                            ),
                            color: 0x5865F2
                        )
                    ]
                )
            ],
            ChannelID(rawValue: 901): [
                message(
                    9011, 901, maya, "The parent timeline stays anchored while this pane is open.",
                    base.addingTimeInterval(700)
                ),
                message(
                    9012, 901, juniper,
                    "And closing it restores ||the member inspector||.",
                    base.addingTimeInterval(730)
                )
            ],
            ChannelID(rawValue: 302): [
                message(
                    3201, 302, juniper,
                    "Cold launch is stable across five runs. I’m moving on to resize stress tests.",
                    base.addingTimeInterval(700)
                ),
                message(
                    3202, 302, theo,
                    "Try rapid inspector toggles too; that used to reveal layout churn immediately.",
                    base.addingTimeInterval(790)
                )
            ],
            ChannelID(rawValue: 230): [
                message(
                    3301, 230, maya,
                    "I dropped the reference links here so they stay with the voice conversation.",
                    base.addingTimeInterval(820)
                ),
                message(
                    3302, 230, nova,
                    "Perfect — the voice room chat should remain available after everyone disconnects.",
                    base.addingTimeInterval(875)
                )
            ],
            ChannelID(rawValue: 330): [
                message(
                    3401, 330, theo,
                    "Coffee is ready. I also added the profiling notes we mentioned on the call.",
                    base.addingTimeInterval(835)
                ),
                message(
                    3402, 330, juniper,
                    "Found them. This side chat is much nicer than losing the context when the call ends.",
                    base.addingTimeInterval(900)
                )
            ],
            ChannelID(rawValue: 400): [
                message(
                    4001, 400, maya, "Hey! I left a layout study in #showcase when you have a minute.",
                    base.addingTimeInterval(980)
                ),
                message(
                    4002, 400, nova,
                    "Just saw it — the hierarchy is much clearer. I’ll try the tighter spacing.",
                    base.addingTimeInterval(1080)
                ),
                message(
                    4003, 400, maya,
                    "Perfect. No rush; this entire conversation is made of demo pixels anyway 🙂",
                    base.addingTimeInterval(1140)
                )
            ],
            ChannelID(rawValue: 401): [
                message(
                    4011, 401, maya,
                    "The group DM should use the same **native timeline** as every other conversation.",
                    base.addingTimeInterval(1160)
                ),
                message(
                    4012, 401, theo,
                    "I’m checking compact spacing, selection, and the shared media path here.",
                    base.addingTimeInterval(1190)
                ),
                message(
                    4013, 401, nova,
                    "Confirmed — only the surface header and recipient state are different.",
                    base.addingTimeInterval(1220)
                )
            ]
        ]
    }

    private func message(
        _ id: UInt64,
        _ channelID: UInt64,
        _ author: User,
        _ content: String,
        _ timestamp: Date,
        reactions: [Reaction] = []
    ) -> Message {
        Message(
            id: MessageID(rawValue: id),
            channelID: ChannelID(rawValue: channelID),
            author: author,
            content: content,
            timestamp: timestamp,
            reactions: reactions
        )
    }

    private func demoAsset(_ name: String) -> URL? {
        MockChatFixture.demoAsset(name)
    }

    private func animatedDemoAsset() -> URL? {
        MockChatFixture.animatedDemoAsset()
    }
}

struct MockProfileDetails {
    let bio: String
    let pronouns: String?
    let accent: UInt32
    let theme: [UInt32]
    let connection: String
}
