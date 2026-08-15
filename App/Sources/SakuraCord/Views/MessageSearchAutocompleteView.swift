import AppKit
import SakuraCordModels
import SwiftUI

nonisolated enum MessageSearchAutocompleteOperator: String, CaseIterable, Identifiable {
    case from
    case `in`
    case has
    case mentions
    case before
    case after
    case authorType = "author_type"
    case pinned

    init?(alias: String) {
        switch alias.lowercased() {
        case "from": self = .from
        case "in": self = .in
        case "has": self = .has
        case "mentions": self = .mentions
        case "before": self = .before
        case "after": self = .after
        case "author_type", "authortype", "type": self = .authorType
        case "pinned": self = .pinned
        default: return nil
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .from: "From a specific user"
        case .in: "Sent in a specific channel"
        case .has: "Includes a specific type of data"
        case .mentions: "Mentions a specific user"
        case .before: "Sent before a date"
        case .after: "Sent after a date"
        case .authorType: "Sent by an author type"
        case .pinned: "Pinned or unpinned"
        }
    }

}

nonisolated enum MessageSearchAutocompleteSuggestion: Identifiable, Equatable {
    struct FilterOverviewPresentation {
        let systemImage: String
        let detail: String
    }

    struct AvatarPresentation {
        let name: String
        let url: URL?
    }

    struct DirectMessageScopePresentation {
        let action: String
        let avatar: AvatarPresentation
        let username: String
    }

    case heading(String)
    case searchQuery(String)
    case directMessageScope(Channel, isSearch: Bool)
    case filter(MessageSearchAutocompleteOperator)
    case user(MessageSearchAutocompleteOperator, User)
    case channel(Channel)
    case thread(MessageThreadSummary)
    case contentType(MessageSearchContentType)
    case authorType(MessageSearchAuthorType)
    case pinned(Bool)
    case date(MessageSearchAutocompleteOperator, String)
    case addSearchFilters
    case moreFilters

    var id: String {
        switch self {
        case .heading(let value): "heading:\(value)"
        case .searchQuery(let value): "search:\(value)"
        case .directMessageScope(let channel, let isSearch):
            "dm-scope:\(isSearch ? "search" : "find"):\(channel.id)"
        case .filter(let value): "filter:\(value.id)"
        case .user(let op, let user): "user:\(op.id):\(user.id)"
        case .channel(let channel): "channel:\(channel.id)"
        case .thread(let thread): "thread:\(thread.id)"
        case .contentType(let value): "content:\(value.rawValue)"
        case .authorType(let value): "author:\(value.rawValue)"
        case .pinned(let value): "pinned:\(value)"
        case .date(let op, let value): "date:\(op.id):\(value)"
        case .addSearchFilters: "add-search-filters"
        case .moreFilters: "more-filters"
        }
    }

    var isSelectable: Bool {
        if case .heading = self { return false }
        return true
    }

    var title: String {
        switch self {
        case .heading(let value): value
        case .searchQuery(let value): "Search for \(value)"
        case .directMessageScope(let channel, let isSearch):
            "\(isSearch ? "Search for" : "Find in") \(channel.name)"
        case .filter(let value): value.title
        case .user(_, let user): user.displayName
        case .channel(let channel): channel.name
        case .thread(let thread): thread.name
        case .contentType(let value): value.rawValue
        case .authorType(let value): value.rawValue
        case .pinned(let value): value ? "true" : "false"
        case .date(_, let value): value
        case .addSearchFilters: "Add search filters"
        case .moreFilters: "More filters"
        }
    }

    var userPresentation: User? {
        guard case .user(_, let user) = self else { return nil }
        return user
    }

    var channelPresentation: Channel? {
        guard case .channel(let channel) = self else { return nil }
        return channel
    }

    var avatarPresentation: AvatarPresentation? {
        switch self {
        case .user(_, let user):
            return AvatarPresentation(name: user.displayName, url: user.avatarURL)
        case .channel(let channel) where channel.kind == .directMessage:
            guard let recipient = channel.recipients.first else { return nil }
            return AvatarPresentation(name: recipient.displayName, url: recipient.avatarURL)
        case .channel(let channel) where channel.kind == .groupDirectMessage:
            return AvatarPresentation(name: channel.name, url: channel.iconURL)
        default:
            return nil
        }
    }

    var directMessageScopePresentation: DirectMessageScopePresentation? {
        guard case .directMessageScope(let channel, let isSearch) = self else { return nil }
        let avatar: AvatarPresentation
        if channel.kind == .directMessage, let recipient = channel.recipients.first {
            avatar = AvatarPresentation(name: recipient.displayName, url: recipient.avatarURL)
        } else {
            avatar = AvatarPresentation(name: channel.name, url: channel.iconURL)
        }
        return DirectMessageScopePresentation(
            action: isSearch ? "Search for" : "Find in",
            avatar: avatar,
            username: channel.name
        )
    }

    var imageAvatarPresentation: AvatarPresentation? {
        directMessageScopePresentation?.avatar ?? avatarPresentation
    }

    var accessibilityLabel: String {
        guard let userPresentation else { return title }
        return "\(userPresentation.displayName), \(userPresentation.username)"
    }

    var filterOverviewPresentation: FilterOverviewPresentation? {
        switch self {
        case .filter(.from):
            FilterOverviewPresentation(systemImage: "person.fill", detail: "from: user")
        case .filter(.in):
            FilterOverviewPresentation(systemImage: "number", detail: "in: channel")
        case .filter(.has):
            FilterOverviewPresentation(systemImage: "link", detail: "has: link, embed or file")
        case .filter(.mentions):
            FilterOverviewPresentation(systemImage: "at", detail: "mentions: user")
        case .moreFilters:
            FilterOverviewPresentation(
                systemImage: "slider.horizontal.3",
                detail: "dates, author type and more"
            )
        default:
            nil
        }
    }

    var autocompleteRowHeight: CGFloat {
        if case .heading = self { return 24 }
        if case .directMessageScope = self { return 34 }
        return filterOverviewPresentation == nil ? 34 : 48
    }

    func valueSystemImage(rulesChannelID: ChannelID?) -> String? {
        switch self {
        case .searchQuery:
            return "magnifyingglass"
        case .channel:
            return nil
        case .thread:
            return ChannelIconPresentation.forumPostSystemImage
        case .contentType(let value):
            return Self.systemImage(for: value)
        case .authorType(let value):
            return Self.systemImage(for: value)
        case .pinned(let value):
            return value ? "pin.fill" : "pin.slash.fill"
        case .date:
            return "calendar"
        case .addSearchFilters:
            return "slider.horizontal.3"
        case .heading, .directMessageScope, .filter, .user, .moreFilters:
            return nil
        }
    }

    private static func systemImage(for value: MessageSearchContentType) -> String {
        switch value {
        case .image: "photo.fill"
        case .video: "video.fill"
        case .link: "link"
        case .file: "doc.fill"
        case .embed: "play.rectangle.fill"
        case .sound: "speaker.wave.2.fill"
        case .poll: "chart.bar.fill"
        case .sticker: "face.smiling.fill"
        case .forward: "arrowshape.turn.up.right.fill"
        }
    }

    private static func systemImage(for value: MessageSearchAuthorType) -> String {
        switch value {
        case .user: "person.fill"
        case .bot: "app.fill"
        case .webhook: "point.3.connected.trianglepath.dotted"
        }
    }

    var valueOverlaySystemImage: String? {
        switch self {
        case .thread(let thread) where thread.isLocked:
            return "lock.fill"
        default:
            return nil
        }
    }

}

