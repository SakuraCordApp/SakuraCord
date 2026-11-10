import Foundation
import Observation
import SakuraCordModels
import SwiftUI

struct MessageSearchPanelView: View {
    let model: AppModel
    @State private var scrollRequest: MessageTimelineScrollRequest?
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        @Bindable var search = model.messageSearch
        MessageSearchResultsContent(
            model: model,
            search: search,
            scrollRequest: scrollRequest,
            headerHeight: headerHeight,
            footerHeight: footerHeight
        )
        // Results scroll beneath the glass controls above and below them,
        // and the window toolbar.
        .safeAreaBar(edge: .top, spacing: 0) {
            MessageSearchResultsHeader(model: model, search: search)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            MessageSearchPagination(model: model, search: search)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .onAppear {
            AppPerformanceSignposts.reportMessageSearchPanelReady()
        }
        .onChange(of: search.submittedQuery) { _, _ in
            guard !search.rows.isEmpty else { return }
            scrollRequest = MessageTimelineScrollRequest(target: .top)
        }
        .onExitCommand {
            _ = model.consumeEscapeForUnfocusedMessageSearch()
        }
    }
}

private struct MessageSearchFilterSummary: View {
    let filters: MessageSearchFilters

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: InterfaceScale.metric(6)) {
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
            .font(.interface(.caption).weight(.medium))
            .padding(.horizontal, InterfaceScale.metric(8))
            .padding(.vertical, InterfaceScale.metric(4))
            .background(.quaternary, in: Capsule())
    }
}

