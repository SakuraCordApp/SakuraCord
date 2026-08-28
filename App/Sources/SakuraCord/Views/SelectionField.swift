import AppKit
import Observation
import SwiftUI

nonisolated enum SelectionFieldImageShape: Hashable, Sendable {
    case circle
    case roundedRectangle
}

nonisolated enum SelectionFieldLeading: Hashable, Sendable {
    case none
    case systemImage(String)
    case text(String)
    case role(
        colorHex: UInt32?,
        iconURL: URL?,
        unicodeEmoji: String?
    )
    case remoteImage(
        url: URL?,
        fallback: String,
        shape: SelectionFieldImageShape = .circle
    )
}

nonisolated enum SelectionFieldTitleStyle: Hashable, Sendable {
    case standard
    case memberColor(UInt32?)
    case roleColor(UInt32?)
}

nonisolated struct SelectionFieldOption<ID: Hashable & Sendable>: Identifiable, Hashable, Sendable
{
    let id: ID
    let title: String
    let subtitle: String?
    let leading: SelectionFieldLeading
    let titleStyle: SelectionFieldTitleStyle
    let searchText: String

    init(
        id: ID,
        title: String,
        subtitle: String? = nil,
        leading: SelectionFieldLeading = .none,
        titleStyle: SelectionFieldTitleStyle = .standard,
        searchTerms: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.leading = leading
        self.titleStyle = titleStyle
        searchText = Self.normalized(
            ([title, subtitle].compactMap { $0 } + searchTerms)
                .joined(separator: " ")
        )
    }

    static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SelectionFieldSource<ID: Hashable & Sendable> {
    typealias Option = SelectionFieldOption<ID>
    typealias DynamicSearch = @MainActor @Sendable (String) async throws -> [Option]

    case local(options: [Option], maximumResults: Int? = nil)
    case dynamic(
        initialOptions: [Option] = [],
        minimumQueryLength: Int = 0,
        debounce: Duration = .milliseconds(120),
        maximumResults: Int? = nil,
        search: DynamicSearch
    )
}

nonisolated enum SelectionFieldSelectionMode: Equatable, Sendable {
    case single
    case multiple(maximum: Int? = nil)

    var allowsMultipleSelection: Bool {
        if case .multiple = self { return true }
        return false
    }

    var maximum: Int? {
        switch self {
        case .single: 1
        case .multiple(let maximum): maximum
        }
    }
}

nonisolated enum SelectionFieldSelectionPresentation: Equatable, Sendable {
    case title
    case cards
}

nonisolated enum SelectionFieldResultPlacement: Equatable, Sendable {
    case below
    case above
}

nonisolated enum SelectionFieldSelectionPolicy {
    static func toggled<ID: Hashable>(
        _ id: ID,
        in selection: [ID],
        mode: SelectionFieldSelectionMode
    ) -> [ID]? {
        if let existingIndex = selection.firstIndex(of: id) {
            var updated = selection
            updated.remove(at: existingIndex)
            return updated
        }
        switch mode {
        case .single:
            return [id]
        case .multiple(let maximum):
            guard maximum.map({ selection.count < $0 }) ?? true else {
                return nil
            }
            return selection + [id]
        }
    }
}

nonisolated struct SelectionFieldConfiguration: Sendable {
    var placeholder: String
    var searchPlaceholder: String
    var emptyTitle: String
    var rowHeight: CGFloat
    var maximumListHeight: CGFloat
    var initiallyExpanded: Bool
    var searches: Bool
    var clearsQueryAfterSelection: Bool
    var collapsesAfterSingleSelection: Bool
    var selectionPresentation: SelectionFieldSelectionPresentation
    var resultPlacement: SelectionFieldResultPlacement

    init(
        placeholder: String = "Select an option…",
        searchPlaceholder: String = "Search",
        emptyTitle: String = "No Matches",
        rowHeight: CGFloat = 44,
        maximumListHeight: CGFloat = 260,
        initiallyExpanded: Bool = false,
        searches: Bool = true,
        clearsQueryAfterSelection: Bool = true,
        collapsesAfterSingleSelection: Bool = true,
        selectionPresentation: SelectionFieldSelectionPresentation = .cards,
        resultPlacement: SelectionFieldResultPlacement = .below
    ) {
        self.placeholder = placeholder
        self.searchPlaceholder = searchPlaceholder
        self.emptyTitle = emptyTitle
        self.rowHeight = rowHeight
        self.maximumListHeight = maximumListHeight
        self.initiallyExpanded = initiallyExpanded
        self.searches = searches
        self.clearsQueryAfterSelection = clearsQueryAfterSelection
        self.collapsesAfterSingleSelection = collapsesAfterSingleSelection
        self.selectionPresentation = selectionPresentation
        self.resultPlacement = resultPlacement
    }
}

@MainActor
@Observable
final class SelectionFieldModel<ID: Hashable & Sendable> {
    typealias Option = SelectionFieldOption<ID>

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case needsMoreCharacters(Int)
        case failed(String)
    }

    private let source: SelectionFieldSource<ID>
    private var optionsByID: [ID: Option]
    private var task: Task<Void, Never>?
    private var generation = 0

    private(set) var query = ""
    private(set) var results: [Option]
    private(set) var state: State

    init(source: SelectionFieldSource<ID>) {
        self.source = source
        let initialOptions: [Option] = switch source {
        case .local(let options, let maximumResults):
            Self.limited(options, maximum: maximumResults)
        case .dynamic(let initialOptions, _, _, let maximumResults, _):
            Self.limited(initialOptions, maximum: maximumResults)
        }
        let retainedOptions: [Option] = switch source {
        case .local(let options, _): options
        case .dynamic(let initialOptions, _, _, _, _): initialOptions
        }
        results = initialOptions
        state = switch source {
        case .local: .loaded
        case .dynamic: .loaded
        }
        optionsByID = Dictionary(
            retainedOptions.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
    }

    isolated deinit {
        task?.cancel()
    }

    func activate() {
        guard state == .idle else { return }
        schedule(query: query, immediate: true)
    }

    func updateQuery(_ value: String) {
        guard query != value else { return }
        query = value
        schedule(query: value, immediate: false)
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    func option(for id: ID) -> Option? {
        optionsByID[id]
    }

    private func schedule(query: String, immediate: Bool) {
        generation &+= 1
        let requestedGeneration = generation
        task?.cancel()

        switch source {
        case .local(let options, let maximumResults):
            let normalizedQuery = Option.normalized(query)
            if normalizedQuery.isEmpty {
                install(Self.limited(options, maximum: maximumResults))
                return
            }
            state = .loading
            task = Task { [weak self] in
                let matches = await Task.detached(priority: .userInitiated) {
                    let filtered = normalizedQuery.isEmpty
                        ? options
                        : options.filter { $0.searchText.contains(normalizedQuery) }
                    return Self.limited(filtered, maximum: maximumResults)
                }.value
                guard let self,
                      !Task.isCancelled,
                      requestedGeneration == generation
                else { return }
                install(matches)
            }

        case let .dynamic(
            initialOptions,
            minimumQueryLength,
            debounce,
            maximumResults,
            search
        ):
            let normalizedQuery = query.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if normalizedQuery.isEmpty {
                install(Self.limited(
                    initialOptions,
                    maximum: maximumResults
                ))
                return
            }
            guard normalizedQuery.count >= minimumQueryLength else {
                results = Self.limited(initialOptions, maximum: maximumResults)
                state = .needsMoreCharacters(minimumQueryLength)
                return
            }
            state = .loading
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    if !immediate, debounce > .zero {
                        try await Task.sleep(for: debounce)
                    }
                    try Task.checkCancellation()
                    let loaded = try await search(normalizedQuery)
                    try Task.checkCancellation()
                    guard requestedGeneration == generation else { return }
                    install(Self.limited(loaded, maximum: maximumResults))
                } catch is CancellationError {
                    return
                } catch {
                    guard requestedGeneration == generation else { return }
                    results = []
                    state = .failed(error.localizedDescription)
                    task = nil
                }
            }
        }
    }

    private func install(_ options: [Option]) {
        results = options
        for option in options {
            optionsByID[option.id] = option
        }
        state = .loaded
        task = nil
    }

    nonisolated private static func limited(
        _ options: [Option],
        maximum: Int?
    ) -> [Option] {
        guard let maximum else { return options }
        return Array(options.prefix(max(0, maximum)))
    }
}

