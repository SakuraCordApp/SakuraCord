import SakuraCordModels

/// Badges SakuraCord adds to profiles whose verified GitHub connection is on a badge's list.
enum SakuraCordBadges {
    private struct Grant {
        let badge: ProfileBadge
        let imageName: String
        let githubAccountIDs: Set<String>
    }

    private static let sponsor = Grant(
        badge: ProfileBadge(id: "sakuracord_sponsor", description: "SakuraCord Sponsor"),
        imageName: "SakuraCordSponsorBadge",
        githubAccountIDs: [
            "57096215", // TheDutchSmoke
            "14123121" // charlie-hotel
        ]
    )

    /// People with at least one merged pull request.
    private static let contributor = Grant(
        badge: ProfileBadge(id: "sakuracord_contributor", description: "SakuraCord Contributor"),
        imageName: "SakuraCordContributorBadge",
        githubAccountIDs: [
            "143897379", // super-original
            "100310118", // Chefski
            "23127866", // StayBlue
            "57096215", // TheDutchSmoke
            "88049488", // Dawsson
            "172957892", // saipi-1129
            "85625843", // AyuBloom
            "156133757" // waruhachi
        ]
    )

    private static let grants = [sponsor, contributor]

    static func badges(for profile: UserProfile) -> [ProfileBadge] {
        let githubAccountIDs = Set(
            profile.connectedAccounts
                .filter { $0.type == "github" && $0.isVerified }
                .map(\.accountID)
        )
        let granted = grants
            .filter { !$0.githubAccountIDs.isDisjoint(with: githubAccountIDs) }
            .map(\.badge)
        return granted + profile.badges
    }

    static func imageName(for badge: ProfileBadge) -> String? {
        grants.first { $0.badge.id == badge.id }?.imageName
    }
}
