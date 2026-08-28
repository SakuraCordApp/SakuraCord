import Foundation

public struct MessageFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let crossposted = Self(rawValue: 1 << 0)
    public static let isCrosspost = Self(rawValue: 1 << 1)
    public static let suppressEmbeds = Self(rawValue: 1 << 2)
    public static let sourceMessageDeleted = Self(rawValue: 1 << 3)
    public static let urgent = Self(rawValue: 1 << 4)
    public static let hasThread = Self(rawValue: 1 << 5)
    public static let ephemeral = Self(rawValue: 1 << 6)
    public static let loading = Self(rawValue: 1 << 7)
    public static let failedToMentionRoles = Self(rawValue: 1 << 8)
    public static let guildFeedHidden = Self(rawValue: 1 << 9)
    public static let shouldShowNonDiscordLinkWarning = Self(rawValue: 1 << 10)
    public static let suppressNotifications = Self(rawValue: 1 << 12)
    public static let voiceMessage = Self(rawValue: 1 << 13)
    public static let forwarded = Self(rawValue: 1 << 14)
    public static let isComponentsV2 = Self(rawValue: 1 << 15)
    public static let isGuildOfficial = Self(rawValue: 1 << 19)

    /// Discord clears this exact whitelist before requiring that no flag bits
    /// remain. Despite appearances, these flags are permitted on a source.
    public static let forwardingAllowed: Self = [
        .crossposted,
        .isCrosspost,
        .suppressEmbeds,
        .urgent,
        .hasThread,
        .failedToMentionRoles,
        .guildFeedHidden,
        .shouldShowNonDiscordLinkWarning,
        .suppressNotifications,
        .voiceMessage,
        .forwarded,
        .isComponentsV2,
        .isGuildOfficial,
    ]
}

public struct DiscordMessageType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let `default` = Self(rawValue: 0)
    public static let recipientAdd = Self(rawValue: 1)
    public static let recipientRemove = Self(rawValue: 2)
    public static let call = Self(rawValue: 3)
    public static let channelNameChange = Self(rawValue: 4)
    public static let channelIconChange = Self(rawValue: 5)
    public static let channelPinnedMessage = Self(rawValue: 6)
    public static let userJoin = Self(rawValue: 7)
    public static let guildBoost = Self(rawValue: 8)
    public static let guildBoostTier1 = Self(rawValue: 9)
    public static let guildBoostTier2 = Self(rawValue: 10)
    public static let guildBoostTier3 = Self(rawValue: 11)
    public static let channelFollowAdd = Self(rawValue: 12)
    public static let threadCreated = Self(rawValue: 18)
    public static let reply = Self(rawValue: 19)
    public static let chatInputCommand = Self(rawValue: 20)
    public static let threadStarter = Self(rawValue: 21)
    public static let guildInviteReminder = Self(rawValue: 22)
    public static let contextMenuCommand = Self(rawValue: 23)
    public static let stageStart = Self(rawValue: 27)
    public static let stageEnd = Self(rawValue: 28)
    public static let stageSpeaker = Self(rawValue: 29)
    public static let stageTopic = Self(rawValue: 31)
    public static let premiumReferral = Self(rawValue: 35)

    /// Exact set used by Discord desktop's current `FORWARDABLE` policy.
    public var isForwardable: Bool {
        switch rawValue {
        case 0, 19, 20, 23, 35:
            true
        default:
            false
        }
    }

    public var hasGeneratedContent: Bool {
        switch rawValue {
        case 1 ... 12, 18, 22, 27 ... 31:
            true
        default:
            false
        }
    }
}

public struct AttachmentFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let clip = Self(rawValue: 1 << 0)
    public static let thumbnail = Self(rawValue: 1 << 1)
    public static let remix = Self(rawValue: 1 << 2)
    public static let spoiler = Self(rawValue: 1 << 3)
    public static let animated = Self(rawValue: 1 << 5)
}

