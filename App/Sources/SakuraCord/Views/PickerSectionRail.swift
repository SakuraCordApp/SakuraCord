import SakuraCordModels
import SwiftUI

enum PickerSectionRailLayout {
    static let width: CGFloat = 46
    static let bookmarkSize: CGFloat = 30
    static let iconSize: CGFloat = 28
}

nonisolated enum PickerSectionGuildOrdering {
    /// Unknown catalogs retain their bookmark so loading and retry remain reachable.
    /// Apply this after each picker's permission and availability policy.
    static func retainingNonemptyCatalogs<Item>(
        _ guilds: [Guild], catalogs: [GuildID: [Item]], isAvailable: (Item) -> Bool
    ) -> [Guild] {
        guilds.filter { catalogs[$0.id]?.contains(where: isAvailable) ?? true }
    }

    static func orderedGuilds(
        railItems: [GuildRailItem],
        guildsByID: [GuildID: Guild],
        fallbackGuilds: [Guild],
        currentGuildID: GuildID?
    ) -> [Guild] {
        var fallbackGuildsByID = Dictionary(
            fallbackGuilds.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        var seenGuildIDs = Set<GuildID>()
        var guilds = railItems
            .flatMap { item -> [GuildID] in
                switch item {
                case .guild(let guildID): [guildID]
                case .folder(let folder): folder.guildIDs
                }
            }
            .compactMap { guildID -> Guild? in
                guard seenGuildIDs.insert(guildID).inserted else { return nil }
                return guildsByID[guildID] ?? fallbackGuildsByID.removeValue(forKey: guildID)
            }
        guilds.append(contentsOf: fallbackGuilds.filter {
            seenGuildIDs.insert($0.id).inserted
        })

        guard let currentGuildID,
              let currentIndex = guilds.firstIndex(where: { $0.id == currentGuildID }),
              currentIndex != guilds.startIndex
        else { return guilds }

        var ordered = guilds
        let currentGuild = ordered.remove(at: currentIndex)
        ordered.insert(currentGuild, at: ordered.startIndex)
        return ordered
    }
}

struct PickerSectionBookmark<Section: Hashable & Identifiable, Content: View>: View
where Section.ID == String {
    let section: Section
    let visibleSection: Section
    let help: String
    let jump: (Section) -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        Button {
            jump(section)
        } label: {
            content()
                .frame(
                    width: PickerSectionRailLayout.iconSize,
                    height: PickerSectionRailLayout.iconSize,
                    alignment: .center
                )
                .contentShape(ConcentricRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(
            width: PickerSectionRailLayout.bookmarkSize,
            height: PickerSectionRailLayout.bookmarkSize,
            alignment: .center
        )
        .background {
            if visibleSection == section {
                ConcentricRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.13))
            } else if isHovering {
                ConcentricRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .onModalHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .id(section.id)
    }
}

/// Shared rail chrome for emoji, stickers and soundboard. Each picker supplies
/// its section order and special bookmarks; spacing and scroll policy live here.
struct PickerSectionRail<Content: View>: View {
    var scrollPosition: Binding<ScrollPosition>?
    @ViewBuilder let content: () -> Content
    @State private var localPosition = ScrollPosition(idType: String.self)

    var body: some View {
        GeometryReader { _ in
            ScrollView {
                LazyVStack(spacing: 2, content: content)
                    .scrollTargetLayout()
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollPosition(scrollPosition ?? $localPosition)
            .scrollIndicators(.never)
        }
        .frame(width: PickerSectionRailLayout.width)
    }
}

struct PickerGuildBookmarkIcon: View {
    let guild: Guild

    var body: some View {
        Group {
            if let url = guild.iconURL {
                StaticRemoteImage(url: url, maximumPixelDimension: 64)
            } else {
                Text(guild.name.prefix(2).uppercased())
                    .font(.caption.weight(.bold))
            }
        }
        .frame(width: 28, height: 28, alignment: .center)
        .background(Color.secondary.opacity(0.12))
        .clipShape(ConcentricRectangle(cornerRadius: 8, style: .continuous))
    }
}