struct SelectionField<ID: Hashable & Sendable>: View {
    typealias Option = SelectionFieldOption<ID>

    @Binding private var selection: [ID]
    @State private var model: SelectionFieldModel<ID>
    @State private var isExpanded: Bool
    @State private var keyboardIndex: Int?
    @State private var searchIsFocused = false

    private let mode: SelectionFieldSelectionMode
    private let configuration: SelectionFieldConfiguration
    private let accessibilityIdentifier: String
    private let onDismiss: (() -> Void)?

    init(
        selection: Binding<[ID]>,
        mode: SelectionFieldSelectionMode,
        source: SelectionFieldSource<ID>,
        configuration: SelectionFieldConfiguration = .init(),
        accessibilityIdentifier: String = "selection-field",
        onDismiss: (() -> Void)? = nil
    ) {
        _selection = selection
        _model = State(initialValue: SelectionFieldModel(source: source))
        _isExpanded = State(initialValue: configuration.initiallyExpanded)
        self.mode = mode
        self.configuration = configuration
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onDismiss = onDismiss
    }

    init(
        selection: Binding<ID?>,
        source: SelectionFieldSource<ID>,
        configuration: SelectionFieldConfiguration = .init(),
        accessibilityIdentifier: String = "selection-field",
        onDismiss: (() -> Void)? = nil
    ) {
        self.init(
            selection: Binding(
                get: { selection.wrappedValue.map { [$0] } ?? [] },
                set: { selection.wrappedValue = $0.first }
            ),
            mode: .single,
            source: source,
            configuration: configuration,
            accessibilityIdentifier: accessibilityIdentifier,
            onDismiss: onDismiss
        )
    }

