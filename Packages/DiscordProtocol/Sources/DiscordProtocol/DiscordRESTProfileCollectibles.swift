import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func profileCollectibleInventory() async throws -> ProfileCollectibleInventory {
        guard let userID = currentUser?.id else { throw ChatProviderError.unauthenticated }
        let generation = profileEditingGeneration
        if let profileInventory { return profileInventory }
        if let profileInventoryTask { return try await profileInventoryTask.value }
        let task = Task { [self] in
            async let categories: ProfileCollectibleCategoriesDTO = request(
                "/collectibles-categories/v2",
                query: [
                    URLQueryItem(name: "include_bundles", value: "true"),
                    URLQueryItem(name: "variants_return_style", value: "2"),
                    URLQueryItem(name: "skip_num_categories", value: "0"),
                ]
            )
            async let purchases: [ProfileCollectibleProductDTO] = request(
                "/users/@me/collectibles-purchases",
                query: [URLQueryItem(name: "variants_return_style", value: "2")]
            )
            let (catalogue, owned) = try await (categories, purchases)
            try Task.checkCancellation()
            guard currentUser?.id == userID, profileEditingGeneration == generation, !requestSafetyCircuitIsOpen else { throw CancellationError() }
            for product in catalogue.categories.flatMap(\.products) + owned { cacheProfileCollectible(product) }
            return ProfileCollectibleInventory(categories: catalogue.categories.map(\.domain), purchases: owned.map(\.domain))
        }
        profileInventoryTask = task
        defer { if profileEditingGeneration == generation { profileInventoryTask = nil } }
        let inventory = try await task.value
        try Task.checkCancellation()
        guard currentUser?.id == userID, profileEditingGeneration == generation, !requestSafetyCircuitIsOpen else { throw CancellationError() }
        profileInventory = inventory
        return inventory
    }

    func profileCollectibleProduct(id: String) async throws -> ProfileCollectibleProduct {
        try await loadProfileCollectibleProduct(id: id, requiresDetails: true).domain
    }

    internal func loadProfileCollectibleProduct(id: String, requiresDetails: Bool = false) async throws -> ProfileCollectibleProductDTO {
        let userID = currentUser?.id
        let generation = profileEditingGeneration
        guard UInt64(id) != nil else { throw ChatProviderError.invalidRequest("Invalid collectible identifier.") }
        if let product = profileCollectibleProducts[id], !requiresDetails || profileDetailedProductIDs.contains(id) { return product }
        if let task = collectibleProductTasks[id] { return try await task.value }
        let task = Task<ProfileCollectibleProductDTO, Error> { [self] in
            try await request(
                "/collectibles-products/\(id)",
                query: [URLQueryItem(name: "locale", value: clientMetadata.locale)]
            )
        }
        collectibleProductTasks[id] = task
        defer { if profileEditingGeneration == generation { collectibleProductTasks[id] = nil } }
        let product = try await task.value
        try Task.checkCancellation()
        guard currentUser?.id == userID, profileEditingGeneration == generation, !requestSafetyCircuitIsOpen else { throw CancellationError() }
        cacheProfileCollectible(product)
        profileDetailedProductIDs.insert(id)
        return product
    }

    internal func cacheProfileCollectible(_ product: ProfileCollectibleProductDTO) {
        // Variant groups may reuse their base variant's SKU. Resolve the concrete
        // variant first so an equipped item always retains its actual artwork.
        profileCollectibleProducts[product.skuID] = product
        for variant in product.variants ?? [] { cacheProfileCollectible(variant) }
        for item in product.items ?? [] {
            guard let effect = item.effect else { continue }
            if profileEffects == nil { profileEffects = [:] }
            if let id = effect.id { profileEffects?[id] = effect }
            if let sku = effect.skuID { profileEffects?[sku] = effect }
        }
    }

    func profileAvatarHistory() async throws -> [ProfileAvatarHistoryEntry] {
        guard let userID = currentUser?.id else { throw ChatProviderError.unauthenticated }
        let generation = profileEditingGeneration
        let response: ProfileAvatarHistoryDTO = try await request("/users/@me/avatars")
        try Task.checkCancellation()
        guard currentUser?.id == userID, profileEditingGeneration == generation, !requestSafetyCircuitIsOpen else { throw CancellationError() }
        return try response.domain(for: userID)
    }

    func deleteProfileAvatarHistoryEntry(id: String) async throws {
        guard currentUser != nil else { throw ChatProviderError.unauthenticated }
        guard UInt64(id) != nil else { throw ChatProviderError.invalidRequest("Invalid archived avatar identifier.") }
        try await requestEmpty("/users/@me/avatars/\(id)", method: "DELETE")
    }

    internal func resetProfileEditingState() {
        profileEditingGeneration &+= 1
        memberPresentationRevisions = [:]
        relationshipRevisions = [:]
        privateChannelRevisions = [:]
        profileSaveID = nil
        invalidateSavedProfilePresentation()
        profileEditingResponses = [:]
        profileWidgetCatalogues = [:]
        profileWidgetConfigurations = [:]
        profileWidgetIdentities = [:]
        invalidateProfileWidgetConnections()
        profileWidgetGameDetails = [:]
        profileSimilarGameIDs = [:]
        profileGameAnnouncementCache = [:]
        profileWidgetGameSearches = [:]
        profileWidgetGameSearchFailures = [:]
        for task in profileWidgetGameSearchTasks.values { task.cancel() }
        profileWidgetGameSearchTasks = [:]
        profileDeveloperMode = false
        profileStatusSettings = nil
        profileStatusSettingsDataVersion = nil
        profileDeveloperSettingsDataVersion = nil
        guildLayoutDataVersion = nil
        inboxSettingsFieldVersions = [:]
        inboxScheduledEvents = InboxScheduledEvents()
        inboxSettingsProto = nil
        inboxSettingsSaveID = nil
        finishStatusSettingsSave()
        profileCustomStatusExpiryTask?.cancel()
        profileCustomStatusExpiryTask = nil
        profileInventoryTask?.cancel()
        profileInventoryTask = nil
        profileInventory = nil
        for task in collectibleProductTasks.values { task.cancel() }
        collectibleProductTasks = [:]
        profileCollectibleProducts = [:]
        profileDetailedProductIDs = []
        profileEffects = nil
    }
}
