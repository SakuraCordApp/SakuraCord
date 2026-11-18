import Foundation

// Plain values describing the demo world's content. They know nothing about
// snowflakes, wire shapes or the world model; the world builder converts them.
// Everything refers to other content by stable string keys: people by
// `DemoPerson.key`, roles by `DemoRole.key`, channels by `DemoChannel.key`
// (unique across guilds and direct channels), messages by `DemoMessage.label`
// (unique within their channel, thread or forum post).

// MARK: - Time

/// A wall-clock moment relative to the scenario epoch's day. Day 0 is the
/// epoch's day and earlier days are negative; the epoch itself is
/// `DemoContent.now`, and nothing in the history happens after it.
public struct DemoTime: Sendable, Hashable, Comparable {
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var second: Int

    public init(day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) {
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// Seconds since 00:00 on day 0 (negative for earlier days).
    public var secondsFromStartOfDayZero: Int { day * 86_400 + hour * 3_600 + minute * 60 + second }

    /// Seconds from `DemoContent.now`; negative in the past.
    public var secondsFromNow: Int { secondsFromStartOfDayZero - DemoContent.now.secondsFromStartOfDayZero }

    public func adding(minutes: Int) -> DemoTime {
        let total = secondsFromStartOfDayZero + minutes * 60
        let day = Int((Double(total) / 86_400).rounded(.down))
        let rest = total - day * 86_400
        return DemoTime(day: day, rest / 3_600, rest % 3_600 / 60, rest % 60)
    }

    public static func < (lhs: DemoTime, rhs: DemoTime) -> Bool {
        lhs.secondsFromStartOfDayZero < rhs.secondsFromStartOfDayZero
    }
}

// MARK: - People

public enum DemoPremium: Sendable, Hashable {
    case none, nitroBasic, nitro

    var premiumType: PremiumType {
        switch self {
        case .none: .none
        case .nitroBasic: .nitroBasic
        case .nitro: .nitro
        }
    }
}

public enum DemoStatus: String, Sendable, Hashable { case online, idle, dnd, offline }

public enum DemoActivity: Sendable, Hashable {
    case playing(String)
    case listening(song: String, artist: String, album: String)
    case watching(String)
    case competing(String)
}

public struct DemoPresence: Sendable, Hashable {
    public var status: DemoStatus
    public var customStatus: String?
    public var customStatusEmoji: String?
    public var activity: DemoActivity?

    public init(_ status: DemoStatus, custom: String? = nil, emoji: String? = nil, activity: DemoActivity? = nil) {
        self.status = status
        customStatus = custom
        customStatusEmoji = emoji
        self.activity = activity
    }
}

/// Inputs for a generated image: `MediaGenerator` turns the same style into the
/// same bytes. `animated` asks for a GIF instead of a still PNG.
public struct DemoImageStyle: Sendable, Hashable {
    public var seed: UInt64
    public var palette: Int
    public var animated: Bool
    /// The picture, for avatars and icons; nil leaves it to the seed.
    public var art: MediaGenerator.Art?

    public init(seed: UInt64, palette: Int, animated: Bool = false, art: MediaGenerator.Art? = nil) {
        self.seed = seed
        self.palette = palette
        self.animated = animated
        self.art = art
    }
}

public struct DemoPerson: Sendable, Hashable, Identifiable {
    public var key: String
    public var username: String
    public var displayName: String
    public var pronouns: String
    public var bio: String
    public var premium: DemoPremium
    public var presence: DemoPresence
    /// Nil for someone who never set one, who shows Discord's default avatar.
    public var avatar: DemoImageStyle?
    /// Profile banner image; Nitro only.
    public var banner: DemoImageStyle?
    public var bannerColor: UInt32
    public var accentColor: UInt32
    /// Nitro profile theme (primary, accent).
    public var themeColors: [UInt32]?
    public var isBot: Bool

    public var id: String { key }