    var body: some View {
        VStack(spacing: 7) {
            if isExpanded, configuration.resultPlacement == .above {
                resultSurface
            }
            field
            if isExpanded, configuration.resultPlacement == .below {
                resultSurface
            }
        }
        .task {
            model.activate()
            if isExpanded {
                synchronizeKeyboardIndex(selectsFirst: true)
                await focusSearch()
            }
        }
        .onDisappear { model.cancel() }
        .onChange(of: model.results.map(\.id)) { _, _ in
            synchronizeKeyboardIndex(selectsFirst: true)
        }
        .onChange(of: model.query) { _, _ in
            synchronizeKeyboardIndex(selectsFirst: true)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var field: some View {
        SelectionFieldChrome(
            options: selection.compactMap(model.option(for:)),
            query: model.query,
            placeholder: searchPrompt,
            isEditable: configuration.searches && isExpanded,
            usesCards: configuration.selectionPresentation == .cards,
            isExpanded: isExpanded,
            wantsFocus: searchIsFocused,
            onQueryChange: model.updateQuery,
            onRemove: remove(_:),
            onFocusChange: { searchIsFocused = $0 },
            onActivate: activateInput,
            onCommand: handleInputCommand(_:),
            onToggle: toggleExpanded
        )
    }

    private var searchPrompt: String {
        selection.isEmpty && !isExpanded
            ? configuration.placeholder
            : configuration.searchPlaceholder
    }

    @ViewBuilder
    private var resultSurface: some View {
        ZStack(alignment: .topTrailing) {
            if model.results.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
            } else {
                SelectionFieldResultList(
                    rows: model.results.map { option in
                        SelectionFieldCanvasRow(
                            title: option.title,
                            subtitle: option.subtitle,
                            leading: option.leading,
                            titleStyle: option.titleStyle,
                            isSelected: selection.contains(option.id)
                        )
                    },
                    rowHeight: configuration.rowHeight,
                    allowsMultipleSelection: mode.allowsMultipleSelection,
                    keyboardIndex: keyboardIndex,
                    activate: activate(index:)
                )
            }
            if model.state == .loading, !model.results.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .padding(10)
                    .accessibilityLabel("Searching")
            }
        }
        .frame(height: resultHeight)
        .glassEffect(
            .regular,
            in: ConcentricRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            ConcentricRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
    }

    private var emptyState: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Searching…")
            case .needsMoreCharacters(let minimum):
                ContentUnavailableView(
                    "Type to Search",
                    systemImage: "text.cursor",
                    description: Text("Enter at least \(minimum) characters.")
                )
            case .failed(let message):
                ContentUnavailableView(
                    "Options Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded:
                ContentUnavailableView(
                    configuration.emptyTitle,
                    systemImage: "magnifyingglass"
                )
            }
        }
        .controlSize(.small)
    }

    private var resultHeight: CGFloat {
        guard !model.results.isEmpty else {
            return min(configuration.maximumListHeight, 124)
        }
        let contentHeight = CGFloat(model.results.count) * configuration.rowHeight + 12
        return min(configuration.maximumListHeight, contentHeight)
    }

    private func toggleExpanded() {
        if isExpanded {
            close()
        } else {
            open()
        }
    }

    private func open() {
        isExpanded = true
        model.activate()
        synchronizeKeyboardIndex(selectsFirst: true)
        Task { await focusSearch() }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
            return
        }
        isExpanded = false
        keyboardIndex = nil
        searchIsFocused = false
    }

    private func focusSearch() async {
        guard configuration.searches else { return }
        await Task.yield()
        searchIsFocused = true
    }

    private func activateInput() {
        if !isExpanded {
            open()
        } else if configuration.searches {
            searchIsFocused = true
        }
    }

    private func handleInputCommand(
        _ command: SelectionFieldInputCommand
    ) -> Bool {
        switch command {
        case .previous:
            moveKeyboardSelection(by: -1)
            return true
        case .next:
            if !isExpanded { open() }
            moveKeyboardSelection(by: 1)
            return true
        case .accept:
            guard isExpanded, let keyboardIndex else {
                open()
                return true
            }
            activate(index: keyboardIndex)
            return true
        case .dismiss:
            guard isExpanded else { return false }
            close()
            return true
        }
    }

    private func moveKeyboardSelection(by delta: Int) {
        guard !model.results.isEmpty else {
            keyboardIndex = nil
            return
        }
        let current = keyboardIndex ?? (delta > 0 ? -1 : 0)
        keyboardIndex = (current + delta + model.results.count) % model.results.count
    }

    private func synchronizeKeyboardIndex(selectsFirst: Bool) {
        guard !model.results.isEmpty else {
            keyboardIndex = nil
            return
        }
        if let keyboardIndex, model.results.indices.contains(keyboardIndex) {
            return
        }
        keyboardIndex = selectsFirst ? 0 : nil
    }

    private func activate(index: Int) {
        guard model.results.indices.contains(index) else { return }
        let id = model.results[index].id
        guard let updated = SelectionFieldSelectionPolicy.toggled(
            id,
            in: selection,
            mode: mode
        ) else {
            NSSound.beep()
            return
        }
        selection = updated

        if mode == .single, configuration.collapsesAfterSingleSelection {
            close()
        } else if configuration.clearsQueryAfterSelection, !model.query.isEmpty {
            model.updateQuery("")
        }
    }

    private func remove(_ id: ID) {
        selection.removeAll { $0 == id }
    }
}

