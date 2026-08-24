import Foundation
import Observation

nonisolated struct SettingsSearchResult: Identifiable, Equatable, Sendable {
    let id: SettingsControlID
    let destination: SettingsDestination
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String
    let scope: SettingsValueScope?
}

nonisolated struct SettingsRevealRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: SettingsDestination
    let controlID: SettingsControlID
}

@Observable
final class SettingsViewState {
    var selectedPage: SettingsPageID = .myAccount {
        didSet {
            guard selectedPage != oldValue else { return }
            if revealRequest != nil {
                revealRequest = nil
            }
            if highlightedControlID != nil {
                highlightTask?.cancel()
                highlightTask = nil
                highlightedControlID = nil
            }
        }
    }

    var searchText = "" {
        didSet { refreshSearchResults() }
    }

    private(set) var searchResults: [SettingsSearchResult] = []
    private(set) var revealRequest: SettingsRevealRequest?
    private(set) var highlightedControlID: SettingsControlID?

    @ObservationIgnored let catalog: SettingsCatalog
    @ObservationIgnored private let searchEntries: [SearchEntry]
    @ObservationIgnored private var locale = Locale.current
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    init(catalog: SettingsCatalog = .foundation) {
        self.catalog = catalog
        searchEntries = Self.makeSearchEntries(catalog: catalog)
    }

    deinit {
        highlightTask?.cancel()
    }

    func restoreSelection(from rawValue: String) {
        selectedPage = SettingsPageID(rawValue: rawValue) ?? .myAccount
    }

    func updateLocale(_ locale: Locale) {
        guard self.locale != locale else { return }
        self.locale = locale
        refreshSearchResults()
    }

    func activate(_ result: SettingsSearchResult) {
        navigate(to: result.destination, controlID: result.id)
        searchText = ""
    }

    @discardableResult
    func activateFirstSearchResult() -> Bool {
        guard let result = searchResults.first else { return false }
        activate(result)
        return true
    }

    func navigate(
        to destination: SettingsDestination,
        controlID: SettingsControlID
    ) {
        selectedPage = destination.page
        revealRequest = SettingsRevealRequest(
            id: UUID(),
            destination: destination,
            controlID: controlID
        )
        emphasize(controlID)
    }

    func emphasize(_ controlID: SettingsControlID) {
        highlightTask?.cancel()
        highlightedControlID = controlID
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled,
                  self?.highlightedControlID == controlID
            else { return }
            self?.highlightedControlID = nil
        }
    }

    private func refreshSearchResults() {
        let normalizedQuery = Self.normalized(searchText)
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        guard !terms.isEmpty else {
            searchResults = []
            return
        }

        searchResults = searchEntries
            .compactMap { entry -> RankedResult? in
                let title = localized(entry.result.title)
                let fields = [title, localized(entry.help)]
                    + entry.keywords.map(localized)
                let normalizedFields = fields.map(Self.normalized)
                guard terms.allSatisfy({ term in
                    normalizedFields.contains { $0.contains(term) }
                }) else { return nil }

                let normalizedTitle = Self.normalized(title)
                let priorityKeywords = entry.priorityKeywords.map {
                    Self.normalized(localized($0))
                }
                let rank: Int
                if normalizedTitle == normalizedQuery {
                    rank = 0
                } else if normalizedTitle.hasPrefix(normalizedQuery) {
                    rank = 1
                } else if normalizedTitle.contains(normalizedQuery) {
                    rank = 2
                } else if priorityKeywords.contains(normalizedQuery) {
                    rank = 3
                } else if priorityKeywords.contains(where: {
                    $0.contains(normalizedQuery)
                }) {
                    rank = 4
                } else {
                    rank = 5
                }
                return RankedResult(result: entry.result, rank: rank, order: entry.order)
            }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.order < $1.order
            }
            .prefix(12)
            .map(\.result)
    }

    private func localized(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func makeSearchEntries(catalog: SettingsCatalog) -> [SearchEntry] {
        var entries: [SearchEntry] = []
        entries.reserveCapacity(catalog.pages.count + catalog.controls.count)

        for (index, page) in catalog.pages.enumerated() {
            entries.append(
                SearchEntry(
                    result: SettingsSearchResult(
                        id: page.overviewControlID,
                        destination: SettingsDestination(page: page.id),
                        title: page.title,
                        detail: page.help,
                        systemImage: page.systemImage,
                        scope: nil
                    ),
                    help: page.help,
                    keywords: page.keywords,
                    priorityKeywords: page.keywords,
                    order: index
                )
            )
        }

        for (index, control) in catalog.controls.enumerated() {
            let page = catalog.page(control.destination.page)
            entries.append(
                SearchEntry(
                    result: SettingsSearchResult(
                        id: control.id,
                        destination: control.destination,
                        title: control.label,
                        detail: page.title,
                        systemImage: page.systemImage,
                        scope: control.scope
                    ),
                    help: control.help,
                    keywords: control.keywords + page.keywords + [page.title],
                    priorityKeywords: control.keywords,
                    order: catalog.pages.count + index
                )
            )
        }
        return entries
    }
}

private extension SettingsViewState {
    nonisolated struct SearchEntry: Sendable {
        let result: SettingsSearchResult
        let help: LocalizedStringResource
        let keywords: [LocalizedStringResource]
        let priorityKeywords: [LocalizedStringResource]
        let order: Int
    }

    nonisolated struct RankedResult: Sendable {
        let result: SettingsSearchResult
        let rank: Int
        let order: Int
    }
}