public enum AttachmentMediaKind: String, Codable, Hashable, Sendable {
    case image, animatedImage, video, audio, file
}

public struct EmojiReference: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var isAnimated: Bool

    public init(id: String? = nil, name: String, isAnimated: Bool = false) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
    }

    public init(rawToken: String) {
        guard rawToken.first == "<", rawToken.last == ">" else {
            id = nil
            name = rawToken
            isAnimated = false
            return
        }

        let enclosed = rawToken.dropFirst().dropLast()
        let animated = enclosed.hasPrefix("a:")
        let payload = animated ? enclosed.dropFirst(2) : enclosed.dropFirst()
        guard animated || enclosed.first == ":",
              let separator = payload.firstIndex(of: ":"),
              separator != payload.startIndex
        else {
            id = nil
            name = rawToken
            isAnimated = false
            return
        }

        let emojiName = payload[..<separator]
        let emojiID = payload[payload.index(after: separator)...]
        guard !emojiID.isEmpty,
              !emojiName.contains(":"),
              emojiID.unicodeScalars.allSatisfy({ (48 ... 57).contains($0.value) })
        else {
            id = nil
            name = rawToken
            isAnimated = false
            return
        }

        id = String(emojiID)
        name = String(emojiName)
        isAnimated = animated
    }

    public var rawToken: String {
        guard let id else { return name }
        return "<\(isAnimated ? "a" : ""):\(name):\(id)>"
    }

    public var accessibilityLabel: String {
        ":\(name):"
    }

    public func imageURL(size: Int = 64) -> URL? {
        guard let id else { return nil }
        var components = URLComponents(
            string: "https://cdn.discordapp.com/emojis/\(id).\(isAnimated ? "gif" : "png")"
        )
        components?.queryItems = [
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "quality", value: "lossless")
        ]
        return components?.url
    }
}

public struct MessageEmbedMedia: Codable, Hashable, Sendable {
    public var url: URL?
    public var proxyURL: URL?
    public var width: Int?
    public var height: Int?
    public var description: String?
    public var contentType: String?
    public var placeholder: String?
    public var placeholderVersion: Int?
    public var flags: UInt64

    public init(
        url: URL? = nil, proxyURL: URL? = nil, width: Int? = nil, height: Int? = nil,
        description: String? = nil, contentType: String? = nil, placeholder: String? = nil,
        placeholderVersion: Int? = nil, flags: UInt64 = 0
    ) {
        self.url = url
        self.proxyURL = proxyURL
        self.width = width
        self.height = height
        self.description = description
        self.contentType = contentType
        self.placeholder = placeholder
        self.placeholderVersion = placeholderVersion
        self.flags = flags
    }
}

public struct MessageEmbedAuthor: Codable, Hashable, Sendable {
    public var name: String
    public var url: URL?
    public var iconURL: URL?
    public var proxyIconURL: URL?

    public init(name: String, url: URL? = nil, iconURL: URL? = nil, proxyIconURL: URL? = nil) {
        self.name = name
        self.url = url
        self.iconURL = iconURL
        self.proxyIconURL = proxyIconURL
    }
}

public struct MessageEmbedProvider: Codable, Hashable, Sendable {
    public var name: String?
    public var url: URL?
    public init(name: String? = nil, url: URL? = nil) {
        self.name = name
        self.url = url
    }
}

public struct MessageEmbedFooter: Codable, Hashable, Sendable {
    public var text: String
    public var iconURL: URL?
    public var proxyIconURL: URL?
    public init(text: String, iconURL: URL? = nil, proxyIconURL: URL? = nil) {
        self.text = text
        self.iconURL = iconURL
        self.proxyIconURL = proxyIconURL
    }
}

public struct MessageEmbedField: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var value: String
    public var isInline: Bool
    public init(id: Int = 0, name: String, value: String, isInline: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
        self.isInline = isInline
    }
}

