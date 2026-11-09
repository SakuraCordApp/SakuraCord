@testable import SakuraCord
import SakuraCordModels
import Observation
import Testing

@Test func `selection field single and multiple policies preserve ordered choices`() {
    #expect(SelectionFieldSelectionPolicy.toggled("first", in: ["first"], mode: .single) == ["first"])
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
@Test func `local selection search is normalized and bounded`() {
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

    #expect(model.state == .loaded)
    #expect(model.results.map(\.id) == [1, 2])

    model.updateQuery("feliz")
    #expect(model.state == .loaded)

    #expect(model.results.map(\.id) == [1])
    #expect(model.option(for: 1)?.title == "Féliz")
    model.replaceSource(.local(options: [SelectionFieldOption(id: 4, title: "Feliz Updated")]))
    #expect(model.state == .loaded)
    #expect(model.results.map(\.id) == [4])
}

@MainActor
@Test
func `dynamic selection search discards a cancelled stale response`() async throws {
    let search = SelectionFieldSearchHarness()
    defer { search.finish() }
    let model = SelectionFieldModel(
        source: SelectionFieldSource<String>.dynamic(
            debounce: .zero,
            search: { query in
                try await search.load(query)
            }
        )
    )

    model.updateQuery("old")
    try #require(await search.waitForQuery("old"))

    model.updateQuery("new")
    try #require(await search.waitForQuery("new"))
    search.resume(
        "new",
        with: [SelectionFieldOption(id: "new", title: "New Result")]
    )
    try #require(await until { model.state != .loading })

    #expect(model.results.map(\.id) == ["new"])

    search.resume(
        "old",
        with: [SelectionFieldOption(id: "old", title: "Old Result")]
    )
    await Task.yield()
    #expect(model.results.map(\.id) == ["new"])
}

@MainActor
@Test func `dynamic selection starts from initial options without searching`() {
    let model = SelectionFieldModel(
        source: SelectionFieldSource<String>.dynamic(
            initialOptions: [
                SelectionFieldOption(id: "cached", title: "Cached")
            ],
            search: { _ in
                Issue.record("Opening a dynamic selection field must not search")
                return []
            }
        )
    )

    model.activate()

    #expect(model.state == .loaded)
    #expect(model.results.map(\.id) == ["cached"])
}

@MainActor
@Test func `component choices use semantic icons titles and role colors`() {
    let channel = ComponentChoiceOptionPresentation.fieldOption(
        ComponentSelectOption(
            label: "#Stage",
            value: "channel",
            entityKind: .channel,
            channelKind: .voice
        ),
        selectKind: .channel
    )
    #expect(channel.title == "Stage")
    #expect(channel.leading == .systemImage("speaker.wave.2.fill"))
    #expect(channel.titleStyle == .standard)

    let role = ComponentChoiceOptionPresentation.fieldOption(
        ComponentSelectOption(
            label: "@Design",
            value: "role",
            entityKind: .role,
            colorHex: 0xF472B6,
            unicodeEmoji: "🎨"
        ),
        selectKind: .role
    )
    #expect(role.title == "Design")
    #expect(role.leading == .role(
        colorHex: 0xF472B6,
        iconURL: nil,
        unicodeEmoji: "🎨"
    ))
    #expect(role.titleStyle == .roleColor(0xF472B6))

    let member = ComponentChoiceOptionPresentation.fieldOption(
        ComponentSelectOption(
            label: "Nova",
            value: "member",
            entityKind: .user,
            colorHex: 0x67E8F9
        ),
        selectKind: .user
    )
    #expect(member.titleStyle == .memberColor(0x67E8F9))
}

@MainActor
private final class SelectionFieldSearchHarness {
    typealias Option = SelectionFieldOption<String>

    private var continuations: [String: CheckedContinuation<[Option], any Error>] = [:]
    private let starts = AsyncStream<String>.makeStream()
    private var finished = false

    func load(_ query: String) async throws -> [Option] {
        guard !finished else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[query] = continuation
            starts.continuation.yield(query)
        }
    }

    func waitForQuery(_ query: String) async -> Bool {
        for await started in starts.stream where started == query { return true }
        return false
    }

    func finish() {
        finished = true
        starts.continuation.finish()
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    func resume(_ query: String, with options: [Option]) {
        continuations.removeValue(forKey: query)?.resume(returning: options)
    }
}

@MainActor
@Test func `component picker cancellation and invalid drafts never submit`() {
    for (values, dismissal, expected) in [
        (["new"], "cancel", [[String]]()),
        ([], "confirm", []),
        (["one", "two", "three"], "confirm", []),
        (["new"], "confirm", [["new"]]),
        (["initial"], "confirm", [["initial"]]),
        (["new"], "outside", [["new"]]),
        ([], "outside", []),
        (["initial"], "outside", []),
    ] {
        var submissions: [[String]] = []
        var closes = 0
        let controller = ComponentChoiceOverlayController(
            initialSelection: ["initial"], minimumSelectionCount: 1,
            maximumSelectionCount: 2,
            submit: { submissions.append($0) }, onClose: { closes += 1 }
        )
        controller.updateSelection(values)
        if dismissal == "confirm" { controller.completeSelection(values, reason: .selected) }
        if dismissal == "outside" { controller.completeSelection(values, reason: .dismissed) }
        controller.close()
        controller.close()
        #expect(submissions == expected)
        #expect(closes == 1)
    }
}

@MainActor
@Test
func `cancelled selection searches can restart without changing the query`() async throws {
    let search = SelectionFieldSearchHarness()
    defer { search.finish() }
    let model = SelectionFieldModel(source: SelectionFieldSource<String>.dynamic(
        debounce: .zero, search: { try await search.load($0) }
    ))
    model.updateQuery("retry")
    try #require(await search.waitForQuery("retry"))
    model.cancel()
    #expect(model.state == .idle)
    search.resume("retry", with: [])
    model.activate()
    try #require(await search.waitForQuery("retry"))
    search.resume("retry", with: [SelectionFieldOption(id: "ok", title: "Recovered")])
    try #require(await until { model.state != .loading })
    #expect(model.results.map(\.id) == ["ok"])
}