    public init(
        key: String, username: String, displayName: String, pronouns: String = "", bio: String = "",
        premium: DemoPremium = .none, presence: DemoPresence, avatar: DemoImageStyle?,
        banner: DemoImageStyle? = nil, bannerColor: UInt32, accentColor: UInt32,
        themeColors: [UInt32]? = nil, isBot: Bool = false
    ) {
        self.key = key
        self.username = username
        self.displayName = displayName
        self.pronouns = pronouns
        self.bio = bio
        self.premium = premium
        self.presence = presence
        self.avatar = avatar
        self.banner = banner
        self.bannerColor = bannerColor
        self.accentColor = accentColor
        self.themeColors = themeColors
        self.isBot = isBot
    }
}

public enum DemoRelationshipKind: Sendable, Hashable { case friend, incomingRequest, outgoingRequest }

public struct DemoRelationship: Sendable, Hashable {
    public var person: String
    public var kind: DemoRelationshipKind
    public var nickname: String?
    public var since: DemoTime

    public init(_ person: String, _ kind: DemoRelationshipKind = .friend, nickname: String? = nil, since: DemoTime) {
        self.person = person
        self.kind = kind
        self.nickname = nickname
        self.since = since
    }
}

// MARK: - Guilds

public enum DemoPermissionPreset: Sendable, Hashable { case owner, admin, moderator, member, bot }

public enum DemoRoleManager: Sendable, Hashable {
    /// The integration role of the bot with this person key.
    case bot(String)
    /// The guild's "Server Booster" role.
    case premiumSubscriber
}

/// Roles are listed highest first; `@everyone` is implicit.
public struct DemoRole: Sendable, Hashable {
    public var key: String
    public var name: String
    public var color: UInt32
    public var hoist: Bool
    public var mentionable: Bool
    public var permissions: DemoPermissionPreset
    /// Unicode role icon (boost tier 2+).
    public var icon: String?
    public var managed: DemoRoleManager?

    public init(
        _ key: String, _ name: String, color: UInt32, hoist: Bool = false, mentionable: Bool = false,
        permissions: DemoPermissionPreset = .member, icon: String? = nil, managed: DemoRoleManager? = nil
    ) {
        self.key = key
        self.name = name
        self.color = color
        self.hoist = hoist
        self.mentionable = mentionable
        self.permissions = permissions
        self.icon = icon
        self.managed = managed
    }
}

public struct DemoMember: Sendable, Hashable {
    public var person: String
    public var nickname: String?
    public var roles: [String]
    public var joined: DemoTime
    public var boostingSince: DemoTime?

    public init(_ person: String, nickname: String? = nil, roles: [String] = [], joined: DemoTime, boostingSince: DemoTime? = nil) {
        self.person = person
        self.nickname = nickname
        self.roles = roles
        self.joined = joined
        self.boostingSince = boostingSince
    }
}

public struct DemoCustomEmoji: Sendable, Hashable {
    public var name: String
    public var motif: MediaGenerator.EmojiMotif
    public var seed: UInt64
    public var animated: Bool

    public init(_ name: String, _ motif: MediaGenerator.EmojiMotif, seed: UInt64, animated: Bool = false) {
        self.name = name
        self.motif = motif
        self.seed = seed
        self.animated = animated
    }
}

public enum DemoStickerFormat: Sendable, Hashable { case png, apng, lottie, gif }

/// Sticker names are unique across all guilds and `DemoContent.standardStickers`.
public struct DemoSticker: Sendable, Hashable {
    public var name: String
    public var description: String
    /// The related unicode emoji Discord stores as the sticker's tags.
    public var tags: String
    public var format: DemoStickerFormat
    public var media: DemoMediaRef

    public init(_ name: String, description: String, tags: String, format: DemoStickerFormat, media: DemoMediaRef) {
        self.name = name
        self.description = description
        self.tags = tags
        self.format = format
        self.media = media
    }
}

public struct DemoCategory: Sendable {
    public var key: String
    /// `nil` for channels that sit above every category.
    public var name: String?
    public var channels: [DemoChannel]

    public init(_ key: String, _ name: String?, _ channels: [DemoChannel]) {
        self.key = key
        self.name = name
        self.channels = channels
    }
}

public struct DemoGuild: Sendable {
    public var key: String
    public var name: String
    public var description: String
    public var icon: DemoImageStyle
    public var banner: DemoImageStyle?
    public var splash: DemoImageStyle?
    public var owner: String
    public var vanityCode: String?
    /// Total boosts; members may boost more than once.
    public var boostCount: Int
    public var roles: [DemoRole]
    public var members: [DemoMember]
    public var emojis: [DemoCustomEmoji]
    public var stickers: [DemoSticker]
    public var categories: [DemoCategory]
    public var systemChannel: String
    public var rulesChannel: String?
    public var afkChannel: String?