public struct MessageEmbed: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var type: String?
    public var description: String?
    public var url: URL?
    public var timestamp: Date?
    public var color: UInt32?
    public var footer: MessageEmbedFooter?
    public var image: MessageEmbedMedia?
    public var thumbnail: MessageEmbedMedia?
    public var video: MessageEmbedMedia?
    public var provider: MessageEmbedProvider?
    public var author: MessageEmbedAuthor?
    public var fields: [MessageEmbedField]

    public init(
        id: String = UUID().uuidString, title: String? = nil, type: String? = nil,
        description: String? = nil, url: URL? = nil, timestamp: Date? = nil, color: UInt32? = nil,
        footer: MessageEmbedFooter? = nil, image: MessageEmbedMedia? = nil,
        thumbnail: MessageEmbedMedia? = nil, video: MessageEmbedMedia? = nil,
        provider: MessageEmbedProvider? = nil, author: MessageEmbedAuthor? = nil,
        fields: [MessageEmbedField] = []
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.description = description
        self.url = url
        self.timestamp = timestamp
        self.color = color
        self.footer = footer
        self.image = image
        self.thumbnail = thumbnail
        self.video = video
        self.provider = provider
        self.author = author
        self.fields = fields
    }
}

public enum StickerFormat: Int, Codable, Hashable, Sendable {
    case png = 1
    case apng = 2
    case lottie = 3
    case gif = 4
}

public struct MessageSticker: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var tags: String?
    public var format: StickerFormat?
    public var guildID: GuildID?
    public var isAvailable: Bool
    public var assetURL: URL?

    public init(
        id: String, name: String, description: String? = nil, tags: String? = nil,
        format: StickerFormat? = nil, guildID: GuildID? = nil, isAvailable: Bool = true,
        assetURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
        self.format = format
        self.guildID = guildID
        self.isAvailable = isAvailable
        self.assetURL = assetURL
    }

    public var mediaURL: URL? {
        if let assetURL {
            return assetURL
        }
        guard format != .lottie else {
            return URL(string: "https://cdn.discordapp.com/stickers/\(id).json")
        }
        return URL(
            string: "https://\(format == .gif ? "media.discordapp.net" : "cdn.discordapp.com")/stickers/\(id).\(format == .gif ? "gif" : "png")"
        )
    }
}

public struct MessageThreadSummary: Codable, Hashable, Sendable {
    public var id: ChannelID
    public var guildID: GuildID?
    public var parentID: ChannelID?
    public var name: String
    public var messageCount: Int
    public var memberCount: Int
    public var lastMessageID: MessageID?
    public var isArchived: Bool
    public var isLocked: Bool
    public var ownerID: UserID?
    public var appliedTagIDs: [ForumTagID]
    public var flags: UInt64
    public var archiveTimestamp: Date?
    public var createdAt: Date?
    public var autoArchiveDuration: Int?
    public var totalMessageSent: Int
    public var notificationSettings: ThreadNotificationSettings?

    public init(
        id: ChannelID, guildID: GuildID? = nil, parentID: ChannelID? = nil, name: String,
        messageCount: Int = 0, memberCount: Int = 0, lastMessageID: MessageID? = nil,
        isArchived: Bool = false, isLocked: Bool = false,
        ownerID: UserID? = nil, appliedTagIDs: [ForumTagID] = [], flags: UInt64 = 0,
        archiveTimestamp: Date? = nil, createdAt: Date? = nil,
        autoArchiveDuration: Int? = nil, totalMessageSent: Int = 0,
        notificationSettings: ThreadNotificationSettings? = nil
    ) {
        self.id = id
        self.guildID = guildID
        self.parentID = parentID
        self.name = name
        self.messageCount = messageCount
        self.memberCount = memberCount
        self.lastMessageID = lastMessageID
        self.isArchived = isArchived
        self.isLocked = isLocked
        self.ownerID = ownerID
        self.appliedTagIDs = appliedTagIDs
        self.flags = flags
        self.archiveTimestamp = archiveTimestamp
        self.createdAt = createdAt
        self.autoArchiveDuration = autoArchiveDuration
        self.totalMessageSent = totalMessageSent
        self.notificationSettings = notificationSettings
    }

