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
            channel.guildID == nil
                && (
                    channel.kind == .directMessage
                        || channel.kind == .groupDirectMessage
                )
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
    var isFilterSheetPresented = false
    var selectedMessageID: MessageID?
    var lastCompletedLatencyMilliseconds: Int?
    var parsedInputText: String?
    var parsedContent = ""
    var isInputFocused = false
    @ObservationIgnored var rows: [MessageRowPresentation] = []
    @ObservationIgnored var rowsRevision: UInt64 = 0
    @ObservationIgnored let rowsUpdateJournal = MessageRowsUpdateJournal()
    @ObservationIgnored var requestTask: Task<Void, Never>?

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
        AppPerformanceSignposts.endResourceWindow(named: "MessageSearchBenchmark")
        AppPerformanceSignposts.endResourceWindow(named: "MessageSearchPaginationBenchmark")
        AppPerformanceSignposts.cancelMessageSearchRequest()
        AppPerformanceSignposts.cancelMessageSearchPagination()
        AppPerformanceSignposts.endMessageSearchScroll()
        requestTask = nil
        queryText = ""
        tokens = []
        parsedInputText = nil
        parsedContent = ""
        filters = .init()
        operatorFilters = .init()
        sort = .newest
        page = nil
        submittedQuery = nil
        errorMessage = nil
        isSearching = false
        isFilterSheetPresented = false
        selectedMessageID = nil
        lastCompletedLatencyMilliseconds = nil
        isInputFocused = false
        rows = []
        rowsRevision &+= 1
    }
}

@MainActor
extension AppModel {
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

    func presentQuickSwitcher() {
        guard sessionState == .workspace else { return }
        if workspaceNavigationOverlay == .quickSwitcher {
            dismissWorkspaceNavigationOverlay()
            return
        }
        AppPerformanceSignposts.beginQuickSwitcherOpen()
        workspaceNavigationOverlay = .quickSwitcher
    }

    func presentMessageSearch() {
        guard sessionState == .workspace,
              selectedChannelID != nil,
              MessageSearchSurfacePolicy.showsToolbar(
                  channelKind: selectedChannel?.kind,
                  hasOpenThread: openThread != nil
              )
        else { return }
        let currentScope = selectedGuildID.map(MessageSearchScope.guild) ?? .directMessages
        if messageSearch.submittedQuery?.scope != currentScope {
            messageSearch.clear()
        }
        workspaceNavigationOverlay = nil
        messageSearch.requestInputFocus()
    }

    func presentMessageSearchFromCommand() {
        presentMessageSearch()
        guard messageSearch.isInputFocused,
              let selectedChannelID,
              let channel = messageSearchChannels.first(where: { $0.id == selectedChannelID })
        else { return }
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
        messageSearch.isPresented = false
        messageSearch.isInputFocused = false
    }

    func dismissMessageSearchIfInputIsEmpty() {
        guard messageSearch.queryText.isEmpty, messageSearch.tokens.isEmpty else { return }
        dismissMessageSearch()
    }

