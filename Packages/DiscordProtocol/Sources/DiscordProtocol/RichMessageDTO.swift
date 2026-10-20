import Foundation
import SakuraCordModels

struct MessageEmbedDTO: Decodable {
    struct Media: Decodable {
        var url: String?
        var proxyURL: String?
        var width: Int?
        var height: Int?
        var description: String?
        var contentType: String?
        var placeholder: String?
        var placeholderVersion: Int?
        var flags: UInt64?
        enum CodingKeys: String, CodingKey {
            case url, width, height, description, placeholder, flags
            case proxyURL = "proxy_url"
            case contentType = "content_type"
            case placeholderVersion = "placeholder_version"
        }

        var domain: MessageEmbedMedia {
            MessageEmbedMedia(
                url: url.flatMap(URL.init), proxyURL: proxyURL.flatMap(URL.init), width: width,
                height: height, description: description, contentType: contentType,
                placeholder: placeholder, placeholderVersion: placeholderVersion, flags: flags ?? 0
            )
        }
    }

    struct Author: Decodable {
        var name: String
        var url: String?
        var iconURL: String?
        var proxyIconURL: String?
        enum CodingKeys: String, CodingKey {
            case name, url
            case iconURL = "icon_url"
            case proxyIconURL = "proxy_icon_url"
        }

        var domain: MessageEmbedAuthor {
            MessageEmbedAuthor(
                name: name, url: url.flatMap(URL.init), iconURL: iconURL.flatMap(URL.init),
                proxyIconURL: proxyIconURL.flatMap(URL.init)
            )
        }
    }

    struct Provider: Decodable {
        var name: String?
        var url: String?
        var domain: MessageEmbedProvider {
            MessageEmbedProvider(name: name, url: url.flatMap(URL.init))
        }
    }

    struct Footer: Decodable {
        var text: String
        var iconURL: String?
        var proxyIconURL: String?
        enum CodingKeys: String, CodingKey {
            case text
            case iconURL = "icon_url"
            case proxyIconURL = "proxy_icon_url"
        }

        var domain: MessageEmbedFooter {
            MessageEmbedFooter(
                text: text, iconURL: iconURL.flatMap(URL.init), proxyIconURL: proxyIconURL.flatMap(URL.init)
            )
        }
    }

    struct Field: Decodable {
        var name: String
        var value: String
        var inline: Bool?
    }

    var title: String?
    var type: String?
    var description: String?
    var url: String?
    var timestamp: String?
    var color: UInt32?
    var footer: Footer?
    var image: Media?
    var thumbnail: Media?
    var video: Media?
    var provider: Provider?
    var author: Author?
    var fields: LossyList<Field>?
    var components: LossyList<MessageComponentDTO>?

    func domain(index: Int) -> MessageEmbed {
        // The wire thumbnail is the main image for article/image embeds.
        // Discord normalizes this before exposing embeds to its renderer.
        let promotesThumbnail = type?.lowercased() == "image" || type?.lowercased() == "article"
        return MessageEmbed(
            id: "embed-\(index)", title: title, type: type, description: description,
            url: url.flatMap(URL.init), timestamp: timestamp.flatMap(DiscordDate.parse), color: color,
            footer: footer?.domain,
            image: (image ?? (promotesThumbnail ? thumbnail : nil))?.domain,
            thumbnail: promotesThumbnail ? nil : thumbnail?.domain,
            video: video?.domain,
            provider: provider?.domain, author: author?.domain,
            fields: (fields?.elements ?? []).enumerated().map {
                MessageEmbedField(
                    id: $0.offset, name: $0.element.name, value: $0.element.value,
                    isInline: $0.element.inline ?? false
                )
            },
            components: components?.elements.enumerated().map {
                $0.element.domain(path: "embed-\(index).\($0.offset)", usesPathIdentity: true)
            }
        )
    }
}

struct MessageStickerDTO: Decodable {
    var id: String
    var name: String?
    var description: String?
    var tags: String?
    var formatType: Int?
    var guildID: String?
    var available: Bool?
    var sortValue: Int?
    enum CodingKeys: String, CodingKey {
        case id, name, description, tags, available
        case formatType = "format_type"
        case guildID = "guild_id"
        case sortValue = "sort_value"
    }

