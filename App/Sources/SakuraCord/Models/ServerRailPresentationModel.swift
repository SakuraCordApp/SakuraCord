import Observation
import OSLog
import SakuraCordModels

struct ServerRailGuildPresentation: Equatable {
    let guild: Guild
    let notificationSettings: GuildNotificationSettings
    let isNotificationMutationPending: Bool
}

@Observable
final class ServerRailGuildEntry: Identifiable {
    let id: GuildID
    var presentation: ServerRailGuildPresentation?
    var isSelected = false

    init(id: GuildID) {
        self.id = id
    }

    @discardableResult
    func update(
        presentation: ServerRailGuildPresentation?
    ) -> Bool {
        guard self.presentation != presentation else { return false }
        self.presentation = presentation
        return true
    }
}

@Observable
final class ServerRailFolderEntry: Identifiable {
    let id: GuildRailItem.RailIdentifier
    var folder: GuildFolder
    var guildEntries: [ServerRailGuildEntry]
    var containsSelectedGuild = false
    var hasUnreadGuild = false
    var mentionCount = 0
    var previewGuilds: [Guild] = []

    init(folder: GuildFolder, guildEntries: [ServerRailGuildEntry]) {
        id = .folder(folder.id)
        self.folder = folder
        self.guildEntries = guildEntries
        refreshDerivedPresentation()
    }

    func update(
        folder: GuildFolder,
        guildEntries: [ServerRailGuildEntry]
    ) {
        if self.folder != folder {
            self.folder = folder
        }
        if self.guildEntries.map(\.id) != guildEntries.map(\.id) {
            self.guildEntries = guildEntries
        }
        refreshDerivedPresentation()
    }

    func refreshDerivedPresentation() {
        let selected = guildEntries.contains(where: \.isSelected)
        if containsSelectedGuild != selected {
            containsSelectedGuild = selected
        }

        let unread = guildEntries.contains {
            ($0.presentation?.guild.unreadCount ?? 0) > 0
        }
        if hasUnreadGuild != unread {
            hasUnreadGuild = unread
        }

        let mentions = guildEntries.reduce(into: 0) {
            $0 += $1.presentation?.guild.mentionCount ?? 0
        }
        if mentionCount != mentions {
            mentionCount = mentions
        }

        let preview = guildEntries.prefix(4).compactMap(\.presentation?.guild)
        if previewGuilds != preview {
            previewGuilds = preview
        }
    }
}

enum ServerRailPresentationItem: Identifiable {
    case guild(ServerRailGuildEntry)
    case folder(ServerRailFolderEntry)

    var id: GuildRailItem.RailIdentifier {
        switch self {
        case .guild(let entry): .guild(entry.id)
        case .folder(let entry): entry.id
        }
    }
}

@Observable
final class ServerRailHomeEntry {
    var isSelected = true
    var isUnread = false
    var mentionCount = 0
}

/// Owns the rail's stable identity graph. Layout changes replace `items`, while
/// ordinary guild, unread, selection, and notification updates mutate only the
/// affected leaf entries. This prevents unrelated loading publications from
/// diffing or rebuilding the complete rail.
@Observable
final class ServerRailPresentationStore {
    var items: [ServerRailPresentationItem] = []
    let home = ServerRailHomeEntry()

    @ObservationIgnored private var guildEntriesByID:
        [GuildID: ServerRailGuildEntry] = [:]
    @ObservationIgnored private var folderEntriesByID:
        [GuildRailItem.RailIdentifier: ServerRailFolderEntry] = [:]
    @ObservationIgnored private var folderEntriesByGuildID:
        [GuildID: [ServerRailFolderEntry]] = [:]
    @ObservationIgnored private var selectedGuildID: GuildID?

    func updateLayout(_ layout: [GuildRailItem]) {
        AppPerformanceSignposts.measureSync("ServerRailLayoutReconciliation") {
            var nextItems: [ServerRailPresentationItem] = []
            nextItems.reserveCapacity(layout.count)
            var nextFoldersByID:
                [GuildRailItem.RailIdentifier: ServerRailFolderEntry] = [:]
            nextFoldersByID.reserveCapacity(folderEntriesByID.count)
            var nextFoldersByGuildID:
                [GuildID: [ServerRailFolderEntry]] = [:]

            for item in layout {
                switch item {
                case .guild(let guildID):
                    nextItems.append(.guild(guildEntry(for: guildID)))
                case .folder(let folder):
                    let identifier = GuildRailItem.RailIdentifier.folder(folder.id)
                    let guildEntries = folder.guildIDs.map(guildEntry(for:))
                    let entry = folderEntriesByID[identifier]
                        ?? ServerRailFolderEntry(
                            folder: folder,
                            guildEntries: guildEntries
                        )
                    entry.update(folder: folder, guildEntries: guildEntries)
                    nextFoldersByID[identifier] = entry
                    for guildID in folder.guildIDs {
                        nextFoldersByGuildID[guildID, default: []].append(entry)
                    }
                    nextItems.append(.folder(entry))
                }
            }

            folderEntriesByID = nextFoldersByID
            folderEntriesByGuildID = nextFoldersByGuildID
            if items.map(\.id) != nextItems.map(\.id) {
                items = nextItems
            }
        }
    }

