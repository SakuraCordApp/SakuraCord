import Foundation
import SakuraCordModels

/// The first-party personal-widget rollout is supplied in READY.apex_experiments.
/// It is independent of Nitro; an absent, unknown, or eligibility-only assignment
/// must not grant access. No locally fabricated experiment assignment is used.
struct ProfileApexAssignmentsDTO: Decodable, Sendable {
    struct Evaluation: Decodable, Sendable {
        var assignments: [Assignment]
    }

    struct Assignment: Decodable, Sendable {
        var nameHash: UInt32
        var variantID: Int?
        var flags: Int

        init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            nameHash = try values.decode(UInt32.self)
            variantID = try values.decodeIfPresent(Int.self)
            flags = values.isAtEnd ? 0 : try values.decodeIfPresent(Int.self) ?? 0
        }
    }

    var assignments: [String: [String: Evaluation]]

    func widgetEligibility(for user: User) -> ProfileWidgetEligibility {
        // Official stable607562 module465318: 2026-07-personal-widget.
        let personalWidgetHash: UInt32 = 2_369_760_879
        let assignment = assignments["1"]?[user.id.description]?.assignments.first {
            $0.nameHash == personalWidgetHash
        }
        let variant = assignment.flatMap { value -> Int? in
            // Apex UseAsEligibility is bit 3. Such assignments do not enable the feature.
            guard value.flags & 8 == 0 else { return nil }
            return value.variantID
        }
        return ProfileWidgetEligibility(
            hasFullNitro: user.premiumType == DiscordPremiumType.nitro,
            hasPersonalWidgetAccess: variant == 1 || variant == 2,
            showsPersonalWidgetCreateEntrypoint: variant == 2
        )
    }
}
