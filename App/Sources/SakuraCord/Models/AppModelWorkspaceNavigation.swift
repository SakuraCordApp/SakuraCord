import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

@MainActor
@Observable
final class MessageSearchState {
    var isPresented = false
    var queryText = ""
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
        filters.merging(operatorFilters)
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
        parsedInputText = nil
        parsedContent = ""
        filters = .init()
        operatorFilters = .init()
        sort = .newest
        page = nil
        submittedQuery = nil
        errorMessage = nil
        isSearching = false
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
            messageSearch.queryText = newValue
            dismissMessageSearchIfInputIsEmpty()
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
        guard sessionState == .workspace, selectedChannelID != nil else { return }
        let currentScope = selectedGuildID.map(MessageSearchScope.guild) ?? .directMessages
        if messageSearch.submittedQuery?.scope != currentScope {
            messageSearch.clear()
        }
        workspaceNavigationOverlay = nil
        messageSearch.requestInputFocus()
    }

    func dismissMessageSearch() {
        guard messageSearch.isPresented else { return }
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
        guard messageSearch.queryText.isEmpty else { return }
        dismissMessageSearch()
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
                self.mergeMessageSearchChannels(page.channels)
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
        messageSearch.filters = filters
        messageSearch.parsedInputText = messageSearch.queryText
        messageSearch.parsedContent = parsed.content
        messageSearch.operatorFilters = parsed.filters
        submitMessageSearch()
    }

    var messageSearchUsers: [User] {
        var values: [UserID: User] = [:]
        for member in members {
            values[member.id] = member.user
        }
        for channel in snapshot?.channels ?? [] {
            for user in channel.recipients {
                values[user.id] = user
            }
        }
        return values.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    var messageSearchChannels: [Channel] {
        let allChannels = snapshot?.channels ?? visibleChannels
        return allChannels.filter { channel in
            if let selectedGuildID {
                return channel.guildID == selectedGuildID && channel.kind != .voice
            }
            return channel.kind == .directMessage || channel.kind == .groupDirectMessage
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func parsedMessageSearchInput() -> MessageSearchParsedInput {
        MessageSearchOperatorParser.parse(
            messageSearch.queryText,
            filters: .init(),
            users: messageSearchUsers,
            channels: messageSearchChannels
        )
    }

    private func messageSearchChannelsByID(
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

    private func mergeMessageSearchChannels(_ channels: [Channel]) {
        guard !channels.isEmpty else { return }
        var known = Set(snapshot?.channels.map(\.id) ?? [])
        for channel in channels where known.insert(channel.id).inserted {
            snapshot?.channels.append(channel)
        }
        forwardSearchSourceRevision &+= 1
    }

    func navigateToSearchResult(_ message: Message) {
        let guildID = message.guildID
            ?? snapshot?.channels.first(where: { $0.id == message.channelID })?.guildID
        messageSearch.selectedMessageID = message.id
        navigate(
            to: guildID,
            channelID: message.channelID,
            messageID: message.id
        )
    }

    func navigateToSearchReply(_ messageID: MessageID) {
        guard let source = messageSearch.page?.results.lazy
            .map(\.hit)
            .first(where: { $0.replyTo == messageID })
        else { return }
        let guildID = source.guildID
            ?? snapshot?.channels.first(where: { $0.id == source.channelID })?.guildID
        navigate(to: guildID, channelID: source.channelID, messageID: messageID)
    }
}