    var domain: MessageSticker {
        MessageSticker(
            id: id, name: name ?? "Sticker", description: description, tags: tags,
            format: formatType.flatMap(StickerFormat.init(rawValue:)),
            guildID: guildID.flatMap(GuildID.init), isAvailable: available ?? true
        )
    }

    func domain(guildID fallbackGuildID: GuildID) -> MessageSticker {
        var value = domain
        if value.guildID == nil { value.guildID = fallbackGuildID }
        return value
    }
}

struct MessageThreadDTO: Decodable {
    struct Metadata: Decodable {
        var archived: Bool?
        var locked: Bool?
        var createTimestamp: String?
        enum CodingKeys: String, CodingKey {
            case archived, locked
            case createTimestamp = "create_timestamp"
        }
    }

    var rateLimitPerUser: Int?
    var id: String
    var guildID: String?
    var parentID: String?
    var ownerID: String?
    var name: String?
    var messageCount: Int?
    var memberCount: Int?
    var lastMessageID: String?
    var threadMetadata: Metadata?
    enum CodingKeys: String, CodingKey {
        case rateLimitPerUser = "rate_limit_per_user"
        case id, name
        case guildID = "guild_id"
        case parentID = "parent_id"
        case ownerID = "owner_id"
        case messageCount = "message_count"
        case memberCount = "member_count"
        case lastMessageID = "last_message_id"
        case threadMetadata = "thread_metadata"
    }

    var domain: MessageThreadSummary? {
        guard let id = ChannelID(id) else { return nil }
        return MessageThreadSummary(
            id: id, guildID: guildID.flatMap(GuildID.init), parentID: parentID.flatMap(ChannelID.init),
            name: name ?? "Thread", messageCount: messageCount ?? 0, memberCount: memberCount ?? 0,
            lastMessageID: lastMessageID.flatMap(MessageID.init),
            isArchived: threadMetadata?.archived ?? false, isLocked: threadMetadata?.locked ?? false,
            ownerID: ownerID.flatMap(UserID.init),
            createdAt: threadMetadata?.createTimestamp.flatMap(DiscordDate.parse),
            rateLimitPerUser: rateLimitPerUser ?? 0
        )
    }
}

final class MessageComponentDTO: Decodable {
    struct Emoji: Decodable {
        var id: String?
        var name: String?
        var animated: Bool?
        var domain: EmojiReference? {
            name.map { EmojiReference(id: id, name: $0, isAnimated: animated ?? false) }
        }
    }

    struct Option: Decodable {
        var label: String
        var value: String
        var description: String?
        var emoji: Emoji?
        var isDefault: Bool?
        enum CodingKeys: String, CodingKey {
            case label, value, description, emoji
            case isDefault = "default"
        }

        var domain: ComponentSelectOption {
            ComponentSelectOption(
                label: label, value: value, description: description, emoji: emoji?.domain,
                isDefault: isDefault ?? false
            )
        }
    }

    struct UnfurledMedia: Decodable {
        var url: String?
        var proxyURL: String?
        var width: Int?
        var height: Int?
        var placeholder: String?
        var placeholderVersion: Int?
        var contentType: String?
        var flags: UInt64?
        var attachmentID: String?
        enum CodingKeys: String, CodingKey {
            case url, width, height, placeholder, flags
            case proxyURL = "proxy_url"
            case placeholderVersion = "placeholder_version"
            case contentType = "content_type"
            case attachmentID = "attachment_id"
        }

        /// A request may reference `attachment://name`; a delivered message
        /// resolves that to a CDN URL and keeps `attachment_id`, while the
        /// attachment itself is absent from `attachments`. Keep both.
        func domain(description: String?, isSpoiler: Bool) -> ComponentMedia {
            let reference = url.flatMap { $0.hasPrefix("attachment://") ? String($0.dropFirst("attachment://".count)) : nil }
            return ComponentMedia(
                url: reference == nil ? url.flatMap(URL.init) : nil,
                proxyURL: proxyURL.flatMap(URL.init), attachmentName: reference ?? attachmentID,
                width: width, height: height, contentType: contentType,
                placeholder: placeholder, placeholderVersion: placeholderVersion,
                flags: flags, description: description, isSpoiler: isSpoiler
            )
        }
    }

