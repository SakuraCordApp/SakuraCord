import Foundation
import Observation
import SakuraCordModels
import SwiftUI

struct MessageSearchPanelView: View {
    let model: AppModel
    @State private var scrollRequest: MessageTimelineScrollRequest?

    var body: some View {
        @Bindable var search = model.messageSearch
        VStack(spacing: 0) {
            MessageSearchResultsHeader(model: model, search: search)
            Divider()
            MessageSearchResultsContent(
                model: model,
                search: search,
                scrollRequest: scrollRequest
            )
            MessageSearchPagination(model: model, search: search)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            if search.isInputFocused {
                MessageSearchSuggestionOverlay(model: model, search: search)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
        }
        .sheet(isPresented: $search.isFilterSheetPresented) {
            MessageSearchFiltersSheet(model: model, search: search)
        }
        .onAppear {
            AppPerformanceSignposts.reportMessageSearchPanelReady()
        }
        .onChange(of: search.submittedQuery) { _, _ in
            guard let firstID = search.rows.first?.id else { return }
            scrollRequest = MessageTimelineScrollRequest(
                target: .message(firstID, anchor: .top)
            )
        }
    }
}

private struct MessageSearchSuggestionOverlay: View {
    let model: AppModel
    let search: MessageSearchState

    var body: some View {
        if !suggestions.isEmpty {
            MessageSearchSuggestions(
                title: suggestionTitle,
                suggestions: suggestions,
                activate: activate
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var suggestions: [MessageSearchSuggestion] {
        let fragment = activeFragment
        if fragment.isEmpty {
            var values: [MessageSearchSuggestion] = []
            if model.selectedGuildID == nil,
               let channel = model.selectedChannel,
               channel.kind == .directMessage || channel.kind == .groupDirectMessage
            {
                values.append(.currentDirectMessage(channel))
            }
            values.append(contentsOf: [
                .operator(.from),
                .operator(.in),
                .operator(.has),
                .operator(.mentions),
                .moreFilters,
            ])
            return values
        }

        guard !search.queryText.dropLast(fragment.count).contains(where: { !$0.isWhitespace })
                || fragment.contains(":")
        else { return [] }
        guard let separator = fragment.firstIndex(of: ":") else {
            return MessageSearchTextOperator.allCases
                .filter { $0.rawValue.hasPrefix(fragment.lowercased()) }
                .map(MessageSearchSuggestion.operator)
        }

        let operatorName = String(fragment[..<separator]).lowercased()
        let value = String(fragment[fragment.index(after: separator)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"@#"))
        guard let searchOperator = MessageSearchTextOperator(alias: operatorName) else {
            return []
        }
        switch searchOperator {
        case .from, .mentions:
            return model.messageSearchUsers
                .filter { value.isEmpty || $0.displayName.localizedCaseInsensitiveContains(value)
                    || $0.username.localizedCaseInsensitiveContains(value) }
                .prefix(8)
                .map { .user(searchOperator, $0) }
        case .in:
            return model.messageSearchChannels
                .filter { value.isEmpty || $0.name.localizedCaseInsensitiveContains(value) }
                .prefix(8)
                .map(MessageSearchSuggestion.channel)
        case .has:
            return MessageSearchContentType.allCases
                .filter { value.isEmpty || $0.rawValue.hasPrefix(value.lowercased()) }
                .map(MessageSearchSuggestion.contentType)
        case .authorType:
            return MessageSearchAuthorType.allCases
                .filter { value.isEmpty || $0.rawValue.hasPrefix(value.lowercased()) }
                .map(MessageSearchSuggestion.authorType)
        case .pinned:
            return [.pinned(true), .pinned(false)]
        case .before, .after:
            return [.dateHint(searchOperator)]
        }
    }

    private var activeFragment: String {
        search.queryText.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }

    private var suggestionTitle: String {
        guard let separator = activeFragment.firstIndex(of: ":"),
              let searchOperator = MessageSearchTextOperator(
                  alias: String(activeFragment[..<separator]).lowercased()
              )
        else { return "Filters" }
        return switch searchOperator {
        case .from, .mentions: "Users"
        case .in: "Channels"
        case .has: "Includes"
        case .before, .after: "Date"
        case .authorType: "Author Type"
        case .pinned: "Pinned"
        }
    }

    private func activate(_ suggestion: MessageSearchSuggestion) {
        switch suggestion {
        case .currentDirectMessage(let channel):
            replaceActiveFragment(with: "in:\(quotedIfNeeded(channel.name))")
        case .operator(let searchOperator):
            replaceActiveFragment(with: "\(searchOperator.rawValue):")
        case .user(let searchOperator, let user):
            replaceActiveFragment(
                with: "\(searchOperator.rawValue):\(quotedIfNeeded(user.username))"
            )
        case .channel(let channel):
            replaceActiveFragment(with: "in:\(quotedIfNeeded(channel.name))")
        case .contentType(let type):
            replaceActiveFragment(with: "has:\(type.rawValue)")
        case .authorType(let type):
            replaceActiveFragment(with: "author_type:\(type.rawValue)")
        case .pinned(let pinned):
            replaceActiveFragment(with: "pinned:\(pinned)")
        case .dateHint(let searchOperator):
            replaceActiveFragment(
                with: "\(searchOperator.rawValue):\(Self.isoDate(Date.now))"
            )
        case .moreFilters:
            search.isInputFocused = false
            search.isFilterSheetPresented = true
            return
        }
        search.requestInputFocus()
    }

    private func replaceActiveFragment(with replacement: String) {
        guard !activeFragment.isEmpty,
              let range = search.queryText.range(of: activeFragment, options: .backwards)
        else {
            search.queryText = replacement
            return
        }
        search.queryText.replaceSubrange(range, with: replacement)
    }

    private func quotedIfNeeded(_ value: String) -> String {
        value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
    }

    private static func isoDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private enum MessageSearchTextOperator: String, CaseIterable, Identifiable {
    case from
    case `in`
    case has
    case mentions
    case before
    case after
    case authorType
    case pinned

    init?(alias: String) {
        switch alias {
        case "from": self = .from
        case "in": self = .in
        case "has": self = .has
        case "mentions": self = .mentions
        case "before": self = .before
        case "after": self = .after
        case "authortype", "author_type", "type": self = .authorType
        case "pinned": self = .pinned
        default: return nil
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .from: "From"
        case .in: "In"
        case .has: "Has"
        case .mentions: "Mentions"
        case .before: "Before"
        case .after: "After"
        case .authorType: "Author Type"
        case .pinned: "Pinned"
        }
    }

    var suggestionTitle: String {
        switch self {
        case .from: "From a specific user"
        case .in: "Sent in a specific channel"
        case .has: "Includes a specific type of data"
        case .mentions: "Mentions a specific user"
        case .before: "Sent before a date"
        case .after: "Sent after a date"
        case .authorType: "Sent by a type of author"
        case .pinned: "Pinned or unpinned"
        }
    }

    var suggestionExample: String {
        switch self {
        case .from: "from: user"
        case .in: "in: channel"
        case .has: "has: link, embed or file"
        case .mentions: "mentions: user"
        case .before: "before: YYYY-MM-DD"
        case .after: "after: YYYY-MM-DD"
        case .authorType: "author_type: bot"
        case .pinned: "pinned: true"
        }
    }

    var systemImage: String {
        switch self {
        case .from: "person.fill"
        case .in: "number"
        case .has: "paperclip"
        case .mentions: "at"
        case .before, .after: "calendar"
        case .authorType: "person.badge.shield.checkmark"
        case .pinned: "pin.fill"
        }
    }
}

private enum MessageSearchSuggestion: Identifiable {
    case currentDirectMessage(Channel)
    case `operator`(MessageSearchTextOperator)
    case user(MessageSearchTextOperator, User)
    case channel(Channel)
    case contentType(MessageSearchContentType)
    case authorType(MessageSearchAuthorType)
    case pinned(Bool)
    case dateHint(MessageSearchTextOperator)
    case moreFilters

    var id: String {
        switch self {
        case .currentDirectMessage(let channel): "scope:\(channel.id)"
        case .operator(let value): "operator:\(value.id)"
        case .user(let value, let user): "user:\(value.id):\(user.id)"
        case .channel(let channel): "channel:\(channel.id)"
        case .contentType(let value): "content:\(value.rawValue)"
        case .authorType(let value): "author:\(value.rawValue)"
        case .pinned(let value): "pinned:\(value)"
        case .dateHint(let value): "date:\(value.id)"
        case .moreFilters: "more-filters"
        }
    }
}

private struct MessageSearchSuggestions: View {
    let title: String
    let suggestions: [MessageSearchSuggestion]
    let activate: (MessageSearchSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if case .some(.currentDirectMessage(let channel)) = suggestions.first {
                Button { activate(suggestions[0]) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                        Text("Find in")
                            .font(.headline.weight(.semibold))
                        AvatarView(
                            name: channel.name,
                            url: channel.iconURL ?? channel.recipients.first?.avatarURL,
                            size: 22
                        )
                        Text(channel.name)
                            .font(.headline.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                    .padding(.horizontal, 12)
                    .frame(height: 54)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Find in \(channel.name)")

                Divider()
                    .padding(.horizontal, -5)
            }

            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 3)

            ForEach(filterSuggestions) { suggestion in
                Button { activate(suggestion) } label: {
                    HStack(spacing: 10) {
                        suggestionIcon(suggestion)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(for: suggestion))
                                .font(.callout.weight(.medium))
                            Text(subtitle(for: suggestion))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                    .padding(.horizontal, 12)
                    .frame(height: 56)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
    }

    private var filterSuggestions: [MessageSearchSuggestion] {
        guard case .some(.currentDirectMessage) = suggestions.first else {
            return suggestions
        }
        return Array(suggestions.dropFirst())
    }

    private func title(for suggestion: MessageSearchSuggestion) -> String {
        switch suggestion {
        case .currentDirectMessage(let channel): "Find in \(channel.name)"
        case .operator(let value): value.suggestionTitle
        case .user(_, let user): user.displayName
        case .channel(let channel): channel.name
        case .contentType(let value): value.title
        case .authorType(let value): value.title
        case .pinned(let value): value ? "True" : "False"
        case .dateHint: "YYYY-MM-DD"
        case .moreFilters: "More filters"
        }
    }

    private func subtitle(for suggestion: MessageSearchSuggestion) -> String {
        switch suggestion {
        case .currentDirectMessage: "Limit results to this conversation"
        case .operator(let value): value.suggestionExample
        case .user(_, let user): "@\(user.username)"
        case .channel(let channel): channel.category ?? "Channel"
        case .contentType: "Message content type"
        case .authorType: "Message author type"
        case .pinned: "Pinned state"
        case .dateHint(let value): "Type a date after \(value.rawValue):"
        case .moreFilters: "Dates, author type, pinned, and more"
        }
    }

    private func systemImage(for suggestion: MessageSearchSuggestion) -> String {
        switch suggestion {
        case .currentDirectMessage: "bubble.left.and.bubble.right"
        case .operator(let value): value.systemImage
        case .user: "person.fill"
        case .channel: "number"
        case .contentType: "paperclip"
        case .authorType: "person.badge.shield.checkmark"
        case .pinned: "pin.fill"
        case .dateHint: "calendar"
        case .moreFilters: "line.3.horizontal.decrease"
        }
    }

    @ViewBuilder
    private func suggestionIcon(_ suggestion: MessageSearchSuggestion) -> some View {
        switch suggestion {
        case .user(_, let user):
            AvatarView(
                name: user.displayName,
                url: user.avatarURL,
                size: 22
            )
        case .currentDirectMessage(let channel):
            AvatarView(
                name: channel.name,
                url: channel.iconURL ?? channel.recipients.first?.avatarURL,
                size: 22
            )
        default:
            Image(systemName: systemImage(for: suggestion))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MessageSearchFilterSummary: View {
    let filters: MessageSearchFilters

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if !filters.authorIDs.isEmpty {
                    chip("From \(filters.authorIDs.count)", image: "person.fill")
                }
                if !filters.channelIDs.isEmpty {
                    chip("In \(filters.channelIDs.count)", image: "number")
                }
                if !filters.contentTypes.isEmpty {
                    chip("Has \(filters.contentTypes.count)", image: "paperclip")
                }
                if !filters.mentionedUserIDs.isEmpty {
                    chip("Mentions \(filters.mentionedUserIDs.count)", image: "at")
                }
                if !filters.authorTypes.isEmpty {
                    chip("Author \(filters.authorTypes.count)", image: "person.badge.shield.checkmark")
                }
                if let pinned = filters.pinned {
                    chip(pinned ? "Pinned" : "Not pinned", image: "pin.fill")
                }
                if filters.minimumMessageID != nil {
                    chip("After", image: "calendar")
                }
                if filters.maximumMessageID != nil {
                    chip("Before", image: "calendar")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, image: String) -> some View {
        Label(title, systemImage: image)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}

private struct MessageSearchResultsHeader: View {
    let model: AppModel
    let search: MessageSearchState

    var body: some View {
        HStack(spacing: 8) {
            Text(resultTitle)
                .font(.headline.weight(.semibold))
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            Button {
                search.isFilterSheetPresented = true
            } label: {
                Label(
                    search.effectiveFilters.isEmpty
                        ? "Filters"
                        : "Filters (\(search.effectiveFilters.count))",
                    systemImage: "line.3.horizontal.decrease"
                )
            }
            .buttonStyle(.borderless)

            Menu {
                ForEach(MessageSearchSort.allCases, id: \.self) { sort in
                    Button {
                        model.updateMessageSearchSort(sort)
                    } label: {
                        if search.sort == sort {
                            Label(sort.title, systemImage: "checkmark")
                        } else {
                            Text(sort.title)
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var resultTitle: String {
        guard let page = search.page else { return "Results" }
        return page.totalResults == 0
            ? "No Results"
            : "\(page.totalResults.formatted()) Results"
    }
}

private struct MessageSearchResultsContent: View {
    let model: AppModel
    let search: MessageSearchState
    let scrollRequest: MessageTimelineScrollRequest?

    var body: some View {
        ZStack {
            if let errorMessage = search.errorMessage {
                ContentUnavailableView(
                    "Search Failed",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text(errorMessage)
                )
            } else if let page = search.page, page.results.isEmpty {
                ContentUnavailableView.search(text: search.queryText)
            } else if search.page != nil {
                NativeMessageTimelineView(
                    model: model,
                    conversation: .search,
                    beginning: nil,
                    firstMessageStartsDayOverride: false,
                    hasMoreMessages: false,
                    isLoadingEarlier: false,
                    bottomContentInset: 0,
                    unreadMessageID: nil,
                    highlightedMessageID: search.selectedMessageID,
                    initialScrollTarget: search.rows.first.map {
                        .message($0.id, anchor: .top)
                    },
                    scrollRequest: scrollRequest,
                    runsPerformanceAutoScroll: false,
                    loadEarlier: {},
                    openReply: model.navigateToSearchReply,
                    onScrollActivityChange: { _ in },
                    onScrollStateChange: { _ in },
                    onUserScrollBegan: {
                        AppPerformanceSignposts.beginMessageSearchScroll()
                    },
                    onUserScrollEnded: { _ in
                        AppPerformanceSignposts.endMessageSearchScroll()
                    }
                )
                .scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                ContentUnavailableView(
                    "Search messages",
                    systemImage: "text.magnifyingglass",
                    description: Text(
                        model.selectedGuildID == nil
                            ? "Search every direct message, or choose a DM with Filters."
                            : "Press Return to search this server. Add filters to narrow the results."
                    )
                )
            }

            if search.isSearching {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Searching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageSearchPagination: View {
    let model: AppModel
    let search: MessageSearchState

    var body: some View {
        if let page = search.page, page.totalResults > MessageSearchQuery.pageSize {
            HStack {
                Spacer(minLength: 0)
                ControlGroup {
                    Button {
                        model.submitMessageSearch(
                            page: search.currentPage - 1,
                            measuresPagination: true
                        )
                    } label: {
                        Label("Previous Page", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(search.currentPage <= 1 || search.isSearching)
                    .help("Previous Page")

                    Menu {
                        ForEach(1 ... max(1, search.pageCount), id: \.self) { number in
                        Button {
                            model.submitMessageSearch(
                                page: number,
                                measuresPagination: true
                            )
                        } label: {
                            if number == search.currentPage {
                                Label("Page \(number)", systemImage: "checkmark")
                            } else {
                                Text("Page \(number)")
                            }
                        }
                        .disabled(search.isSearching || number == search.currentPage)
                        }
                    } label: {
                        Text("Page \(search.currentPage) of \(search.pageCount)")
                            .monospacedDigit()
                    }
                    .disabled(search.isSearching)

                    Button {
                        model.submitMessageSearch(
                            page: search.currentPage + 1,
                            measuresPagination: true
                        )
                    } label: {
                        Label("Next Page", systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(search.currentPage >= search.pageCount || search.isSearching)
                    .help("Next Page")
                }
                .controlSize(.regular)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

private struct MessageSearchFiltersSheet: View {
    private static let contentWidth: CGFloat = 464

    let model: AppModel
    let search: MessageSearchState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MessageSearchFilters()
    @State private var beforeEnabled = false
    @State private var beforeDate = Date.now
    @State private var afterEnabled = false
    @State private var afterDate = Date.now
    @State private var pinnedChoice = MessageSearchPinnedChoice.any

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Filters")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
            .padding(18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MessageSearchMultiSelect(
                        title: "From",
                        subtitle: "Sent by any of the selected users",
                        values: users,
                        selectedIDs: draft.authorIDs,
                        label: { $0.displayName },
                        update: { draft.authorIDs = $0 }
                    )

                    MessageSearchMultiSelect(
                        title: "In",
                        subtitle: channelSubtitle,
                        values: channels,
                        selectedIDs: draft.channelIDs,
                        label: { $0.name },
                        update: { draft.channelIDs = $0 }
                    )

                    MessageSearchOptionMenu(
                        title: "Has",
                        subtitle: "Includes any of the selected types of data",
                        values: MessageSearchContentType.allCases,
                        selected: draft.contentTypes,
                        label: { $0.title },
                        update: { draft.contentTypes = $0 }
                    )

                    MessageSearchMultiSelect(
                        title: "Mentions",
                        subtitle: "Mentions any of the selected users",
                        values: users,
                        selectedIDs: draft.mentionedUserIDs,
                        label: { $0.displayName },
                        update: { draft.mentionedUserIDs = $0 }
                    )

                    MessageSearchDateFilters(
                        beforeEnabled: $beforeEnabled,
                        beforeDate: $beforeDate,
                        afterEnabled: $afterEnabled,
                        afterDate: $afterDate
                    )

                    MessageSearchOptionMenu(
                        title: "Author Type",
                        subtitle: "Sent by any selected type of author",
                        values: MessageSearchAuthorType.allCases,
                        selected: draft.authorTypes,
                        label: { $0.title },
                        update: { draft.authorTypes = $0 }
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        MessageSearchFilterLabel(
                            title: "Pinned",
                            subtitle: "Whether the message is pinned"
                        )
                        MessageSearchFilterMenu(title: pinnedChoice.title) {
                            ForEach(MessageSearchPinnedChoice.allCases) { choice in
                                Button {
                                    pinnedChoice = choice
                                } label: {
                                    if choice == pinnedChoice {
                                        Label(choice.title, systemImage: "checkmark")
                                    } else {
                                        Text(choice.title)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: Self.contentWidth, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }

            Divider()
            HStack {
                Button("Clear Filters") {
                    draft = .init()
                    beforeEnabled = false
                    afterEnabled = false
                    pinnedChoice = .any
                }
                .disabled(draft.isEmpty && !beforeEnabled && !afterEnabled)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply Filters") { apply() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)
        }
        .frame(width: 500, height: 650)
        .onAppear { restoreDraft() }
    }

    private var users: [User] {
        model.messageSearchUsers
    }

    private var channels: [Channel] {
        model.messageSearchChannels
    }

    private var channelSubtitle: String {
        model.selectedGuildID == nil
            ? "Sent in any of the selected DMs"
            : "Sent in any of the selected channels"
    }

    private func restoreDraft() {
        draft = search.filters
        beforeEnabled = draft.maximumMessageID != nil
        beforeDate = draft.maximumMessageID?.createdAt ?? .now
        afterEnabled = draft.minimumMessageID != nil
        if let minimum = draft.minimumMessageID?.createdAt,
           let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: minimum)
        {
            afterDate = previousDay
        } else {
            afterDate = .now
        }
        pinnedChoice = MessageSearchPinnedChoice(draft.pinned)
    }

    private func apply() {
        let calendar = Calendar.current
        draft.maximumMessageID = beforeEnabled
            ? .messageSearchBoundary(at: calendar.startOfDay(for: beforeDate))
            : nil
        draft.minimumMessageID = afterEnabled
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: afterDate))
                .map { MessageID.messageSearchBoundary(at: $0) }
            : nil
        draft.pinned = pinnedChoice.value
        model.applyMessageSearchFilters(draft)
        dismiss()
    }

}

private struct MessageSearchMultiSelect<Value: Identifiable>: View
where Value.ID: Hashable {
    let title: String
    let subtitle: String
    let values: [Value]
    let selectedIDs: [Value.ID]
    let label: (Value) -> String
    let update: ([Value.ID]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageSearchFilterLabel(title: title, subtitle: subtitle)
            MessageSearchFilterMenu(title: selectionTitle) {
                ForEach(values) { value in
                    Button {
                        toggle(value.id)
                    } label: {
                        if selectedIDs.contains(value.id) {
                            Label(label(value), systemImage: "checkmark")
                        } else {
                            Text(label(value))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionTitle: String {
        selectedIDs.isEmpty ? "Any" : "\(selectedIDs.count) selected"
    }

    private func toggle(_ id: Value.ID) {
        var values = selectedIDs
        if let index = values.firstIndex(of: id) {
            values.remove(at: index)
        } else {
            values.append(id)
        }
        update(values)
    }
}

private struct MessageSearchOptionMenu<Value: Hashable>: View {
    let title: String
    let subtitle: String
    let values: [Value]
    let selected: [Value]
    let label: (Value) -> String
    let update: ([Value]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageSearchFilterLabel(title: title, subtitle: subtitle)
            MessageSearchFilterMenu(
                title: selected.isEmpty ? "Any" : "\(selected.count) selected"
            ) {
                ForEach(values, id: \.self) { value in
                    Button {
                        toggle(value)
                    } label: {
                        if selected.contains(value) {
                            Label(label(value), systemImage: "checkmark")
                        } else {
                            Text(label(value))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ value: Value) {
        var values = selected
        if let index = values.firstIndex(of: value) {
            values.remove(at: index)
        } else {
            values.append(value)
        }
        update(values)
    }
}

private struct MessageSearchDateFilters: View {
    @Binding var beforeEnabled: Bool
    @Binding var beforeDate: Date
    @Binding var afterEnabled: Bool
    @Binding var afterDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageSearchFilterLabel(
                title: "Date",
                subtitle: "When the message was sent"
            )
            if !beforeEnabled, !afterEnabled {
                MessageSearchFilterMenu(
                    title: "Add date",
                    leadingSystemImage: "plus"
                ) {
                    Button("Before a date") { beforeEnabled = true }
                    Button("After a date") { afterEnabled = true }
                }
            }
            if beforeEnabled {
                dateRow(
                    title: "Before",
                    date: $beforeDate,
                    remove: { beforeEnabled = false }
                )
            }
            if afterEnabled {
                dateRow(
                    title: "After",
                    date: $afterDate,
                    remove: { afterEnabled = false }
                )
            }
            if beforeEnabled != afterEnabled {
                Button(afterEnabled ? "Add a before date" : "Add an after date") {
                    if afterEnabled {
                        beforeEnabled = true
                    } else {
                        afterEnabled = true
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dateRow(
        title: String,
        date: Binding<Date>,
        remove: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .fontWeight(.medium)
            Spacer()
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
            Button("Remove \(title.lowercased()) date", systemImage: "xmark") {
                remove()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }
}

private struct MessageSearchFilterLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fontWeight(.semibold)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MessageSearchFilterMenuLabel: View {
    let title: String
    var leadingSystemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            if let leadingSystemImage {
                Image(systemName: leadingSystemImage)
            }
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 42)
        .contentShape(.rect)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
    }
}

private struct MessageSearchFilterMenu<Content: View>: View {
    let title: String
    var leadingSystemImage: String?
    let content: Content

    init(
        title: String,
        leadingSystemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leadingSystemImage = leadingSystemImage
        self.content = content()
    }

    var body: some View {
        ZStack {
            MessageSearchFilterMenuLabel(
                title: title,
                leadingSystemImage: leadingSystemImage
            )
            .allowsHitTesting(false)

            Menu {
                content
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(title)
        }
        .frame(height: 42)
    }
}

private enum MessageSearchPinnedChoice: String, CaseIterable, Identifiable {
    case any
    case pinned
    case notPinned

    init(_ value: Bool?) {
        self = switch value {
        case true: .pinned
        case false: .notPinned
        case nil: .any
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .any: "Any"
        case .pinned: "True"
        case .notPinned: "False"
        }
    }

    var value: Bool? {
        switch self {
        case .any: nil
        case .pinned: true
        case .notPinned: false
        }
    }
}

private extension MessageSearchSort {
    var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .mostRelevant: "Most Relevant"
        }
    }
}

private extension MessageSearchContentType {
    var title: String { rawValue.capitalized }
}

private extension MessageSearchAuthorType {
    var title: String { rawValue.capitalized }
}
