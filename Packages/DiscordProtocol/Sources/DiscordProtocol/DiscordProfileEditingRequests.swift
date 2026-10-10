import Foundation
import SakuraCordModels

struct ProfileEditingRequest: Equatable, Sendable {
    var path: String
    var method: String
    var body: [String: JSONValue]
    var headers: [String: String]

    static func identity(
        _ changes: ProfileIdentityChanges, in scope: ProfileEditingScope
    ) -> Self? {
        guard changes.hasChanges else { return nil }
        var body: [String: JSONValue] = [:]
        var headers: [String: String] = [:]
        body[scope.guildID == nil ? "global_name" : "nick"] = changes.name.jsonValue(JSONValue.string)
        body["avatar_decoration_sku_id"] = changes.decorationSKUID.jsonValue(JSONValue.string)
        switch changes.avatar {
        case .unchanged: break
        case .clear: body["avatar"] = .null
        case let .set(.history(entry)): body["avatar_id"] = .string(entry.id)
        case let .set(.upload(image)):
            body["avatar"] = image.dataURI
            body["avatar_description"] = .string(image.description)
            headers = image.originalMD5Headers(
                field: scope.guildID == nil ? "user_default_profile_avatar" : "user_guild_profile_avatar"
            )
        }
        if scope.guildID == nil {
            body["nameplate_sku_id"] = changes.nameplateSKUID.jsonValue(JSONValue.string)
        } else if let nameplate = changes.nameplateSKUID.jsonValue({ .object(["sku_id": .string($0)]) }) {
            body["collectibles"] = .object(["nameplate": nameplate])
        }
        switch changes.displayNameStyle {
        case .unchanged: break
        case .clear:
            body["display_name_font_id"] = .null
            body["display_name_effect_id"] = .null
            body["display_name_colors"] = .null
        case let .set(style):
            body["display_name_font_id"] = .number(Double(style.fontID))
            body["display_name_effect_id"] = .number(Double(style.effectID))
            body["display_name_colors"] = .array(style.colors.map { .number(Double($0)) })
        }
        let path = scope.guildID.map { "/guilds/\($0)/members/@me" } ?? "/users/@me"
        return Self(path: path, method: "PATCH", body: body, headers: headers)
    }

    static func metadata(
        _ changes: ProfileMetadataChanges, in scope: ProfileEditingScope
    ) -> Self? {
        guard changes.hasChanges else { return nil }
        var body: [String: JSONValue] = [:]
        var headers: [String: String] = [:]
        body["bio"] = changes.bio.jsonValue(JSONValue.string)
        body["pronouns"] = changes.pronouns.jsonValue(JSONValue.string)
        body["accent_color"] = changes.accentColor.jsonValue { .number(Double($0)) }
        switch changes.banner {
        case .unchanged: break
        case .clear: body["banner"] = .null
        case let .set(image):
            body["banner"] = image.dataURI
            headers = image.originalMD5Headers(
                field: scope.guildID == nil ? "user_default_profile_banner" : "user_guild_profile_banner"
            )
        }
        switch changes.themeColors {
        case .unchanged: break
        case .clear: body["theme_colors"] = .array([.null, .null])
        case let .set(colors):
            body["theme_colors"] = .array([colors.primary, colors.accent].map {
                $0.map { .number(Double($0)) } ?? .null
            })
        }
        switch changes.collectibleSKUIDs {
        case .unchanged: break
        case .clear: body["collectibles_sku_ids"] = .array([])
        case let .set(ids): body["collectibles_sku_ids"] = .array(ids.map(JSONValue.string))
        }
        let path = scope.guildID.map { "/guilds/\($0)/profile/%40me" } ?? "/users/%40me/profile"
        return Self(path: path, method: "PATCH", body: body, headers: headers)
    }

    static func serverTag(_ guildID: GuildID?) -> Self {
        Self(
            path: "/users/@me/clan", method: "PUT",
            body: [
                "identity_guild_id": guildID.map { .string($0.description) } ?? .null,
                "identity_enabled": .bool(guildID != nil),
            ],
            headers: [:]
        )
    }
}

extension ProfileChange {
    func jsonValue(_ encode: (Value) -> JSONValue) -> JSONValue? {
        switch self {
        case .unchanged: nil
        case .clear: .null
        case let .set(value): encode(value)
        }
    }
}

extension ProfileImageUpload {
    var dataURI: JSONValue {
        .string("data:\(mediaType);base64,\(data.base64EncodedString())")
    }

    func originalMD5Headers(field: String) -> [String: String] {
        guard let originalMD5 else { return [:] }
        return ["X-Discord-Original-MD5": "\(field)=\"\(originalMD5)\""]
    }
}