enum MessageSearchAutocompletePolicy {
    struct Result {
        let suggestions: [MessageSearchAutocompleteSuggestion]
        let selectsFirst: Bool
    }

    static func result(model: AppModel) -> Result {
        let fragment = activeFragment(in: model.messageSearch.queryText)
        if fragment.isEmpty {
            let filters = staticFilterSuggestions
            if model.selectedGuildID == nil,
               let selectedChannelID = model.selectedChannelID,
               let channel = model.messageSearchChannels.first(where: {
                   $0.id == selectedChannelID
               })
            {
                let presentedChannel = presentedChannel(channel)
                let searchesCurrentChannel = model.messageSearch.tokens.contains { token in
                    guard case .channel(let channelID, _) = token.kind else { return false }
                    return channelID == selectedChannelID
                }
                if !model.messageSearch.tokens.isEmpty, !searchesCurrentChannel {
                    return Result(
                        suggestions: [
                            .searchQuery(searchText(for: model.messageSearch.tokens)),
                        ] + filters,
                        selectsFirst: false
                    )
                }
                return Result(
                    suggestions: [
                        .directMessageScope(
                            presentedChannel,
                            isSearch: searchesCurrentChannel
                        ),
                    ] + filters,
                    selectsFirst: false
                )
            }
            return Result(
                suggestions: filters,
                selectsFirst: false
            )
        }

        guard let separator = fragment.firstIndex(of: ":") else {
            return allFilterResult(
                query: fragment,
                model: model,
                index: searchIndex(model: model)
            )
        }
        guard let searchOperator = MessageSearchAutocompleteOperator(
            alias: String(fragment[..<separator])
        ) else {
            return Result(suggestions: [], selectsFirst: false)
        }

        let value = String(fragment[fragment.index(after: separator)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"@#"))
        let rows: [MessageSearchAutocompleteSuggestion]
        switch searchOperator {
        case .from, .mentions:
            rows = [.heading(searchOperator == .from ? "From User" : "Mentions User")]
                + userResults(
                    query: value,
                    op: searchOperator,
                    model: model,
                    index: searchIndex(model: model),
                    limit: 10
                )
        case .in:
            rows = [.heading("In Channel")]
                + channelResults(
                    query: value,
                    model: model,
                    index: searchIndex(model: model),
                    limit: 10
                )
        case .has:
            rows = [.heading("Message Contains")]
                + MessageSearchContentType.allCases.filter {
                    fuzzyContains($0.rawValue, query: value)
                }.map(MessageSearchAutocompleteSuggestion.contentType)
        case .authorType:
            return Result(
                suggestions: [.searchQuery(fragment)] + staticFilterSuggestions,
                selectsFirst: false
            )
        case .pinned:
            rows = [.pinned(true), .pinned(false)]
        case .before, .after:
            rows = []
        }
        return Result(suggestions: rows, selectsFirst: false)
    }

    static func activeFragment(in value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }

