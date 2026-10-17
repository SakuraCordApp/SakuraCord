import AppIntents
import CoreSpotlight
import Foundation
import SakuraCordModels
import UniformTypeIdentifiers

/// A conversation belongs to one signed-in account, so Spotlight can keep
/// every saved account's conversations side by side.
nonisolated struct ConversationEntityID: Hashable, Sendable, EntityIdentifierConvertible {
    var accountID: String
    var channelID: ChannelID

    var entityIdentifierString: String {
        "\(accountID):\(channelID.description)"
    }

    static func entityIdentifier(for entityIdentifierString: String) -> ConversationEntityID? {
        guard let separator = entityIdentifierString.lastIndex(of: ":"),
              let channelID = ChannelID(String(entityIdentifierString[entityIdentifierString.index(after: separator)...]))
        else { return nil }
        return ConversationEntityID(
            accountID: String(entityIdentifierString[..<separator]),
            channelID: channelID
        )
    }
}

nonisolated struct ConversationEntity: AppEntity, IndexedEntity, Equatable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = ConversationQuery()

    var id: ConversationEntityID
    var title: String
    var subtitle: String?
    var isDirectMessage = false

    var displayString: String {
        title
    }

    var displayRepresentation: DisplayRepresentation {
        if let subtitle {
            DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: image)
        } else {
            DisplayRepresentation(title: "\(title)", image: image)
        }
    }

    /// DMs show the person's initial, channels a "#", both as SF Symbols so
    /// Spotlight and Shortcuts render them without fetching avatars.
    private var image: DisplayRepresentation.Image {
        guard isDirectMessage else {
            return DisplayRepresentation.Image(systemName: "number")
        }
        if let initial = title.first?.lowercased(), initial.count == 1,
           let scalar = initial.unicodeScalars.first, ("a" ... "z").contains(scalar)
        {
            return DisplayRepresentation.Image(systemName: "\(initial).circle.fill")
        }
        return DisplayRepresentation.Image(systemName: "person.circle.fill")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.displayName = title
        if let subtitle {
            attributes.contentDescription = subtitle
        }
        return attributes
    }
}

nonisolated struct ConversationQuery: EntityQuery, EntityStringQuery, Sendable {
    func entities(for identifiers: [ConversationEntityID]) async throws -> [ConversationEntity] {
        await Self.resolve(identifiers)
    }

    /// Saved shortcuts resolve their conversation on a cold launch, so wait for
    /// the restored workspace before looking it up. Conversations from another
    /// saved account resolve to a placeholder so opening one can switch accounts.
    @MainActor
    private static func resolve(_ identifiers: [ConversationEntityID]) async -> [ConversationEntity] {
        let model = await IntentModelAccess.workspaceModel()
        let catalog = Dictionary(uniqueKeysWithValues: IntentConversationCatalog.current().map { ($0.id, $0) })
        let savedAccountIDs = Set(model?.savedAccounts.map(\.accountID) ?? [])
        return identifiers.compactMap { identifier in
            if let entity = catalog[identifier] {
                return entity
            }
            guard identifier.accountID != model?.activeAccountID,
                  savedAccountIDs.contains(identifier.accountID)
            else { return nil }
            return IntentConversationCatalog.lastIndexedEntity(for: identifier)
                ?? ConversationEntity(id: identifier, title: "Conversation")
        }
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        await MainActor.run {
            IntentConversationCatalog.recent(limit: 20)
        }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return await MainActor.run {
            guard !query.isEmpty else {
                return IntentConversationCatalog.recent(limit: 20)
            }
            return IntentConversationCatalog.current().filter {
                $0.title.localizedCaseInsensitiveContains(query)
            }.prefix(20).map { $0 }
        }
    }
}

@MainActor
enum IntentConversationCatalog {
    private static var spotlightIndexTask: Task<Void, Never>?
    private static var pendingSignature: (accountID: String, entities: [ConversationEntity])?
    /// What Spotlight holds for each account indexed during this launch. An
    /// account missing here has an unknown baseline and is rebuilt once.
    private static var indexedEntitiesByAccount: [String: [ConversationEntityID: ConversationEntity]] = [:]

    private static func spotlightDomain(for accountID: String) -> String {
        "conversations.\(accountID)"
    }

    static func lastIndexedEntity(for identifier: ConversationEntityID) -> ConversationEntity? {
        indexedEntitiesByAccount[identifier.accountID]?[identifier]
    }

