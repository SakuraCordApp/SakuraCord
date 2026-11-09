import SakuraCordModels
import SwiftUI

struct ProfileGameDetails: View {
    let metadata: ProfileGameMetadata
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: ProfileGameMetrics.sectionSpacing) {
            if !stores.isEmpty {
                ProfileGameSection("Available On") {
                    ProfileGameGroup {
                        ForEach(stores) { store in
                            ProfileGameRow(url: store.url) {
                                ProfileGameBrandIcon(category: store.category)
                                Text(ProfileGameLabels.websites[store.category] ?? "Store").font(.interfaceSystem(size: 14, weight: .medium))
                                Spacer(minLength: InterfaceScale.metric(8))
                                Image(systemName: "arrow.up.right").font(.interfaceSystem(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .help(store.url.host ?? "")
                        }
                    }
                }
            }
            reviews
            if !details.isEmpty {
                ProfileGameSection("Details") {
                    ProfileGameGroup {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                            ProfileGameRow {
                                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                                    Text(detail.title).font(.interfaceSystem(size: 12)).foregroundStyle(.secondary)
                                    Text(detail.value).font(.interfaceSystem(size: 13, weight: .medium)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            if !links.isEmpty {
                ProfileGameSection("Links") {
                    HStack(spacing: InterfaceScale.metric(8)) {
                        ForEach(links, id: \.category) { site in
                            Button { openURL(site.url) } label: {
                                ProfileGameBrandIcon(category: site.category, size: 16).profileGameActionLabel(isIcon: true)
                            }
                            .buttonStyle(.plain)
                            .profileGameAction(.secondary)
                            .help(ProfileGameLabels.websites[site.category] ?? site.url.host ?? "")
                            .accessibilityLabel(ProfileGameLabels.websites[site.category] ?? "Website")
                        }
                    }
                }
            }
        }
    }

    private var stores: [ProfileGameWebsite] {
        let steam = metadata.steamURL.map { [ProfileGameWebsite(category: 0, url: $0)] } ?? []
        return steam + metadata.websites.filter { ProfileGameLabels.storeCategories.contains($0.category) }
    }

    private var links: [ProfileGameWebsite] {
        ProfileGameLabels.websiteOrder.compactMap { category in metadata.websites.first { $0.category == category } }
    }

    private var details: [(title: LocalizedStringResource, value: String)] {
        [
            ("Developer", metadata.developers.joined(separator: ", ")),
            ("Publisher", metadata.publishers.joined(separator: ", ")),
            ("Release Date", metadata.releaseDate?.formatted(date: .long, time: .omitted) ?? ""),
            ("Genres", ProfileGameLabels.genres(metadata.genres)),
            ("Platforms", ProfileGameLabels.platforms(metadata.platforms)),
        ].filter { !$0.1.isEmpty }
    }

    @ViewBuilder private var reviews: some View {
        let steamURL = metadata.isRetiredFromSteam ? nil : metadata.steamURL
        if metadata.criticReviews != nil || steamURL != nil {
            ProfileGameSection("Reviews") {
                ProfileGameGroup {
                    if let url = steamURL {
                        let steam = metadata.steamReviews
                        let showsRecent = (steam?.recentCount ?? 0) >= 10
                        if showsRecent {
                            steamReview("Recent", rating: steam?.recentRating, count: steam?.recentCount, recent: true, url: url)
                        }
                        let localized = steam?.localizedRating != nil && (steam?.localizedCount ?? 0) >= 200 && (steam?.count ?? 0) >= 2000
                        steamReview(localized ? "English" : "All Time", rating: localized ? steam?.localizedRating : steam?.rating,
                                    count: localized ? steam?.localizedCount : steam?.count, recent: false, url: url)
                    }
                    if let critic = metadata.criticReviews {
                        ProfileGameRow(url: critic.url) {
                            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                                Text("OpenCritic").font(.interfaceSystem(size: 12)).foregroundStyle(.secondary)
                                Text(ProfileGameLabels.criticTiers[critic.tier] ?? "").font(.interfaceSystem(size: 13, weight: .semibold))
                            }
                            Spacer(minLength: InterfaceScale.metric(8))
                            if critic.rating > 0, (critic.count ?? 0) > 0 {
                                ProfileGameCriticScore(rating: critic.rating, tier: critic.tier)
                            }
                        }
                    }
                }
            }
        }
    }

    private func steamReview(_ title: LocalizedStringResource, rating: Double?, count: Int?, recent: Bool, url: URL) -> some View {
        ProfileGameRow(url: url) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                HStack(spacing: InterfaceScale.metric(4)) {
                    ProfileGameBrandIcon(category: 0, size: 12)
                    Text(title)
                }
                .font(.interfaceSystem(size: 12)).foregroundStyle(.secondary)
                Text(ProfileGameLabels.steamRating(rating, count: count, recent: recent))
                    .font(.interfaceSystem(size: 13, weight: .semibold))
                    .foregroundStyle(steamTone(rating: rating, count: count))
            }
            Spacer(minLength: InterfaceScale.metric(8))
            if let count, count >= 10 {
                Text("\(count.formatted(.number.notation(.compactName))) reviews").font(.interfaceSystem(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    .help("\(count.formatted()) reviews")
            }
        }
    }

    /// Steam's own review colours, darkened for legibility on light surfaces.
    private func steamTone(rating: Double?, count: Int?) -> Color {
        let dark = colorScheme == .dark
        guard let rating, let count, count >= 10 else { return .secondary }
        if rating >= 70 { return Color(hex: dark ? 0x66C0F4 : 0x1A78B8) }
        if rating >= 40 { return Color(hex: dark ? 0xC9A85A : 0x8A6D1F) }
        return Color(hex: dark ? 0xE8775A : 0xB5452A)
    }
}

/// A grouped list surface, matching the profile widget cards. Rows highlight
/// inset from its edge, like a native list.
struct ProfileGameGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .padding(ProfileGameMetrics.groupInset)
            .background(.primary.opacity(0.04), in: .rect(cornerRadius: ProfileGameMetrics.cardRadius))
    }
}

struct ProfileGameRow<Content: View>: View {
    var url: URL?
    @ViewBuilder let content: () -> Content
    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ProfileGameMetrics.cardRadius - ProfileGameMetrics.groupInset)
        let row = HStack(spacing: InterfaceScale.metric(10)) { content() }
            .padding(.horizontal, InterfaceScale.metric(10))
            .padding(.vertical, InterfaceScale.metric(8))
            .frame(minHeight: InterfaceScale.metric(40))
            .background(.primary.opacity(isHovered ? 0.06 : 0), in: shape)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        if let url {
            Button { openURL(url) } label: { row }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onModalHover { isHovered = $0 }
        } else {
            row
        }
    }
}

struct ProfileGameBrandIcon: View {
    let category: Int
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let brand = ProfileGameLabels.brands[category], let image = ConnectionBrand.image(for: brand, colorScheme: colorScheme) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: category == 23 ? "cube.fill" : "globe").resizable().scaledToFit().fontWeight(.medium)
            }
        }
        .frame(width: InterfaceScale.metric(size), height: InterfaceScale.metric(size))
        .accessibilityHidden(true)
    }
}

