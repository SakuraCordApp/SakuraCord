import Foundation
import SakuraCordModels

struct MockChatFixture {
    fileprivate struct TimelineFixtureInput {
        let count: Int
        let now: Date
        let channelID: ChannelID
        let guildID: GuildID
        let users: [User]
        let mediaURL: URL?
        let animatedMediaURL: URL?
        let videoURL: URL?
        let lottieURL: URL?
        let includesAnimatedMedia: Bool
    }

    let currentUser: User
    let snapshot: BootstrapSnapshot
    let membersByGuild: [GuildID: [Member]]
    let emojisByGuild: [GuildID: [DiscordEmoji]]
    let messagesByChannel: [ChannelID: [Message]]
    let profilesByUser: [UserID: UserProfile]

    static func make(
        now: Date = .now,
        includesLongServerList: Bool = false,
        timelineMessageCount: Int? = nil,
        timelineIncludesAnimatedMedia: Bool = false
    ) -> Self {
        MockFixtureAssembly(
            now: now,
            includesLongServerList: includesLongServerList,
            timelineMessageCount: timelineMessageCount,
            timelineIncludesAnimatedMedia: timelineIncludesAnimatedMedia
        ).fixture
    }

    static func demoAsset(_ name: String) -> URL? {
        demoResource(name, extension: "png")
    }

