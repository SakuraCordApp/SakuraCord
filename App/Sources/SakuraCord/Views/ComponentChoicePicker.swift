import AppKit
import SakuraCordModels
import SwiftUI

struct ComponentChoicePicker: View {
    typealias Loader = @MainActor @Sendable (String) async throws
        -> [ComponentSelectOption]

    @State private var selection: [String] = []
    @State private var knownOptionsByValue:
        [String: ComponentSelectOption] = [:]

    private let resultPlacement: SelectionFieldResultPlacement
    private let placeholder: String
    private let selectKind: ComponentSelectKind
    private let options: [ComponentSelectOption]
    private let initialOptions: [ComponentSelectOption]
    private let maximumSelectionCount: Int
    private let loader: Loader
    private let selectionChanged: ([ComponentSelectOption]) -> Void
    private let complete: ([String], SelectionFieldCompletion) -> Void

    init(
        placeholder: String,
        resultPlacement: SelectionFieldResultPlacement,
        selectKind: ComponentSelectKind,
        options: [ComponentSelectOption],
        initialOptions: [ComponentSelectOption],
        selectedOptions: [ComponentSelectOption]?,
        maximumSelectionCount: Int,
        loader: @escaping Loader,
        selectionChanged: @escaping ([ComponentSelectOption]) -> Void,
        complete: @escaping ([String], SelectionFieldCompletion) -> Void
    ) {
        self.resultPlacement = resultPlacement
        self.placeholder = placeholder
        self.selectKind = selectKind
        self.options = options
        self.initialOptions = initialOptions
        self.maximumSelectionCount = max(1, maximumSelectionCount)
        self.loader = loader
        self.selectionChanged = selectionChanged
        self.complete = complete
        let initiallySelected = selectedOptions
            ?? options.filter(\.isDefault)
        _selection = State(
            initialValue: Array(initiallySelected.map(\.value).prefix(
                max(1, maximumSelectionCount)
            ))
        )
        _knownOptionsByValue = State(
            initialValue: Dictionary(
                (options + initialOptions + initiallySelected).map {
                    ($0.value, $0)
                },
                uniquingKeysWith: { _, newer in newer }
            )
        )
    }

    var body: some View {
        SelectionField(
            selection: selectionBinding,
            mode: selectionMode,
            source: source,
            configuration: SelectionFieldConfiguration(
                placeholder: placeholder,
                searchPlaceholder: "Search options",
                maximumListHeight: 232,
                initiallyExpanded: true,
                collapsesAfterSingleSelection: true,
                resultPlacement: resultPlacement
            ),
            accessibilityIdentifier: "component-selection-field",
            onComplete: { complete(selection, $0) }
        )
        .frame(maxWidth: .infinity)
    }

    private var selectionBinding: Binding<[String]> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                selectionChanged(
                    newValue.compactMap { knownOptionsByValue[$0] }
                )

            }
        )
    }

    private var selectionMode: SelectionFieldSelectionMode {
        maximumSelectionCount == 1
            ? .single
            : .multiple(maximum: maximumSelectionCount)
    }

    private var source: SelectionFieldSource<String> {
        if selectKind == .string {
            return .local(
                options: options.map {
                    ComponentChoiceOptionPresentation.fieldOption(
                        $0,
                        selectKind: selectKind
                    )
                },
                maximumResults: 25
            )
        }
        var seenInitialValues = Set<String>()
        let initial = (initialOptions + selection.compactMap {
            knownOptionsByValue[$0]
        }).filter { seenInitialValues.insert($0.value).inserted }
        return .dynamic(
            initialOptions: initial.map {
                ComponentChoiceOptionPresentation.fieldOption(
                    $0,
                    selectKind: selectKind
                )
            },
            debounce: .milliseconds(120),
            maximumResults: 25
        ) { query in
            let loaded = try await loader(query)
            for option in loaded {
                knownOptionsByValue[option.value] = option
            }
            return loaded.map {
                ComponentChoiceOptionPresentation.fieldOption(
                    $0,
                    selectKind: selectKind
                )
            }
        }
    }
}

enum ComponentChoiceOptionPresentation {
    static func fieldOption(
        _ option: ComponentSelectOption,
        selectKind: ComponentSelectKind
    ) -> SelectionFieldOption<String> {
        let entityKind = option.entityKind
            ?? defaultEntityKind(for: selectKind)
        return SelectionFieldOption(
            id: option.value,
            title: title(for: option, entityKind: entityKind),
            subtitle: option.description,
            leading: leading(for: option, entityKind: entityKind),
            titleStyle: titleStyle(
                for: option,
                entityKind: entityKind
            ),
            searchTerms: [option.value]
        )
    }

    private static func defaultEntityKind(
        for selectKind: ComponentSelectKind
    ) -> ComponentSelectOptionEntityKind? {
        switch selectKind {
        case .string:
            nil
        case .user:
            .user
        case .role:
            .role
        case .channel:
            .channel
        case .mentionable:
            nil
        }
    }

    private static func title(
        for option: ComponentSelectOption,
        entityKind: ComponentSelectOptionEntityKind?
    ) -> String {
        switch entityKind {
        case .role:
            option.label.hasPrefix("@")
                ? String(option.label.dropFirst())
                : option.label
        case .channel:
            option.label.hasPrefix("#")
                ? String(option.label.dropFirst())
                : option.label
        case .user, nil:
            option.label
        }
    }

    private static func leading(
        for option: ComponentSelectOption,
        entityKind: ComponentSelectOptionEntityKind?
    ) -> SelectionFieldLeading {
        switch entityKind {
        case .user:
            return .remoteImage(
                url: option.imageURL,
                fallback: option.label,
                shape: .circle
            )
        case .role:
            return .role(
                colorHex: option.colorHex,
                iconURL: option.imageURL,
                unicodeEmoji: option.unicodeEmoji
            )
        case .channel:
            return .systemImage(
                ChannelIconPresentation.systemImage(
                    for: option.channelKind ?? .unknown,
                    isHidden: false
                )
            )
        case nil:
            if let imageURL = option.imageURL {
                return .remoteImage(
                    url: imageURL,
                    fallback: option.label,
                    shape: (option.imageShape ?? .circle) == .circle
                        ? .circle
                        : .roundedRectangle
                )
            }
            return option.emoji.map(leading(for:)) ?? .none
        }
    }

    private static func titleStyle(
        for option: ComponentSelectOption,
        entityKind: ComponentSelectOptionEntityKind?
    ) -> SelectionFieldTitleStyle {
        switch entityKind {
        case .user:
            .memberColor(option.colorHex)
        case .role:
            .roleColor(option.colorHex)
        case .channel, nil:
            .standard
        }
    }

    static func leading(
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

    static func fieldHeight(
        options: [ComponentSelectOption],
        selectKind: ComponentSelectKind,
        fieldWidth: CGFloat
    ) -> CGFloat {
        SelectionFieldLayoutMetrics.preferredHeight(
            options: options.map {
                fieldOption($0, selectKind: selectKind)
            },
            width: fieldWidth
        )
    }
}

extension NativeTimelineComponentLayout {
    var selectMediaKeys: [NativeTimelineMediaKey] {
        selects.flatMap { select -> [NativeTimelineMediaKey] in
            // Load the image the field draws, so the two cannot disagree.
            select.selectedOptions.compactMap { option in
                guard let url = ComponentChoiceOptionPresentation
                    .fieldOption(option, selectKind: select.kind)
                    .leading.imageURL,
                    !url.isFileURL
                else { return nil }
                return .media(url, maximumPixelDimension: 64)
            }
        }
    }
}
