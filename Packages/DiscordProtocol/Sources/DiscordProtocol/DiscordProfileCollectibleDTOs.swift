import Foundation
import SakuraCordModels

struct ProfileCollectibleCategoriesDTO: Decodable {
    var categories: [ProfileCollectibleCategoryDTO]
}

struct ProfileCollectibleCategoryDTO: Decodable {
    var skuID: String
    var name: String
    var summary: String
    var catalogBannerURL: URL?
    var products: [ProfileCollectibleProductDTO]

    enum CodingKeys: String, CodingKey {
        case skuID = "sku_id"
        case name, summary, products
        case catalogBannerURL = "catalog_banner_url"
    }

    var domain: ProfileCollectibleCategory {
        ProfileCollectibleCategory(
            id: skuID, name: name, summary: summary, bannerURL: catalogBannerURL,
            products: products.map(\.domain)
        )
    }
}

struct ProfileCollectibleProductDTO: Decodable {
    var skuID: String
    var name: String
    var summary: String
    var categorySKUID: String?
    var type: Int
    var premiumType: Int
    var purchaseType: Int?
    var items: [ProfileCollectibleItemDTO]?
    var variants: [Self]?
    var bundledProducts: [Self]?
    var variantLabel: String?
    var variantValue: String?
    var baseVariantSKUID: String?
    var purchasedAt: String?
    var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case skuID = "sku_id"
        case name, summary, type, items, variants
        case categorySKUID = "category_sku_id"
        case premiumType = "premium_type"
        case purchaseType = "purchase_type"
        case bundledProducts = "bundled_products"
        case variantLabel = "variant_label"
        case variantValue = "variant_value"
        case baseVariantSKUID = "base_variant_sku_id"
        case purchasedAt = "purchased_at"
        case expiresAt = "expires_at"
    }

    var domain: ProfileCollectibleProduct {
        ProfileCollectibleProduct(
            id: skuID, name: name, summary: summary, categoryID: categorySKUID,
            type: type, premiumType: premiumType, purchaseType: purchaseType, items: (items ?? []).compactMap(\.domain),
            variants: (variants ?? []).map(\.domain), bundledProducts: (bundledProducts ?? []).map(\.domain),
            variantLabel: variantLabel, variantColor: variantValue, baseVariantID: baseVariantSKUID,
            purchasedAt: purchasedAt.flatMap(DiscordDate.parse),
            // An unrecognized expiry must fail closed rather than grant permanent ownership.
            expiresAt: expiresAt.map { DiscordDate.parse($0) ?? .distantPast }
        )
    }
}

struct ProfileCollectibleItemDTO: Decodable {
    var domain: ProfileCollectibleItem?
    var effect: ProfileEffectConfigDTO?

    enum CodingKeys: String, CodingKey {
        case type, asset, label, palette
        case skuID = "sku_id"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try values.decode(Int.self, forKey: .type)
        guard let kind = ProfileCollectibleKind(rawValue: rawType) else { return }
        let sku = try values.decode(String.self, forKey: .skuID)
        var label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        let artwork: ProfileCollectibleArtwork
        switch kind {
        case .avatarDecoration:
            let asset = try values.decode(String.self, forKey: .asset)
            guard let url = DiscordCDN.avatarDecorationPreset(asset) else {
                throw DecodingError.dataCorruptedError(forKey: .asset, in: values, debugDescription: "Invalid decoration asset")
            }
            artwork = .avatarDecoration(url)
        case .effect:
            let configuration = try ProfileEffectConfigDTO(from: decoder)
            effect = configuration
            if label.isEmpty { label = configuration.accessibilityLabel ?? configuration.title ?? "" }
            artwork = .effect(configuration.domain)
        case .nameplate:
            let base = DiscordCDN.collectiblesShopBase(sku)
            artwork = .nameplate(Nameplate(
                staticURL: URL(string: "\(base)/static"), animatedURL: URL(string: "\(base)/animated"),
                label: label, palette: try values.decodeIfPresent(String.self, forKey: .palette) ?? "none"
            ))
        case .frame:
            artwork = try .frame(ProfileFrameDTO(from: decoder).domain)
        }
        domain = ProfileCollectibleItem(id: sku, kind: kind, label: label, artwork: artwork)
    }
}

private struct ProfileFrameDTO: Decodable {
    struct Layer: Decodable {
        var id: String
        var type: String
        var order: String
        var anchor: String
        var responsive: Bool
    }

    var skuID: String
    var label: String
    var innerWidth: Double
    var overflowTop: Double
    var overflowBottom: Double
    var overflowHorizontal: Double
    var layers: [Layer]

    enum CodingKeys: String, CodingKey {
        case skuID = "sku_id"
        case label, layers
        case innerWidth = "inner_width"
        case overflowTop = "overflow_top"
        case overflowBottom = "overflow_bottom"
        case overflowHorizontal = "overflow_horizontal"
    }

    var domain: ProfileFrame {
        get throws {
            guard innerWidth > 0 else {
                throw ChatProviderError.invalidRequest("Discord returned invalid profile frame dimensions.")
            }
            return try ProfileFrame(
                id: skuID, label: label, innerWidth: innerWidth, overflowTop: overflowTop,
                overflowBottom: overflowBottom, overflowHorizontal: overflowHorizontal,
                layers: layers.map { layer in
                    guard let url = URL(string: "\(DiscordCDN.collectiblesShopBase(skuID))/\(layer.id)/static") else {
                        throw ChatProviderError.invalidRequest("Discord returned an invalid profile frame asset.")
                    }
                    return ProfileFrameLayer(
                        id: layer.id, type: layer.type, order: layer.order, anchor: layer.anchor,
                        isResponsive: layer.responsive, staticURL: url
                    )
                }
            )
        }
    }
}

struct ProfileAvatarHistoryDTO: Decodable {
    struct Avatar: Decodable {
        var id: String
        var storageHash: String
        var description: String
        enum CodingKeys: String, CodingKey {
            case id, description
            case storageHash = "storage_hash"
        }
    }

    var avatars: [Avatar]

    func domain(for userID: UserID) throws -> [ProfileAvatarHistoryEntry] {
        try avatars.map { avatar in
            let path = "https://cdn.discordapp.com/avatars/\(userID)/archived/\(avatar.id)/\(avatar.storageHash).webp"
            let animation = avatar.storageHash.hasPrefix("a_") ? "&animated=true" : ""
            guard let url = URL(string: path + "?size=128" + animation), let cropURL = URL(string: path + "?size=2048" + animation) else {
                throw ChatProviderError.invalidRequest("Discord returned an invalid archived avatar asset.")
            }
            return ProfileAvatarHistoryEntry(
                id: avatar.id, storageHash: avatar.storageHash, description: avatar.description, imageURL: url, cropImageURL: cropURL
            )
        }
    }
}