    @discardableResult
    func consumeEscapeForUnfocusedMessageSearch() -> Bool {
        guard messageSearch.isPresented, !messageSearch.isInputFocused else { return false }
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

    func dismissWorkspaceNavigationOverlay() {
        if workspaceNavigationOverlay == .quickSwitcher {
            AppPerformanceSignposts.beginQuickSwitcherClose()
        }
        workspaceNavigationOverlay = nil
    }

    func activateQuickSwitcherDestination(_ destination: ForwardDestination) {
        switch destination.kind {
        case .channel(let channel):
            workspaceNavigationOverlay = nil
            navigate(to: channel.id)
        case .thread(let thread, _):
            workspaceNavigationOverlay = nil
            navigate(to: thread.guildID, linkedChannelID: thread.id)
        case .user(let user, let directMessage):
            if let directMessage {
                workspaceNavigationOverlay = nil
                navigate(to: directMessage.id)
                return
            }
            workspaceNavigationOverlay = nil
            let session = accountSession()
            startAccountChildTask(account: session) { model, session in
                do {
                    let channel = try await session.provider.ensurePrivateChannel(for: user.id)
                    guard model.isCurrentAccountSession(session) else { return }
                    if model.snapshot?.channels.contains(where: { $0.id == channel.id }) == false {
                        model.snapshot?.channels.append(channel)
                        model.forwardSearchSourceRevision &+= 1
                    }
                    model.navigate(to: channel.id)
                } catch {
                    guard model.isCurrentAccountSession(session) else { return }
                    model.errorMessage = error.localizedDescription
                }
            }
        }
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
            AppPerformanceSignposts.endResourceWindow(named: "MessageSearchBenchmark")
            AppPerformanceSignposts.endResourceWindow(
                named: "MessageSearchPaginationBenchmark"
            )
            AppPerformanceSignposts.cancelMessageSearchRequest()
            AppPerformanceSignposts.cancelMessageSearchPagination()
            messageSearch.page = nil
            messageSearch.submittedQuery = nil
            messageSearch.errorMessage = nil
            messageSearch.rows = []
            messageSearch.rowsRevision &+= 1
            messageSearch.isPresented = false
            return
        }

        presentMessageSearchResultsIfNeeded()

        messageSearch.requestTask?.cancel()
        AppPerformanceSignposts.endResourceWindow(named: "MessageSearchBenchmark")
        AppPerformanceSignposts.endResourceWindow(
            named: "MessageSearchPaginationBenchmark"
        )
        AppPerformanceSignposts.cancelMessageSearchRequest()
        AppPerformanceSignposts.cancelMessageSearchPagination()
        messageSearch.isSearching = true
        messageSearch.errorMessage = nil
        let resourceWindowName = beginMessageSearchMeasurement(
            measuresPagination: measuresPagination
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        let session = accountSession()
        messageSearch.requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await session.provider.searchMessages(query)
                try Task.checkCancellation()
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
                self.messageSearch.page = page
                self.messageSearch.submittedQuery = query
                self.messageSearch.rows = rows
                self.messageSearch.rowsRevision &+= 1
                self.messageSearch.errorMessage = nil
                self.messageSearch.isSearching = false
                self.messageSearch.lastCompletedLatencyMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                )
                self.messageSearch.requestTask = nil
                self.finishMessageSearchMeasurement(
                    resourceWindowName,
                    measuresPagination: measuresPagination
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentAccountSession(session) else { return }
                self.messageSearch.page = nil
                self.messageSearch.rows = []
                self.messageSearch.rowsRevision &+= 1
                self.messageSearch.errorMessage = error.localizedDescription
                self.messageSearch.isSearching = false
                self.messageSearch.requestTask = nil
                self.cancelMessageSearchMeasurement(
                    resourceWindowName,
                    measuresPagination: measuresPagination
                )
            }
        }
    }

    private func presentMessageSearchResultsIfNeeded() {
        guard !messageSearch.isPresented else { return }
        AppPerformanceSignposts.beginMessageSearchOpen()
        messageSearch.isPresented = true
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
        var users = (snapshot?.messageSearchUsers ?? []).filter {
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
                (snapshot?.quickSwitcherGuildMemberUserIDs[selectedGuildID] ?? [])
                + localGuildUsers.map(\.id)
            for userID in orderedUserIDs where seen.insert(userID).inserted {
                if let user = localGuildUsersByID[userID] {
                    users.append(user)
                }
            }
        }
        if let currentUser = snapshot?.currentUser,
           seen.insert(currentUser.id).inserted
        {
            users.insert(currentUser, at: 0)
        }
        return users
    }

    var messageSearchChannels: [Channel] {
        let allChannels = snapshot?.channels ?? visibleChannels
        let eligible = allChannels.filter { channel in
            if let selectedGuildID {
                return channel.guildID == selectedGuildID
            }
            return channel.kind == .directMessage || channel.kind == .groupDirectMessage
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
        guard let selectedGuildID,
              let guild = snapshot?.guilds.first(where: { $0.id == selectedGuildID })
        else { return "Search in DMs" }
        return "Search \(guild.name)"
    }

    func messageSearchPresentedName(for channel: Channel) -> String {
        if channel.kind == .directMessage, let recipient = channel.recipients.first {
            return recipient.username
        }
        return channel.name
    }

    func messageSearchGuildAliases(guildID: GuildID) -> [UserID: [String]] {
        var aliases: [UserID: [String]] = [:]
        func append(_ value: String?, for userID: UserID) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  aliases[userID, default: []].contains(where: {
                      $0.localizedCaseInsensitiveCompare(value) == .orderedSame
                  }) == false
            else { return }
            aliases[userID, default: []].append(value)
        }
        for (userID, nickname) in snapshot?.quickSwitcherGuildMemberAliases[guildID] ?? [:] {
            append(nickname, for: userID)
        }
        for member in membersByGuildID[guildID]?.values ?? [UserID: Member]().values {
            append(member.globalDisplayName, for: member.id)
            append(member.user.displayName, for: member.id)
        }
        for member in memberListsByGuildID[guildID] ?? [] {
            append(member.globalDisplayName, for: member.id)
            append(member.user.displayName, for: member.id)
        }
        return aliases
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

    func navigateToSearchResult(_ message: Message) {
        messageSearch.selectedMessageID = message.id
        guard let result = messageSearch.page?.results.first(where: {
            $0.hit.id == message.id
        }) else { return }
        navigateToMessageSearchResult(result, messageID: message.id)
    }

    func navigateToPinnedResult(_ message: Message) {
        navigateToMessageResult(
            source: message,
            messageID: message.id,
            initialMessages: message.channelID == openThread?.id ? [message] : nil,
            isKnownThread: message.channelID == openThread?.id
        )
    }

    func navigateToPinnedReply(_ messageID: MessageID) {
        guard let source = pinnedMessages.items.first(where: {
            $0.message.replyTo == messageID
        })?.message else { return }
        let isKnownThread = source.channelID == openThread?.id
        navigateToMessageResult(
            source: source,
            messageID: messageID,
            initialMessages: isKnownThread ? [source] : nil,
            isKnownThread: isKnownThread
        )
    }

    func navigateToSearchReply(_ messageID: MessageID) {
        guard let result = messageSearch.page?.results.first(where: {
            $0.hit.replyTo == messageID
        })
        else { return }
        navigateToMessageSearchResult(result, messageID: messageID)
    }

    private func navigateToMessageSearchResult(
        _ result: MessageSearchResult,
        messageID: MessageID
    ) {
        let isGuildThreadResult = messageSearch.submittedQuery?.scope.guildID != nil
            && messageSearch.page?.channels.contains(where: {
                $0.id == result.hit.channelID
            }) == true
        navigateToMessageResult(
            source: result.hit,
            messageID: messageID,
            initialMessages: result.messages,
            isKnownThread: isGuildThreadResult
        )
    }

    private func navigateToMessageResult(
        source: Message,
        messageID: MessageID,
        initialMessages: [Message]?,
        isKnownThread: Bool
    ) {
        let guildID = source.guildID
            ?? snapshot?.channels.first(where: { $0.id == source.channelID })?.guildID
        if isKnownThread {
            navigate(
                to: guildID,
                linkedChannelID: source.channelID,
                messageID: messageID,
                initialMessages: initialMessages ?? [source]
            )
        } else {
            navigate(
                to: guildID,
                channelID: source.channelID,
                messageID: messageID
            )
        }
    }
}