    public init(
        key: String, name: String, description: String, icon: DemoImageStyle, banner: DemoImageStyle? = nil,
        splash: DemoImageStyle? = nil, owner: String, vanityCode: String? = nil, boostCount: Int,
        roles: [DemoRole], members: [DemoMember], emojis: [DemoCustomEmoji], stickers: [DemoSticker],
        categories: [DemoCategory], systemChannel: String, rulesChannel: String? = nil, afkChannel: String? = nil
    ) {
        self.key = key
        self.name = name
        self.description = description
        self.icon = icon
        self.banner = banner
        self.splash = splash
        self.owner = owner
        self.vanityCode = vanityCode
        self.boostCount = boostCount
        self.roles = roles
        self.members = members
        self.emojis = emojis
        self.stickers = stickers
        self.categories = categories
        self.systemChannel = systemChannel
        self.rulesChannel = rulesChannel
        self.afkChannel = afkChannel
    }

    public var channels: [DemoChannel] { categories.flatMap(\.channels) }

    /// Discord's premium tier for `boostCount`.
    public var boostTier: Int {
        switch boostCount {
        case 14...: 3
        case 7...: 2
        case 2...: 1
        default: 0
        }
    }
}

// MARK: - Channels

public enum DemoChannelKind: Sendable, Hashable { case text, voice, announcement, forum, stage }

public struct DemoVoiceState: Sendable, Hashable {
    public var person: String
    public var muted: Bool
    public var deafened: Bool
    public var streaming: Bool
    public var camera: Bool

    public init(_ person: String, muted: Bool = false, deafened: Bool = false, streaming: Bool = false, camera: Bool = false) {
        self.person = person
        self.muted = muted
        self.deafened = deafened
        self.streaming = streaming
        self.camera = camera
    }
}

public struct DemoForumTag: Sendable, Hashable {
    public var name: String
    public var emoji: String?
    public var moderated: Bool

    public init(_ name: String, emoji: String? = nil, moderated: Bool = false) {
        self.name = name
        self.emoji = emoji
        self.moderated = moderated
    }
}

/// A forum post. Its first message is the starter and its author the poster.
public struct DemoForumPost: Sendable {
    public var title: String
    public var tags: [String]
    public var messages: [DemoMessage]
    public var pinned: Bool
    public var archived: Bool

    public init(_ title: String, tags: [String], pinned: Bool = false, archived: Bool = false, _ messages: [DemoMessage]) {
        self.title = title
        self.tags = tags
        self.messages = messages
        self.pinned = pinned
        self.archived = archived
    }
}

public struct DemoThread: Sendable {
    public var name: String
    public var messages: [DemoMessage]
    public var archived: Bool

    public init(_ name: String, archived: Bool = false, _ messages: [DemoMessage]) {
        self.name = name
        self.messages = messages
        self.archived = archived
    }
}

public struct DemoChannel: Sendable {
    public var key: String
    public var name: String
    public var kind: DemoChannelKind
    public var topic: String?
    public var slowmodeSeconds: Int
    public var nsfw: Bool
    public var messages: [DemoMessage]
    public var forumTags: [DemoForumTag]
    public var posts: [DemoForumPost]
    public var voiceStates: [DemoVoiceState]
    public var userLimit: Int
    /// Label of the first message the signed-in user hasn't read; `nil` when
    /// everything is read.
    public var unreadFrom: String?