    struct MediaItem: Decodable {
        var media: UnfurledMedia?
        var description: String?
        var spoiler: Bool?
    }

    struct DefaultValue: Decodable {
        var id: StringOrIntegerDTO
        var type: String

        var domain: ComponentDefaultValue? {
            ComponentDefaultValueKind(rawValue: type).map {
                ComponentDefaultValue(id: id.value, kind: $0)
            }
        }
    }

    var type: Int
    var id: Int?
    var customID: String?
    var style: Int?
    var label: String?
    var emoji: Emoji?
    var url: String?
    var skuID: String?
    var disabled: Bool?
    var placeholder: String?
    var minValues: Int?
    var maxValues: Int?
    var options: LossyList<Option>?
    var channelTypes: [Int]?
    var content: String?
    var description: String?
    var components: LossyList<MessageComponentDTO>?
    var component: MessageComponentDTO?
    var accessory: MessageComponentDTO?
    var media: UnfurledMedia?
    var file: UnfurledMedia?
    var items: LossyList<MediaItem>?
    var divider: Bool?
    var spacing: Int?
    var accentColor: UInt32?
    var spoiler: Bool?
    var required: Bool?
    var value: String?
    var minimumLength: Int?
    var maximumLength: Int?
    var defaultValue: Bool?
    var defaultValues: LossyList<DefaultValue>?
    var fileTypes: [String]?

    enum CodingKeys: String, CodingKey {
        case type, id, style, label, emoji, url, disabled, placeholder, options, content, description,
             components, component, accessory, media, file, items, divider, spacing, spoiler, required,
             value
        case customID = "custom_id"
        case skuID = "sku_id"
        case minValues = "min_values"
        case maxValues = "max_values"
        case channelTypes = "channel_types"
        case accentColor = "accent_color"
        case minimumLength = "min_length"
        case maximumLength = "max_length"
        case defaultValue = "default"
        case defaultValues = "default_values"
        case fileTypes = "file_types"
    }

    func domain(path: String, usesPathIdentity: Bool = false) -> MessageComponent {
        // Website previews have independent component trees; their numeric IDs
        // must not collide with another embed or the message's own components.
        let stableID = usesPathIdentity ? path : id.map(String.init) ?? path
        let children = (components?.elements ?? []).enumerated().map {
            $0.element.domain(path: "\(path).\($0.offset)", usesPathIdentity: usesPathIdentity)
        }
        let mediaValue = (type == 13 ? file : media)?.domain(description: description, isSpoiler: spoiler ?? false)
            ?? ComponentMedia(description: description, isSpoiler: spoiler ?? false)
        switch type {
        case 1: return .actionRow(id: stableID, children: children)
        case 2:
            return .button(
                id: stableID, style: style.flatMap(ComponentButtonStyle.init(rawValue:)), label: label,
                emoji: emoji?.domain, customID: customID, url: url.flatMap(URL.init), skuID: skuID,
                disabled: disabled ?? false
            )
        case 3, 5, 6, 7, 8:
            guard let kind = ComponentSelectKind(rawValue: type), let customID else {
                return .unsupported(id: stableID, type: type, label: label)
            }
            // Entity selects have no options; their defaults arrive as
            // `default_values` and are carried as preselected entity options.
            let selectOptions = kind == .string
                ? (options?.elements ?? []).map(\.domain)
                : defaultEntityOptions
            return .select(
                id: stableID, kind: kind, customID: customID, placeholder: placeholder,
                minValues: minValues ?? 1, maxValues: maxValues ?? 1, disabled: disabled ?? false,
                options: selectOptions, channelTypes: channelTypes ?? []
            )
        case 9:
            return .section(
                id: stableID, children: children,
                accessory: accessory?.domain(path: "\(path).accessory", usesPathIdentity: usesPathIdentity)
            )
        case 10: return .textDisplay(id: stableID, content: content ?? "")
        case 11: return .thumbnail(id: stableID, media: mediaValue)
        case 12:
            let values = (items?.elements ?? []).enumerated().map { index, item in
                ComponentGalleryItem(
                    id: "\(stableID).\(index)",
                    media: item.media?.domain(description: item.description, isSpoiler: item.spoiler ?? false)
                        ?? ComponentMedia(description: item.description, isSpoiler: item.spoiler ?? false)
                )
            }
            return .mediaGallery(id: stableID, items: values)
        case 13: return .file(id: stableID, media: mediaValue)
        case 14: return .separator(id: stableID, divider: divider ?? true, spacing: spacing ?? 1)
        case 17:
            return .container(
                id: stableID, accentColor: accentColor, spoiler: spoiler ?? false, children: children
            )
        default: return .unsupported(id: stableID, type: type, label: label)
        }
    }