    fileprivate static func demoResource(
        _ name: String,
        extension fileExtension: String
    ) -> URL? {
        Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "DemoAssets"
        ) ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    }

    private static let animatedDemoAssetURL: URL? = {
        let encoded =
            "R0lGODlhIAAgAPIHAAAAAFhl8lhl8lhl8lhl8lhl8lhl8v///"
            + "yH/C05FVFNDQVBFMi4wAwEAAAAh+QQJAAAAACwAAAAAIAAgAA"
            + "ADVwi63P4wykmrvTjrzbv/WyAMxiAEH1EYbGsUBEeQrjvE2lr"
            + "XhRbsQBRGANwJMrRia5BR7pDOZYYYNRwxv6oQo1P2NDPlTdZ1"
            + "wT4ikmkLarvf8Lh8Tt8kAAAh+QQJAAAAACwAAAAAIAAgAIIAAA"
            + "DtQkXtQkXtQkXtQkXtQkXtQkX///8DVwi63P4wykmrvTjrzbv"
            + "/4BMIgzEIwUcURusaBcER5fsOssbadqEFvGAKIwjyBJma0TXIL"
            + "HnJJzNTlBqQGKB1iNktfRraEjfzvmKfUenEDbnf8Lh8Tp8nAA"
            + "A7"
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sakuracord-animated-custom-emoji-fixture-v1.gif"
            )
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }()

    static func animatedDemoAsset() -> URL? {
        animatedDemoAssetURL
    }

    fileprivate static func makeTimelinePerformanceMessages(
        _ input: TimelineFixtureInput
    ) -> [Message] {
        guard input.count > 0, !input.users.isEmpty else { return [] }
        let start = input.now.addingTimeInterval(-Double(input.count) * 35)
        return (0 ..< input.count).map {
            timelinePerformanceMessage(input, index: $0, start: start)
        }
    }

    private static func timelinePerformanceMessage(
        _ input: TimelineFixtureInput,
        index: Int,
        start: Date
    ) -> Message {
        let id = MessageID(rawValue: 5_000_000 + UInt64(index))
        let author = input.users[index % input.users.count]
        let animatedMediaKind = input.includesAnimatedMedia ? index % 12 : -1
        let components = timelineComponents(index: index)
        return Message(
            id: id,
            channelID: input.channelID,
            author: author,
            content: timelineContent(
                index: index,
                animatedMediaKind: animatedMediaKind,
                animatedMediaURL: input.animatedMediaURL
            ),
            timestamp: start.addingTimeInterval(Double(index) * 35),
            replyTo: index > 0 && index.isMultiple(of: 43)
                ? MessageID(rawValue: id.rawValue - 1)
                : nil,
            attachments: timelineAttachments(
                index: index,
                mediaURL: input.mediaURL
            ),
            reactions: timelineReactions(index: index, users: input.users),
            flags: components.isEmpty ? [] : [.isComponentsV2],
            guildID: input.guildID,
            embeds: timelineEmbeds(
                index: index,
                count: input.count,
                animatedMediaKind: animatedMediaKind,
                videoURL: input.videoURL
            ),
            components: components,
            stickers: timelineStickers(
                index: index,
                animatedMediaKind: animatedMediaKind,
                lottieURL: input.lottieURL
            ),
            mentionedUsers: index % 8 == 4 ? [input.users[1]] : []
        )
    }

    private static func timelineContent(
        index: Int,
        animatedMediaKind: Int,
        animatedMediaURL: URL?
    ) -> String {
        if animatedMediaKind == 2 {
            return animatedMediaURL.map {
                "[Animated raster benchmark](\($0.absoluteString))"
            } ?? "Animated raster benchmark"
        }
        return switch index % 8 {
        case 0:
            "A compact timeline message \(index) keeps the common path representative."
        case 1:
            "Inline custom emoji <:aurora_glow:900000000000000101> and native emoji ✨ remain aligned with text."
        case 2:
            "**Markdown \(index)** includes [a link](https://example.com), `inline code`, and ~~strikethrough~~."
        case 3:
            "A deliberately longer message wraps across multiple lines so the benchmark exercises dynamic row heights without synthetic fixed-size cells. Pass \(index)."
        case 4:
            "Mention fixture <@2> and channel fixture <#211> keep attachment-backed tokens in the hot path."
        case 5:
            "First line for message \(index).\nSecond line exercises TextKit layout.\nThird line finishes the sample."
        case 6:
            "# Heading \(index)\nBody copy follows beneath the heading."
        default:
            "Reaction-heavy fixture \(index) 👍"
        }
    }

    private static func timelineReactions(
        index: Int,
        users: [User]
    ) -> [Reaction] {
        guard index.isMultiple(of: 13) else { return [] }
        return [
            Reaction(
                emoji: "✨",
                count: 4,
                reactors: users.prefix(4).map(ReactionReactor.init(user:))
            ),
            Reaction(emoji: "🔥", count: 2),
        ]
    }

    private static func timelineAttachments(
        index: Int,
        mediaURL: URL?
    ) -> [Attachment] {
        guard index.isMultiple(of: 97), let mediaURL else { return [] }
        return [
            Attachment(
                id: "timeline-\(index)",
                filename: "timeline-\(index).png",
                url: mediaURL,
                mediaType: "image/png",
                width: 720,
                height: 420,
                size: 120_000,
                description: "Offline timeline benchmark image \(index)",
                isSpoiler: index.isMultiple(of: 194)
            )
        ]
    }

    private static func timelineEmbeds(
        index: Int,
        count: Int,
        animatedMediaKind: Int,
        videoURL: URL?
    ) -> [MessageEmbed] {
        var embeds: [MessageEmbed] = index.isMultiple(of: 89)
            ? [
                MessageEmbed(
                    title: "Benchmark embed \(index)",
                    type: "rich",
                    description: "A fixture-backed embed preserves card layout while scrolling.",
                    color: 0x7C3AED,
                    fields: [
                        MessageEmbedField(
                            id: 1,
                            name: "Rows",
                            value: count.formatted(),
                            isInline: true
                        ),
                        MessageEmbedField(
                            id: 2,
                            name: "Mode",
                            value: "Offline",
                            isInline: true
                        ),
                    ]
                )
            ]
            : []
        if animatedMediaKind == 0, let videoURL {
            embeds.append(
                MessageEmbed(
                    title: "Animated video benchmark \(index)",
                    type: "gifv",
                    video: MessageEmbedMedia(
                        url: videoURL,
                        width: 320,
                        height: 180,
                        description: "A looping benchmark video.",
                        contentType: "video/mp4"
                    ),
                    provider: MessageEmbedProvider(
                        name: "Offline media performance fixture"
                    )
                )
            )
        }
        return embeds
    }

    private static func timelineStickers(
        index: Int,
        animatedMediaKind: Int,
        lottieURL: URL?
    ) -> [MessageSticker] {
        guard animatedMediaKind == 1, let lottieURL else { return [] }
        return [
            MessageSticker(
                id: "offline-lottie-\(index)",
                name: "Pulse",
                description: "Bundled Lottie sticker benchmark",
                tags: "pulse,benchmark",
                format: .lottie,
                assetURL: lottieURL
            )
        ]
    }

    private static func timelineComponents(index: Int) -> [MessageComponent] {
        guard index.isMultiple(of: 131) else { return [] }
        return [
            .container(
                id: "timeline-component-\(index)",
                accentColor: 0x5865F2,
                spoiler: index.isMultiple(of: 262),
                children: [
                    .textDisplay(
                        id: "timeline-text-\(index)",
                        content: "## Components V2 fixture \(index)"
                    ),
                    .separator(
                        id: "timeline-separator-\(index)",
                        divider: true,
                        spacing: 1
                    ),
                    .actionRow(
                        id: "timeline-actions-\(index)",
                        children: [
                            .button(
                                id: "timeline-button-\(index)",
                                style: .primary,
                                label: "Benchmark control",
                                emoji: EmojiReference(name: "⚡️"),
                                customID: "offline-timeline-\(index)",
                                url: nil,
                                skuID: nil,
                                disabled: false
                            )
                        ]
                    ),
                ]
            )
        ]
    }

    fileprivate static func message(
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

    fileprivate static func profile(
        for user: User,
        member: Member,
        guilds: [Guild],
        friends: [User]
    ) -> UserProfile {
        let details = switch user.id.rawValue {
        case 1:
            MockProfileDetails(
                bio: "Native-app engineer who likes quiet interfaces, fast launch times, and tea that was forgotten on the desk.",
                pronouns: "they/them", accent: 0x7C3AED, theme: [0x1E1B4B, 0x7C3AED], connection: "nova-labs"
            )
        case 2:
            MockProfileDetails(
                bio: "Product designer collecting delightful empty states and unusually specific keyboard shortcuts.",
                pronouns: "she/her", accent: 0xF97316, theme: [0x431407, 0xF97316], connection: "maya-orbit"
            )
        case 3:
            MockProfileDetails(
                bio: "Audio engineer, amateur field recordist, and persistent advocate for sensible buffer sizes.",
                pronouns: "he/him", accent: 0x0D9488, theme: [0x042F2E, 0x0D9488], connection: "theo-audio"
            )
        case 4:
            MockProfileDetails(
                bio: "QA engineer. Breaks layouts professionally and labels the reproduction steps recreationally.",
                pronouns: "she/they", accent: 0x2563EB, theme: [0x172554, 0x2563EB], connection: "juniper-tests"
            )
        case 6:
            MockProfileDetails(
                bio: "Illustrator who answers DMs with sketches. Shows up under the friend nickname you gave them.",
                pronouns: "he/him", accent: 0x0EA5E9, theme: [0x082F49, 0x0EA5E9], connection: "kai-sketches"
            )
        default:
            MockProfileDetails(
                bio: "Community moderator who writes kind guidelines and remembers where every useful thread lives.",
                pronouns: "they/them", accent: 0xC026D3, theme: [0x4A044E, 0xC026D3], connection: "rowan-vale"
            )
        }
        return UserProfile(
            user: user,
            displayName: member.user.displayName,
            avatarURL: user.avatarURL,
            bannerURL: guilds.first?.iconURL,
            accentHex: details.accent,
            themeHexes: details.theme,
            bio: details.bio,
            pronouns: details.pronouns,
            badges: [
                ProfileBadge(id: "active_developer", description: "Demo Contributor"),
                ProfileBadge(id: "nitro", description: "Color Enthusiast")
            ],
            mutualGuilds: guilds.map { MutualGuild(id: $0.id, name: $0.name, iconURL: $0.iconURL) },
            mutualFriends: Array(friends.prefix(3)),
            mutualFriendsCount: friends.count,
            roles: member.roles,
            connectedAccounts: [
                ConnectedAccount(
                    accountID: details.connection, type: "github", name: details.connection, isVerified: true
                )
            ],
            premiumSince: Calendar.current.date(byAdding: .year, value: -1, to: .now),
            legacyUsername: "\(user.username)#0001",
            customStatus: member.customStatus
        )
    }
}