    public init(
        _ key: String, _ name: String, kind: DemoChannelKind = .text, topic: String? = nil, slowmodeSeconds: Int = 0,
        forumTags: [DemoForumTag] = [], posts: [DemoForumPost] = [], voiceStates: [DemoVoiceState] = [],
        userLimit: Int = 0, unreadFrom: String? = nil, messages: [DemoMessage] = []
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.topic = topic
        self.slowmodeSeconds = slowmodeSeconds
        nsfw = false
        self.messages = messages
        self.forumTags = forumTags
        self.posts = posts
        self.voiceStates = voiceStates
        self.userLimit = userLimit
        self.unreadFrom = unreadFrom
    }
}

/// A DM (one recipient) or group DM. `recipients` excludes the signed-in user.
public struct DemoDirectChannel: Sendable {
    public var key: String
    public var recipients: [String]
    public var name: String?
    public var icon: DemoImageStyle?
    public var owner: String?
    public var unreadFrom: String?
    public var messages: [DemoMessage]

    public init(
        _ key: String, recipients: [String], name: String? = nil, icon: DemoImageStyle? = nil, owner: String? = nil,
        unreadFrom: String? = nil, messages: [DemoMessage]
    ) {
        self.key = key
        self.recipients = recipients
        self.name = name
        self.icon = icon
        self.owner = owner
        self.unreadFrom = unreadFrom
        self.messages = messages
    }

    public var isGroup: Bool { recipients.count > 1 || name != nil }
}

// MARK: - Messages

/// `":name:"` string literals are custom guild emoji; anything else is unicode.
public enum DemoEmojiRef: Sendable, Hashable, ExpressibleByStringLiteral {
    case unicode(String)
    case custom(String)

    public init(stringLiteral value: String) {
        if value.count > 2, value.hasPrefix(":"), value.hasSuffix(":") {
            self = .custom(String(value.dropFirst().dropLast()))
        } else {
            self = .unicode(value)
        }
    }
}

public struct DemoReaction: Sendable, Hashable {
    public var emoji: DemoEmojiRef
    public var users: [String]
    /// Super (burst) reactions; Nitro only.
    public var burstUsers: [String]

    public init(_ emoji: DemoEmojiRef, _ users: String..., burst: [String] = []) {
        self.emoji = emoji
        self.users = users
        burstUsers = burst
    }
}

public struct DemoMessageRef: Sendable, Hashable {
    public var channel: String
    public var label: String

    public init(_ channel: String, _ label: String) {
        self.channel = channel
        self.label = label
    }
}

/// Where an attachment's or embed's bytes come from.
public enum DemoMediaRef: Sendable, Hashable {
    /// `MediaGenerator.photoJPEG`.
    case photo(seed: UInt64, scene: MediaGenerator.PhotoScene)
    /// `MediaGenerator.animatedGIF`: drifting blobs, or a bouncing motif.
    case animation(seed: UInt64, motif: MediaGenerator.EmojiMotif? = nil)
    /// `MediaGenerator.stickerPNG`.
    case sticker(seed: UInt64, motif: MediaGenerator.EmojiMotif)
    /// A file in `Resources/Media`.
    case bundled(String)
}

public enum DemoAttachmentKind: Sendable, Hashable { case image, video, audio, voice, file }

public struct DemoAttachment: Sendable, Hashable {
    public var kind: DemoAttachmentKind
    public var filename: String
    public var contentType: String
    /// Nominal size; use the real byte count for generated media.
    public var size: Int
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var altText: String?
    public var spoiler: Bool
    public var media: DemoMediaRef

    public static func photo(
        _ filename: String, seed: UInt64, _ scene: MediaGenerator.PhotoScene, width: Int = 1_280, height: Int = 960,
        alt: String? = nil, spoiler: Bool = false
    ) -> DemoAttachment {
        DemoAttachment(
            kind: .image, filename: filename, contentType: "image/jpeg", size: width * height / 8, width: width,
            height: height, durationSeconds: nil, altText: alt, spoiler: spoiler, media: .photo(seed: seed, scene: scene)
        )
    }

    public static func gif(
        _ filename: String, seed: UInt64, motif: MediaGenerator.EmojiMotif? = nil, size: Int = 256, alt: String? = nil
    ) -> DemoAttachment {
        DemoAttachment(
            kind: .image, filename: filename, contentType: "image/gif", size: size * size, width: size, height: size,
            durationSeconds: nil, altText: alt, spoiler: false, media: .animation(seed: seed, motif: motif)
        )
    }