    private var defaultEntityOptions: [ComponentSelectOption] {
        (defaultValues?.elements ?? []).compactMap(\.domain).map { value in
            let entityKind: ComponentSelectOptionEntityKind = switch value.kind {
            case .user: .user
            case .role: .role
            case .channel: .channel
            }
            return ComponentSelectOption(
                label: value.id, value: value.id, entityKind: entityKind, isDefault: true
            )
        }
    }

    /// Decodes one node of a returned modal. Discord omits `required` for
    /// optional controls, so absence means optional rather than required.
    func modalNode(path: String) -> ModalNode {
        let stableID = id.map(String.init) ?? path
        switch type {
        case 1:
            return .actionRow(
                id: stableID,
                children: (components?.elements ?? []).enumerated().map {
                    $0.element.modalNode(path: "\(path).\($0.offset)")
                }
            )
        case 18:
            return .label(
                id: stableID, label: label ?? "", description: description,
                child: component?.modalNode(path: "\(path).component")
                    ?? .unsupported(id: "\(stableID).component", type: -1)
            )
        case 10:
            return .textDisplay(id: stableID, content: content ?? "")
        default:
            return modalControl(id: stableID).map(ModalNode.control)
                ?? .unsupported(id: stableID, type: type)
        }
    }

    private func modalControl(id stableID: String) -> ModalControl? {
        guard let customID else { return nil }
        let isRequired = required ?? false
        let kind: ModalControl.Kind
        switch type {
        case 4:
            kind = .textInput(
                style: ModalTextInputStyle(rawValue: style ?? 1) ?? .short,
                placeholder: placeholder, minLength: minimumLength, maxLength: maximumLength,
                initialValue: value
            )
        case 3, 5, 6, 7, 8:
            guard let selectKind = ComponentSelectKind(rawValue: type) else { return nil }
            kind = .select(
                kind: selectKind, placeholder: placeholder,
                options: (options?.elements ?? []).map(\.domain),
                minValues: minValues ?? 1, maxValues: maxValues ?? 1,
                channelTypes: channelTypes ?? [],
                defaultValues: (defaultValues?.elements ?? []).compactMap(\.domain)
            )
        case 19:
            kind = .fileUpload(
                minValues: minValues ?? 1, maxValues: maxValues ?? 1, fileTypes: fileTypes ?? []
            )
        case 21:
            kind = .radioGroup(options: (options?.elements ?? []).map(\.domain))
        case 22:
            let optionCount = options?.elements.count ?? 1
            kind = .checkboxGroup(
                options: (options?.elements ?? []).map(\.domain),
                minValues: minValues ?? (isRequired ? 1 : 0),
                maxValues: maxValues ?? max(1, optionCount)
            )
        case 23:
            kind = .checkbox(isInitiallyChecked: defaultValue ?? false)
        default:
            return nil
        }
        return ModalControl(
            id: stableID, customID: customID, kind: kind, isRequired: isRequired,
            isDisabled: disabled ?? false, label: type == 4 ? label : nil
        )
    }
}