    public var isPinned: Bool { flags & (1 << 1) != 0 }

    private enum CodingKeys: String, CodingKey {
        case id, guildID, parentID, name, messageCount, memberCount, lastMessageID
        case isArchived, isLocked, ownerID, appliedTagIDs, flags, archiveTimestamp
        case createdAt, autoArchiveDuration, totalMessageSent
        case notificationSettings
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ChannelID.self, forKey: .id)
        guildID = try values.decodeIfPresent(GuildID.self, forKey: .guildID)
        parentID = try values.decodeIfPresent(ChannelID.self, forKey: .parentID)
        name = try values.decode(String.self, forKey: .name)
        messageCount = try values.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        memberCount = try values.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        lastMessageID = try values.decodeIfPresent(MessageID.self, forKey: .lastMessageID)
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        ownerID = try values.decodeIfPresent(UserID.self, forKey: .ownerID)
        appliedTagIDs = try values.decodeIfPresent([ForumTagID].self, forKey: .appliedTagIDs) ?? []
        flags = try values.decodeIfPresent(UInt64.self, forKey: .flags) ?? 0
        archiveTimestamp = try values.decodeIfPresent(Date.self, forKey: .archiveTimestamp)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
        autoArchiveDuration = try values.decodeIfPresent(Int.self, forKey: .autoArchiveDuration)
        totalMessageSent = try values.decodeIfPresent(Int.self, forKey: .totalMessageSent) ?? 0
        notificationSettings = try values.decodeIfPresent(
            ThreadNotificationSettings.self,
            forKey: .notificationSettings
        )
    }
}

public struct ComponentEmoji: Codable, Hashable, Sendable {
    public var reference: EmojiReference
    public init(reference: EmojiReference) {
        self.reference = reference
    }
}

public enum ComponentButtonStyle: Int, Codable, Hashable, Sendable {
    case primary = 1
    case secondary = 2
    case success = 3
    case destructive = 4
    case link = 5
    case premium = 6
}

public enum ComponentSelectKind: Int, Codable, Hashable, Sendable {
    case string = 3
    case user = 5
    case role = 6
    case mentionable = 7
    case channel = 8
}

public enum ComponentSelectOptionImageShape: String, Codable, Hashable, Sendable {
    case circle
    case roundedRectangle
}

public enum ComponentSelectOptionEntityKind: String, Codable, Hashable, Sendable {
    case user
    case role
    case channel
}

public struct ComponentSelectOption: Identifiable, Codable, Hashable, Sendable {
    public var id: String {
        value
    }

    public var label: String
    public var value: String
    public var description: String?
    public var emoji: EmojiReference?
    public var imageURL: URL?
    public var imageShape: ComponentSelectOptionImageShape?
    public var entityKind: ComponentSelectOptionEntityKind?
    public var channelKind: ChannelKindValue?
    public var colorHex: UInt32?
    public var unicodeEmoji: String?
    public var isDefault: Bool
    public init(
        label: String, value: String, description: String? = nil, emoji: EmojiReference? = nil,
        imageURL: URL? = nil,
        imageShape: ComponentSelectOptionImageShape? = nil,
        entityKind: ComponentSelectOptionEntityKind? = nil,
        channelKind: ChannelKindValue? = nil,
        colorHex: UInt32? = nil,
        unicodeEmoji: String? = nil,
        isDefault: Bool = false
    ) {
        self.label = label
        self.value = value
        self.description = description
        self.emoji = emoji
        self.imageURL = imageURL
        self.imageShape = imageShape
        self.entityKind = entityKind
        self.channelKind = channelKind
        self.colorHex = colorHex
        self.unicodeEmoji = unicodeEmoji
        self.isDefault = isDefault
    }
}

