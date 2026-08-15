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

struct MessageSearchFiltersOverlay: View {
    private static let contentWidth: CGFloat = 464

    let model: AppModel
    let search: MessageSearchState
    let animationState: WindowModalAnimationState
    let dismiss: () -> Void
    @State private var draft = MessageSearchFilters()
    @State private var beforeEnabled = false
    @State private var beforeDate = Date.now
    @State private var afterEnabled = false
    @State private var afterDate = Date.now
    @State private var pinnedChoice = MessageSearchPinnedChoice.any

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.48)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                GlassEffectContainer(spacing: 0) {
                    panel
                        .background(
                            Color(nsColor: .windowBackgroundColor),
                            in: ConcentricRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay {
                            ConcentricRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.separator, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
                        .scaleEffect(animationState.isVisible ? 1 : 0.965)
                        .frame(
                            width: min(500, max(0, geometry.size.width - 48)),
                            height: min(650, max(0, geometry.size.height - 48))
                        )
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .accessibilityAddTraits(.isModal)
        .animation(
            .easeOut(duration: WindowModalAnimationTiming.openingSeconds),
            value: animationState.isVisible
        )
        .onExitCommand(perform: dismiss)
        .onAppear { restoreDraft() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Filters")
                    .font(.title2.weight(.semibold))
                Spacer()
                HoverCloseButton(
                    help: "Close",
                    accessibilityIdentifier: "message-search-close",
                    action: dismiss
                )
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
        draft = search.effectiveFilters
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
        Menu {
            content
        } label: {
            MessageSearchFilterMenuLabel(
                title: title,
                leadingSystemImage: leadingSystemImage
            )
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(title)
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
