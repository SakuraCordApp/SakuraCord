@testable import SakuraCord
import Testing

@Test func `selection field single and multiple policies preserve ordered choices`() {
    #expect(
        SelectionFieldSelectionPolicy.toggled(
            "second",
            in: ["first"],
            mode: .single
        ) == ["second"]
    )
    #expect(
        SelectionFieldSelectionPolicy.toggled(
            "second",
            in: ["first", "second"],
            mode: .multiple(maximum: 3)
        ) == ["first"]
    )
    #expect(
        SelectionFieldSelectionPolicy.toggled(
            "third",
            in: ["first", "second"],
            mode: .multiple(maximum: 2)
        ) == nil
    )
}

@MainActor
@Test func `local selection search is normalized and bounded`() async {
    let model = SelectionFieldModel(
        source: SelectionFieldSource.local(
            options: [
                SelectionFieldOption(id: 1, title: "Féliz", searchTerms: ["friend"]),
                SelectionFieldOption(id: 2, title: "Carl-bot"),
                SelectionFieldOption(id: 3, title: "Marcel"),
            ],
            maximumResults: 2
        )
    )

    model.updateQuery("feliz")
    while model.state == .loading {
        await Task.yield()
    }

    #expect(model.results.map(\.id) == [1])
    #expect(model.option(for: 1)?.title == "Féliz")
}

@MainActor
@Test func `dynamic selection search discards a cancelled stale response`() async {
    let search = SelectionFieldSearchHarness()
    let model = SelectionFieldModel(
        source: SelectionFieldSource<String>.dynamic(
            debounce: .zero,
            search: { query in
                try await search.load(query)
            }
        )
    )

    model.updateQuery("old")
    while !search.hasPendingQuery("old") {
        await Task.yield()
    }

    model.updateQuery("new")
    while !search.hasPendingQuery("new") {
        await Task.yield()
    }
    search.resume(
        "new",
        with: [SelectionFieldOption(id: "new", title: "New Result")]
    )
    while model.state == .loading {
        await Task.yield()
    }

    #expect(model.results.map(\.id) == ["new"])

    search.resume(
        "old",
        with: [SelectionFieldOption(id: "old", title: "Old Result")]
    )
    await Task.yield()
    #expect(model.results.map(\.id) == ["new"])
}

@MainActor
private final class SelectionFieldSearchHarness {
    typealias Option = SelectionFieldOption<String>

    private var continuations: [String: CheckedContinuation<[Option], any Error>] = [:]

    func load(_ query: String) async throws -> [Option] {
        try await withCheckedThrowingContinuation { continuation in
            continuations[query] = continuation
        }
    }

    func hasPendingQuery(_ query: String) -> Bool {
        continuations[query] != nil
    }

    func resume(_ query: String, with options: [Option]) {
        continuations.removeValue(forKey: query)?.resume(returning: options)
    }
}
