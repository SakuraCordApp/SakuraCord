import Foundation
import SakuraCordModels

struct ProfileWidgetCatalogueDTO: Decodable {
    let applications: [ProfileWidgetApplicationDTO]
    let configs: [String: [ProfileApplicationWidgetDTO]]

    func domain() -> [ProfileApplicationWidget] {
        applications.flatMap { application in
            (configs[application.id] ?? []).map { $0.domain(application: application) }
        }
    }
}

struct ProfileWidgetApplicationDTO: Decodable {
    let id: String
    let name: String
    let icon: String?
    let connectionEntrypointURL: URL?
    let parentID: String?
    enum CodingKeys: String, CodingKey { case id, name, icon; case connectionEntrypointURL = "connection_entrypoint_url", parentID = "parent_id" }
}

struct ProfileApplicationWidgetDTO: Decodable {
    struct Surface: Decodable {
        struct Component: Decodable { let fields: [String: Field] }
        let layout: String
        let components: [String: Component]
    }
    struct Field: Decodable {
        let valueType: String
        let presentationType: String
        let value: String
        let fallback: JSONValue?
        enum CodingKeys: String, CodingKey {
            case value, fallback
            case valueType = "value_type", presentationType = "presentation_type"
        }
        func domain(applicationID: String, assets: [Asset]) -> ProfileWidgetConfiguredField {
            let source: ProfileWidgetFieldSource
            switch valueType {
            case "custom_string": source = .literal(.text(value))
            case "data":
                let fallbackField = fallback.flatMap { try? JSONValueDecoder().decode(Field.self, from: $0) }
                source = .data(key: value, fallback: fallbackField?.domain(applicationID: applicationID, assets: assets))
            case "application_asset":
                if let asset = assets.first(where: { $0.key == value }), let image = asset.image(applicationID: applicationID) {
                    source = .literal(image)
                } else { source = .unavailable }
            default: source = .unavailable
            }
            return ProfileWidgetConfiguredField(presentation: presentationType, source: source)
        }
    }
    struct AssetMetadata: Decodable {
        let width: Double
        let height: Double
        let isAnimated: Bool
        enum CodingKeys: String, CodingKey { case width, height; case isAnimated = "is_animated" }
    }
    struct Asset: Decodable {
        let key: String
        let assetID: String
        let metadata: AssetMetadata
        enum CodingKeys: String, CodingKey { case key, metadata; case assetID = "asset_id" }

        func image(applicationID: String) -> ProfileWidgetValue? {
            guard UInt64(applicationID) != nil, UInt64(assetID) != nil, metadata.width > 0, metadata.height > 0 else { return nil }
            guard let url = DiscordCDN.applicationAsset(
                applicationID, assetID: assetID, fileExtension: "webp",
                size: DiscordCDN.supportedSize(atLeast: metadata.width), animated: metadata.isAnimated
            ) else { return nil }
            return .image(url: url, width: metadata.width, height: metadata.height)
        }
    }

    let configID: String
    let applicationID: String
    let displayName: String
    let status: String
    let surfaces: [String: Surface]
    let resolvedAssets: [Asset]?
    let application: ProfileWidgetApplicationDTO?
    enum CodingKeys: String, CodingKey {
        case status, surfaces, application
        case configID = "config_id", applicationID = "application_id", displayName = "display_name", resolvedAssets = "resolved_assets"
    }

    func domain(application metadata: ProfileWidgetApplicationDTO? = nil) -> ProfileApplicationWidget {
        let metadata = metadata ?? application
        let iconURL = metadata?.icon.flatMap { URL(string: "https://cdn.discordapp.com/app-icons/\(applicationID)/\($0).png?size=32&keep_aspect_ratio=false") }
        let mappedSurfaces = surfaces.filter { $0.key != "activity_accessory" }.mapValues { surface in
            ProfileWidgetSurface(layout: surface.layout, components: surface.components.mapValues { component in
                component.fields.mapValues { $0.domain(applicationID: applicationID, assets: resolvedAssets ?? []) }
            })
        }
        return ProfileApplicationWidget(
            id: configID, applicationID: applicationID, name: displayName, applicationName: metadata?.name ?? displayName,
            applicationIconURL: iconURL, connectionURL: metadata?.connectionEntrypointURL,
            isPublished: status == "published", surfaces: mappedSurfaces, connectionApplicationID: metadata?.parentID
        )
    }
}

struct ProfileWidgetIdentitiesDTO: Decodable {
    struct DataFields: Decodable {
        struct Dynamic: Decodable { let type: Int; let name: String; let value: JSONValue }
        let primary: [String: JSONValue]?
        let dynamic: [Dynamic]?
    }
    struct Profile: Decodable {
        let username: String?
        let data: DataFields?
    }
    struct Identity: Decodable {
        let applicationID: String
        let profile: Profile?
        enum CodingKeys: String, CodingKey { case profile; case applicationID = "application_id" }

        var domain: ProfileWidgetApplicationIdentity {
            var values: [String: ProfileWidgetValue] = [:]
            if let username = profile?.username { values["username"] = .text(username) }
            for (key, value) in profile?.data?.primary ?? [:] {
                if let converted = Self.value(value) { values[key] = converted }
            }
            for field in profile?.data?.dynamic ?? [] {
                guard let converted = Self.value(field.value) else { continue }
                switch (field.type, converted) {
                case (1, .text), (2, .number), (3, .image): values[field.name] = converted
                default: break
                }
            }
            return ProfileWidgetApplicationIdentity(applicationID: applicationID, data: values)
        }

        private static func value(_ value: JSONValue) -> ProfileWidgetValue? {
            switch value {
            case let .string(text): return .text(text)
            case let .number(number): return .number(number)
            case let .object(object):
                guard case let .string(rawURL) = object["proxy_url"], let url = URL(string: rawURL),
                      case let .number(width) = object["width"], width > 0,
                      case let .number(height) = object["height"], height > 0 else { return nil }
                return .image(url: url, width: width, height: height)
            default: return nil
            }
        }
    }
    let identities: [Identity]
}