    private static func allFilterResult(
        query: String,
        model: AppModel,
        index: ForwardDestinationSearchPolicy.Index
    ) -> Result {
        var resultRows: [MessageSearchAutocompleteSuggestion] = []
        let users = userResults(
            query: query,
            op: .from,
            model: model,
            index: index,
            limit: 3
        )
        if !users.isEmpty {
            resultRows.append(.heading("From User"))
            resultRows += users
        }
        let channels = channelResults(
            query: query,
            model: model,
            index: index,
            limit: 3
        )
        if !channels.isEmpty {
            resultRows.append(.heading("In Channel"))
            resultRows += channels
        }
        let mentions = userResults(
            query: query,
            op: .mentions,
            model: model,
            index: index,
            limit: 3
        )
        if !mentions.isEmpty {
            resultRows.append(.heading("Mentions User"))
            resultRows += mentions
        }
        guard !resultRows.isEmpty else {
            return Result(
                suggestions: [.searchQuery(query)] + staticFilterSuggestions,
                selectsFirst: false
            )
        }
        return Result(
            suggestions: [.searchQuery(query), .addSearchFilters] + resultRows,
            selectsFirst: false
        )
    }

    private static var staticFilterSuggestions: [MessageSearchAutocompleteSuggestion] {
        [
            .heading("Filters"),
            .filter(.from),
            .filter(.in),
            .filter(.has),
            .filter(.mentions),
            .moreFilters,
        ]
    }

    private static func searchText(for tokens: [MessageSearchToken]) -> String {
        tokens.map { token in
            guard let separator = token.canonicalSyntax.firstIndex(of: ":") else {
                return token.canonicalSyntax
            }
            let value = token.canonicalSyntax[token.canonicalSyntax.index(after: separator)...]
            return "\(token.canonicalSyntax[...separator]) \(value)"
        }.joined(separator: " ")
    }

    private static func userResults(
        query: String,
        op: MessageSearchAutocompleteOperator,
        model: AppModel,
        index: ForwardDestinationSearchPolicy.Index,
        limit: Int
    ) -> [MessageSearchAutocompleteSuggestion] {
        if query.isEmpty {
            if let guildID = model.selectedGuildID {
                var joinedUserIDs = Set(
                    model.snapshot?.quickSwitcherJoinedGuildMemberUserIDs[guildID] ?? []
                )
                let recentMessages = model.messages.suffix(30)
                joinedUserIDs.formUnion(recentMessages.lazy.compactMap { message in
                    message.guildID == guildID && message.guildMember != nil
                        ? message.author.id : nil
                })
                var seen = Set<UserID>()
                // Discord's channel MessageStore hydrates the newest ten
                // messages and a twenty-message viewport fill. Walk that
                // verified live window newest first and de-duplicate authors;
                // SakuraCord can retain a larger timeline across navigation.
                return recentMessages.reversed().compactMap { message -> User? in
                    guard message.channelID == model.selectedChannelID,
                          joinedUserIDs.contains(message.author.id),
                          seen.insert(message.author.id).inserted,
                          !isBlockedOrIgnored(message.author.id, model: model)
                    else { return nil }
                    return message.author
                }.prefix(limit).map { userSuggestion($0, op: op, model: model) }
            }
            return index.messageSearchUnqueriedUserResults(limit: limit).map {
                userSuggestion($0, op: op, model: model)
            }.filter {
                guard case .user(_, let user) = $0 else { return true }
                return !isBlockedOrIgnored(user.id, model: model)
            }
        }
        if let guildID = model.selectedGuildID {
            let snapshot = model.snapshot
            var joinedUserIDs = Set(
                snapshot?.quickSwitcherJoinedGuildMemberUserIDs[guildID] ?? []
            )
            joinedUserIDs.formUnion(model.messages.lazy.compactMap { message in
                message.guildID == guildID && message.guildMember != nil
                    ? message.author.id : nil
            })
            let scoredRows = userSearchIndex(
                model: model,
                index: index
            ).scoredResults(
                query: query,
                categories: [.user],
                limitPerCategory: limit,
                requiresDestinationEligibility: false,
                allowedUserIDs: joinedUserIDs
            )
            var suggestions = scoredRows.compactMap { row -> MessageSearchAutocompleteSuggestion? in
                guard case .user(let user, _) = row.destination.kind else { return nil }
                guard !isBlockedOrIgnored(user.id, model: model) else { return nil }
                return userSuggestion(user, op: op, model: model)
            }
            let normalizedQuery = query.trimmingCharacters(
                in: CharacterSet(charactersIn: "@")
            ).lowercased()
            if "me".hasPrefix(normalizedQuery), !normalizedQuery.isEmpty,
               let currentUser = snapshot?.currentUser,
               joinedUserIDs.contains(currentUser.id)
            {
                suggestions.removeAll {
                    if case .user(_, let user) = $0 { return user.id == currentUser.id }
                    return false
                }
                suggestions.insert(userSuggestion(currentUser, op: op, model: model), at: 0)
            }
            return Array(suggestions.prefix(limit))
        }
        var suggestions: [MessageSearchAutocompleteSuggestion] = userSearchIndex(
            model: model,
            index: index
        ).scoredResults(
            query: query,
            categories: [.user],
            limitPerCategory: limit,
            requiresDestinationEligibility: false,
            preservesSourceOrderForEqualScores: true
        ).compactMap { row -> MessageSearchAutocompleteSuggestion? in
            guard case .user(let user, _) = row.destination.kind else { return nil }
            guard !isBlockedOrIgnored(user.id, model: model) else { return nil }
            return userSuggestion(user, op: op, model: model)
        }
        let normalizedQuery = query.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        if "me".hasPrefix(normalizedQuery), !normalizedQuery.isEmpty,
           let currentUser = model.snapshot?.currentUser
        {
            suggestions.removeAll {
                if case .user(_, let user) = $0 { return user.id == currentUser.id }
                return false
            }
            suggestions.insert(
                userSuggestion(currentUser, op: op, model: model),
                at: 0
            )
        }
        return Array(suggestions.prefix(limit))
    }