private struct ProfileGameCriticScore: View {
    let rating: Double
    let tier: Int

    var body: some View {
        let color = ProfileGameLabels.criticTierColors[tier] ?? .secondary
        Text(Int(rating.rounded(.down)).formatted())
            .font(.interfaceSystem(size: 13, weight: .bold)).monospacedDigit()
            .frame(width: InterfaceScale.metric(34), height: InterfaceScale.metric(34))
            .background(color.opacity(0.16), in: .circle)
            .overlay { Circle().strokeBorder(color, lineWidth: 2) }
    }
}

enum ProfileGameLabels {
    static let websiteOrder = [1, 4, 5, 8, 9, 19, 14, 6]
    static let websites = [
        0: "Steam", 1: "Website", 4: "Facebook", 5: "X", 6: "Twitch", 8: "Instagram", 9: "YouTube", 14: "Reddit",
        16: "Epic Games", 19: "Bluesky", 20: "Battle.net", 21: "Riot Games", 22: "Roblox", 23: "Minecraft"
    ]
    static let storeCategories: Set = [16, 20, 21, 22, 23]
    /// Connection icon keys. Category 0 stands for Steam, which arrives as its own URL.
    static let brands = [
        0: "steam", 4: "facebook", 5: "twitter", 6: "twitch", 8: "instagram", 9: "youtube", 14: "reddit",
        16: "epicgames", 19: "bluesky", 20: "battlenet", 21: "riotgames", 22: "roblox"
    ]
    static let criticTiers = [1: "Mighty", 2: "Strong", 3: "Fair", 4: "Weak"]
    static let criticTierColors = [1: Color(hex: 0xFC430A), 2: Color(hex: 0xB43CC8), 3: Color(hex: 0x4AA1CE), 4: Color(hex: 0x80B06A)]

