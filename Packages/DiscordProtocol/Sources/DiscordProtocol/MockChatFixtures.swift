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

    fileprivate static func demoAsset(_ name: String) -> URL? {
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

    fileprivate static func animatedDemoAsset() -> URL? {
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
            status: member.status,
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
        let textPermissions: UInt64 = (1 << 10) | (1 << 11) | (1 << 16) | (1 << 20)
            | (1 << 34) | (1 << 38)
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
            currentUserPermissions: textPermissions,
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
                category: "START HERE", position: 0
            ),
            Channel(
                id: ChannelID(rawValue: 201), guildID: auroraID, name: "release-notes", kind: .announcement,
                category: "START HERE", position: 1
            ),
            Channel(
                id: ChannelID(rawValue: 202), guildID: auroraID, name: "guidelines", category: "START HERE",
                position: 2
            ),
            Channel(
                id: ChannelID(rawValue: 210), guildID: auroraID, name: "general",
                topic: "A relaxed place for the Aurora Studio community", category: "COMMUNITY",
                position: 0, unreadCount: 3
            ),
            Channel(
                id: ChannelID(rawValue: 211), guildID: auroraID, name: "design-lab",
                topic: "Interface critique, prototypes, and visual experiments", category: "COMMUNITY",
                position: 1
            ),
            Channel(
                id: ChannelID(rawValue: 212), guildID: auroraID, name: "swift-help",
                topic: "Friendly help for Swift and AppKit questions", category: "COMMUNITY", position: 2
            ),
            Channel(
                id: ChannelID(rawValue: 213), guildID: auroraID, name: "empty-canvas",
                topic: "A quiet channel ready for its first message", category: "COMMUNITY", position: 3
            ),
            Channel(
                id: ChannelID(rawValue: 214), guildID: auroraID, name: "read-only",
                topic: "Updates that members can read but not reply to", category: "COMMUNITY", position: 4,
                permissionOverwrites: [
                    ChannelPermissionOverwrite(id: nova.id.description, type: 1, deny: 1 << 11)
                ]
            ),
            Channel(
                id: ChannelID(rawValue: 215), guildID: auroraID, name: "staff-vault",
                category: "COMMUNITY", position: 5,
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
                category: "PROJECTS", position: 0,
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
                kind: .forum, category: "PROJECTS", position: 1,
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
                category: "VOICE", position: 0
            ),
            Channel(
                id: ChannelID(rawValue: 300), guildID: nativeLabID, name: "native-apps",
                topic: "Shipping polished software with Apple frameworks", category: "LAB", position: 0
            ),
            Channel(
                id: ChannelID(rawValue: 301), guildID: nativeLabID, name: "showcase",
                topic: "Share screenshots and works in progress", category: "LAB", position: 1
            ),
            Channel(
                id: ChannelID(rawValue: 302), guildID: nativeLabID, name: "performance",
                topic: "Profiling, rendering, and energy use", category: "LAB", position: 2
            ),
            Channel(
                id: ChannelID(rawValue: 330), guildID: nativeLabID, name: "Coffee Room",
                topic: "A voice room with a persistent text chat", kind: .voice,
                category: "VOICE", position: 0
            ),
            Channel(
                id: ChannelID(rawValue: 400), guildID: nil, name: "Maya Ortiz", kind: .directMessage,
                recipients: [maya]
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
            id: RoleID(rawValue: 11), name: "Engineering", position: 18, colorHex: 0x67E8F9
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
                customStatus: "Making the empty states less empty"
            ),
            Member(
                user: theo,
                roleName: "Engineering",
                status: .idle,
                rolePosition: 18,
                isRoleCategory: true,
                roles: [engineeringRole],
                activityText: "Listening to a test mix"
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
        ]
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
        let profiles = Dictionary(
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

private struct MockMessageFixtureBuilder {
    let auroraID: GuildID
    let nativeLabID: GuildID
    let base: Date
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
                )
            ],
            ChannelID(rawValue: 211): [
                message(
                    2101, 211, maya,
                    "Design note: toolbar identity should answer “where am I?” without competing with the channel title.",
                    base.addingTimeInterval(520)
                ),
                message(
                    2102, 211, nova,
                    "I’m using the server mark first, then the channel control. Both stay readable when the window narrows.",
                    base.addingTimeInterval(590)
                ),
                message(
                    2103, 211, rowan,
                    "The placeholder also needs a proper accessibility label for unnamed servers.",
                    base.addingTimeInterval(690)
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

private struct MockProfileDetails {
    let bio: String
    let pronouns: String?
    let accent: UInt32
    let theme: [UInt32]
    let connection: String
}