    func updateGuilds(
        _ guildsByID: [GuildID: Guild],
        notificationSettings: (Guild) -> GuildNotificationSettings,
        isMutationPending: (GuildID) -> Bool
    ) {
        AppPerformanceSignposts.measureSync("ServerRailGuildReconciliation") {
            var affectedFolderIDs: Set<GuildRailItem.RailIdentifier> = []
            for (guildID, entry) in guildEntriesByID {
                let presentation = guildsByID[guildID].map { guild in
                    ServerRailGuildPresentation(
                        guild: guild,
                        notificationSettings: notificationSettings(guild),
                        isNotificationMutationPending:
                            isMutationPending(guildID)
                    )
                }
                if entry.update(presentation: presentation) {
                    for folder in folderEntriesByGuildID[guildID] ?? [] {
                        affectedFolderIDs.insert(folder.id)
                    }
                }
            }

            // A bootstrap can publish guild data before its rail layout. Keep
            // entries ready so the later structural publication reuses them.
            for (guildID, guild) in guildsByID
                where guildEntriesByID[guildID] == nil
            {
                let entry = guildEntry(for: guildID)
                _ = entry.update(
                    presentation: ServerRailGuildPresentation(
                        guild: guild,
                        notificationSettings: notificationSettings(guild),
                        isNotificationMutationPending:
                            isMutationPending(guildID)
                    )
                )
            }

            for folderID in affectedFolderIDs {
                folderEntriesByID[folderID]?.refreshDerivedPresentation()
            }
        }
    }

    func updateGuild(
        _ guild: Guild?,
        id guildID: GuildID,
        notificationSettings: (Guild) -> GuildNotificationSettings,
        isMutationPending: (GuildID) -> Bool
    ) {
        let entry = guildEntry(for: guildID)
        let presentation = guild.map {
            ServerRailGuildPresentation(
                guild: $0,
                notificationSettings: notificationSettings($0),
                isNotificationMutationPending: isMutationPending(guildID)
            )
        }
        guard entry.update(presentation: presentation) else { return }
        for folder in folderEntriesByGuildID[guildID] ?? [] {
            folder.refreshDerivedPresentation()
        }
    }

    func updateSelection(_ guildID: GuildID?) {
        guard selectedGuildID != guildID else { return }
        let previousGuildID = selectedGuildID
        selectedGuildID = guildID
        home.isSelected = guildID == nil

        var affectedFolderIDs: Set<GuildRailItem.RailIdentifier> = []
        for id in [previousGuildID, guildID].compactMap({ $0 }) {
            guildEntriesByID[id]?.isSelected = id == guildID
            for folder in folderEntriesByGuildID[id] ?? [] {
                affectedFolderIDs.insert(folder.id)
            }
        }
        for folderID in affectedFolderIDs {
            folderEntriesByID[folderID]?.refreshDerivedPresentation()
        }
    }

    private func guildEntry(for guildID: GuildID) -> ServerRailGuildEntry {
        if let entry = guildEntriesByID[guildID] {
            return entry
        }
        let entry = ServerRailGuildEntry(id: guildID)
        entry.isSelected = selectedGuildID == guildID
        guildEntriesByID[guildID] = entry
        return entry
    }
}

extension AppModel {
    func replaceServerRailGuilds(_ guildsByID: [GuildID: Guild]) {
        if serverRailGuildsByID != guildsByID {
            serverRailGuildsByID = guildsByID
        }
        refreshServerRailPresentation()
    }

    func updateServerRailGuild(_ guild: Guild) {
        if serverRailGuildsByID[guild.id] != guild {
            serverRailGuildsByID[guild.id] = guild
        }
        refreshServerRailPresentation(guildID: guild.id)
    }

    func refreshServerRailPresentation(guildID: GuildID? = nil) {
        if let guildID {
            serverRailPresentation.updateGuild(
                serverRailGuildsByID[guildID],
                id: guildID,
                notificationSettings: guildNotificationSettings,
                isMutationPending: isGuildNotificationMutationPending
            )
        } else {
            serverRailPresentation.updateGuilds(
                serverRailGuildsByID,
                notificationSettings: guildNotificationSettings,
                isMutationPending: isGuildNotificationMutationPending
            )
        }
    }
}
