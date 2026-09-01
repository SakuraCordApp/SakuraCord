import SakuraCordModels
import SwiftUI

enum PickerSectionRailLayout {
    static let width: CGFloat = 46
    static let bookmarkSize: CGFloat = 30
    static let iconSize: CGFloat = 28
}

nonisolated enum PickerSectionGuildOrdering {
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
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .id(section.id)
    }
}