struct SelectionFieldChrome<
    ID: Hashable & Sendable
>: NSViewRepresentable {
    let options: [SelectionFieldOption<ID>]
    let query: String
    let placeholder: String
    let isEditable: Bool
    let usesCards: Bool
    let isExpanded: Bool
    let wantsFocus: Bool
    let onQueryChange: (String) -> Void
    let onRemove: (ID) -> Void
    let onFocusChange: (Bool) -> Void
    let onActivate: () -> Void
    let onCommand: (SelectionFieldInputCommand) -> Bool
    let onToggle: () -> Void

    func makeNSView(context: Context) -> SelectionFieldControl<ID> {
        SelectionFieldControl(frame: .zero)
    }

    func updateNSView(
        _ control: SelectionFieldControl<ID>,
        context: Context
    ) {
        control.update(SelectionFieldControlConfiguration(
            options: options,
            query: query,
            placeholder: placeholder,
            isEditable: isEditable,
            usesCards: usesCards,
            isExpanded: isExpanded,
            wantsFocus: wantsFocus,
            onQueryChange: onQueryChange,
            onRemove: onRemove,
            onFocusChange: onFocusChange,
            onActivate: onActivate,
            onCommand: onCommand,
            onToggle: onToggle
        ))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView control: SelectionFieldControl<ID>,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(
            width: width,
            height: control.preferredHeight(forWidth: width)
        )
    }
}