public struct ComponentMedia: Codable, Hashable, Sendable {
    public var url: URL?
    public var proxyURL: URL?
    public var attachmentName: String?
    public var width: Int?
    public var height: Int?
    public var contentType: String?
    public var placeholder: String?
    public var placeholderVersion: Int?
    public var flags: UInt64?
    public var description: String?
    public var isSpoiler: Bool
    public init(
        url: URL? = nil, proxyURL: URL? = nil, attachmentName: String? = nil,
        width: Int? = nil, height: Int? = nil, contentType: String? = nil,
        placeholder: String? = nil, placeholderVersion: Int? = nil, flags: UInt64? = nil,
        description: String? = nil, isSpoiler: Bool = false
    ) {
        self.url = url
        self.proxyURL = proxyURL
        self.attachmentName = attachmentName
        self.width = width
        self.height = height
        self.contentType = contentType
        self.placeholder = placeholder
        self.placeholderVersion = placeholderVersion
        self.flags = flags
        self.description = description
        self.isSpoiler = isSpoiler
    }
}

public struct ComponentGalleryItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var media: ComponentMedia
    public init(id: String = UUID().uuidString, media: ComponentMedia) {
        self.id = id
        self.media = media
    }
}

public indirect enum MessageComponent: Identifiable, Codable, Hashable, Sendable {
    case actionRow(id: String, children: [MessageComponent])
    case button(
        id: String, style: ComponentButtonStyle?, label: String?, emoji: EmojiReference?,
        customID: String?, url: URL?, skuID: String?, disabled: Bool
    )
    case select(
        id: String, kind: ComponentSelectKind, customID: String, placeholder: String?, minValues: Int,
        maxValues: Int, disabled: Bool, options: [ComponentSelectOption], channelTypes: [Int]
    )
    case section(id: String, children: [MessageComponent], accessory: MessageComponent?)
    case textDisplay(id: String, content: String)
    case thumbnail(id: String, media: ComponentMedia)
    case mediaGallery(id: String, items: [ComponentGalleryItem])
    case file(id: String, media: ComponentMedia)
    case separator(id: String, divider: Bool, spacing: Int)
    case container(id: String, accentColor: UInt32?, spoiler: Bool, children: [MessageComponent])
    case unsupported(id: String, type: Int, label: String?)

    public var id: String {
        switch self {
        case let .actionRow(id, _), let .button(id, _, _, _, _, _, _, _),
             let .select(id, _, _, _, _, _, _, _, _), let .section(id, _, _), let .textDisplay(id, _),
             let .thumbnail(id, _), let .mediaGallery(id, _), let .file(id, _), let .separator(id, _, _),
             let .container(id, _, _, _), let .unsupported(id, _, _):
            id
        }
    }
}

public enum GIFMediaKind: String, Codable, Hashable, Sendable {
    case image
    case video
}

public struct GIFSearchResult: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var url: URL
    public var previewURL: URL?
    public var thumbnailURL: URL?
    public var mediaURL: URL?
    public var mediaKind: GIFMediaKind?
    public var width: Int?
    public var height: Int?
    public init(
        id: String, title: String, url: URL, previewURL: URL? = nil, width: Int? = nil,
        height: Int? = nil, thumbnailURL: URL? = nil, mediaURL: URL? = nil,
        mediaKind: GIFMediaKind? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.previewURL = previewURL
        self.thumbnailURL = thumbnailURL
        self.mediaURL = mediaURL
        self.mediaKind = mediaKind
        self.width = width
        self.height = height
    }
}

public struct GIFPickerCategory: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var query: String
    public var previewURL: URL?

    public init(id: String, name: String, query: String, previewURL: URL? = nil) {
        self.id = id
        self.name = name
        self.query = query
        self.previewURL = previewURL
    }
}

