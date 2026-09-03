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

    func domain(index: Int) -> MessageEmbed {
        MessageEmbed(
            id: "embed-\(index)", title: title, type: type, description: description,
            url: url.flatMap(URL.init), timestamp: timestamp.flatMap(DiscordDate.parse), color: color,
            footer: footer?.domain, image: image?.domain, thumbnail: thumbnail?.domain,
            video: video?.domain,
            provider: provider?.domain, author: author?.domain,
            fields: (fields?.elements ?? []).enumerated().map {
                MessageEmbedField(
                    id: $0.offset, name: $0.element.name, value: $0.element.value,
                    isInline: $0.element.inline ?? false
                )
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
    }

    var id: String
    var guildID: String?
    var parentID: String?
    var name: String?
    var messageCount: Int?
    var memberCount: Int?
    var lastMessageID: String?
    var threadMetadata: Metadata?
    enum CodingKeys: String, CodingKey {
        case id, name
        case guildID = "guild_id"
        case parentID = "parent_id"
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
            isArchived: threadMetadata?.archived ?? false, isLocked: threadMetadata?.locked ?? false
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
    }

    struct MediaItem: Decodable {
        var media: UnfurledMedia?
        var description: String?
        var spoiler: Bool?
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
    }

    func domain(path: String) -> MessageComponent {
        let stableID = id.map(String.init) ?? path
        let children = (components?.elements ?? []).enumerated().map {
            $0.element.domain(path: "\(path).\($0.offset)")
        }
        let mediaValue: ComponentMedia = {
            let source = type == 13 ? file : media
            let raw = source?.url
            let attachment =
                raw?.hasPrefix("attachment://") == true
                    ? String(raw!.dropFirst("attachment://".count)) : source?.attachmentID
            return ComponentMedia(
                url: attachment == nil ? raw.flatMap(URL.init) : nil,
                proxyURL: source?.proxyURL.flatMap(URL.init), attachmentName: attachment,
                width: source?.width, height: source?.height, contentType: source?.contentType,
                placeholder: source?.placeholder, placeholderVersion: source?.placeholderVersion,
                flags: source?.flags, description: description, isSpoiler: spoiler ?? false
            )
        }()
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
            return .select(
                id: stableID, kind: kind, customID: customID, placeholder: placeholder,
                minValues: minValues ?? 1, maxValues: maxValues ?? 1, disabled: disabled ?? false,
                options: (options?.elements ?? []).map(\.domain), channelTypes: channelTypes ?? []
            )
        case 9:
            return .section(
                id: stableID, children: children, accessory: accessory?.domain(path: "\(path).accessory")
            )
        case 10: return .textDisplay(id: stableID, content: content ?? "")
        case 11: return .thumbnail(id: stableID, media: mediaValue)
        case 12:
            let values = (items?.elements ?? []).enumerated().map { index, item in
                let raw = item.media?.url
                let attachment =
                    raw?.hasPrefix("attachment://") == true
                        ? String(raw!.dropFirst("attachment://".count)) : item.media?.attachmentID
                return ComponentGalleryItem(
                    id: "\(stableID).\(index)",
                    media: ComponentMedia(
                        url: attachment == nil ? raw.flatMap(URL.init) : nil,
                        proxyURL: item.media?.proxyURL.flatMap(URL.init), attachmentName: attachment,
                        width: item.media?.width, height: item.media?.height,
                        contentType: item.media?.contentType, placeholder: item.media?.placeholder,
                        placeholderVersion: item.media?.placeholderVersion, flags: item.media?.flags,
                        description: item.description, isSpoiler: item.spoiler ?? false
                    )
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

    func modalControl(path: String) -> ModalControl {
        let stableID = id.map(String.init) ?? path
        switch type {
        case 1:
            return components?.elements.first?.modalControl(path: "\(path).0")
                ?? .unsupported(id: stableID, type: type)
        case 18:
            return .label(
                id: stableID, label: label ?? "Field", description: description,
                child: component?.modalControl(path: "\(path).component")
                    ?? .unsupported(id: "\(stableID).component", type: -1)
            )
        case 4:
            guard let customID else { return .unsupported(id: stableID, type: type) }
            return .textInput(
                id: stableID, customID: customID, style: style ?? 1, label: label,
                value: value, placeholder: placeholder, required: required ?? true,
                minLength: minimumLength, maxLength: maximumLength
            )
        case 3, 5, 6, 7, 8:
            guard let customID, let kind = ComponentSelectKind(rawValue: type) else {
                return .unsupported(id: stableID, type: type)
            }
            return .select(
                id: stableID, customID: customID, kind: kind,
                options: (options?.elements ?? []).map(\.domain), required: required ?? true,
                minValues: minValues ?? (required == false ? 0 : 1), maxValues: maxValues ?? 1
            )
        case 19:
            guard let customID else { return .unsupported(id: stableID, type: type) }
            return .fileUpload(
                id: stableID, customID: customID, required: required ?? true,
                minValues: minValues ?? (required == false ? 0 : 1), maxValues: maxValues ?? 1
            )
        case 21:
            guard let customID else { return .unsupported(id: stableID, type: type) }
            return .radioGroup(
                id: stableID, customID: customID, options: (options?.elements ?? []).map(\.domain),
                required: required ?? true
            )
        case 22:
            guard let customID else { return .unsupported(id: stableID, type: type) }
            return .checkboxGroup(
                id: stableID, customID: customID, options: (options?.elements ?? []).map(\.domain),
                minValues: minValues ?? (required == false ? 0 : 1),
                maxValues: maxValues ?? max(1, options?.elements.count ?? 1)
            )
        case 23:
            guard let customID else { return .unsupported(id: stableID, type: type) }
            return .checkbox(
                id: stableID, customID: customID, label: label ?? "Enabled",
                value: defaultValue ?? false
            )
        default:
            return .unsupported(id: stableID, type: type)
        }
    }
}
