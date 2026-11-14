import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

nonisolated enum MessageSearchSurfacePolicy {
    static func showsToolbar(channelKind: ChannelKindValue?, hasOpenThread: Bool) -> Bool {
        guard !hasOpenThread else { return false }
        return switch channelKind {
        case .text, .announcement, .forum, .directMessage, .groupDirectMessage:
            true
        case .voice, .unknown, nil:
            false
        }
    }
}

nonisolated enum MessageSearchChannelMergePolicy {
    static func canonicalPrivateChannels(in channels: [Channel]) -> [Channel] {
        channels.filter { channel in
            channel.guildID == nil && channel.kind.isDirectMessage
        }
    }
}

@MainActor
@Observable
final class MessageSearchState {
    var isPresented = false
    var queryText = ""
    var tokens: [MessageSearchToken] = []
    var filters = MessageSearchFilters()
    var operatorFilters = MessageSearchFilters()
    var sort = MessageSearchSort.newest
    var page: MessageSearchPage?
    var submittedQuery: MessageSearchQuery?
    var errorMessage: String?
    var isSearching = false
    var isFilterModalPresented = false
    var selectedMessageID: MessageID?
    var lastCompletedLatencyMilliseconds: Int?
    var parsedInputText: String?
    var parsedContent = ""
    var isInputFocused = false
    @ObservationIgnored var rows: [MessageRowPresentation] = []
    @ObservationIgnored var rowsRevision: UInt64 = 0
    @ObservationIgnored let rowsUpdateJournal = MessageRowsUpdateJournal()
    @ObservationIgnored var requestTask: Task<Void, Never>?
    @ObservationIgnored var pollRefreshJournal: ConversationRefreshJournal?

    var currentPage: Int {
        guard let submittedQuery else { return 1 }
        return submittedQuery.offset / MessageSearchQuery.pageSize + 1
    }

    var pageCount: Int { page?.maximumPageCount ?? 1 }

    var resolvedContent: String {
        queryText == parsedInputText ? parsedContent : queryText
    }

    var effectiveFilters: MessageSearchFilters {
        tokens.reduce(filters.merging(operatorFilters)) { filters, token in
            filters.merging(token.filters)
        }
    }

    func requestInputFocus() {
        isInputFocused = true
    }

    func clear() {
        requestTask?.cancel()
        isPresented = false
        AppPerformanceSignposts.endResourceWindow(named: "MessageSearchBenchmark")
        AppPerformanceSignposts.endResourceWindow(named: "MessageSearchPaginationBenchmark")
        AppPerformanceSignposts.cancelMessageSearchRequest()
        AppPerformanceSignposts.cancelMessageSearchPagination()
        AppPerformanceSignposts.endMessageSearchScroll()
        requestTask = nil
        pollRefreshJournal = nil
        queryText = ""
        tokens = []
        parsedInputText = nil
        parsedContent = ""
        filters = .init()
        operatorFilters = .init()
        sort = .newest
        isSearching = false
        isFilterModalPresented = false
        lastCompletedLatencyMilliseconds = nil
        isInputFocused = false
        clearResults()
    }

    /// Forgets the results, keeping the query and filters.
    func clearResults() {
        page = nil
        submittedQuery = nil
        errorMessage = nil
        selectedMessageID = nil
        rows = []
        rowsRevision &+= 1
    }
}

@MainActor
extension AppModel {
    var retainedMessageSearches: [MessageSearchState] {
        [messageSearch] + Array(messageSearchesByGuildID.values)
    }

    func switchMessageSearchScope(from previousGuildID: GuildID?) {
        // Timings belong to the visible search, while requests may finish off-screen.
        cancelMessageSearchMeasurement("MessageSearchBenchmark", measuresPagination: false)
        cancelMessageSearchMeasurement("MessageSearchPaginationBenchmark", measuresPagination: true)
        AppPerformanceSignposts.endMessageSearchScroll()
        messageSearch.isInputFocused = false
        messageSearch.isFilterModalPresented = false
        messageSearchesByGuildID[previousGuildID] = messageSearch
        messageSearch = messageSearchesByGuildID.removeValue(forKey: selectedGuildID) ?? MessageSearchState()
    }

    func resetMessageSearches() {
        for search in retainedMessageSearches { search.clear() }
        messageSearchesByGuildID.removeAll()
        messageSearch = MessageSearchState()
    }

