import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func validateProfileChanges(_ changes: ProfileEditChanges, in scope: ProfileEditingScope, user: User) throws {
        func checkLength(_ change: ProfileChange<String>, maximum: Int, field: String) throws {
            if case let .set(value) = change, value.utf16.count > maximum {
                throw ChatProviderError.invalidRequest("\(field) must be \(maximum) characters or fewer.")
            }
        }
        try checkLength(changes.identity.name, maximum: 32, field: "Display name")
        try checkLength(changes.metadata.bio, maximum: 300, field: "About Me")
        try checkLength(changes.metadata.pronouns, maximum: 40, field: "Pronouns")
        let hasFullNitro = user.premiumType == DiscordPremiumType.nitro
        try validateProfileNitroAccess(changes, in: scope, hasFullNitro: hasFullNitro)
        try validateProfileImages(changes, user: user, hasFullNitro: hasFullNitro)
        try validateProfileNameStyle(changes.identity.displayNameStyle)
        if case let .set(colors) = changes.metadata.themeColors {
            guard [colors.primary, colors.accent].compactMap({ $0 }).allSatisfy({ $0 <= 0xFF_FFFF }) else {
                throw ChatProviderError.invalidRequest("Profile colors must be sRGB colors.")
            }
        }
        try validateProfileCollectibles(changes, hasFullNitro: hasFullNitro)
    }

    private func validateProfileNitroAccess(
        _ changes: ProfileEditChanges, in scope: ProfileEditingScope, hasFullNitro: Bool
    ) throws {
        if !hasFullNitro {
            if case .set = changes.metadata.banner { throw nitroProfileError() }
            if case .set = changes.metadata.themeColors { throw nitroProfileError() }
            if case .set = changes.identity.displayNameStyle { throw nitroProfileError() }
            if scope.guildID != nil {
                if case .set = changes.identity.avatar { throw nitroProfileError() }
                if case .set = changes.metadata.bio { throw nitroProfileError() }
                if case .set = changes.metadata.pronouns { throw nitroProfileError() }
            }
        }
    }

    private func validateProfileImages(_ changes: ProfileEditChanges, user: User, hasFullNitro: Bool) throws {
        if case let .set(.upload(image)) = changes.identity.avatar {
            try validateProfileImage(image)
            if image.isAnimated || image.mediaType == "image/gif", user.premiumType != DiscordPremiumType.nitroClassic, !hasFullNitro {
                throw nitroProfileError()
            }
        }
        if case let .set(.history(entry)) = changes.identity.avatar,
           entry.storageHash.hasPrefix("a_"), user.premiumType != DiscordPremiumType.nitroClassic, !hasFullNitro {
            throw nitroProfileError()
        }
        if case let .set(image) = changes.metadata.banner { try validateProfileImage(image) }
    }

    private func validateProfileNameStyle(_ change: ProfileChange<DisplayNameStyle>) throws {
        guard case let .set(style) = change else { return }
        guard DiscordProfileNameStyles.catalog.fonts.contains(where: { $0.id == style.fontID }),
              let effect = ProfileNameEffect(rawValue: style.effectID)
        else { throw ChatProviderError.invalidRequest("Choose a display name style from the available options.") }
        let colorCount = switch effect {
        case .gradient: 2
        case .gummy: 4
        case .prism: 5
        default: 1
        }
        let usesDefaultColor = effect == .solid && style.colors.isEmpty
        guard usesDefaultColor || style.colors.count == colorCount,
              style.colors.allSatisfy({ $0 <= 0xFF_FFFF }) else {
            throw ChatProviderError.invalidRequest("Display name colors must be sRGB colors.")
        }
    }

    private func validateProfileCollectibles(_ changes: ProfileEditChanges, hasFullNitro: Bool) throws {
        var selections: [(String, ProfileCollectibleKind?)] = []
        if case let .set(id) = changes.identity.decorationSKUID { selections.append((id, .avatarDecoration)) }
        if case let .set(id) = changes.identity.nameplateSKUID { selections.append((id, .nameplate)) }
        if case let .set(ids) = changes.metadata.collectibleSKUIDs { selections += ids.map { ($0, nil) } }
        for (id, expectedKind) in selections {
            guard let inventory = profileInventory, let item = inventory.item(id: id),
                  inventory.owns(itemID: id),
                  expectedKind.map({ item.kind == $0 }) ?? (item.kind == .effect || item.kind == .frame)
            else { throw ChatProviderError.invalidRequest("This collectible is not in your available inventory. Reopen the picker to refresh it.") }
            if !inventory.canUse(itemID: id, hasFullNitro: hasFullNitro) { throw nitroProfileError() }
        }
    }

    private func nitroProfileError() -> ChatProviderError {
        .invalidRequest("This profile customization requires Nitro.")
    }

    private func validateProfileImage(_ image: ProfileImageUpload) throws {
        guard !image.data.isEmpty,
              ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"].contains(image.mediaType)
        else { throw ChatProviderError.invalidRequest("Choose a supported profile image.") }
        if let md5 = image.originalMD5 {
            guard md5.count == 32, md5.allSatisfy(\.isHexDigit) else {
                throw ChatProviderError.invalidRequest("The original profile image digest is invalid.")
            }
        }
    }
}