    /// The bundled two-second 320×180 clip.
    public static func video(_ filename: String, alt: String? = nil) -> DemoAttachment {
        DemoAttachment(
            kind: .video, filename: filename, contentType: "video/mp4", size: 3_410, width: 320, height: 180,
            durationSeconds: 2, altText: alt, spoiler: false, media: .bundled("benchmark-video.mp4")
        )
    }

    /// The bundled 6.2-second Opus clip as a voice message.
    public static let voiceMessage = DemoAttachment(
        kind: .voice, filename: "voice-message.ogg", contentType: "audio/ogg", size: 18_723, width: nil, height: nil,
        durationSeconds: 6.2, altText: nil, spoiler: false, media: .bundled("demo-voice-message.ogg")
    )

    /// The bundled Opus clip as a regular audio file.
    public static func audio(_ filename: String) -> DemoAttachment {
        DemoAttachment(
            kind: .audio, filename: filename, contentType: "audio/ogg", size: 18_723, width: nil, height: nil,
            durationSeconds: 6.2, altText: nil, spoiler: false, media: .bundled("demo-voice-message.ogg")
        )
    }

    public static func file(_ filename: String, bundled: String, contentType: String, size: Int) -> DemoAttachment {
        DemoAttachment(
            kind: .file, filename: filename, contentType: contentType, size: size, width: nil, height: nil,
            durationSeconds: nil, altText: nil, spoiler: false, media: .bundled(bundled)
        )
    }
}

public enum DemoEmbedKind: String, Sendable, Hashable { case rich, article, video, image, gifv, link }

public struct DemoEmbedMedia: Sendable, Hashable {
    public var media: DemoMediaRef
    public var width: Int
    public var height: Int

    public init(_ media: DemoMediaRef, width: Int, height: Int) {
        self.media = media
        self.width = width
        self.height = height
    }
}

public struct DemoEmbedField: Sendable, Hashable {
    public var name: String
    public var value: String
    public var inline: Bool

    public init(_ name: String, _ value: String, inline: Bool = true) {
        self.name = name
        self.value = value
        self.inline = inline
    }
}

public struct DemoEmbed: Sendable, Hashable {
    public var kind: DemoEmbedKind
    public var url: String?
    public var title: String?
    public var description: String?
    public var color: UInt32?
    public var provider: String?
    public var authorName: String?
    public var authorURL: String?
    /// Person whose avatar is the author icon.
    public var authorIcon: String?
    public var footer: String?
    /// Person whose avatar is the footer icon.
    public var footerIcon: String?
    public var fields: [DemoEmbedField]
    public var image: DemoEmbedMedia?
    public var thumbnail: DemoEmbedMedia?
    public var video: DemoEmbedMedia?
    public var timestamp: DemoTime?

    public init(
        _ kind: DemoEmbedKind, url: String? = nil, title: String? = nil, description: String? = nil,
        color: UInt32? = nil, provider: String? = nil, authorName: String? = nil, authorURL: String? = nil,
        authorIcon: String? = nil, footer: String? = nil, footerIcon: String? = nil, fields: [DemoEmbedField] = [],
        image: DemoEmbedMedia? = nil, thumbnail: DemoEmbedMedia? = nil, video: DemoEmbedMedia? = nil,
        timestamp: DemoTime? = nil
    ) {
        self.kind = kind
        self.url = url
        self.title = title
        self.description = description
        self.color = color
        self.provider = provider
        self.authorName = authorName
        self.authorURL = authorURL
        self.authorIcon = authorIcon
        self.footer = footer
        self.footerIcon = footerIcon
        self.fields = fields
        self.image = image
        self.thumbnail = thumbnail
        self.video = video
        self.timestamp = timestamp
    }
}

public struct DemoPollAnswer: Sendable, Hashable {
    public var text: String
    public var emoji: DemoEmojiRef?
    public var voters: [String]

    public init(_ text: String, emoji: DemoEmojiRef? = nil, voters: [String]) {
        self.text = text
        self.emoji = emoji
        self.voters = voters
    }
}

/// The poll expires `durationHours` after its message was sent.
public struct DemoPoll: Sendable, Hashable {
    public var question: String
    public var answers: [DemoPollAnswer]
    public var allowMultiselect: Bool
    public var durationHours: Int
    public var finalized: Bool