    var messageSearchInputText: String {
        get { messageSearch.queryText }
        set {
            messageSearch.queryText = newValue.replacingOccurrences(of: "\u{FFFC}", with: "")
            let text = messageSearch.queryText
            let parsed = MessageSearchTokenParser.parse(
                text,
                users: messageSearchUsers,
                channels: messageSearchChannels
            )
            let implicitTokens = parsed.tokens.filter { token in
                switch token.kind {
                case .contentType, .authorType, .pinned, .before, .after: true
                case .from, .channel, .mentions: false
                }
            }
            guard !implicitTokens.isEmpty else { return }
            for token in implicitTokens where !messageSearch.tokens.contains(token) {
                messageSearch.tokens.append(token)
            }
            messageSearch.queryText = MessageSearchTokenParser.lexicalTokens(in: text)
                .filter { rawToken in
                    let token = MessageSearchTokenParser.parse(
                        rawToken,
                        users: messageSearchUsers,
                        channels: messageSearchChannels
                    ).tokens.first
                    return token.map { !implicitTokens.contains($0) } ?? true
                }
                .joined(separator: " ")
        }
    }

    var canShowMessageSearch: Bool {
        MessageSearchSurfacePolicy.showsToolbar(
            channelKind: selectedChannel?.kind,
            hasOpenThread: hasThreadPane && !isThreadFullWidth
        )
    }

    /// The workspace's own toolbar (`WorkspaceTitlebar`) keeps the search
    /// field in place beside a thread pane, where it fades out instead of
    /// leaving the toolbar.
    var keepsMessageSearchFieldInPlace: Bool {
        sessionState == .workspace && showsConversationWorkspace
            && MessageSearchSurfacePolicy.showsToolbar(channelKind: selectedChannel?.kind, hasOpenThread: false)
    }

    var isMessageSearchVisible: Bool {
        messageSearch.isPresented && canShowMessageSearch && showsConversationWorkspace
    }

    func presentMessageSearch() {
        if isBrowsingGuildChannels {
            onboarding.isChannelSearchFocused = true
            return
        }
        if isFriendsSearchActive {
            friends.isSearchFocused = true
            return
        }
        guard sessionState == .workspace,
              selectedChannelID != nil,
              canShowMessageSearch
        else { return }
        workspaceNavigationOverlay = nil
        messageSearch.requestInputFocus()
    }

    func presentMessageSearchFromCommand() {
        presentMessageSearch()
        guard !isBrowsingGuildChannels, messageSearch.isInputFocused else { return }
        let channel: Channel? = if isThreadFullWidth, let openThread {
            threadNavigationChannel(openThread)
        } else {
            messageSearchChannels.first(where: { $0.id == selectedChannelID })
        }
        guard let channel else { return }
        messageSearch.tokens.removeAll { token in
            if case .channel = token.kind { return true }
            return false
        }
        messageSearch.tokens.append(MessageSearchToken(kind: .channel(
            channelID: channel.id,
            name: messageSearchPresentedName(for: channel)
        )))
    }

    func dismissMessageSearch() {
        messageSearch.requestTask?.cancel()
        AppPerformanceSignposts.endResourceWindow(named: "MessageSearchBenchmark")
        AppPerformanceSignposts.endResourceWindow(named: "MessageSearchPaginationBenchmark")
        AppPerformanceSignposts.cancelMessageSearchRequest()
        AppPerformanceSignposts.cancelMessageSearchPagination()
        AppPerformanceSignposts.endMessageSearchScroll()
        messageSearch.requestTask = nil
        messageSearch.isSearching = false
        messageSearch.pollRefreshJournal = nil
        WorkspaceLayoutMotion.perform(in: self, categories: inspectorMotionCategories) {
            messageSearch.isPresented = false
        }
        messageSearch.isInputFocused = false
        // Once the results have slid away, so the next search doesn't show
        // them while its own results load.
        let search = messageSearch
        Task {
            await WorkspaceLayoutMotion.untilSettled()
            if !search.isPresented { search.clearResults() }
        }
    }

    func dismissMessageSearchIfInputIsEmpty() {
        guard messageSearch.queryText.isEmpty, messageSearch.tokens.isEmpty else { return }
        dismissMessageSearch()
    }

    @discardableResult
    func consumeEscapeForUnfocusedMessageSearch() -> Bool {
        guard isMessageSearchVisible, !messageSearch.isInputFocused else { return false }
        clearMessageSearchInput()
        dismissMessageSearch()
        return true
    }

    func clearMessageSearchUsingBuiltInButton() {
        clearMessageSearchInput()
        dismissMessageSearch()
    }

