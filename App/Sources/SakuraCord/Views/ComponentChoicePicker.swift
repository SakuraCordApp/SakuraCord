import SakuraCordModels
import SwiftUI

struct ComponentChoicePicker: View {
    typealias Loader = @MainActor @Sendable (String) async throws
        -> [ComponentSelectOption]

    @State private var selection: [String] = []

    private let placeholder: String
    private let options: [ComponentSelectOption]
    private let minimumSelectionCount: Int
    private let maximumSelectionCount: Int
    private let loader: Loader
    private let submit: ([String]) -> Void

    init(
        placeholder: String,
        options: [ComponentSelectOption],
        minimumSelectionCount: Int,
        maximumSelectionCount: Int,
        loader: @escaping Loader,
        submit: @escaping ([String]) -> Void
    ) {
        self.placeholder = placeholder
        self.options = options
        self.minimumSelectionCount = max(0, minimumSelectionCount)
        self.maximumSelectionCount = max(1, maximumSelectionCount)
        self.loader = loader
        self.submit = submit
        _selection = State(
            initialValue: Array(
                options.filter(\.isDefault).map(\.value)
                    .prefix(max(1, maximumSelectionCount))
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SelectionField(
                selection: $selection,
                mode: selectionMode,
                source: source,
                configuration: SelectionFieldConfiguration(
                    placeholder: placeholder,
                    searchPlaceholder: "Search options",
                    maximumListHeight: maximumSelectionCount > 1 ? 232 : 260,
                    initiallyExpanded: true,
                    clearsQueryAfterSelection: maximumSelectionCount > 1,
                    collapsesAfterSingleSelection: false,
                    selectionPresentation: .cards
                ),
                accessibilityIdentifier: "component-selection-field"
            )

            if maximumSelectionCount > 1 {
                HStack(spacing: 8) {
                    Text(selectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select") {
                        submit(selection)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SakuraCordAccentColor.color)
                    .disabled(!selectionCountIsValid)
                }
            }
        }
        .padding(12)
        .frame(
            width: 372,
            height: maximumSelectionCount > 1 ? 358 : 326,
            alignment: .top
        )
        .onChange(of: selection) { oldValue, newValue in
            guard maximumSelectionCount == 1,
                  newValue.count == 1,
                  newValue != oldValue
            else { return }
            submit(newValue)
        }
    }

    private var selectionMode: SelectionFieldSelectionMode {
        maximumSelectionCount == 1
            ? .single
            : .multiple(maximum: maximumSelectionCount)
    }

    private var source: SelectionFieldSource<String> {
        if !options.isEmpty {
            return .local(
                options: options.map(Self.fieldOption),
                maximumResults: 25
            )
        }
        return .dynamic(
            debounce: .milliseconds(120),
            maximumResults: 25
        ) { query in
            try await loader(query).map(Self.fieldOption)
        }
    }

    private var selectionCountIsValid: Bool {
        selection.count >= minimumSelectionCount
            && selection.count <= maximumSelectionCount
    }

    private var selectionSummary: String {
        if minimumSelectionCount == maximumSelectionCount {
            return "Select \(minimumSelectionCount)"
        }
        return "Select \(minimumSelectionCount)–\(maximumSelectionCount)"
    }

    private static func fieldOption(
        _ option: ComponentSelectOption
    ) -> SelectionFieldOption<String> {
        SelectionFieldOption(
            id: option.value,
            title: option.label,
            subtitle: option.description,
            leading: option.emoji.map(leading(for:)) ?? .none,
            searchTerms: [option.value]
        )
    }

    private static func leading(
        for emoji: EmojiReference
    ) -> SelectionFieldLeading {
        if let url = emoji.imageURL(size: 64) {
            return .remoteImage(
                url: url,
                fallback: emoji.name,
                shape: .roundedRectangle
            )
        }
        return .text(emoji.name)
    }
}
