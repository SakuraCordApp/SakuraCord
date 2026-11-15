import Foundation
import Observation

nonisolated struct SettingsSearchResult: Identifiable, Equatable, Sendable {
    let id: SettingsControlID
    let destination: SettingsDestination
    let title: LocalizedStringResource
    let pageTitle: LocalizedStringResource?
    let systemImage: String
}

nonisolated struct SettingsRevealRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: SettingsDestination
    let controlID: SettingsControlID
}

@Observable
final class SettingsViewState {
    private var currentPage: SettingsPageID = .myAccount
    @ObservationIgnored var allowsNavigation: ((SettingsDestination, SettingsControlID) -> Bool)?
    var selectedPage: SettingsPageID {
        get { currentPage }
        set {
            guard newValue != currentPage,
                  allowsNavigation?(SettingsDestination(page: newValue), .overview(newValue)) != false else { return }
            selectPage(newValue)
        }
    }

    var searchText = "" {
        didSet { refreshSearchResults() }
    }

    private(set) var searchResults: [SettingsSearchResult] = []
    private(set) var selectedSearchResultID: SettingsControlID?
    private(set) var revealRequest: SettingsRevealRequest?
    private(set) var highlightedControlID: SettingsControlID?

    @ObservationIgnored let catalog: SettingsCatalog
    @ObservationIgnored private let searchEntries: [SearchEntry]
    @ObservationIgnored private let sectionByControlID: [SettingsControlID: SettingsSectionID]
    @ObservationIgnored private var locale = Locale.current
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    init(catalog: SettingsCatalog = .foundation) {
        self.catalog = catalog
        searchEntries = Self.makeSearchEntries(catalog: catalog)
        sectionByControlID = Dictionary(uniqueKeysWithValues: catalog.controls.compactMap {
            guard let section = $0.destination.section else { return nil }
            return ($0.id, section)
        })
    }

    deinit {
        highlightTask?.cancel()
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

    @discardableResult
    func activateSelectedSearchResult() -> Bool {
        guard let selectedSearchResultID,
              let result = searchResults.first(where: {
                  $0.id == selectedSearchResultID
              })
        else { return false }
        activate(result)
        return true
    }

    func selectSearchResult(_ id: SettingsControlID) {
        guard searchResults.contains(where: { $0.id == id }) else { return }
        selectedSearchResultID = id
    }

    func moveSearchSelection(by delta: Int) {
        let ids = searchResults.map(\.id)
        guard !ids.isEmpty else {
            selectedSearchResultID = nil
            return
        }
        let currentIndex = selectedSearchResultID.flatMap(ids.firstIndex(of:)) ?? -1
        let nextIndex = (currentIndex + delta + ids.count) % ids.count
        selectedSearchResultID = ids[nextIndex]
    }

    func navigate(
        to destination: SettingsDestination,
        controlID: SettingsControlID
    ) {
        guard destination.page == currentPage || allowsNavigation?(destination, controlID) != false else { return }
        selectPage(destination.page)
        revealRequest = SettingsRevealRequest(
            id: UUID(),
            destination: destination,
            controlID: controlID
        )
        emphasize(controlID)
    }

    private func selectPage(_ page: SettingsPageID) {
        guard page != currentPage else { return }
        currentPage = page
        revealRequest = nil
        highlightTask?.cancel()
        highlightTask = nil
        highlightedControlID = nil
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

    func sectionID(for controlID: SettingsControlID) -> SettingsSectionID? {
        sectionByControlID[controlID]
    }

    private func refreshSearchResults() {
        let normalizedQuery = Self.normalized(searchText)
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        guard !terms.isEmpty else {
            searchResults = []
            selectedSearchResultID = nil
            return
        }

        let results = searchEntries
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
        searchResults = results
        selectedSearchResultID = results.first?.id
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
                        pageTitle: nil,
                        systemImage: page.systemImage
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
                        pageTitle: page.title,
                        systemImage: page.systemImage
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
