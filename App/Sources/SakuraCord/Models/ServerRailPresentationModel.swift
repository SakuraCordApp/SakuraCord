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
}

@Observable
final class ServerRailDirectMessageEntry: Identifiable {
    let id: ChannelID
    var channel: Channel
    var isSelected = false

    init(channel: Channel) {
        id = channel.id
        self.channel = channel
    }
}

/// Owns the rail's stable identity graph. Layout changes replace `items`, while
/// ordinary guild, unread, selection, and notification updates mutate only the
/// affected leaf entries. This prevents unrelated loading publications from
/// diffing or rebuilding the complete rail.
@Observable
final class ServerRailPresentationStore {
    var items: [ServerRailPresentationItem] = []
    var directMessages: [ServerRailDirectMessageEntry] = []
    let home = ServerRailHomeEntry()
    private(set) var orderedNavigationGuildIDs: [GuildID] = []
    private(set) var navigationGuildIDs: Set<GuildID> = []

    @ObservationIgnored private var layoutGuildIDs: [GuildID] = []
    @ObservationIgnored private var availableGuildIDs: Set<GuildID> = []

    @ObservationIgnored private var guildEntriesByID:
        [GuildID: ServerRailGuildEntry] = [:]
    @ObservationIgnored private var folderEntriesByID:
        [GuildRailItem.RailIdentifier: ServerRailFolderEntry] = [:]
    @ObservationIgnored private var folderEntriesByGuildID:
        [GuildID: [ServerRailFolderEntry]] = [:]
    @ObservationIgnored private var selectedGuildID: GuildID?
    @ObservationIgnored private var selectedChannelID: ChannelID?
    @ObservationIgnored private var directMessageEntriesByID:
        [ChannelID: ServerRailDirectMessageEntry] = [:]

    func updateDirectMessages(
        _ channels: [Channel],
        unacknowledgedChannelIDs: Set<ChannelID>
    ) {
        let conversations = channels.filter {
            ($0.kind == .directMessage || $0.kind == .groupDirectMessage)
                && $0.messageRequest == nil
                && unacknowledgedChannelIDs.contains($0.id)
        }
        var nextEntries: [ServerRailDirectMessageEntry] = []
        nextEntries.reserveCapacity(conversations.count)
        var nextEntriesByID: [ChannelID: ServerRailDirectMessageEntry] = [:]
        nextEntriesByID.reserveCapacity(conversations.count)

        for channel in conversations {
            let entry = directMessageEntriesByID[channel.id]
                ?? ServerRailDirectMessageEntry(channel: channel)
            if entry.channel != channel {
                entry.channel = channel
            }
            entry.isSelected = selectedGuildID == nil && selectedChannelID == channel.id
            nextEntries.append(entry)
            nextEntriesByID[channel.id] = entry
        }

        directMessageEntriesByID = nextEntriesByID
        refreshHomeSelection()
        if directMessages.map(\.id) != nextEntries.map(\.id) {
            directMessages = nextEntries
        }
    }

    func updateLayout(_ layout: [GuildRailItem]) {
        layoutGuildIDs = layout.flatMap { item -> [GuildID] in
            switch item {
            case let .guild(id): [id]
            case let .folder(folder): folder.guildIDs
            }
        }
        refreshNavigationGuilds()
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

    func updateAvailableGuildIDs(_ ids: Dictionary<GuildID, Guild>.Keys) {
        let available = Set(ids)
        guard availableGuildIDs != available else { return }
        availableGuildIDs = available
        refreshNavigationGuilds()
    }

    private func refreshNavigationGuilds() {
        let ordered = layoutGuildIDs.filter { availableGuildIDs.contains($0) }
        guard orderedNavigationGuildIDs != ordered else { return }
        orderedNavigationGuildIDs = ordered
        navigationGuildIDs = Set(ordered)
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

    func updateSelection(_ guildID: GuildID?, channelID: ChannelID?) {
        guard selectedGuildID != guildID || selectedChannelID != channelID else { return }
        let previousGuildID = selectedGuildID
        let previousChannelID = selectedChannelID
        selectedGuildID = guildID
        selectedChannelID = channelID
        refreshHomeSelection()

        for id in [previousChannelID, channelID].compactMap({ $0 }) {
            directMessageEntriesByID[id]?.isSelected =
                guildID == nil && id == channelID
        }

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

    private func refreshHomeSelection() {
        home.isSelected = selectedGuildID == nil
            && selectedChannelID.flatMap { directMessageEntriesByID[$0] } == nil
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
    func refreshServerRailSelection() {
        serverRailPresentation.updateSelection(
            selectedGuildID,
            channelID: selectedChannelID
        )
    }

    func refreshServerRailDirectMessages(replacing previous: BootstrapSnapshot?) {
        guard previous?.channels != snapshot?.channels else { return }
        refreshServerRailDirectMessages()
    }

    func refreshServerRailDirectMessages() {
        serverRailPresentation.updateDirectMessages(
            snapshot?.channels ?? [],
            unacknowledgedChannelIDs: readState.unacknowledgedDirectMessageChannelIDs()
        )
    }

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

    func moveServerRailItems(
        _ sources: [GuildRailItem.RailIdentifier],
        to destination: GuildRailDestination
    ) {
        editServerRail(serverRailItems.moving(sources, to: destination))
    }

    /// Dropping one server onto another makes a folder of the two. Like the
    /// first-party client, the folder gets a random unused 32-bit identifier.
    func combineServerRailGuild(_ source: GuildID, onto target: GuildID) {
        var folderID: Int64
        repeat {
            folderID = Int64(UInt32.random(in: 0 ... .max))
        } while serverRailItems.contains { $0.id == .folder(folderID) }
        editServerRail(serverRailItems.combining(source, onto: target, folderID: folderID))
    }

    func updateServerFolder(_ id: Int64, name: String?, colorHex: UInt32?) {
        editServerRail(serverRailItems.updatingFolder(id, name: name, colorHex: colorHex))
    }

    func markServerFolderRead(_ guildIDs: [GuildID]) {
        guildIDs.forEach(markGuildRead)
    }

    /// Shows an edited rail immediately and hands it to the provider, which
    /// owns saving it and reverting a rejected save.
    private func editServerRail(_ edited: [GuildRailItem]) {
        let previous = serverRailItems
        guard edited != previous else { return }
        // Only the rail changes now. The account-wide refresh that follows a
        // layout change waits until the rail has settled, so it cannot stall
        // the animation.
        serverRailItems = edited
        let session = accountSession()
        let previousTask = serverRailLayoutTask
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, isCurrentAccountSession(session), serverRailItems == edited else { return }
            applyServerRailLayout(edited)
        }
        serverRailLayoutTask = Task { [weak self] in
            await previousTask?.value
            guard let self, isCurrentAccountSession(session) else { return }
            do {
                try await session.provider.updateGuildRailLayout(edited)
            } catch {
                guard isCurrentAccountSession(session) else { return }
                if serverRailItems == edited { applyServerRailLayout(previous) }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyServerRailLayout(_ items: [GuildRailItem]) {
        guard let guilds = snapshot?.guilds else { return }
        let guildsByID = Dictionary(guilds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let railGuildIDs = items.flattenedGuildIDs
        let placed = Set(railGuildIDs)
        consumeGuildLayoutChanged(
            guilds: guilds.filter { !placed.contains($0.id) } + railGuildIDs.compactMap { guildsByID[$0] },
            railItems: items
        )
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
