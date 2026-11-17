import Foundation

/// Resolves an explicit draft without modifying its saved source or inventing
/// server overrides from inherited values. Views render the resulting UserProfile.
public enum ProfileDraftProjection {
    public static func resolve(
        snapshot: ProfileEditingSnapshot,
        changes: ProfileEditChanges,
        inventory: ProfileCollectibleInventory?,
        avatarUploadURL: URL? = nil,
        bannerUploadURL: URL? = nil,
        serverTag: PrimaryGuildIdentity? = nil
    ) -> UserProfile {
        var result = snapshot.presentation
        if let widgets = changes.widgets { result.widgets = widgets }
        let fallback = snapshot.scope.guildID == nil ? nil : snapshot.mainPresentation
        applyIdentity(changes.identity, to: &result, fallback: fallback, avatarUploadURL: avatarUploadURL)
        applyMetadata(changes.metadata, to: &result, fallback: fallback,
                      mainPresentation: snapshot.mainPresentation, bannerUploadURL: bannerUploadURL)
        applyIdentityCosmetics(changes.identity, to: &result, fallback: fallback, inventory: inventory)
        applyProfileCollectibles(changes.metadata.collectibleSKUIDs, to: &result, fallback: fallback, inventory: inventory)
        switch changes.serverTag {
        case .unchanged: break
        case .clear: result.user.primaryGuild = nil
        case .set: result.user.primaryGuild = serverTag
        }
        return result
    }

    private static func applyIdentity(
        _ changes: ProfileIdentityChanges, to result: inout UserProfile,
        fallback: UserProfile?, avatarUploadURL: URL?
    ) {
        result.displayName = text(
            changes.name, saved: result.displayName,
            fallback: fallback?.displayName ?? result.user.username
        ) ?? result.user.username
        result.user.displayName = result.displayName
        switch changes.avatar {
        case .unchanged: break
        case .clear: result.avatarURL = fallback?.avatarURL ?? result.user.defaultAvatarURL
        case let .set(.history(entry)): result.avatarURL = avatarUploadURL ?? entry.cropImageURL
        case .set(.upload): result.avatarURL = avatarUploadURL ?? result.avatarURL
        }
        result.user.avatarURL = result.avatarURL
    }

    private static func applyMetadata(
        _ changes: ProfileMetadataChanges, to result: inout UserProfile,
        fallback: UserProfile?, mainPresentation: UserProfile, bannerUploadURL: URL?
    ) {
        switch changes.banner {
        case .unchanged: break
        case .clear: result.bannerURL = fallback?.bannerURL
        case .set: result.bannerURL = bannerUploadURL
        }
        result.bio = text(changes.bio, saved: result.bio, fallback: fallback?.bio)
        result.pronouns = text(changes.pronouns, saved: result.pronouns, fallback: fallback?.pronouns)
        switch changes.accentColor {
        case .unchanged: break
        case .clear: result.accentHex = fallback?.accentHex
        case let .set(color): result.accentHex = color
        }
        switch changes.themeColors {
        case .unchanged: break
        case .clear: result.themeHexes = fallback?.themeHexes ?? []
        case let .set(colors):
            if let primary = colors.primary, let accent = colors.accent { result.themeHexes = [primary, accent] } else { result.themeHexes = mainPresentation.themeHexes }
        }
    }

    private static func applyIdentityCosmetics(
        _ changes: ProfileIdentityChanges, to result: inout UserProfile,
        fallback: UserProfile?, inventory: ProfileCollectibleInventory?
    ) {
        switch changes.decorationSKUID {
        case .unchanged: break
        case .clear: result.user.avatarDecorationURL = fallback?.user.avatarDecorationURL
        case let .set(id):
            if case let .avatarDecoration(url) = inventory?.item(id: id)?.artwork {
                result.user.avatarDecorationURL = url
            }
        }
        switch changes.nameplateSKUID {
        case .unchanged: break
        case .clear: result.user.nameplate = fallback?.user.nameplate
        case let .set(id):
            if case let .nameplate(nameplate) = inventory?.item(id: id)?.artwork { result.user.nameplate = nameplate }
        }
        switch changes.displayNameStyle {
        case .unchanged: break
        case .clear: result.user.displayNameStyle = fallback?.user.displayNameStyle
        case let .set(style): result.user.displayNameStyle = style
        }
    }

    private static func applyProfileCollectibles(
        _ change: ProfileChange<[String]>, to result: inout UserProfile,
        fallback: UserProfile?, inventory: ProfileCollectibleInventory?
    ) {
        switch change {
        case .unchanged: break
        case .clear:
            result.effect = fallback?.effect
            result.frame = fallback?.frame
        case let .set(ids):
            result.effect = fallback?.effect
            result.frame = fallback?.frame
            for id in ids {
                switch inventory?.item(id: id)?.artwork {
                case let .effect(effect): result.effect = effect
                case let .frame(frame): result.frame = frame
                default: break
                }
            }
        }
    }

    private static func text(_ change: ProfileChange<String>, saved: String?, fallback: String?) -> String? {
        switch change {
        case .unchanged: saved
        case .clear: fallback
        case let .set(value): value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
        }
    }
}