public struct GIFPickerLanding: Codable, Hashable, Sendable {
    public var categories: [GIFPickerCategory]
    public var trendingPreviewURL: URL?

    public init(categories: [GIFPickerCategory], trendingPreviewURL: URL? = nil) {
        self.categories = categories
        self.trendingPreviewURL = trendingPreviewURL
    }
}

public enum ComponentInteractionKind: String, Codable, Hashable, Sendable {
    case button, stringSelect, userSelect, roleSelect, mentionableSelect, channelSelect
}

public struct ComponentInteractionSubmission: Codable, Hashable, Sendable {
    public var messageID: MessageID
    public var channelID: ChannelID
    public var guildID: GuildID?
    public var applicationID: ApplicationID?
    public var customID: String
    public var kind: ComponentInteractionKind
    public var values: [String]
    public var nonce: String
    public init(
        messageID: MessageID, channelID: ChannelID, guildID: GuildID? = nil,
        applicationID: ApplicationID? = nil, customID: String, kind: ComponentInteractionKind,
        values: [String] = [], nonce: String = ClientNonce.make()
    ) {
        self.messageID = messageID
        self.channelID = channelID
        self.guildID = guildID
        self.applicationID = applicationID
        self.customID = customID
        self.kind = kind
        self.values = values
        self.nonce = nonce
    }
}

public indirect enum ModalControl: Identifiable, Codable, Hashable, Sendable {
    case label(id: String, label: String, description: String?, child: ModalControl)
    case textInput(
        id: String, customID: String, style: Int, label: String?, value: String?, placeholder: String?,
        required: Bool, minLength: Int?, maxLength: Int?
    )
    case select(
        id: String, customID: String, kind: ComponentSelectKind, options: [ComponentSelectOption],
        required: Bool, minValues: Int, maxValues: Int
    )
    case fileUpload(id: String, customID: String, required: Bool, minValues: Int, maxValues: Int)
    case radioGroup(id: String, customID: String, options: [ComponentSelectOption], required: Bool)
    case checkboxGroup(
        id: String, customID: String, options: [ComponentSelectOption], minValues: Int, maxValues: Int
    )
    case checkbox(id: String, customID: String, label: String, value: Bool)
    case unsupported(id: String, type: Int)

    public var id: String {
        switch self {
        case let .label(id, _, _, _), let .textInput(id, _, _, _, _, _, _, _, _),
             let .select(id, _, _, _, _, _, _), let .fileUpload(id, _, _, _, _),
             let .radioGroup(id, _, _, _), let .checkboxGroup(id, _, _, _, _), let .checkbox(id, _, _, _),
             let .unsupported(id, _):
            id
        }
    }
}

public struct InteractionModal: Identifiable, Codable, Hashable, Sendable {
    public var id: String {
        customID
    }

    public var customID: String
    public var title: String
    public var controls: [ModalControl]
    public init(customID: String, title: String, controls: [ModalControl]) {
        self.customID = customID
        self.title = title
        self.controls = controls
    }
}

public struct ModalSubmission: Codable, Hashable, Sendable {
    public var customID: String
    public var values: [String: [String]]
    public var fileURLs: [String: [URL]]
    public init(customID: String, values: [String: [String]], fileURLs: [String: [URL]] = [:]) {
        self.customID = customID
        self.values = values
        self.fileURLs = fileURLs
    }
}

public enum InteractionEvent: Equatable, Sendable {
    case created(nonce: String, interactionID: String)
    case succeeded(nonce: String)
    case failed(nonce: String, message: String)
    case presentModal(nonce: String, modal: InteractionModal)
}

public enum MessageSendProgress: Equatable, Sendable {
    case preparing
    case reserving(files: Int)
    case uploading(fileName: String, completed: Int64, total: Int64)
    case submitting
    case awaitingReconciliation(nonce: String)
    case completed(messageID: MessageID)
}
