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

nonisolated enum SelectionFieldCompletion: Sendable {
    case selected
    case dismissed
    case cancelled
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
        if mode == .single { return [id] }
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
    var maximumListHeight: CGFloat
    var initiallyExpanded: Bool
    var searches: Bool
    var collapsesAfterSingleSelection: Bool
    var resultPlacement: SelectionFieldResultPlacement

    init(
        placeholder: String = "Select an option…",
        searchPlaceholder: String = "Search",
        emptyTitle: String = "No Matches",
        maximumListHeight: CGFloat = 260,
        initiallyExpanded: Bool = false,
        searches: Bool = true,
        collapsesAfterSingleSelection: Bool = true,
        resultPlacement: SelectionFieldResultPlacement = .below
    ) {
        self.placeholder = placeholder
        self.searchPlaceholder = searchPlaceholder
        self.emptyTitle = emptyTitle
        self.maximumListHeight = maximumListHeight
        self.initiallyExpanded = initiallyExpanded
        self.searches = searches
        self.collapsesAfterSingleSelection = collapsesAfterSingleSelection
        self.resultPlacement = resultPlacement
    }
}

struct SelectionField<ID: Hashable & Sendable>: View {
    typealias Option = SelectionFieldOption<ID>

    @Binding private var selection: [ID]
    @State private var model: SelectionFieldModel<ID>
    @State private var isExpanded = false
    @State private var fieldWidth: CGFloat = 360
    @State private var hovered = false
    @State private var hoveredTokenID: ID?
    @State private var highlightedID: ID?
    @State private var resultHeight: CGFloat = 260
    @State private var searchIsFocused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private let source: SelectionFieldSource<ID>
    private let mode: SelectionFieldSelectionMode
    private let configuration: SelectionFieldConfiguration
    private let accessibilityIdentifier: String
    private let onComplete: ((SelectionFieldCompletion) -> Void)?

    init(
        selection: Binding<[ID]>,
        mode: SelectionFieldSelectionMode,
        source: SelectionFieldSource<ID>,
        configuration: SelectionFieldConfiguration = .init(),
        accessibilityIdentifier: String = "selection-field",
        onComplete: ((SelectionFieldCompletion) -> Void)? = nil
    ) {
        _selection = selection
        _model = State(initialValue: SelectionFieldModel(source: source))
        _isExpanded = State(initialValue: configuration.initiallyExpanded)
        self.source = source
        self.mode = mode
        self.configuration = configuration
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onComplete = onComplete
    }

    init(
        selection: Binding<ID?>,
        source: SelectionFieldSource<ID>,
        configuration: SelectionFieldConfiguration = .init(),
        accessibilityIdentifier: String = "selection-field",
        onComplete: ((SelectionFieldCompletion) -> Void)? = nil
    ) {
        self.init(
            selection: Binding(
                get: { selection.wrappedValue.map { [$0] } ?? [] },
                set: { selection.wrappedValue = $0.first }
            ),
            mode: .single, source: source, configuration: configuration,
            accessibilityIdentifier: accessibilityIdentifier, onComplete: onComplete
        )
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) { field }
        .background {
            SelectionFieldDropdown(
                isPresented: isExpanded, height: resultHeight,
                preferredPlacement: configuration.resultPlacement, reduceMotion: reduceMotion,
                dismiss: { close(.dismissed) }, cancel: { close(.cancelled) },
                content: { height in menu(height: height).disabled(!isEnabled) }
            )
        }
        .onAppear {
            model.retainSelectedOptions(selection)
            if isExpanded { prepareExpansion() }
        }
        .onChange(of: selection) { _, ids in model.retainSelectedOptions(ids) }
        .onChange(of: sourceOptions) { _, _ in model.replaceSource(source) }
        .onChange(of: model.results.map(\.id)) { _, ids in
            if let highlightedID, ids.contains(highlightedID) { return }
            highlightedID = model.query.isEmpty ? nil : ids.first
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled, isExpanded { close(.cancelled) }
        }
        .onDisappear { model.cancel() }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var sourceOptions: [Option] {
        switch source {
        case .local(let options, _), .dynamic(let options, _, _, _, _): options
        }
    }

