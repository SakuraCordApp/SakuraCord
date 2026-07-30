import Observation
import SakuraCordModels
import SwiftUI

@MainActor
@Observable
final class ComponentChoicePickerModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    typealias Loader =
        @MainActor (String) async throws -> [ComponentSelectOption]

    private let loader: Loader
    private let debounce: Duration
    private var loadTask: Task<Void, Never>?
    private var requestGeneration = 0

    private(set) var query = ""
    private(set) var choices: [ComponentSelectOption] = []
    private(set) var state: LoadState = .idle

    init(
        debounce: Duration = .milliseconds(180),
        loader: @escaping Loader
    ) {
        self.debounce = debounce
        self.loader = loader
    }

    func loadInitialChoices() {
        scheduleLoad(isImmediate: true)
    }

    func updateQuery(_ value: String) {
        guard query != value else { return }
        query = value
        scheduleLoad(isImmediate: false)
    }

    func cancel() {
        requestGeneration += 1
        loadTask?.cancel()
        loadTask = nil
    }

    private func scheduleLoad(isImmediate: Bool) {
        requestGeneration += 1
        let generation = requestGeneration
        let requestedQuery = query
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !isImmediate, debounce > .zero {
                    try await Task.sleep(for: debounce)
                }
                try Task.checkCancellation()
                let loadedChoices = try await loader(requestedQuery)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                choices = Array(loadedChoices.prefix(25))
                state = .loaded
                loadTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration else { return }
                choices = []
                state = .failed(error.localizedDescription)
                loadTask = nil
            }
        }
    }
}

struct ComponentChoicePicker: View {
    @State private var model: ComponentChoicePickerModel
    @FocusState private var searchIsFocused: Bool

    private let placeholder: String
    private let select: (ComponentSelectOption) -> Void

    init(
        placeholder: String,
        loader: @escaping ComponentChoicePickerModel.Loader,
        select: @escaping (ComponentSelectOption) -> Void
    ) {
        self.placeholder = placeholder
        self.select = select
        _model = State(
            initialValue: ComponentChoicePickerModel(loader: loader)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(placeholder)
                .font(.headline)
                .lineLimit(2)

            TextField(
                "Search",
                text: Binding(
                    get: { model.query },
                    set: model.updateQuery
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($searchIsFocused)
            .accessibilityLabel("Search component choices")

            choiceContent
        }
        .padding(12)
        .frame(width: 340, height: 300)
        .task {
            model.loadInitialChoices()
            searchIsFocused = true
        }
        .onDisappear {
            model.cancel()
        }
    }

    @ViewBuilder
    private var choiceContent: some View {
        switch model.state {
        case .idle, .loading:
            Spacer()
            ProgressView("Loading choices…")
                .frame(maxWidth: .infinity)
            Spacer()
        case .loaded where model.choices.isEmpty:
            ContentUnavailableView(
                "No Matches",
                systemImage: "magnifyingglass",
                description: Text("Try a different search.")
            )
        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.choices) { option in
                        Button {
                            select(option)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .lineLimit(1)
                                if let description = option.description {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .accessibilityLabel(option.label)
                        .accessibilityHint(
                            option.description ?? "Select this option"
                        )
                    }
                }
            }
        case let .failed(message):
            ContentUnavailableView(
                "Choices Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}