    static func genres(_ values: [Int]) -> String { values.compactMap { genreNames[$0] }.joined(separator: ", ") }
    static func platforms(_ values: [Int]) -> String {
        let desktop = values.contains(0) || values.contains(6) || values.contains(7)
        return ([desktop ? "Desktop" : nil] + values.compactMap { [1: "Xbox", 2: "PlayStation", 5: "Nintendo"][$0] }).compactMap { $0 }.joined(separator: ", ")
    }

    static func steamRating(_ rating: Double?, count: Int?, recent: Bool) -> String {
        guard let rating, let count, count >= 10 else { return "No user reviews" }
        if rating >= 80 {
            if !recent, count < 50 { return "Positive" }
            return count < (recent ? 100 : 500) || rating < 95 ? "Very Positive" : "Overwhelmingly Positive"
        }
        if rating >= 70 { return "Mostly Positive" }
        if rating >= 40 { return "Mixed" }
        if rating >= 20 { return "Mostly Negative" }
        if !recent, count < 50 { return "Negative" }
        return count < (recent ? 100 : 500) ? "Very Negative" : "Overwhelmingly Negative"
    }

    private static let genreNames: [Int: String] = [
        1: "Action",
        2: "Action RPG",
        3: "Beat 'Em Up/Brawler",
        4: "Hack and Slash",
        5: "Platformer",
        6: "Stealth",
        7: "Survival",
        8: "Adventure",
        9: "Action-Adventure",
        10: "Metroidvania",
        11: "Open-world",
        12: "Psychological Horror",
        13: "Sandbox",
        14: "Survival Horror",
        15: "Visual Novel",
        16: "Driving/Racing",
        17: "Vehicular Combat",
        18: "Massively Multiplayer",
        19: "MMORPG",
        20: "Role-Playing",
        21: "Dungeon Crawler",
        22: "Roguelike",
        23: "Shooter",
        24: "Light-Gun",
        25: "Shoot 'Em Up",
        26: "FPS",
        27: "Dual-Joystick Shooter",
        28: "Simulation",
        29: "Flight Simulator",
        30: "Train Simulator",
        31: "Life Simulator",
        32: "Fishing",
        33: "Sports",
        34: "Baseball",
        35: "Basketball",
        36: "Billiards",
        37: "Bowling",
        38: "Boxing",
        39: "Football",
        40: "Golf",
        41: "Hockey",
        42: "Skateboarding/Skating",
        43: "Snowboarding/Skiing",
        44: "Football",
        45: "Athletics",
        46: "Surfing/Wakeboarding",
        47: "Wrestling",
        48: "Strategy",
        49: "4X",
        50: "Artillery",
        51: "RTS",
        52: "Tower Defence",
        53: "Turn-Based Strategy",
        54: "Wargame",
        55: "MOBA",
        56: "Fighting",
        57: "Puzzle",
        58: "Card Game",
        59: "Education",
        60: "Fitness",
        61: "Gambling",
        62: "Music/Rhythm",
        63: "Party/Mini-Game",
        64: "Pinball",
        65: "Trivia/Board Game",
        66: "Tactical",
        67: "Indie",
        68: "Arcade",
        69: "Point and Click",
    ]
}