    private static func isBlockedOrIgnored(_ userID: UserID, model: AppModel) -> Bool {
        model.snapshot?.blockedOrIgnoredUserIDs.contains(userID) == true
    }

    private static func userSuggestion(
        _ user: User,
        op: MessageSearchAutocompleteOperator,
        model: AppModel
    ) -> MessageSearchAutocompleteSuggestion {
        var presentedUser = user
        if model.selectedGuildID == nil,
           let relationshipNickname = model.snapshot?
            .relationshipNicknamesByUserID[user.id]
        {
            presentedUser.displayName = relationshipNickname
        }
        return .user(op, presentedUser)
    }

    private static func channelResults(
        query: String,
        model: AppModel,
        index: ForwardDestinationSearchPolicy.Index,
        limit: Int
    ) -> [MessageSearchAutocompleteSuggestion] {
        if model.selectedGuildID == nil {
            let dmIndex = searchIndex(
                model: model,
                users: model.messageSearchChannels.compactMap { channel in
                    guard channel.kind == .directMessage else { return nil }
                    return channel.recipients.first
                }
            )
            let scoredRows = query.isEmpty
                ? dmIndex.messageSearchUnqueriedDirectMessageResults(
                    currentChannelID: model.selectedChannelID,
                    limit: limit
                )
                : dmIndex.messageSearchDirectMessageResults(
                    query: query,
                    limit: limit
                )
            let rows = scoredRows.compactMap { row -> MessageSearchAutocompleteSuggestion? in
                switch row.destination.kind {
                case .channel(let channel): return .channel(channel)
                case .user(_, let directMessage):
                    return directMessage.map(Self.channelSuggestion)
                case .thread: return nil
                }
            }
            return Array(rows.prefix(limit))
        }
        if query.isEmpty {
            return index.messageSearchUnqueriedChannelResults(
                currentGuildID: model.selectedGuildID,
                currentChannelID: model.selectedChannelID,
                limit: limit
            ).compactMap { row in
                switch row.destination.kind {
                case .channel(let channel): .channel(channel)
                case .thread(let thread, _): .thread(thread)
                case .user: nil
                }
            }
        }
        return index.scoredResults(
            query: query,
            categories: [.selectableChannel, .voiceChannel],
            limitPerCategory: limit,
            requiresDestinationEligibility: false,
            preservesSourceOrderForEqualScores: true
        ).compactMap { row in
            switch row.destination.kind {
            case .channel(let channel): .channel(channel)
            case .thread(let thread, _): .thread(thread)
            case .user(_, let directMessage): directMessage.map(Self.channelSuggestion)
            }
        }.prefix(limit).map { $0 }
    }

    private static func channelSuggestion(_ channel: Channel) -> MessageSearchAutocompleteSuggestion {
        .channel(presentedChannel(channel))
    }

    private static func presentedChannel(_ channel: Channel) -> Channel {
        var value = channel
        if channel.kind == .directMessage, let recipient = channel.recipients.first {
            value.name = recipient.username
        }
        return value
    }