private struct MessageSearchResultsHeader: View {
    let model: AppModel
    let search: MessageSearchState

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Text(resultTitle)
                .font(.interface(.headline).weight(.semibold))
                .contentTransition(.numericText())
                .padding(.horizontal, InterfaceScale.metric(14))
                .frame(height: MessageSearchFloatingControl.height)
                .glassEffect(.regular, in: Capsule())
            Spacer(minLength: InterfaceScale.metric(8))
            Button {
                search.isFilterModalPresented = true
            } label: {
                MessageSearchFloatingControl.circle("Filters", systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Filters")

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
                MessageSearchFloatingControl.circle("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Sort")
        }
        .padding(.horizontal, MessageSearchFloatingControl.barInset)
        .padding(.top, InterfaceScale.metric(4))
        .padding(.bottom, MessageSearchFloatingControl.barInset)
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
    let headerHeight: CGFloat
    let footerHeight: CGFloat

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
                    // The timeline pads its own ends, so the bars' inner
                    // insets would double up with that padding.
                    bottomContentInset: max(0, footerHeight - MessageSearchFloatingControl.barInset),
                    topBarHeight: max(0, headerHeight - MessageSearchFloatingControl.barInset),
                    unreadMessageID: nil,
                    highlightedMessageID: search.selectedMessageID,
                    initialScrollTarget: .top,
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
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .ignoresSafeArea(.container, edges: .vertical)
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
                VStack(spacing: InterfaceScale.metric(10)) {
                    ProgressView()
                    Text("Searching…")
                        .font(.interface(.caption))
                        .foregroundStyle(.secondary)
                }
                .padding(InterfaceScale.metric(18))
                .glassEffect(.regular, in: .rect(cornerRadius: InterfaceScale.metric(12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The search panel's floating glass controls. A circle's glass goes on its
/// button rather than its label, so a disabled button dims only its symbol.
private enum MessageSearchFloatingControl {
    static var height: CGFloat { InterfaceScale.metric(30) }
    /// Between a bar's controls and the panel's edges and results.
    static var barInset: CGFloat { InterfaceScale.metric(8) }

    static func circle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.interface(.body).weight(.medium))
            .frame(width: height, height: height)
            .contentShape(Circle())
    }
}

private struct MessageSearchPagination: View {
    let model: AppModel
    let search: MessageSearchState
    @State private var pageText = ""
    @FocusState private var isPageFieldFocused: Bool

    var body: some View {
        if let page = search.page, page.totalResults > MessageSearchQuery.pageSize {
            HStack(spacing: InterfaceScale.metric(8)) {
                pageButton("Previous Page", systemImage: "chevron.left", to: search.currentPage - 1)
                    .disabled(search.currentPage <= 1 || search.isSearching)
                pageField
                pageButton("Next Page", systemImage: "chevron.right", to: search.currentPage + 1)
                    .disabled(search.currentPage >= search.pageCount || search.isSearching)
            }
            .padding(MessageSearchFloatingControl.barInset)
            .frame(maxWidth: .infinity)
            .onChange(of: search.currentPage, initial: true) { _, page in pageText = String(page) }
            .onChange(of: isPageFieldFocused) { _, isFocused in
                // Focusing clears the number, so typing starts a new one.
                pageText = isFocused ? "" : String(search.currentPage)
            }
        }
    }

    /// The page shown, which the reader can type over, and the last page.
    private var pageField: some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            Text("Page")
                .foregroundStyle(.primary.opacity(0.7))
            ZStack {
                // As wide as the last page's number.
                Text(String(repeating: "8", count: String(search.pageCount).count)).hidden()
                TextField(String(search.currentPage), text: $pageText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($isPageFieldFocused)
                    .onSubmit(showTypedPage)
                    // Cancels the edit rather than reaching the panel, which
                    // closes search.
                    .onExitCommand { isPageFieldFocused = false }
            }
            .fixedSize()
            Text("of \(search.pageCount)")
                .foregroundStyle(.primary.opacity(0.7))
        }
        // The whole bubble takes the click.
        .allowsHitTesting(false)
        .font(.interface(.body).weight(.medium))
        .monospacedDigit()
        .padding(.horizontal, InterfaceScale.metric(14))
        .frame(height: MessageSearchFloatingControl.height)
        .contentShape(Capsule())
        .onTapGesture { isPageFieldFocused = true }
        // Not interactive: the field flickers as pressed glass settles.
        .glassEffect(.regular, in: Capsule())
        .disabled(search.isSearching)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(search.currentPage) of \(search.pageCount)")
    }

    private func pageButton(_ title: String, systemImage: String, to page: Int) -> some View {
        Button {
            model.submitMessageSearch(page: page, measuresPagination: true)
        } label: {
            MessageSearchFloatingControl.circle(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(title)
    }

    private func showTypedPage() {
        let typed = Int(pageText)
        isPageFieldFocused = false
        guard let typed else { return }
        let page = min(max(typed, 1), search.pageCount)
        guard page != search.currentPage else { return }
        model.submitMessageSearch(page: page, measuresPagination: true)
    }
}

private struct MessageSearchFilterPresentation: Identifiable {
    let id = "message-search-filters"
}

struct MessageSearchFiltersWindowOverlay: View {
    let model: AppModel

    var body: some View {
        WindowModalOverlay(
            presentation: model.messageSearch.isFilterModalPresented
                ? MessageSearchFilterPresentation() : nil,
            dismiss: {
                model.messageSearch.isFilterModalPresented = false
            },
            content: { _, animationState in
                MessageSearchFiltersOverlay(
                    model: model,
                    search: model.messageSearch,
                    animationState: animationState,
                    dismiss: {
                        animationState.dismiss(committingPresentation: true)
                    }
                )
            }
        )
    }
}

struct MessageSearchFiltersOverlay: View {
    private static var contentWidth: CGFloat { InterfaceScale.metric(464) }

    let model: AppModel
    let search: MessageSearchState
    let animationState: WindowModalContext
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
                WindowModalBackdrop(opacity: 0.48, dismiss: dismiss)
                GlassEffectContainer(spacing: 0) {
                    panel
                        .background(
                            Color(nsColor: .windowBackgroundColor),
                            in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous)
                        )
                        .overlay {
                            ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous)
                                .stroke(.separator, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.28), radius: InterfaceScale.metric(24), y: 10)
                        .scaleEffect(animationState.isVisible ? 1 : 0.965)
                        .frame(
                            width: min(500, max(0, geometry.size.width - 48)),
                            height: min(650, max(0, geometry.size.height - 48))
                        )
                        .padding(InterfaceScale.metric(24))
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
                    .font(.interface(.title2).weight(.semibold))
                Spacer()
                HoverCloseButton(
                    help: "Close",
                    accessibilityIdentifier: "message-search-close",
                    action: dismiss
                )
            }
            .padding(InterfaceScale.metric(18))

            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(18)) {
                    MessageSearchMultiSelect(
                        title: "From",
                        subtitle: "Sent by any of the selected users",
                        values: users,
                        selectedIDs: draft.authorIDs,
                        label: { $0.displayName },
                        rowSubtitle: { $0.username },
                        leading: { user in
                            .remoteImage(
                                url: user.avatarURL,
                                fallback: user.displayName
                            )
                        },
                        update: { draft.authorIDs = $0 }
                    )

                    MessageSearchMultiSelect(
                        title: "In",
                        subtitle: channelSubtitle,
                        values: channels,
                        selectedIDs: draft.channelIDs,
                        label: { $0.name },
                        rowSubtitle: { channelSelectionSubtitle($0) },
                        leading: { channelSelectionLeading($0) },
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
                        rowSubtitle: { $0.username },
                        leading: { user in
                            .remoteImage(
                                url: user.avatarURL,
                                fallback: user.displayName
                            )
                        },
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

                    VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
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
                .padding(.horizontal, InterfaceScale.metric(18))
                .padding(.bottom, InterfaceScale.metric(18))
            }
            .clipped()

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
                    .tint(SakuraCordAccentColor.color)
            }
            .padding(InterfaceScale.metric(18))
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

    private func channelSelectionLeading(
        _ channel: Channel
    ) -> SelectionFieldLeading {
        switch channel.kind {
        case .directMessage:
            let recipient = channel.recipients.first
            return .remoteImage(
                url: recipient?.avatarURL,
                fallback: recipient?.displayName ?? channel.name
            )
        case .groupDirectMessage:
            return .remoteImage(
                url: channel.iconURL,
                fallback: channel.name
            )
        case .voice:
            return .systemImage("speaker.wave.2.fill")
        case .forum:
            return .systemImage("rectangle.3.group.bubble.left.fill")
        case .announcement:
            return .systemImage("megaphone.fill")
        case .text, .unknown:
            return .systemImage("number")
        }
    }

    private func channelSelectionSubtitle(_ channel: Channel) -> String? {
        switch channel.kind {
        case .directMessage:
            return channel.recipients.first?.username
        case .groupDirectMessage:
            return "Group DM"
        case .voice:
            return "Voice"
        case .forum:
            return "Forum"
        case .announcement:
            return "Announcement"
        case .text:
            return "Text"
        case .unknown:
            return nil
        }
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
where Value.ID: Hashable & Sendable {
    let title: String
    let subtitle: String
    let values: [Value]
    let selectedIDs: [Value.ID]
    let label: (Value) -> String
    let rowSubtitle: (Value) -> String?
    let leading: (Value) -> SelectionFieldLeading
    let update: @MainActor @Sendable ([Value.ID]) -> Void

    init(
        title: String,
        subtitle: String,
        values: [Value],
        selectedIDs: [Value.ID],
        label: @escaping (Value) -> String,
        rowSubtitle: @escaping (Value) -> String? = { _ in nil },
        leading: @escaping (Value) -> SelectionFieldLeading = { _ in .none },
        update: @escaping @MainActor @Sendable ([Value.ID]) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.values = values
        self.selectedIDs = selectedIDs
        self.label = label
        self.rowSubtitle = rowSubtitle
        self.leading = leading
        self.update = update
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            MessageSearchFilterLabel(title: title, subtitle: subtitle)
            SelectionField(
                selection: Binding(
                    get: { selectedIDs },
                    set: update
                ),
                mode: .multiple(),
                source: .local(options: values.map { value in
                    SelectionFieldOption(
                        id: value.id,
                        title: label(value),
                        subtitle: rowSubtitle(value),
                        leading: leading(value)
                    )
                }),
                configuration: SelectionFieldConfiguration(
                    placeholder: "Any",
                    searchPlaceholder: "Search \(title.lowercased())",
                    maximumListHeight: 220
                ),
                accessibilityIdentifier: "message-search-\(title.lowercased())-field"
            )
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageSearchOptionMenu<Value: Hashable & Sendable>: View {
    let title: String
    let subtitle: String
    let values: [Value]
    let selected: [Value]
    let label: (Value) -> String
    let update: @MainActor @Sendable ([Value]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            MessageSearchFilterLabel(title: title, subtitle: subtitle)
            SelectionField(
                selection: Binding(
                    get: { selected },
                    set: update
                ),
                mode: .multiple(),
                source: .local(options: values.map { value in
                    SelectionFieldOption(
                        id: value,
                        title: label(value)
                    )
                }),
                configuration: SelectionFieldConfiguration(
                    placeholder: "Any",
                    searchPlaceholder: "Search \(title.lowercased())",
                    maximumListHeight: 220
                ),
                accessibilityIdentifier: "message-search-\(title.lowercased())-field"
            )
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageSearchDateFilters: View {
    @Binding var beforeEnabled: Bool
    @Binding var beforeDate: Date
    @Binding var afterEnabled: Bool
    @Binding var afterDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
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
                .font(.interface(.caption))
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
                .tint(SakuraCordAccentColor.color)
                .labelsHidden()
            Button("Remove \(title.lowercased()) date", systemImage: "xmark") {
                remove()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, InterfaceScale.metric(12))
        .frame(height: InterfaceScale.metric(42))
        .glassEffect(.regular, in: .rect(cornerRadius: InterfaceScale.metric(8)))
    }
}

private struct MessageSearchFilterLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
            Text(title)
                .fontWeight(.semibold)
            Text(subtitle)
                .font(.interface(.caption))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MessageSearchFilterMenuLabel: View {
    let title: String
    var leadingSystemImage: String?

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            if let leadingSystemImage {
                Image(systemName: leadingSystemImage)
            }
            Text(title)
                .lineLimit(1)
            Spacer(minLength: InterfaceScale.metric(8))
            Image(systemName: "chevron.down")
                .font(.interface(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, InterfaceScale.metric(12))
        .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(42))
        .contentShape(.rect)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: InterfaceScale.metric(8)))
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
        .frame(height: InterfaceScale.metric(42))
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