private struct MockFixtureAssembly {
    let now: Date
    let includesLongServerList: Bool
    let timelineMessageCount: Int?
    let timelineIncludesAnimatedMedia: Bool

    var fixture: MockChatFixture {
        let auroraID = GuildID(rawValue: 100)
        let nativeLabID = GuildID(rawValue: 101)
        let startHereCategoryID = ChannelID(rawValue: 190)
        let communityCategoryID = ChannelID(rawValue: 191)
        let projectsCategoryID = ChannelID(rawValue: 192)
        let auroraVoiceCategoryID = ChannelID(rawValue: 193)
        let labCategoryID = ChannelID(rawValue: 290)
        let labVoiceCategoryID = ChannelID(rawValue: 291)
        let textPermissions: UInt64 = (1 << 0) | (1 << 10) | (1 << 11) | (1 << 15) | (1 << 16) | (1 << 20)
            | (1 << 34) | (1 << 38) | (1 << 51)
        let auroraIcon = demoAsset("guild-aurora")
        let nativeLabIcon = demoAsset("guild-native-lab")
        let animatedFixture = animatedDemoAsset()
        let videoFixture = demoResource("benchmark-video", extension: "mp4")
        let lottieFixture = demoResource("benchmark-lottie", extension: "json")
        let animatedFixtureLink = animatedFixture.map {
            "[Animated fixture](\($0.absoluteString))"
        } ?? "Animated fixture"

        let nova = User(
            id: UserID(rawValue: 1),
            username: "nova.chen",
            displayName: "Nova Chen",
            avatarURL: demoAsset("avatar-nova"),
            nameplate: Nameplate(label: "Aurora gradient", palette: "cobalt"),
            primaryGuild: PrimaryGuildIdentity(guildID: auroraID, tag: "AUR"),
            displayNameStyle: DisplayNameStyle(effectID: 2, colors: [0x67E8F9, 0xA78BFA]),
            premiumType: 2
        )
        let maya = User(
            id: UserID(rawValue: 2),
            username: "maya.orbit",
            displayName: "Maya Ortiz",
            avatarURL: demoAsset("avatar-maya"),
            primaryGuild: PrimaryGuildIdentity(guildID: auroraID, tag: "AUR")
        )
        let theo = User(
            id: UserID(rawValue: 3),
            username: "theo.audio",
            displayName: "Theo Park",
            avatarURL: demoAsset("avatar-theo")
        )
        let juniper = User(
            id: UserID(rawValue: 4),
            username: "juniper.qa",
            displayName: "Juniper Reed",
            avatarURL: demoAsset("avatar-juniper")
        )
        let rowan = User(
            id: UserID(rawValue: 5),
            username: "rowan.community",
            displayName: "Rowan Vale",
            avatarURL: demoAsset("avatar-rowan")
        )
        // A friend outside the demo servers whose friend nickname, "Kai 🌊",
        // replaces his name in private conversations.
        let kai = User(
            id: UserID(rawValue: 6),
            username: "kai.moreno",
            displayName: "Kai Moreno"
        )
        let friendNicknames = [kai.id: "Kai 🌊"]
        let verifiedApp = User(
            id: UserID(rawValue: 900_000_000_000_000_101),
            username: "verified",
            displayName: "Verified",
            isBot: true
        )

        let aurora = Guild(
            id: auroraID,
            name: "Aurora Studio",
            iconURL: auroraIcon,
            accentHex: 0x8B5CF6,
            unreadCount: 3,
            ownerID: maya.id,
            currentUserPermissions: textPermissions | (1 << 27),
            rulesChannelID: ChannelID(rawValue: 202)
        )
        let nativeLab = Guild(
            id: nativeLabID,
            name: "Mac Native Lab",
            iconURL: nativeLabIcon,
            accentHex: 0x35C7A8,
            currentUserPermissions: textPermissions
        )
        let emojisByGuild = [
            auroraID: [
                DiscordEmoji(
                    id: "900000000000000101",
                    name: "aurora_glow",
                    guildID: auroraID,
                    assetURL: demoAsset("guild-aurora")
                ),
                DiscordEmoji(
                    id: "900000000000000102",
                    name: "nova_wave",
                    guildID: auroraID,
                    assetURL: demoAsset("avatar-nova")
                ),
                DiscordEmoji(
                    id: "900000000000000103",
                    name: "bug_hunt",
                    guildID: auroraID,
                    assetURL: demoAsset("avatar-juniper")
                )
            ],
            nativeLabID: [
                DiscordEmoji(
                    id: "900000000000000201",
                    name: "native_mac",
                    guildID: nativeLabID,
                    assetURL: demoAsset("guild-native-lab")
                ),
                DiscordEmoji(
                    id: "900000000000000202",
                    name: "swift_spark",
                    guildID: nativeLabID,
                    assetURL: demoAsset("avatar-theo")
                ),
                DiscordEmoji(
                    id: "900000000000000203",
                    name: "animated_fixture",
                    isAnimated: true,
                    guildID: nativeLabID,
                    assetURL: animatedFixture
                )
            ]
        ]
        let longListGuilds =
            includesLongServerList
                ? (0 ..< 18).map { index in
            Guild(
                id: GuildID(rawValue: UInt64(1000 + index)),
                name: String(format: "Scroll Test %02d", index + 1),
                accentHex: [0xF97316, 0x22C55E, 0x3B82F6, 0xA855F7][index % 4],
                unreadCount: index.isMultiple(of: 5) ? index + 1 : 0,
                currentUserPermissions: textPermissions
            )
        } : []

        let forumTags = [
            ForumTag(id: ForumTagID(rawValue: 8_001), name: "Visual", emojiName: "🖌️"),
            ForumTag(id: ForumTagID(rawValue: 8_002), name: "Behaviour", emojiName: "🔧"),
            ForumTag(id: ForumTagID(rawValue: 8_003), name: "Critical", isModerated: true, emojiName: "❗"),
            ForumTag(id: ForumTagID(rawValue: 8_004), name: "Complete", isModerated: true, emojiName: "✅"),
            ForumTag(id: ForumTagID(rawValue: 8_005), name: "Open", emojiName: "🤔")
        ]
        var channels = [
            Channel(
                id: ChannelID(rawValue: 200), guildID: auroraID, name: "welcome", kind: .announcement,
                category: "START HERE", categoryID: startHereCategoryID,
                position: 0, categoryPosition: 0
            ),
            Channel(
                id: ChannelID(rawValue: 201), guildID: auroraID, name: "release-notes", kind: .announcement,
                category: "START HERE", categoryID: startHereCategoryID,
                position: 1, categoryPosition: 0
            ),
            Channel(
                id: ChannelID(rawValue: 202), guildID: auroraID, name: "guidelines", category: "START HERE",
                categoryID: startHereCategoryID, position: 2, categoryPosition: 0
            ),
            Channel(
                id: ChannelID(rawValue: 210), guildID: auroraID, name: "general",
                topic: "A relaxed place for the Aurora Studio community", category: "COMMUNITY",
                categoryID: communityCategoryID, position: 0, categoryPosition: 1,
                unreadCount: 3
            ),
            Channel(
                id: ChannelID(rawValue: 211), guildID: auroraID, name: "design-lab",
                topic: "Interface critique, prototypes, and visual experiments", category: "COMMUNITY",
                categoryID: communityCategoryID, position: 1, categoryPosition: 1
            ),
            Channel(
                id: ChannelID(rawValue: 212), guildID: auroraID, name: "swift-help",
                topic: "Friendly help for Swift and AppKit questions", category: "COMMUNITY",
                categoryID: communityCategoryID, position: 2, categoryPosition: 1
            ),
            Channel(
                id: ChannelID(rawValue: 213), guildID: auroraID, name: "empty-canvas",
                topic: "A quiet channel ready for its first message", category: "COMMUNITY",
                categoryID: communityCategoryID, position: 3, categoryPosition: 1
            ),
            Channel(
                id: ChannelID(rawValue: 214), guildID: auroraID, name: "read-only",
                topic: "Updates that members can read but not reply to", category: "COMMUNITY",
                categoryID: communityCategoryID, position: 4, categoryPosition: 1,
                permissionOverwrites: [
                    ChannelPermissionOverwrite(id: nova.id.description, type: 1, deny: 1 << 11)
                ]
            ),
            Channel(
                id: ChannelID(rawValue: 215), guildID: auroraID, name: "staff-vault",
                category: "COMMUNITY", categoryID: communityCategoryID,
                position: 5, categoryPosition: 1,
                permissionOverwrites: [
                    ChannelPermissionOverwrite(
                        id: RoleID(rawValue: 10).description,
                        type: 0,
                        allow: 1 << 10
                    ),
                    ChannelPermissionOverwrite(
                        id: RoleID(rawValue: 12).description,
                        type: 0,
                        allow: 1 << 10
                    ),
                    ChannelPermissionOverwrite(
                        id: maya.id.description,
                        type: 1,
                        allow: 1 << 10
                    ),
                    ChannelPermissionOverwrite(
                        id: nova.id.description,
                        type: 1,
                        deny: (1 << 10) | (1 << 16)
                    )
                ],
                lastMessageID: MessageID(
                    ClientNonce.make(now: now.addingTimeInterval(-3_900))
                ),
                lastPinTimestamp: now.addingTimeInterval(-8 * 24 * 60 * 60 - 2_400)
            ),
            Channel(
                id: ChannelID(rawValue: 220), guildID: auroraID, name: "feedback",
                topic: "Share one focused idea per post. Search for duplicates, choose the most relevant tags, and keep critique constructive.",
                kind: .forum,
                category: "PROJECTS", categoryID: projectsCategoryID,
                position: 0, categoryPosition: 2,
                flags: 1 << 4,
                availableTags: forumTags,
                defaultReaction: ForumDefaultReaction(emojiName: "👍"),
                defaultSortOrder: .latestActivity,
                defaultForumLayout: .list,
                defaultTagMatch: .matchSome,
                defaultAutoArchiveDuration: 4_320
            ),
            Channel(
                id: ChannelID(rawValue: 221), guildID: auroraID, name: "bug-reports",
                topic: "Describe the problem, expected result, and reproduction steps. Add screenshots when they help.",
                kind: .forum, category: "PROJECTS", categoryID: projectsCategoryID,
                position: 1, categoryPosition: 2,
                flags: 1 << 4,
                availableTags: forumTags,
                defaultReaction: ForumDefaultReaction(emojiName: "👍"),
                defaultSortOrder: .latestActivity,
                defaultForumLayout: .list,
                defaultTagMatch: .matchSome,
                defaultAutoArchiveDuration: 4_320
            ),
            Channel(
                id: ChannelID(rawValue: 230), guildID: auroraID, name: "Studio Lounge",
                topic: "Drop-in conversation and the messages shared alongside it", kind: .voice,
                category: "VOICE", categoryID: auroraVoiceCategoryID,
                position: 0, categoryPosition: 3
            ),
            Channel(
                id: ChannelID(rawValue: 300), guildID: nativeLabID, name: "native-apps",
                topic: "Shipping polished software with Apple frameworks", category: "LAB",
                categoryID: labCategoryID, position: 0, categoryPosition: 0
            ),
            Channel(
                id: ChannelID(rawValue: 301), guildID: nativeLabID, name: "showcase",
                topic: "Share screenshots and works in progress", category: "LAB",
                categoryID: labCategoryID, position: 1, categoryPosition: 0
            ),
            Channel(
                id: ChannelID(rawValue: 302), guildID: nativeLabID, name: "performance",
                topic: "Profiling, rendering, and energy use", category: "LAB",
                categoryID: labCategoryID, position: 2, categoryPosition: 0
            ),
            Channel(
                id: ChannelID(rawValue: 330), guildID: nativeLabID, name: "Coffee Room",
                topic: "A voice room with a persistent text chat", kind: .voice,
                category: "VOICE", categoryID: labVoiceCategoryID,
                position: 0, categoryPosition: 1
            ),
            Channel(
                id: ChannelID(rawValue: 400), guildID: nil, name: "Maya Ortiz", hasExplicitName: false,
                kind: .directMessage, recipients: [maya]
            ),
            Channel(
                id: ChannelID(rawValue: 402), guildID: nil, name: friendNicknames[kai.id] ?? kai.displayName,
                hasExplicitName: false, kind: .directMessage, recipients: [kai]
            ),
            Channel(
                id: ChannelID(rawValue: 401), guildID: nil, name: "Design crew",
                ownerID: nova.id,
                kind: .groupDirectMessage,
                recipients: [maya, theo, juniper]
            )
        ]
        channels.append(
            contentsOf: longListGuilds.enumerated().map { index, guild in
            Channel(
                id: ChannelID(rawValue: UInt64(2000 + index)),
                guildID: guild.id,
                name: "general",
                topic: "Synthetic channel for testing long demo server lists"
            )
            }
        )

        let designerRole = GuildRole(
            id: RoleID(rawValue: 10), name: "Design", position: 20, colorHex: 0xF472B6
        )
        let engineeringRole = GuildRole(
            id: RoleID(rawValue: 11), name: "Engineering", position: 18, colorHex: 0x67E8F9,
            iconURL: demoAsset("guild-native-lab")
        )
        let moderatorRole = GuildRole(
            id: RoleID(rawValue: 12), name: "Community", position: 16, colorHex: 0xFBBF24
        )
        let qualityRole = GuildRole(
            id: RoleID(rawValue: 13), name: "Quality", position: 14, colorHex: 0xA7F3D0
        )

        var guildMaya = maya
        guildMaya.displayName = "Maya • Orbit"
        let auroraMembers = [
            Member(
                user: nova,
                roleName: "Engineering",
                status: .online,
                rolePosition: 18,
                isRoleCategory: true,
                roles: [engineeringRole],
                activityText: "Polishing a macOS build",
                customStatus: "<:aurora_glow:900000000000000101> Tea, tabs, and tiny details — polishing one more build before dinner"
            ),
            Member(
                user: guildMaya,
                roleName: "Design",
                status: .online,
                rolePosition: 20,
                isRoleCategory: true,
                roles: [designerRole],
                globalDisplayName: maya.displayName,
                activityText: "Reviewing interaction states",
                customStatus: "Making the empty states less empty",
                isMobileOnly: true
            ),
            Member(
                user: theo,
                roleName: "Engineering",
                status: .idle,
                rolePosition: 18,
                isRoleCategory: true,
                roles: [engineeringRole],
                activityText: "Listening to a test mix",
                customStatus: "Making a playlist for the weekend",
                isListeningToMusic: true
            ),
            Member(
                user: juniper,
                roleName: "Quality",
                status: .online,
                rolePosition: 14,
                isRoleCategory: true,
                roles: [qualityRole],
                activityText: "<:bug_hunt:900000000000000103> Reproduced it twice, therefore science",
                customStatus: "<:bug_hunt:900000000000000103> Reproduced it twice, therefore science"
            ),
            Member(
                user: rowan,
                roleName: "Community",
                status: .offline,
                rolePosition: 16,
                isRoleCategory: true,
                roles: [moderatorRole]
            )
        ].map { member in
            var member = member
            member.joinedAt = now.addingTimeInterval(-86400)
            return member
        }
        let nativeLabMembers = [
            auroraMembers[0],
            auroraMembers[1],
            auroraMembers[2],
            auroraMembers[3]
        ]
        var membersByGuild = [auroraID: auroraMembers, nativeLabID: nativeLabMembers]
        for guild in longListGuilds {
            membersByGuild[guild.id] = [auroraMembers[0], auroraMembers[3]]
        }
        let guilds = [aurora, nativeLab] + longListGuilds
        let guildRailItems: [GuildRailItem]
        if includesLongServerList {
            guildRailItems = [
                .guild(auroraID),
                .folder(GuildFolder(
                    id: 7_001,
                    name: "Native Projects",
                    colorHex: 0x35C7A8,
                    guildIDs: [nativeLabID] + longListGuilds.prefix(4).map(\.id)
                )),
                .folder(GuildFolder(
                    id: 7_002,
                    name: "Communities",
                    colorHex: 0x8B5CF6,
                    guildIDs: longListGuilds.dropFirst(4).prefix(6).map(\.id)
                ))
            ] + longListGuilds.dropFirst(10).map { .guild($0.id) }
        } else {
            guildRailItems = guilds.map { .guild($0.id) }
        }
        let allUsers = [nova, maya, theo, juniper, rowan]
        var profiles = Dictionary(
            uniqueKeysWithValues: allUsers.map { user in
                let member = auroraMembers.first(where: { $0.id == user.id })!
                return (
                    user.id,
                    profile(
                        for: user,
                        member: member,
                        guilds: guilds,
                        friends: allUsers.filter { $0.id != user.id }
                    )
                )
            }
        )
        profiles[kai.id] = profile(
            for: kai, member: Member(user: kai, roleName: "Direct Message", status: .online),
            guilds: [], friends: [nova]
        )

        let base = now.addingTimeInterval(-2700)
        let layoutAttachment = demoAsset("demo-layout").map {
            Attachment(
                id: "demo-layout",
                filename: "aurora-layout-study.png",
                url: $0,
                mediaType: "image/png",
                width: 720,
                height: 420,
                size: 2800,
                description: "A synthetic layout study bundled with demo mode."
            )
        }
        let galleryAttachments: [Attachment] =
            layoutAttachment.map { attachment in
                (0 ..< 3).map { index in
                    Attachment(
                        id: "demo-gallery-\(index)", filename: "layout-\(index).png", url: attachment.url,
                        mediaType: "image/png", width: index == 0 ? 720 : 420, height: 420,
                        size: attachment.size, description: "Synthetic gallery tile \(index + 1) of 3."
                    )
                }
            } ?? []
        let spoilerAttachment = layoutAttachment.map {
            Attachment(
                id: "demo-spoiler",
                filename: "SPOILER-layout-study.png",
                url: $0.url,
                mediaType: "image/png",
                width: 720,
                height: 420,
                size: $0.size,
                description: "A bundled spoiler preview for offline parity testing.",
                isSpoiler: true
            )
        }
        let spoilerAnimatedAttachment = animatedDemoAsset().map {
            Attachment(
                id: "demo-spoiler-gif",
                filename: "SPOILER-animation.gif",
                url: $0,
                mediaType: "image/gif",
                width: 32,
                height: 32,
                size: 1_024,
                description: "A concealed animated offline fixture.",
                isSpoiler: true,
                isAnimated: true
            )
        }
        let spoilerVideoAttachment = layoutAttachment.map {
            Attachment(
                id: "demo-spoiler-video",
                filename: "SPOILER-preview.mp4",
                url: $0.url,
                mediaType: "video/mp4",
                width: 1_280,
                height: 720,
                size: 4_096,
                description: "A concealed video geometry fixture.",
                isSpoiler: true
            )
        }
        let spoilerFileAttachment = layoutAttachment.map {
            Attachment(
                id: "demo-spoiler-file",
                filename: "SPOILER-notes.txt",
                url: $0.url,
                mediaType: "text/plain",
                size: 512,
                description: "A concealed file interaction fixture.",
                isSpoiler: true
            )
        }
        let demoSticker = layoutAttachment.map {
            MessageSticker(
                id: "demo-sticker", name: "Native sparkle", description: "A bundled offline sticker",
                tags: "sparkle,native", format: .png, guildID: nativeLabID, assetURL: $0.url
            )
        }
        let lottieSticker = MessageSticker(
            id: "offline-lottie", name: "Pulse", description: "Bundled Lottie sticker fixture",
            tags: "pulse,benchmark", format: .lottie, assetURL: lottieFixture
        )
        let thread = MessageThreadSummary(
            id: ChannelID(rawValue: 901), guildID: nativeLabID, parentID: ChannelID(rawValue: 301),
            name: "Rich message feedback", messageCount: 2, memberCount: 3,
            lastMessageID: MessageID(rawValue: 9012)
        )
        var messages = MockMessageFixtureBuilder(
            auroraID: auroraID,
            nativeLabID: nativeLabID,
            base: base,
            now: now,
            nova: nova,
            maya: maya,
            theo: theo,
            juniper: juniper,
            rowan: rowan,
            verifiedApp: verifiedApp,
            layoutAttachment: layoutAttachment,
            galleryAttachments: galleryAttachments,
            spoilerAttachment: spoilerAttachment,
            spoilerAnimatedAttachment: spoilerAnimatedAttachment,
            spoilerVideoAttachment: spoilerVideoAttachment,
            spoilerFileAttachment: spoilerFileAttachment,
            demoSticker: demoSticker,
            lottieSticker: lottieSticker,
            animatedFixtureLink: animatedFixtureLink,
            videoFixture: videoFixture,
            thread: thread
        ).messages
        if let timelineMessageCount {
            messages[ChannelID(rawValue: 210)] = makeTimelinePerformanceMessages(.init(
                count: timelineMessageCount,
                now: now,
                channelID: ChannelID(rawValue: 210),
                guildID: auroraID,
                users: [nova, maya, theo, juniper, rowan],
                mediaURL: layoutAttachment?.url,
                animatedMediaURL: animatedFixture,
                videoURL: videoFixture,
                lottieURL: lottieFixture,
                includesAnimatedMedia: timelineIncludesAnimatedMedia
            ))
        }
        messages[ChannelID(rawValue: 402)] = [
            message(4021, 402, kai, "Sketched three icon ideas for the nickname dialog — sending them over.", base.addingTimeInterval(1240)),
            message(4022, 402, nova, "Love them. Right-click my name and give me a nickname too 😄", base.addingTimeInterval(1270)),
        ]
        for (index, guild) in longListGuilds.enumerated() {
            let channelID = ChannelID(rawValue: UInt64(2000 + index))
            messages[channelID] = [
                message(
                UInt64(6000 + index),
                channelID.rawValue,
                index.isMultiple(of: 2) ? nova : juniper,
                "This synthetic conversation belongs to **\(guild.name)** and exists only to exercise long-list scrolling.",
                base.addingTimeInterval(Double(1200 + index * 30))
                )
            ]
        }

        let snapshotChannels = channels.map { channel in
            var channel = channel
            channel.lastMessageID = messages[channel.id]?.last?.id ?? channel.lastMessageID
            return channel
        }
        let readStates = snapshotChannels.compactMap { channel -> ChannelReadState? in
            guard let latest = channel.lastMessageID else { return nil }
            switch channel.id.rawValue {
            case 210:
                return ChannelReadState(
                    channelID: channel.id,
                    lastAcknowledgedMessageID: MessageID(rawValue: latest.rawValue - 1),
                    mentionCount: 3
                )
            case 211, 300:
                return ChannelReadState(
                    channelID: channel.id,
                    lastAcknowledgedMessageID: MessageID(rawValue: latest.rawValue - 1)
                )
            default:
                return ChannelReadState(
                    channelID: channel.id,
                    lastAcknowledgedMessageID: latest
                )
            }
        }
        return MockChatFixture(
            currentUser: nova,
            snapshot: BootstrapSnapshot(
                currentUser: nova,
                friendUserIDs: [maya.id, kai.id, theo.id],
                relationshipNicknamesByUserID: friendNicknames,
                relationships: [
                    Relationship(id: maya.id, type: .friend, user: maya, since: base),
                    Relationship(id: kai.id, type: .friend, user: kai, nickname: friendNicknames[kai.id], since: base),
                    Relationship(id: theo.id, type: .friend, user: theo, since: base),
                    Relationship(id: juniper.id, type: .incomingRequest, user: juniper),
                    Relationship(id: rowan.id, type: .outgoingRequest, user: rowan),
                ],
                guilds: guilds,
                guildRailItems: guildRailItems,
                channels: snapshotChannels,
                members: auroraMembers,
                readStates: readStates,
                notificationSettings: [
                    GuildNotificationSettings(
                        guildID: auroraID,
                        messageNotifications: .onlyMentions
                    ),
                    GuildNotificationSettings(
                        guildID: nativeLabID,
                        messageNotifications: .allMessages
                    ),
                ]
            ),
            membersByGuild: membersByGuild,
            emojisByGuild: emojisByGuild,
            messagesByChannel: messages,
            profilesByUser: profiles
        )
    }

    private func demoAsset(_ name: String) -> URL? {
        MockChatFixture.demoAsset(name)
    }

    private func demoResource(_ name: String, extension fileExtension: String) -> URL? {
        MockChatFixture.demoResource(name, extension: fileExtension)
    }

    private func animatedDemoAsset() -> URL? {
        MockChatFixture.animatedDemoAsset()
    }

    private func makeTimelinePerformanceMessages(
        _ input: MockChatFixture.TimelineFixtureInput
    ) -> [Message] {
        MockChatFixture.makeTimelinePerformanceMessages(input)
    }

    private func message(
        _ id: UInt64,
        _ channelID: UInt64,
        _ author: User,
        _ content: String,
        _ timestamp: Date,
        reactions: [Reaction] = []
    ) -> Message {
        MockChatFixture.message(
            id,
            channelID,
            author,
            content,
            timestamp,
            reactions: reactions
        )
    }

    private func profile(
        for user: User,
        member: Member,
        guilds: [Guild],
        friends: [User]
    ) -> UserProfile {
        MockChatFixture.profile(
            for: user,
            member: member,
            guilds: guilds,
            friends: friends
        )
    }
}
