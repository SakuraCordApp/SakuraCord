import Foundation
import SakuraCordModels

extension DiscordExperiments {
    /// The personal-widget rollout is an apex experiment independent of Nitro;
    /// an absent, unknown or eligibility-only assignment does not grant access.
    func widgetEligibility(for user: User) -> ProfileWidgetEligibility {
        let variant = apexVariant("2026-07-personal-widget")
        return ProfileWidgetEligibility(
            hasFullNitro: user.premiumType == DiscordPremiumType.nitro,
            hasPersonalWidgetAccess: variant == 1 || variant == 2,
            showsPersonalWidgetCreateEntrypoint: variant == 2
        )
    }
}