    /// Mirrors the active account's conversations into Spotlight. Coalesced
    /// because snapshots change in bursts during bootstrap, and only the
    /// difference from what is already indexed is written. Other accounts'
    /// items stay put; they are removed only when that account is removed.
    static func scheduleSpotlightIndex(for model: AppModel) {
        guard isIndexingEnabled(for: model) else { return }
        guard model.sessionState == .workspace, model.snapshot != nil,
              let accountID = model.activeAccountID
        else {
            spotlightIndexTask?.cancel()
            spotlightIndexTask = nil
            pendingSignature = nil
            return
        }
        let entities = current().sorted { $0.id.channelID.description < $1.id.channelID.description }
        if let pendingSignature, pendingSignature.accountID == accountID, pendingSignature.entities == entities {
            return
        }
        pendingSignature = (accountID, entities)
        let session = model.accountSession()
        spotlightIndexTask?.cancel()
        spotlightIndexTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard model.isCurrentAccountSession(session), model.activeAccountID == accountID else {
                pendingSignature = nil
                return
            }
            let index = CSSearchableIndex.default()
            let domain = spotlightDomain(for: accountID)
            let baseline = indexedEntitiesByAccount[accountID]
            let previous = baseline ?? [:]
            let latest = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
            if baseline != nil {
                let removed = previous.keys.filter { latest[$0] == nil }
                if !removed.isEmpty {
                    try? await index.deleteAppEntities(identifiedBy: removed, ofType: ConversationEntity.self)
                }
            } else {
                try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            }
            guard !Task.isCancelled, model.isCurrentAccountSession(session) else {
                // Spotlight may now hold a partial update; rebuild this account.
                indexedEntitiesByAccount[accountID] = nil
                pendingSignature = nil
                return
            }
            let changed = entities.filter { previous[$0.id] != $0 }
            if !changed.isEmpty {
                let items = changed.map { entity in
                    let item = CSSearchableItem(appEntity: entity)
                    item.domainIdentifier = domain
                    return item
                }
                try? await index.indexSearchableItems(items)
            }
            indexedEntitiesByAccount[accountID] = latest
        }
    }

    /// Signing an account out or removing it drops only that account's items.
    static func removeSpotlightItems(forAccount accountID: String, model: AppModel) {
        guard isIndexingEnabled(for: model) else { return }
        if pendingSignature?.accountID == accountID {
            spotlightIndexTask?.cancel()
            spotlightIndexTask = nil
            pendingSignature = nil
        }
        indexedEntitiesByAccount[accountID] = nil
        let domain = spotlightDomain(for: accountID)
        Task {
            try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        }
    }

    private static func isIndexingEnabled(for model: AppModel) -> Bool {
        SakuraCordRuntimeModelHolder.shared.model === model
            && model.launchMode == .normal
            && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
    }

    /// The conversation the workspace is showing, for on-screen context.
    static func onScreenEntity(for model: AppModel) -> ConversationEntity? {
        guard let channel = model.selectedChannel, channel.kind != .unknown,
              model.activeAccountID != nil
        else { return nil }
        return entity(for: channel, model: model)
    }

    static func current() -> [ConversationEntity] {
        guard let model = SakuraCordRuntimeModelHolder.shared.model else {
            return []
        }
        var seen = Set<ChannelID>()
        var result: [ConversationEntity] = []
        guard model.activeAccountID != nil else { return [] }
        // visibleChannels is already permission-filtered; raw snapshot channels
        // must pass the same view check the forward picker uses.
        let snapshotChannels = (model.snapshot?.channels ?? []).filter {
            model.canSearchForwardDestination($0)
        }
        for channel in model.visibleChannels + snapshotChannels {
            guard channel.kind != .unknown,
                  seen.insert(channel.id).inserted
            else { continue }
            result.append(entity(for: channel, model: model))
        }
        return result
    }

    static func recent(limit: Int) -> [ConversationEntity] {
        guard let model = SakuraCordRuntimeModelHolder.shared.model else {
            return []
        }
        let catalog = Dictionary(uniqueKeysWithValues: current().map { ($0.id, $0) })
        guard let accountID = model.activeAccountID else { return [] }
        var ordered: [ConversationEntity] = []
        var seen = Set<ConversationEntityID>()
        if let selected = model.selectedChannelID,
           let entity = catalog[ConversationEntityID(accountID: accountID, channelID: selected)]
        {
            ordered.append(entity)
            seen.insert(entity.id)
        }
        for channelID in model.forwardDestinationHistory {
            let identifier = ConversationEntityID(accountID: accountID, channelID: channelID)
            guard seen.insert(identifier).inserted,
                  let entity = catalog[identifier]
            else { continue }
            ordered.append(entity)
        }
        ordered.append(
            contentsOf: catalog.values
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.title < $1.title }
        )
        return Array(ordered.prefix(limit))
    }

    private static func entity(for channel: Channel, model: AppModel) -> ConversationEntity {
        let guildName = channel.guildID.flatMap { guildID in
            model.serverRailGuildsByID[guildID]?.name
                ?? model.snapshot?.guilds.first { $0.id == guildID }?.name
        }
        return ConversationEntity(
            id: ConversationEntityID(accountID: model.activeAccountID ?? "", channelID: channel.id),
            title: title(for: channel),
            subtitle: subtitle(for: channel, guildName: guildName),
            isDirectMessage: channel.kind == .directMessage || channel.kind == .groupDirectMessage
        )
    }

    private static func title(for channel: Channel) -> String {
        switch channel.kind {
        case .directMessage, .groupDirectMessage:
            if channel.hasExplicitName, !channel.name.isEmpty {
                return channel.name
            }
            let names = channel.recipients.map(\.displayName).filter { !$0.isEmpty }
            return names.isEmpty ? channel.name : names.joined(separator: ", ")
        default:
            return channel.guildID == nil ? channel.name : "#\(channel.name)"
        }
    }

    private static func subtitle(for channel: Channel, guildName: String?) -> String? {
        switch channel.kind {
        case .directMessage:
            "Direct Message"
        case .groupDirectMessage:
            "Group Direct Message"
        default:
            guildName
        }
    }
}