    private var selectedOptions: [Option] {
        selection.map { model.option(for: $0) ?? Option(id: $0, title: "Unavailable option") }
    }

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
    }

    private var field: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            ProfileRoleFlowLayout(spacing: SelectionFieldLayoutMetrics.tokenSpacing, alignment: .center) {
                ForEach(selectedOptions) { option in
                    token(option)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                if selection.isEmpty {
                    Text(configuration.placeholder)
                        .font(.interfaceSystem(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: SelectionFieldLayoutMetrics.tokenHeight, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if isExpanded { close(.dismissed) } else { open() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.interfaceSystem(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.86), value: isExpanded)
                    .foregroundStyle(isExpanded ? SakuraCordAccentColor.color : .secondary)
                    .frame(width: InterfaceScale.metric(22), height: InterfaceScale.metric(28))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Close options" : "Show options")
        }
        .padding(.horizontal, InterfaceScale.metric(11))
        .padding(.vertical, InterfaceScale.metric(7))
        .frame(minHeight: InterfaceScale.metric(44))
        .contentShape(.rect(cornerRadius: InterfaceScale.metric(11)))
        .onTapGesture { open() }
        .glassEffect(.regular, in: .rect(cornerRadius: InterfaceScale.metric(11)))
        .overlay {
            RoundedRectangle(cornerRadius: InterfaceScale.metric(11))
                .strokeBorder(isExpanded
                    ? SakuraCordAccentColor.color.opacity(0.65)
                    : Color.primary.opacity(hovered ? 0.25 : 0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onModalHover { hovered = $0 }
        .animation(motion, value: selection)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fieldWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(configuration.placeholder)
    }

    private func token(_ option: Option) -> some View {
        HStack(spacing: InterfaceScale.metric(5)) {
            SelectionFieldOptionLabel(option: option)
            Button {
                withAnimation(motion) { selection.removeAll { $0 == option.id } }
            } label: {
                Image(systemName: "xmark")
                    .font(.interfaceSystem(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(28))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(option.title)")
        }
        .padding(.leading, InterfaceScale.metric(9))
        .padding(.trailing, InterfaceScale.metric(5))
        .frame(
            width: SelectionFieldLayoutMetrics.tokenWidth(
                option,
                availableWidth: SelectionFieldLayoutMetrics.tokenAvailableWidth(in: fieldWidth)
            ),
            height: SelectionFieldLayoutMetrics.tokenHeight
        )
        .background(.primary.opacity(hoveredTokenID == option.id ? 0.26 : 0.08), in: Capsule())
        .onModalHover { hoveredTokenID = $0 ? option.id : nil }
        .animation(nil, value: hoveredTokenID == option.id)
    }

    private func menu(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if configuration.searches {
                PickerSearchHeader(
                    text: Binding(get: { model.query }, set: { model.updateQuery($0) }),
                    focus: { searchIsFocused = true },
                    input: {
                    SelectionFieldSearchInput(
                        query: Binding(get: { model.query }, set: { model.updateQuery($0) }),
                        placeholder: configuration.searchPlaceholder,
                        wantsFocus: searchIsFocused,
                        searches: true,
                        activate: { searchIsFocused = true },
                        move: moveHighlight,
                        accept: acceptHighlight,
                        dismiss: { close(.cancelled) }
                    )
                })
                Divider().overlay(.primary.opacity(0.04))
            }
            SelectionFieldMenu(
                model: model, selection: $selection, highlightedID: $highlightedID, mode: mode,
                configuration: configuration,
                height: max(0, height - (configuration.searches ? ChatChromeMetrics.pickerSearchHeaderHeight + 1 : 0)),
                activate: activate
            )
        }
        // The list floats over message text; a backing keeps rows legible
        // while the glass still picks up the surrounding tint.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.78), in: .rect(cornerRadius: InterfaceScale.metric(11)))
        .glassEffect(.regular, in: .rect(cornerRadius: InterfaceScale.metric(11)))
        .overlay {
            RoundedRectangle(cornerRadius: InterfaceScale.metric(11)).strokeBorder(.primary.opacity(0.1), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private func prepareExpansion() {
        model.updateQuery("")
        model.replaceSource(source)
        model.activate()
        highlightedID = nil
        resultHeight = min(configuration.maximumListHeight, max(100, CGFloat(model.results.count) * 52 + 12))
            + (configuration.searches ? ChatChromeMetrics.pickerSearchHeaderHeight + 1 : 0)
        searchIsFocused = configuration.searches
    }

    private func open() {
        guard isEnabled else { return }
        if !isExpanded {
            prepareExpansion()
            isExpanded = true
        } else {
            searchIsFocused = configuration.searches
        }
    }

    private func close(_ completion: SelectionFieldCompletion) {
        searchIsFocused = false
        if let onComplete { onComplete(completion); return }
        isExpanded = false
        model.cancel()
    }

    private func activate(_ id: ID) {
        guard isEnabled, model.state == .loaded,
              let updated = SelectionFieldSelectionPolicy.toggled(id, in: selection, mode: mode) else { return }
        withAnimation(motion) { selection = updated }
        if mode == .single, configuration.collapsesAfterSingleSelection { close(.selected) }
    }

    private func moveHighlight(_ delta: Int) {
        guard isExpanded else { open(); return }
        let ids = model.results.map(\.id)
        guard !ids.isEmpty else { return }
        let current = highlightedID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        highlightedID = ids[min(ids.count - 1, max(0, current + delta))]
    }

    private func acceptHighlight() {
        guard isExpanded else { open(); return }
        if let highlightedID { activate(highlightedID) }
    }
}
