import Foundation

/// One product in the collectibles shop.
public struct CollectibleProduct: Sendable {
    public var skuID: Snowflake
    public var name: String
    public var summary: String
    /// 0 avatar decoration, 2 nameplate; its items carry the same type.
    public var type: Int
    /// Wire-shaped items (`type`, `sku_id`, `asset`, `label`, and `palette` for a nameplate).
    public var items: [JSON]
    public var categorySKU: Snowflake
    /// Price in euro cents without Nitro, and with it.
    public var price: Int
    public var nitroPrice: Int
}

/// A shop category: its products and the six pieces of art every category has.
public struct CollectibleCategory: Sendable {
    public var skuID: Snowflake
    public var name: String
    public var summary: String
    public var products: [Snowflake]
    /// `catalog_banner_url`, `featured_block_url`, `logo_url`, `pdp_bg_url`, `mobile_banner_url`, `mobile_bg_url`.
    public var art: [String: String]
}

public struct CollectiblesShop: Sendable {
    public var categories: [CollectibleCategory] = []
    public var products: [Snowflake: CollectibleProduct] = [:]
    /// What each user bought and when, oldest first.
    public var purchases: [Snowflake: [(sku: Snowflake, at: Date)]] = [:]
}

extension World {
    static let collectibleArtFields = ["catalog_banner_url", "featured_block_url", "logo_url", "pdp_bg_url", "mobile_banner_url", "mobile_bg_url"]

    /// Opens a shop category with new art, ready for products.
    func addCollectibleCategory(name: String, summary: String, at date: Date) -> Snowflake {
        var art: [String: String] = [:]
        for field in Self.collectibleArtFields {
            let hash = nextHash()
            registerAsset(hash)
            art[field] = hash
        }
        let id = nextID(at: date)
        collectibles.categories.append(CollectibleCategory(skuID: id, name: name, summary: summary, products: [], art: art))
        return id
    }

    func addCollectibleProduct(_ product: CollectibleProduct) {
        collectibles.products[product.skuID] = product
        if let index = collectibles.categories.firstIndex(where: { $0.skuID == product.categorySKU }) {
            collectibles.categories[index].products.append(product.skuID)
        }
    }

    func recordPurchase(_ sku: Snowflake, by userID: Snowflake, at date: Date) {
        collectibles.purchases[userID, default: []].append((sku, date))
    }

    func collectibleProduct(_ sku: Snowflake) throws -> CollectibleProduct {
        guard let product = collectibles.products[sku] else { throw WorldError.unknown("SKU", code: 10013) }
        return product
    }

    /// The fields every rendering of a product shares.
    private func renderProductBase(_ product: CollectibleProduct) -> JSONObject {
        JSONObject([
            ("sku_id", product.skuID.json), ("name", .string(product.name)), ("summary", .string(product.summary)),
            ("store_listing_id", product.skuID.json), ("styles", Self.collectibleStyles), ("items", .array(product.items)),
            ("type", .int(product.type)), ("premium_type", 0), ("category_sku_id", product.categorySKU.json),
        ])
    }

    /// `GET /collectibles-products/{id}`, and each product of a shop category with its prices.
    func renderProduct(_ product: CollectibleProduct, withPrices: Bool) -> JSON {
        var object = renderProductBase(product)
        object["preview_assets"] = .null
        object["google_sku_ids"] = .object(JSONObject())
        object["is_first_party"] = true
        if withPrices {
            func price(_ amount: Int) -> JSON {
                .object(JSONObject([("country_prices", .object(JSONObject([
                    ("country_code", "NL"),
                    ("prices", .array([.object(JSONObject([("amount", .int(amount)), ("currency", "eur"), ("exponent", 2)]))])),
                ])))]))
            }
            object["prices"] = .object(JSONObject([("0", price(product.price)), ("4", price(product.nitroPrice))]))
        }
        return .object(object)
    }

    /// `GET /collectibles-categories/v2`.
    func renderCollectibleCategories() -> JSON {
        .object(JSONObject([
            ("categories", .array(collectibles.categories.map { category in
                var object = JSONObject([
                    ("sku_id", category.skuID.json), ("name", .string(category.name)), ("summary", .string(category.summary)),
                    ("store_listing_id", category.skuID.json), ("styles", Self.collectibleStyles),
                    ("hero_ranking", .array(category.products.map(\.json))),
                    ("products", .array(category.products.compactMap { collectibles.products[$0] }.map { renderProduct($0, withPrices: true) })),
                ])
                for field in Self.collectibleArtFields {
                    object[field] = .string("https://cdn.discordapp.com/media/v1/collectibles-shop/\(category.art[field] ?? "")")
                }
                return .object(object)
            })),
            ("collections", []),
        ]))
    }

    /// `GET /users/@me/collectibles-purchases`: everything the user bought, which never expires here.
    func renderPurchases(_ userID: Snowflake) -> JSON {
        .array((collectibles.purchases[userID] ?? []).compactMap { purchase in
            guard let product = collectibles.products[purchase.sku] else { return nil }
            var object = renderProductBase(product)
            object["unpublished_at"] = .null
            object["purchase_type"] = 1
            object["purchased_at"] = World.timestamp(purchase.at)
            object["expires_at"] = .null
            return .object(object)
        })
    }

    private static let collectibleStyles = JSON.object(JSONObject([
        ("background_colors", [4_396_172, 1_513_265]), ("button_colors", [5_793_266, 5_793_266]),
        ("confetti_colors", [11_626_751, 16_752_335, 9_291_519]),
    ]))
}