    private static func searchIndex(
        model: AppModel,
        users: [User]? = nil
    ) -> ForwardDestinationSearchPolicy.Index {
        let snapshot = model.snapshot
        let guilds = Dictionary(
            (snapshot?.guilds ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let channels = model.messageSearchChannels
        let channelIDs = Set(channels.map(\.id))
        let threadSource = (snapshot?.threads ?? []) + (snapshot?.activeJoinedThreads ?? [])
        let latestThreadsByID = Dictionary(
            threadSource.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        var seenThreadIDs = Set<ChannelID>()
        let threads = threadSource.compactMap { thread -> MessageThreadSummary? in
            guard seenThreadIDs.insert(thread.id).inserted,
                  let latest = latestThreadsByID[thread.id],
                  model.selectedGuildID == latest.guildID
            else { return nil }
            return latest
        }
        let searchableIDs = channelIDs.union(threads.map(\.id))
        let maximumUsageScore = model.discordSyncedGuildAndChannelUsageScores
            .values.max()
        return ForwardDestinationSearchPolicy.makeIndex(
            channels: channels,
            threads: threads,
            includesUnjoinedThreads: true,
            channelStoreOrder: channels.map(\.id),
            users: users ?? model.messageSearchUsers,
            userBoosterChannels: (snapshot?.channels ?? channels).filter { channel in
                snapshot?.messageSearchUserBoosterChannelIDs.contains(channel.id) ?? true
            },
            includesChannelRecipientsAsUsers: users == nil,
            friendUserIDs: snapshot?.friendUserIDs ?? [],
            relationshipNicknamesByUserID: snapshot?.relationshipNicknamesByUserID ?? [:],
            // queryAllUsers/queryDMChannels operate on UserStore records, not
            // GuildMemberStore nicknames. Guild aliases belong exclusively to
            // queryGuildUsers and otherwise create false DM matches.
            userSearchAliasesByUserID: model.selectedGuildID == nil
                ? [:]
                : snapshot?.userSearchAliasesByUserID ?? [:],
            // UserStore contains the current account. The autocomplete layer
            // suppresses it only for Discord's special `me` query handling.
            currentUserID: nil,
            guilds: guilds,
            usageScores: model.discordSyncedGuildAndChannelUsageScores,
            maximumUsageScore: maximumUsageScore,
            searchableChannelIDs: searchableIDs,
            eligibleChannelIDs: searchableIDs
        )
    }

    private static func userSearchIndex(
        model: AppModel,
        index: ForwardDestinationSearchPolicy.Index
    ) -> ForwardDestinationSearchPolicy.Index {
        guard let snapshot = model.snapshot,
              let selectedGuildID = model.selectedGuildID
        else { return index }
        var aliases = snapshot.userSearchAliasesByUserID
        let selected = [selectedGuildID]
        let guildIDs = selected + snapshot.quickSwitcherGuildMemberAliases.keys.sorted().filter {
            !selected.contains($0)
        }
        for guildID in guildIDs {
            for userID in (snapshot.quickSwitcherGuildMemberAliases[guildID] ?? [:]).keys.sorted() {
                guard let alias = snapshot.quickSwitcherGuildMemberAliases[guildID]?[userID],
                      aliases[userID, default: []].contains(where: {
                          $0.localizedCaseInsensitiveCompare(alias) == .orderedSame
                      }) == false
                else { continue }
                aliases[userID, default: []].append(alias)
            }
        }
        return index.quickSwitcherUserIndex(userSearchAliasesByUserID: aliases)
    }

    private static func fuzzyContains(_ candidate: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var index = query.lowercased().startIndex
        let normalizedQuery = query.lowercased()
        for character in candidate.lowercased() where index < normalizedQuery.endIndex {
            if character == normalizedQuery[index] {
                index = normalizedQuery.index(after: index)
            }
        }
        return index == normalizedQuery.endIndex
    }

}

struct MessageSearchAutocompleteView: View {
    let model: AppModel
    let width: CGFloat
    @State private var selectedID: String?
    @State private var keyboardNavigationActive = true
    @State private var keyMonitor: Any?

    var body: some View {
        let result = MessageSearchAutocompletePolicy.result(model: model)
        let rulesChannelID = model.selectedGuildID.flatMap {
            model.serverRailGuildsByID[$0]?.rulesChannelID
        }
        let channelSystemImagesByID = Dictionary(
            result.suggestions.compactMap { suggestion -> (ChannelID, String)? in
                guard let channel = suggestion.channelPresentation else { return nil }
                return (
                    channel.id,
                    ChannelIconPresentation.systemImage(
                        for: channel,
                        access: model.conversationAccess(for: channel),
                        rulesChannelID: rulesChannelID
                    )
                )
            },
            uniquingKeysWith: { _, newer in newer }
        )
        Group {
            if !result.suggestions.isEmpty {
                MessageSearchAutocompleteList(
                    rows: result.suggestions,
                    channelSystemImagesByID: channelSystemImagesByID,
                    selectedID: selectedID,
                    keyboardNavigationActive: keyboardNavigationActive,
                    enableMouseFocus: { keyboardNavigationActive = false },
                    focus: { selectedID = $0 },
                    activate: activate
                )
                .frame(width: width)
                .frame(height: autocompleteHeight(for: result.suggestions))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            synchronizeSelection(result)
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .task {
            // Discord's autocomplete consumes its authenticated FrecencyStore.
            // Load the same account-scoped settings when search first appears;
            // this request is coalesced with the picker and forwarding paths.
            await model.loadDiscordEmojiSettings()
        }
        .onChange(of: model.messageSearch.queryText) { _, _ in
            keyboardNavigationActive = true
            synchronizeSelection(MessageSearchAutocompletePolicy.result(model: model))
        }
    }

    private func autocompleteHeight(
        for suggestions: [MessageSearchAutocompleteSuggestion]
    ) -> CGFloat {
        min(420, 10 + suggestions.reduce(0) { height, suggestion in
            height + suggestion.autocompleteRowHeight + 2
        })
    }

    private func synchronizeSelection(_ result: MessageSearchAutocompletePolicy.Result) {
        let ids = result.suggestions.filter(\.isSelectable).map(\.id)
        selectedID = result.selectsFirst ? ids.first : nil
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:
            model.handleMessageSearchEscape()
            return true
        case 36, 76:
            guard let selectedID,
                  let suggestion = MessageSearchAutocompletePolicy.result(model: model)
                    .suggestions.first(where: { $0.id == selectedID })
            else {
                model.submitMessageSearchInput()
                return true
            }
            activate(suggestion)
            return true
        case 125 where modifiers.isDisjoint(with: [.command, .option, .shift]),
             45 where modifiers == [.control]:
            moveSelection(delta: 1)
            return true
        case 126 where modifiers.isDisjoint(with: [.command, .option, .shift]),
             35 where modifiers == [.control]:
            moveSelection(delta: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(delta: Int) {
        let ids = MessageSearchAutocompletePolicy.result(model: model)
            .suggestions.filter(\.isSelectable).map(\.id)
        selectedID = ids.isEmpty ? nil : QuickSwitcherSelectionPolicy.moved(
            current: selectedID.map(QuickSwitcherResultID.navigation),
            selectableIDs: ids.map(QuickSwitcherResultID.navigation),
            delta: delta
        ).flatMap { id in
            guard case .navigation(let value) = id else { return nil }
            return value
        }
        keyboardNavigationActive = true
    }

    private func activate(_ suggestion: MessageSearchAutocompleteSuggestion) {
        let fragment = MessageSearchAutocompletePolicy.activeFragment(
            in: model.messageSearch.queryText
        )
        switch suggestion {
        case .heading:
            return
        case .searchQuery:
            model.submitMessageSearchInput()
        case .directMessageScope(let channel, let isSearch):
            if isSearch {
                model.submitMessageSearchInput()
            } else {
                complete(fragment: fragment, token: .init(kind: .channel(
                    channelID: channel.id,
                    name: channel.name
                )))
            }
        case .filter(let searchOperator):
            replaceActiveFragment(fragment, with: "\(searchOperator.rawValue):")
        case .user(let op, let user):
            complete(
                fragment: fragment,
                token: MessageSearchToken(kind: op == .from
                    ? .from(userID: user.id, username: user.username, displayName: user.displayName)
                    : .mentions(userID: user.id, username: user.username, displayName: user.displayName))
            )
        case .channel(let channel):
            complete(fragment: fragment, token: .init(kind: .channel(
                channelID: channel.id,
                name: channel.name
            )))
        case .thread(let thread):
            complete(fragment: fragment, token: .init(kind: .channel(
                channelID: thread.id,
                name: thread.name
            )))
        case .contentType(let value):
            complete(fragment: fragment, token: .init(kind: .contentType(value)))
        case .authorType(let value):
            complete(fragment: fragment, token: .init(kind: .authorType(value)))
        case .pinned(let value):
            complete(fragment: fragment, token: .init(kind: .pinned(value)))
        case .date(let op, let value):
            let parsed = MessageSearchTokenParser.parse(
                "\(op.rawValue):\(value)",
                users: model.messageSearchUsers,
                channels: model.messageSearchChannels
            )
            if let token = parsed.tokens.first { complete(fragment: fragment, token: token) }
        case .addSearchFilters, .moreFilters:
            model.messageSearch.isInputFocused = false
            model.messageSearch.isFilterSheetPresented = true
        }
    }

    private func complete(fragment: String, token: MessageSearchToken) {
        removeActiveFragment(fragment)
        if !model.messageSearch.tokens.contains(token) {
            model.messageSearch.tokens.append(token)
        }
        model.messageSearch.requestInputFocus()
    }

    private func replaceActiveFragment(_ fragment: String, with replacement: String) {
        guard !fragment.isEmpty,
              let range = model.messageSearch.queryText.range(of: fragment, options: .backwards)
        else {
            model.messageSearch.queryText = replacement
            return
        }
        model.messageSearch.queryText.replaceSubrange(range, with: replacement)
    }

    private func removeActiveFragment(_ fragment: String) {
        guard !fragment.isEmpty,
              let range = model.messageSearch.queryText.range(of: fragment, options: .backwards)
        else { return }
        model.messageSearch.queryText.removeSubrange(range)
        model.messageSearch.queryText = model.messageSearch.queryText
            .trimmingCharacters(in: .whitespaces)
    }
}

private struct MessageSearchAutocompleteList: NSViewRepresentable {
    let rows: [MessageSearchAutocompleteSuggestion]
    let channelSystemImagesByID: [ChannelID: String]
    let selectedID: String?
    let keyboardNavigationActive: Bool
    let enableMouseFocus: () -> Void
    let focus: (String) -> Void
    let activate: (MessageSearchAutocompleteSuggestion) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = MessageSearchAutocompleteCanvas()
        canvas.autoresizingMask = [.width]
        let scrollView = NSScrollView()
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let canvas = scrollView.documentView as? MessageSearchAutocompleteCanvas else { return }
        canvas.update(
            rows: rows,
            channelSystemImagesByID: channelSystemImagesByID,
            selectedID: selectedID,
            keyboardNavigationActive: keyboardNavigationActive,
            enableMouseFocus: enableMouseFocus,
            focus: focus,
            activate: activate
        )
    }
}

private final class MessageSearchAutocompleteCanvas: NSView {
    private static let inset: CGFloat = 6
    private static let spacing: CGFloat = 2

    override var isFlipped: Bool { true }

    private var rows: [MessageSearchAutocompleteSuggestion] = []
    private var channelSystemImagesByID: [ChannelID: String] = [:]
    private var origins: [CGFloat] = []
    private var selectedID: String?
    private var keyboardNavigationActive = true
    private var enableMouseFocus: () -> Void = {}
    private var focus: (String) -> Void = { _ in }
    private var activate: (MessageSearchAutocompleteSuggestion) -> Void = { _ in }
    private var hoveredIndex: Int?
    private var pressedIndex: Int?
    private var trackingArea: NSTrackingArea?
    private var accessibilityRows: [String: MessageSearchAXRow] = [:]
    private var images: [URL: CGImage] = [:]
    private var imageTasks: [URL: Task<Void, Never>] = [:]

    deinit {
        for task in imageTasks.values { task.cancel() }
    }

    func update(
        rows: [MessageSearchAutocompleteSuggestion],
        channelSystemImagesByID: [ChannelID: String],
        selectedID: String?,
        keyboardNavigationActive: Bool,
        enableMouseFocus: @escaping () -> Void,
        focus: @escaping (String) -> Void,
        activate: @escaping (MessageSearchAutocompleteSuggestion) -> Void
    ) {
        let previousSelection = self.selectedID
        self.rows = rows
        self.channelSystemImagesByID = channelSystemImagesByID
        self.selectedID = selectedID
        self.keyboardNavigationActive = keyboardNavigationActive
        self.enableMouseFocus = enableMouseFocus
        self.focus = focus
        self.activate = activate
        rebuildDocument()
        reconcileAccessibilityRows()
        reconcileImages()
        if keyboardNavigationActive,
           previousSelection != selectedID,
           let selectedID,
           let index = rows.firstIndex(where: { $0.id == selectedID })
        {
            scrollToVisible(rowRect(at: index))
        }
        needsDisplay = true
    }

    private func rebuildDocument() {
        var rowOrigin = Self.inset
        origins = rows.map { row in
            defer { rowOrigin += row.autocompleteRowHeight + Self.spacing }
            return rowOrigin
        }
        frame = CGRect(
            x: 0,
            y: 0,
            width: enclosingScrollView?.contentSize.width ?? frame.width,
            height: max(1, rowOrigin + Self.inset - Self.spacing)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reconcileAccessibilityRows()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let value = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(value)
        trackingArea = value
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let index = selectableIndex(at: convert(event.locationInWindow, from: nil))
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        guard let index else { return }
        if keyboardNavigationActive {
            keyboardNavigationActive = false
            enableMouseFocus()
        }
        focus(rows[index].id)
    }

    override func mouseExited(with event: NSEvent) { hoveredIndex = nil }

    override func mouseDown(with event: NSEvent) {
        pressedIndex = selectableIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let index = selectableIndex(at: convert(event.locationInWindow, from: nil))
        defer { pressedIndex = nil }
        guard index == pressedIndex, let index else { return }
        activate(rows[index])
    }

    private func selectableIndex(at point: CGPoint) -> Int? {
        guard point.x >= Self.inset, point.x <= bounds.maxX - Self.inset else { return nil }
        return rows.indices.first { rows[$0].isSelectable && rowRect(at: $0).contains(point) }
    }

    private func rowRect(at index: Int) -> CGRect {
        CGRect(
            x: Self.inset,
            y: origins[index],
            width: max(0, bounds.width - Self.inset * 2),
            height: rows[index].autocompleteRowHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for index in rows.indices where rowRect(at: index).intersects(dirtyRect) {
            draw(row: rows[index], at: index)
        }
    }

    private func draw(row: MessageSearchAutocompleteSuggestion, at index: Int) {
        let rect = rowRect(at: index)
        if row.id == selectedID, row.isSelectable {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        if !row.isSelectable {
            drawText(
                row.title,
                rect: rect.insetBy(dx: 8, dy: 4),
                font: .systemFont(ofSize: 12, weight: .semibold),
                color: .labelColor.withAlphaComponent(0.72)
            )
            return
        }
        if let overview = row.filterOverviewPresentation {
            drawFilterOverview(row: row, presentation: overview, in: rect)
            return
        }
        if let scope = row.directMessageScopePresentation {
            drawDirectMessageScope(scope, in: rect)
            return
        }
        let avatar = row.avatarPresentation
        let systemImage = row.channelPresentation.flatMap {
            channelSystemImagesByID[$0.id]
        } ?? row.valueSystemImage(rulesChannelID: nil)
        let iconRect = CGRect(x: rect.minX + 8, y: rect.minY + 6, width: 22, height: 22)
        if let avatar {
            drawAvatar(name: avatar.name, url: avatar.url, in: iconRect)
        } else if let systemImage {
            drawSystemImage(systemImage, in: iconRect)
            if let overlay = row.valueOverlaySystemImage {
                drawSystemImage(
                    overlay,
                    in: CGRect(x: iconRect.maxX - 9, y: iconRect.minY - 1, width: 11, height: 11),
                    pointSize: 8
                )
            }
        }
        let hasLeadingIcon = avatar != nil || systemImage != nil
        let textX = hasLeadingIcon ? iconRect.maxX + 8 : rect.minX + 10
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let usernameFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let username = row.userPresentation?.username
        let usernameWidth = username.map {
            min(
                max(0, (rect.maxX - textX - 10) * 0.45),
                ceil(($0 as NSString).size(withAttributes: [.font: usernameFont]).width)
            )
        } ?? 0
        let titleWidth = min(
            rect.maxX - textX - 10 - (usernameWidth > 0 ? usernameWidth + 6 : 0),
            ceil((row.title as NSString).size(withAttributes: [.font: titleFont]).width)
        )
        let titleRect = CGRect(
            x: textX,
            y: rect.minY + 8,
            width: max(0, titleWidth),
            height: 18
        )
        drawText(
            row.title,
            rect: titleRect,
            font: titleFont,
            color: .labelColor
        )
        if let username, usernameWidth > 0 {
            drawText(
                username,
                rect: CGRect(
                    x: titleRect.maxX + 6,
                    y: rect.minY + 9,
                    width: usernameWidth,
                    height: 17
                ),
                font: usernameFont,
                color: .labelColor.withAlphaComponent(0.70)
            )
        }
    }

    private func drawFilterOverview(
        row: MessageSearchAutocompleteSuggestion,
        presentation: MessageSearchAutocompleteSuggestion.FilterOverviewPresentation,
        in rect: CGRect
    ) {
        let iconRect = CGRect(x: rect.minX + 9, y: rect.minY + 13, width: 22, height: 22)
        drawSystemImage(presentation.systemImage, in: iconRect)
        let textX = iconRect.maxX + 10
        drawText(
            row.title,
            rect: CGRect(x: textX, y: rect.minY + 5, width: rect.maxX - textX - 10, height: 19),
            font: .systemFont(ofSize: 14, weight: .medium),
            color: .labelColor
        )
        drawText(
            presentation.detail,
            rect: CGRect(x: textX, y: rect.minY + 25, width: rect.maxX - textX - 10, height: 17),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor.withAlphaComponent(0.62)
        )
    }

    private func drawDirectMessageScope(
        _ presentation: MessageSearchAutocompleteSuggestion.DirectMessageScopePresentation,
        in rect: CGRect
    ) {
        let searchRect = CGRect(x: rect.minX + 8, y: rect.minY + 6, width: 22, height: 22)
        drawSystemImage("magnifyingglass", in: searchRect)
        let actionFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let actionWidth = ceil((presentation.action as NSString).size(
            withAttributes: [.font: actionFont]
        ).width)
        let actionRect = CGRect(
            x: searchRect.maxX + 8,
            y: rect.minY + 8,
            width: actionWidth,
            height: 18
        )
        drawText(
            presentation.action,
            rect: actionRect,
            font: actionFont,
            color: .labelColor
        )
        let avatarRect = CGRect(
            x: actionRect.maxX + 8,
            y: rect.minY + 6,
            width: 22,
            height: 22
        )
        drawAvatar(
            name: presentation.avatar.name,
            url: presentation.avatar.url,
            in: avatarRect
        )
        drawText(
            presentation.username,
            rect: CGRect(
                x: avatarRect.maxX + 7,
                y: rect.minY + 8,
                width: max(0, rect.maxX - avatarRect.maxX - 17),
                height: 18
            ),
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor
        )
    }

    private func drawSystemImage(
        _ name: String,
        in rect: CGRect,
        pointSize: CGFloat = 17
    ) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .medium
        ).applying(
            NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
        )
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        else { return }
        let destination = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: image.size,
            alignmentRect: image.alignmentRect,
            in: rect
        )
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawAvatar(name: String, url: URL?, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        if let url, let image = images[url] {
            let destination = QuickSwitcherIconGeometry.aspectFillRect(
                imageSize: CGSize(width: image.width, height: image.height),
                in: rect
            )
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: destination.minY * 2 + destination.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: destination)
        } else {
            NSColor.controlAccentColor.setFill()
            context.fillEllipse(in: rect)
            drawText(
                String(name.prefix(1)).uppercased(),
                rect: rect.offsetBy(dx: 0, dy: 5),
                font: .systemFont(ofSize: 10, weight: .semibold),
                color: .white,
                alignment: .center
            )
        }
        context.restoreGState()
    }

    private func drawText(
        _ value: String,
        rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        (value as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func reconcileImages() {
        let wantedURLs = Set(rows.compactMap { $0.imageAvatarPresentation?.url })
        for url in wantedURLs { requestImage(url) }
        for (url, task) in imageTasks where !wantedURLs.contains(url) {
            task.cancel()
            imageTasks[url] = nil
        }
        for url in images.keys.filter({ !wantedURLs.contains($0) }) {
            images[url] = nil
        }
    }

    private func requestImage(_ url: URL) {
        guard images[url] == nil, imageTasks[url] == nil else { return }
        imageTasks[url] = Task { [weak self] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url,
                maximumPixelDimension: 96,
                priority: .visible
            )
            guard !Task.isCancelled, let self else { return }
            imageTasks[url] = nil
            guard let image else { return }
            images[url] = image
            for index in rows.indices where rows[index].imageAvatarPresentation?.url == url {
                setNeedsDisplay(rowRect(at: index))
            }
        }
    }

    private func reconcileAccessibilityRows() {
        guard origins.count == rows.count else { return }
        var visibleIDs = Set<String>()
        for index in rows.indices {
            let row = rows[index]
            visibleIDs.insert(row.id)
            let proxy = accessibilityRows[row.id] ?? {
                let value = MessageSearchAXRow()
                addSubview(value)
                accessibilityRows[row.id] = value
                return value
            }()
            proxy.configure(
                row: row,
                isSelected: selectedID == row.id,
                activate: { [weak self] in self?.activate(row) }
            )
            proxy.frame = rowRect(at: index)
        }
        for (id, proxy) in accessibilityRows where !visibleIDs.contains(id) {
            proxy.removeFromSuperview()
            accessibilityRows[id] = nil
        }
        setAccessibilityChildren(rows.compactMap { accessibilityRows[$0.id] })
    }
}

private final class MessageSearchAXRow: NSView {
    private var activation: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        row: MessageSearchAutocompleteSuggestion,
        isSelected: Bool,
        activate: @escaping () -> Void
    ) {
        activation = row.isSelectable ? activate : nil
        setAccessibilityElement(true)
        setAccessibilityRole(row.isSelectable ? .button : .staticText)
        setAccessibilityLabel(row.accessibilityLabel)
        setAccessibilityIdentifier("message-search-suggestion-\(row.id)")
        setAccessibilityValue(isSelected ? "Selected" : "")
    }

    override func accessibilityPerformPress() -> Bool {
        guard let activation else { return false }
        activation()
        return true
    }
}