    public init(_ question: String, multiselect: Bool = false, hours: Int = 24, finalized: Bool = false, _ answers: [DemoPollAnswer]) {
        self.question = question
        self.answers = answers
        allowMultiselect = multiselect
        durationHours = hours
        self.finalized = finalized
    }
}

public enum DemoButtonStyle: Sendable, Hashable { case primary, secondary, success, danger, link }

public struct DemoSelectOption: Sendable, Hashable {
    public var label: String
    public var value: String
    public var description: String?
    public var emoji: DemoEmojiRef?

    public init(_ label: String, value: String, description: String? = nil, emoji: DemoEmojiRef? = nil) {
        self.label = label
        self.value = value
        self.description = description
        self.emoji = emoji
    }
}

public enum DemoComponent: Sendable, Hashable {
    /// A link button carries `url` and no custom ID.
    case button(label: String, style: DemoButtonStyle, emoji: DemoEmojiRef? = nil, customID: String? = nil, url: String? = nil, disabled: Bool = false)
    case select(customID: String, placeholder: String, options: [DemoSelectOption], minValues: Int = 1, maxValues: Int = 1)
}

public struct DemoActionRow: Sendable, Hashable {
    public var components: [DemoComponent]

    public init(_ components: [DemoComponent]) { self.components = components }
}

public enum DemoSystemKind: Sendable, Hashable {
    case memberJoin
    case boost
    case boostTier(Int)
    /// "X pinned a message": the label of the pinned message.
    case pinned(String)
    /// A thread started without a starter message; its name is the content and
    /// its messages are the message's `thread`.
    case threadCreated
    case recipientAdded(String)
    case recipientRemoved(String)
    case call(participants: [String], durationMinutes: Int?)
    case channelNameChanged(String)
    case channelIconChanged
    /// The label of the finished poll's message.
    case pollResult(String)
    case channelFollowAdded(String)
}

/// A slash command whose reply this message is.
public struct DemoInteraction: Sendable, Hashable {
    public var user: String
    public var command: String

    public init(_ user: String, _ command: String) {
        self.user = user
        self.command = command
    }
}

/// One message. `content` uses `DemoMarkup` placeholders for mentions,
/// custom emoji and timestamps.
public struct DemoMessage: Sendable {
    public var author: String
    public var at: DemoTime
    public var content: String
    public var label: String?
    public var replyTo: String?
    public var forward: DemoMessageRef?
    public var reactions: [DemoReaction]
    public var attachments: [DemoAttachment]
    public var embeds: [DemoEmbed]
    public var poll: DemoPoll?
    public var stickers: [String]
    public var components: [DemoActionRow]
    public var system: DemoSystemKind?
    public var interaction: DemoInteraction?
    public var pinned: Bool
    public var editedAfterMinutes: Int?
    public var thread: DemoThread?

    public init(
        _ author: String, _ at: DemoTime, _ content: String = "", label: String? = nil, replyTo: String? = nil,
        forward: DemoMessageRef? = nil, reactions: [DemoReaction] = [], attachments: [DemoAttachment] = [],
        embeds: [DemoEmbed] = [], poll: DemoPoll? = nil, stickers: [String] = [], components: [DemoActionRow] = [],
        system: DemoSystemKind? = nil, interaction: DemoInteraction? = nil, pinned: Bool = false,
        edited: Int? = nil, thread: DemoThread? = nil
    ) {
        self.author = author
        self.at = at
        self.content = content
        self.label = label
        self.replyTo = replyTo
        self.forward = forward
        self.reactions = reactions
        self.attachments = attachments
        self.embeds = embeds
        self.poll = poll
        self.stickers = stickers
        self.components = components
        self.system = system
        self.interaction = interaction
        self.pinned = pinned
        editedAfterMinutes = edited
        self.thread = thread
    }
}

// MARK: - Markup placeholders

/// Placeholders inside `DemoMessage.content` (and embed text) that the world
/// replaces with real Discord markup once it has assigned IDs:
///
/// - `<@key>` user mention, `<@&key>` role mention, `<#key>` channel mention
/// - `<:name:>` and `<a:name:>` custom emoji by guild emoji name
/// - `<t:DAY@HH:MM:STYLE>` timestamp, e.g. `<t:+2@19:00:F>`
/// - `<day:DAY:STYLE>` that day's weekday name: `l` "saturday", `L` "Saturday",
///   `s` "sat", `S` "Sat". Day 0 can be any weekday, so chat never names one literally.
///
/// `@everyone` and `@here` are written literally.
public enum DemoMarkup {
    public enum Token: Sendable, Hashable {
        case user(String)
        case role(String)
        case channel(String)
        case emoji(name: String, animated: Bool)
        case timestamp(DemoTime, style: String)
        case weekday(day: Int, style: Character)
    }

