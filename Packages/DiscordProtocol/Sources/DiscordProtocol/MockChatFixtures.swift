import Foundation
import SakuraCordModels

struct MockChatFixture {
    let currentUser: User
    let snapshot: BootstrapSnapshot
    let membersByGuild: [GuildID: [Member]]
    let emojisByGuild: [GuildID: [DiscordEmoji]]
    let messagesByChannel: [ChannelID: [Message]]
    let profilesByUser: [UserID: UserProfile]

    static func make(now: Date = .now, includesLongServerList: Bool = false) -> Self {
        let auroraID = GuildID(rawValue: 100)
        let nativeLabID = GuildID(rawValue: 101)
        let textPermissions: UInt64 = (1 << 10) | (1 << 11) | (1 << 16) | (1 << 20)
            | (1 << 34) | (1 << 38)
        let auroraIcon = demoAsset("guild-aurora")
        let nativeLabIcon = demoAsset("guild-native-lab")

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
                    assetURL: demoAsset("avatar-rowan")
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
                customStatus: "Reproduced it twice, therefore science"
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
        let demoSticker = layoutAttachment.map {
            MessageSticker(
                id: "demo-sticker", name: "Native sparkle", description: "A bundled offline sticker",
                tags: "sparkle,native", format: .png, guildID: nativeLabID, assetURL: $0.url
            )
        }
        let lottieSticker = MessageSticker(
            id: "749054660769218631", name: "Wave", description: "Discord standard sticker fixture",
            tags: "wave,hello", format: .lottie
        )
        let thread = MessageThreadSummary(
            id: ChannelID(rawValue: 901), guildID: nativeLabID, parentID: ChannelID(rawValue: 301),
            name: "Rich message feedback", messageCount: 2, memberCount: 3,
            lastMessageID: MessageID(rawValue: 9012)
        )
        var messages: [ChannelID: [Message]] = [
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
                    "[mmLol](https://cdn.discordapp.com/emojis/216154654256398347.webp?size=96&quality=lossless)",
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
                                url: URL(
                                    string: "https://www.w3schools.com/html/mov_bbb.mp4"
                                ),
                                width: 1280, height: 720, description: "A looping sample video.",
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
                            "This preview uses decoded embed data and performs no speculative unfurl request.",
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
                                    content: "❓ You selected **Other**. <@&10> will be there shortly to assist you!"
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
                )
            ],
            ChannelID(rawValue: 901): [
                message(
                    9011, 901, maya, "The parent timeline stays anchored while this pane is open.",
                    base.addingTimeInterval(700)
                ),
                message(
                    9012, 901, juniper, "And closing it restores the member inspector.",
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
            ]
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

        return Self(
            currentUser: nova,
            snapshot: BootstrapSnapshot(
                currentUser: nova,
                guilds: guilds,
                guildRailItems: guildRailItems,
                channels: channels,
                members: auroraMembers
            ),
            membersByGuild: membersByGuild,
            emojisByGuild: emojisByGuild,
            messagesByChannel: messages,
            profilesByUser: profiles
        )
    }

    private static func demoAsset(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "DemoAssets")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
    }

    private static func message(
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

    private static func profile(
        for user: User,
        member: Member,
        guilds: [Guild],
        friends: [User]
    ) -> UserProfile {
        let details:
            (bio: String, pronouns: String?, accent: UInt32, theme: [UInt32], connection: String) =
                switch user.id.rawValue {
                case 1:
                    (
                "Native-app engineer who likes quiet interfaces, fast launch times, and tea that was forgotten on the desk.",
                "they/them", 0x7C3AED, [0x1E1B4B, 0x7C3AED], "nova-labs"
            )
                case 2:
                    (
                "Product designer collecting delightful empty states and unusually specific keyboard shortcuts.",
                "she/her", 0xF97316, [0x431407, 0xF97316], "maya-orbit"
            )
                case 3:
                    (
                "Audio engineer, amateur field recordist, and persistent advocate for sensible buffer sizes.",
                "he/him", 0x0D9488, [0x042F2E, 0x0D9488], "theo-audio"
            )
                case 4:
                    (
                "QA engineer. Breaks layouts professionally and labels the reproduction steps recreationally.",
                "she/they", 0x2563EB, [0x172554, 0x2563EB], "juniper-tests"
            )
                default:
                    (
                "Community moderator who writes kind guidelines and remembers where every useful thread lives.",
                "they/them", 0xC026D3, [0x4A044E, 0xC026D3], "rowan-vale"
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