    func messageSearchEditingDidEnd() {
        messageSearch.isInputFocused = false
        guard messageSearch.queryText.isEmpty, messageSearch.tokens.isEmpty else { return }
        dismissMessageSearch()
    }

    func handleMessageSearchEscape() {
        if messageSearch.queryText.isEmpty, messageSearch.tokens.isEmpty {
            dismissMessageSearch()
            return
        }
        clearMessageSearchInput()
        messageSearch.requestInputFocus()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  messageSearch.queryText.isEmpty,
                  messageSearch.tokens.isEmpty
            else { return }
            messageSearch.requestInputFocus()
        }
    }

    private func clearMessageSearchInput() {
        messageSearch.queryText = ""
        messageSearch.tokens = []
        messageSearch.operatorFilters = .init()
        messageSearch.parsedInputText = nil
        messageSearch.parsedContent = ""
    }

    func submitMessageSearch(
        page requestedPage: Int = 1,
        measuresPagination: Bool = false
    ) {
        let scope: MessageSearchScope
        if let guildID = selectedGuildID {
            scope = .guild(guildID)
        } else {
            scope = .directMessages
        }
        let clampedPage = min(400, max(1, requestedPage))
        let query = MessageSearchQuery(
            scope: requestedPage > 1
                ? messageSearch.submittedQuery?.scope ?? scope
                : scope,
            content: messageSearch.resolvedContent,
            filters: messageSearch.effectiveFilters,
            sort: messageSearch.sort,
            offset: (clampedPage - 1) * MessageSearchQuery.pageSize
        )
        guard !query.isEmpty else {
            messageSearch.requestTask?.cancel()
            messageSearch.requestTask = nil
            messageSearch.isSearching = false
            messageSearch.pollRefreshJournal = nil
            AppPerformanceSignposts.endResourceWindow(named: "MessageSearchBenchmark")
            AppPerformanceSignposts.endResourceWindow(
                named: "MessageSearchPaginationBenchmark"
            )
            AppPerformanceSignposts.cancelMessageSearchRequest()
            AppPerformanceSignposts.cancelMessageSearchPagination()
            messageSearch.clearResults()
            messageSearch.isPresented = false
            return
        }

        presentMessageSearchResultsIfNeeded()
        startMessageSearchRequest(query, measuresPagination: measuresPagination)
    }

    private func startMessageSearchRequest(_ query: MessageSearchQuery, measuresPagination: Bool) {
        let search = messageSearch
        search.requestTask?.cancel()
        AppPerformanceSignposts.endResourceWindow(named: "MessageSearchBenchmark")
        AppPerformanceSignposts.endResourceWindow(
            named: "MessageSearchPaginationBenchmark"
        )
        AppPerformanceSignposts.cancelMessageSearchRequest()
        AppPerformanceSignposts.cancelMessageSearchPagination()
        search.isSearching = true
        conversationRefreshJournalRevision &+= 1
        search.pollRefreshJournal = ConversationRefreshJournal(revision: conversationRefreshJournalRevision)
        search.errorMessage = nil
        let resourceWindowName = beginMessageSearchMeasurement(
            measuresPagination: measuresPagination
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        let session = accountSession()
        search.requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetchedPage = try await session.provider.searchMessages(query)
                try Task.checkCancellation()
                let page = self.messageSearchPagePreservingPollVotes(fetchedPage, search: search)
                let channelsByID = self.messageSearchChannelsByID(
                    additionalChannels: page.channels
                )
                let rows = await Task.detached(priority: .userInitiated) {
                    MessageSearchPresentation.rows(
                        for: page,
                        channelsByID: channelsByID
                    )
                }.value
                try Task.checkCancellation()
                guard self.isCurrentAccountSession(session) else {
                    throw CancellationError()
                }
                self.mergeMessageSearchPrivateChannels(page.channels)
                // Replay from the original response so vote deltas are applied
                // once even when more events arrived during row preparation.
                let latestPage = self.messageSearchPagePreservingPollVotes(fetchedPage, search: search)
                search.page = latestPage
                search.submittedQuery = query
                search.rows = latestPage == page ? rows : MessageSearchPresentation.rows(
                    for: latestPage, channelsByID: channelsByID
                )
                search.rowsRevision &+= 1
                search.errorMessage = nil
                search.isSearching = false
                search.pollRefreshJournal = nil
                search.lastCompletedLatencyMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                )
                search.requestTask = nil
                if self.messageSearch === search {
                    self.finishMessageSearchMeasurement(resourceWindowName, measuresPagination: measuresPagination)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.isCurrentAccountSession(session) else { return }
                search.page = nil
                search.rows = []
                search.rowsRevision &+= 1
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                search.errorMessage = error.localizedDescription
                search.isSearching = false
                search.pollRefreshJournal = nil
                search.requestTask = nil
                if self.messageSearch === search {
                    self.cancelMessageSearchMeasurement(resourceWindowName, measuresPagination: measuresPagination)
                }
            }
        }
    }

    private func presentMessageSearchResultsIfNeeded() {
        guard !isMessageSearchVisible else { return }
        AppPerformanceSignposts.beginMessageSearchOpen()
        WorkspaceLayoutMotion.perform(in: self, categories: inspectorMotionCategories) {
            // Results take a side chat pane's place: it closes for good.
            closePaneSideConversation()
            messageSearch.isPresented = true
        }
    }

    func submitMessageSearchInput() {
        let parsed = parsedMessageSearchInput()
        messageSearch.parsedInputText = messageSearch.queryText
        messageSearch.parsedContent = parsed.content
        messageSearch.operatorFilters = parsed.filters
        messageSearch.isInputFocused = false
        submitMessageSearch()
    }

    func updateMessageSearchSort(_ sort: MessageSearchSort) {
        guard messageSearch.sort != sort else { return }
        messageSearch.sort = sort
        guard messageSearch.page != nil else { return }
        submitMessageSearch()
    }

    private func beginMessageSearchMeasurement(
        measuresPagination: Bool
    ) -> String {
        let resourceWindowName = measuresPagination
            ? "MessageSearchPaginationBenchmark"
            : "MessageSearchBenchmark"
        AppPerformanceSignposts.beginResourceWindow(named: resourceWindowName)
        if measuresPagination {
            AppPerformanceSignposts.beginMessageSearchPagination()
        } else {
            AppPerformanceSignposts.beginMessageSearchRequest()
        }
        return resourceWindowName
    }

    private func finishMessageSearchMeasurement(
        _ resourceWindowName: String,
        measuresPagination: Bool
    ) {
        AppPerformanceSignposts.endResourceWindow(named: resourceWindowName)
        if measuresPagination {
            AppPerformanceSignposts.reportMessageSearchPaginationReady()
        } else {
            AppPerformanceSignposts.reportMessageSearchResultsReady()
        }
    }

    private func cancelMessageSearchMeasurement(
        _ resourceWindowName: String,
        measuresPagination: Bool
    ) {
        AppPerformanceSignposts.endResourceWindow(named: resourceWindowName)
        if measuresPagination {
            AppPerformanceSignposts.cancelMessageSearchPagination()
        } else {
            AppPerformanceSignposts.cancelMessageSearchRequest()
        }
    }

    func applyMessageSearchFilters(_ filters: MessageSearchFilters) {
        let parsed = parsedMessageSearchInput()
        messageSearch.filters = .init()
        messageSearch.tokens = messageSearchTokens(for: filters)
        messageSearch.parsedInputText = messageSearch.queryText
        messageSearch.parsedContent = parsed.content
        messageSearch.operatorFilters = parsed.filters
        submitMessageSearch()
    }

    var messageSearchUsers: [User] {
        var seen = Set<UserID>()
        // Discord's queryAllUsers path reads UserStore insertion order. This
        // projection contains every live Gateway user DTO, including broad
        // READY_SUPPLEMENTAL hydration, without app-specific disk-only users.
        var users = messageSearchSourceUsers.filter {
            seen.insert($0.id).inserted
        }
        if let selectedGuildID {
            // GuildMemberStore can resolve a member before the corresponding
            // UserStore update reaches the app snapshot (notably members
            // supplied by a live search chunk). Discord still admits that
            // member to queryGuildUsers immediately. Resolve those IDs from
            // the selected guild without changing their authoritative member
            // store ordering, which is supplied separately to the matcher.
            let localGuildUsers =
                (membersByGuildID[selectedGuildID]?.values.map(\.user) ?? [])
                + (memberListsByGuildID[selectedGuildID]?.map(\.user) ?? [])
                + messages.map(\.author)
            let localGuildUsersByID = Dictionary(
                localGuildUsers.map { ($0.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
            )
            let orderedUserIDs =
                (quickSwitcherGuildMemberUserIDs[selectedGuildID] ?? [])
                + localGuildUsers.map(\.id)
            for userID in orderedUserIDs where seen.insert(userID).inserted {
                if let user = localGuildUsersByID[userID] {
                    users.append(user)
                }
            }
        }
        if let currentUser,
           seen.insert(currentUser.id).inserted
        {
            users.insert(currentUser, at: 0)
        }
        return users
    }

    var messageSearchChannels: [Channel] {
        let allChannels = currentUser == nil ? visibleChannels : messagePresentationChannels
        let eligible = allChannels.filter { channel in
            if let selectedGuildID {
                return channel.guildID == selectedGuildID
            }
            return channel.kind.isDirectMessage
        }
        // Message search reads ChannelStore directly. Keep READY insertion
        // order here; the quick switcher's persisted restoration order is a
        // separate concern and must not leak into a clean search session.
        guard selectedGuildID == nil else { return eligible }
        return eligible.sorted { left, right in
            left.position == right.position
                ? left.id < right.id
                : left.position < right.position
        }
    }

    var messageSearchPromptTitle: String {
        guard let guild = selectedGuild else { return "Search in DMs" }
        return "Search \(guild.name)"
    }

    func messageSearchPresentedName(for channel: Channel) -> String {
        if channel.kind == .directMessage, let recipient = channel.recipients.first {
            return recipient.username
        }
        return channel.name
    }

    func parsePastedMessageSearchSyntax(_ value: String) {
        let parsed = MessageSearchTokenParser.parse(
            value,
            users: messageSearchUsers,
            channels: messageSearchChannels
        )
        for token in parsed.tokens where !messageSearch.tokens.contains(token) {
            messageSearch.tokens.append(token)
        }
        messageSearch.queryText = parsed.text
    }

    private func messageSearchTokens(
        for filters: MessageSearchFilters
    ) -> [MessageSearchToken] {
        let usersByID = Dictionary(
            messageSearchUsers.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let channelsByID = Dictionary(
            messageSearchChannels.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        var values: [MessageSearchToken] = []
        values += filters.authorIDs.compactMap { id in
            usersByID[id].map {
                MessageSearchToken(kind: .from(
                    userID: id,
                    username: $0.username,
                    displayName: $0.displayName
                ))
            }
        }
        values += filters.channelIDs.compactMap { id in
            channelsByID[id].map {
                MessageSearchToken(kind: .channel(channelID: id, name: $0.name))
            }
        }
        values += filters.contentTypes.map {
            MessageSearchToken(kind: .contentType($0))
        }
        values += filters.mentionedUserIDs.compactMap { id in
            usersByID[id].map {
                MessageSearchToken(kind: .mentions(
                    userID: id,
                    username: $0.username,
                    displayName: $0.displayName
                ))
            }
        }
        values += filters.authorTypes.map {
            MessageSearchToken(kind: .authorType($0))
        }
        if let pinned = filters.pinned {
            values.append(MessageSearchToken(kind: .pinned(pinned)))
        }
        let calendar = Calendar.current
        if let boundary = filters.maximumMessageID {
            let date = boundary.createdAt
            values.append(MessageSearchToken(kind: .before(
                value: Self.messageSearchISODate(date, calendar: calendar),
                boundary: boundary
            )))
        }
        if let boundary = filters.minimumMessageID,
           let date = calendar.date(byAdding: .day, value: -1, to: boundary.createdAt)
        {
            values.append(MessageSearchToken(kind: .after(
                value: Self.messageSearchISODate(date, calendar: calendar),
                boundary: boundary
            )))
        }
        return values
    }

    private static func messageSearchISODate(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func parsedMessageSearchInput() -> MessageSearchParsedInput {
        MessageSearchOperatorParser.parse(
            messageSearch.queryText,
            filters: .init(),
            users: messageSearchUsers,
            channels: messageSearchChannels
        )
    }

    func messageSearchChannelsByID(
        additionalChannels: [Channel]
    ) -> [ChannelID: Channel] {
        var channels = Dictionary(
            uniqueKeysWithValues: (snapshot?.channels ?? []).map { ($0.id, $0) }
        )
        for channel in visibleChannels {
            channels[channel.id] = channel
        }
        for channel in additionalChannels {
            channels[channel.id] = channel
        }
        return channels
    }

    private func mergeMessageSearchPrivateChannels(_ channels: [Channel]) {
        let privateChannels = MessageSearchChannelMergePolicy
            .canonicalPrivateChannels(in: channels)
        guard !privateChannels.isEmpty else { return }
        var known = Set(snapshot?.channels.map(\.id) ?? [])
        for channel in privateChannels where known.insert(channel.id).inserted {
            snapshot?.channels.append(channel)
        }
        forwardSearchSourceRevision &+= 1
    }
}