    /// Tokens in order of appearance.
    public static func tokens(in text: String) -> [Token] {
        segments(text).compactMap { segment in
            if case .token(let token) = segment { token } else { nil }
        }
    }

    /// `text` with every placeholder replaced; `id` returns the snowflake for a
    /// user, role, channel or emoji token, `unix` the seconds for a time.
    public static func resolve(_ text: String, id: (Token) -> String, unix: (DemoTime) -> Int) -> String {
        segments(text).map { segment in
            switch segment {
            case .text(let text): text
            case .token(let token):
                switch token {
                case .user: "<@\(id(token))>"
                case .role: "<@&\(id(token))>"
                case .channel: "<#\(id(token))>"
                case .emoji(let name, let animated): "<\(animated ? "a" : ""):\(name):\(id(token))>"
                case .timestamp(let time, let style): "<t:\(unix(time)):\(style)>"
                case .weekday(let day, let style): weekday(Date(timeIntervalSince1970: Double(unix(DemoTime(day: day, 12, 0)))), style: style)
                }
            }
        }.joined()
    }

    private static func weekday(_ date: Date, style: Character) -> String {
        let name = date.formatted(.dateTime.weekday(style.lowercased() == "s" ? .abbreviated : .wide).locale(Locale(identifier: "en_US_POSIX")))
        return style.isLowercase ? name.lowercased() : name
    }

    private enum Segment { case text(String), token(Token) }

    private static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var rest = text[...]
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">"),
                  let token = token(String(rest[rest.index(after: open) ..< close]))
            else {
                result.append(.text(String(rest[...open])))
                rest = rest[rest.index(after: open)...]
                continue
            }
            result.append(.text(String(rest[..<open])))
            result.append(.token(token))
            rest = rest[rest.index(after: close)...]
        }
        result.append(.text(String(rest)))
        return result
    }

    private static func token(_ body: String) -> Token? {
        let isKey: (Substring) -> Bool = { key in
            !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
                && !key.allSatisfy(\.isNumber)
        }
        if body.hasPrefix("@&") { return isKey(body.dropFirst(2)) ? .role(String(body.dropFirst(2))) : nil }
        if body.hasPrefix("@") { return isKey(body.dropFirst()) ? .user(String(body.dropFirst())) : nil }
        if body.hasPrefix("#") { return isKey(body.dropFirst()) ? .channel(String(body.dropFirst())) : nil }
        if body.hasPrefix("t:") { return timestamp(body.dropFirst(2)) }
        if body.hasPrefix("day:") { return weekday(body.dropFirst(4)) }
        for (prefix, animated) in [(":", false), ("a:", true)] where body.hasPrefix(prefix) && body.hasSuffix(":") {
            let name = body.dropFirst(prefix.count).dropLast()
            return isKey(name) && !name.contains(":") ? .emoji(name: String(name), animated: animated) : nil
        }
        return nil
    }

    private static func timestamp(_ body: Substring) -> Token? {
        let parts = body.split(separator: ":")
        guard parts.count == 3, let at = parts[0].firstIndex(of: "@"),
              let day = Int(parts[0][..<at]), let hour = Int(parts[0][parts[0].index(after: at)...]),
              let minute = Int(parts[1])
        else { return nil }
        return .timestamp(DemoTime(day: day, hour, minute), style: String(parts[2]))
    }

    private static func weekday(_ body: Substring) -> Token? {
        let parts = body.split(separator: ":")
        guard parts.count == 2, let day = Int(parts[0]), let style = parts[1].first, parts[1].count == 1, "lLsS".contains(style)
        else { return nil }
        return .weekday(day: day, style: style)
    }
}
