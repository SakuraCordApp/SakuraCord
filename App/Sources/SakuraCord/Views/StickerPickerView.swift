import AppKit
import Foundation
import Observation
import SakuraCordModels
import SwiftUI

private enum StickerPickerMetrics {
    static let columns = 3
    static let cellWidth: CGFloat = 140
    static let cellHeight: CGFloat = 126
    static let previewSize: CGFloat = 110
    static let gridSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 6
}

private enum StickerPickerSectionID: Hashable, Identifiable {
    case favorites
    case frequent
    case guild(GuildID)
    case pack(String)
    case search

    var id: String {
        switch self {
        case .favorites: "favorites"
        case .frequent: "frequent"
        case let .guild(id): "guild:\(id)"
        case let .pack(id): "pack:\(id)"
        case .search: "search"
        }
    }

    var contentID: String {
        "sticker-content:\(id)"
    }
}

private struct StickerPickerItem: Identifiable, Hashable {
    let sticker: MessageSticker
    let source: String

    var id: String { sticker.id }
    var searchText: String {
        [sticker.name, sticker.description, sticker.tags, source]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct StickerPickerSection: Identifiable {
    let id: StickerPickerSectionID
    let title: String
    let items: [StickerPickerItem]
    let emptyMessage: String
}

private struct StickerPickerDocumentRow: Identifiable {
    enum Content {
        case header(title: String, count: Int)
        case stickers([StickerPickerCell])
        case empty(String)
    }

    let id: String
    let section: StickerPickerSectionID
    let content: Content

    static func headerID(for section: StickerPickerSectionID) -> String {
        section.contentID
    }

    var listInsets: EdgeInsets {
        if case .stickers = content {
            return EdgeInsets(
                top: StickerPickerMetrics.rowSpacing / 2,
                leading: 0,
                bottom: StickerPickerMetrics.rowSpacing / 2,
                trailing: 0
            )
        }
        return EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
    }
}

private struct StickerPickerCell: Identifiable {
    let id: String
    let rowID: String
    let item: StickerPickerItem
}

@MainActor
@Observable
private final class StickerPickerDocumentStore {
    var query = "" {
        didSet { rebuild() }
    }
    private(set) var sections: [StickerPickerSection] = []
    private(set) var guilds: [Guild] = []
    private(set) var packs: [StickerPack] = []
    private(set) var favoriteIDs: Set<String> = []
    private(set) var rows: [StickerPickerDocumentRow] = []
    private(set) var selectableCells: [StickerPickerCell] = []
    var visibleSection: StickerPickerSectionID = .favorites

    private var stickersByGuild: [GuildID: [MessageSticker]] = [:]
    private var settings = StickerUserSettings()
    private var navigationRows: [[String]] = []
    private var cellsByID: [String: StickerPickerCell] = [:]

    func synchronize(with model: AppModel) {
        let guilds = PickerSectionGuildOrdering.orderedGuilds(
            railItems: model.serverRailItems,
            guildsByID: model.serverRailGuildsByID,
            fallbackGuilds: model.snapshot?.guilds ?? [],
            currentGuildID: model.selectedGuildID
        )
        guard self.guilds != guilds
            || stickersByGuild != model.stickersByGuild
            || packs != model.standardStickerPacks
            || settings != model.stickerUserSettings
        else { return }
        self.guilds = guilds
        stickersByGuild = model.stickersByGuild
        packs = model.standardStickerPacks
        settings = model.stickerUserSettings
        favoriteIDs = Set(settings.favoriteIDs)
        rebuild()
    }

    func isFavorite(_ item: StickerPickerItem) -> Bool {
        favoriteIDs.contains(item.id)
    }

    func destinationCell(
        from currentID: String?,
        direction: EmojiPickerGridDirection
    ) -> StickerPickerCell? {
        let destinationID = EmojiPickerGridNavigation.destinationID(
            rows: navigationRows,
            currentID: currentID,
            direction: direction
        )
        return destinationID.flatMap { cellsByID[$0] }
    }

    private func rebuild() {
        let catalog = allItems()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !normalized.isEmpty {
            sections = [
                StickerPickerSection(
                    id: .search,
                    title: "Search Results",
                    items: catalog.filter { $0.searchText.contains(normalized) },
                    emptyMessage: "No stickers match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”."
                )
            ]
            rebuildSelectableCells()
            visibleSection = .search
            return
        }

        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favorites = settings.favoriteIDs.compactMap { byID[$0] }
        let frequent = settings.frequentlyUsedIDs.compactMap { byID[$0] }
        var result = [
            StickerPickerSection(
                id: .favorites,
                title: "Favorites",
                items: favorites,
                emptyMessage: "Your favorite stickers will appear here."
            ),
            StickerPickerSection(
                id: .frequent,
                title: "Frequently Used",
                items: frequent,
                emptyMessage: "Stickers you use will appear here."
            ),
        ]
        result.append(contentsOf: guilds.map { guild in
            StickerPickerSection(
                id: .guild(guild.id),
                title: guild.name,
                items: (stickersByGuild[guild.id] ?? [])
                    .filter(\.isAvailable)
                    .map { StickerPickerItem(sticker: $0, source: guild.name) },
                emptyMessage: "This server has no stickers."
            )
        })
        result.append(contentsOf: packs.map { pack in
            StickerPickerSection(
                id: .pack(pack.id),
                title: pack.name,
                items: pack.stickers
                    .filter(\.isAvailable)
                    .map { StickerPickerItem(sticker: $0, source: pack.name) },
                emptyMessage: "This sticker pack is empty."
            )
        })
        sections = result
        rebuildSelectableCells()
    }

    private func allItems() -> [StickerPickerItem] {
        var seen: Set<String> = []
        var result: [StickerPickerItem] = []
        for guild in guilds {
            for sticker in stickersByGuild[guild.id] ?? []
                where sticker.isAvailable && seen.insert(sticker.id).inserted
            {
                result.append(StickerPickerItem(sticker: sticker, source: guild.name))
            }
        }
        for pack in packs {
            for sticker in pack.stickers
                where sticker.isAvailable && seen.insert(sticker.id).inserted
            {
                result.append(StickerPickerItem(sticker: sticker, source: pack.name))
            }
        }
        return result
    }

    private func rebuildSelectableCells() {
        rows = sections.flatMap(documentRows(for:))
        let selectableRows = rows.compactMap { row -> [StickerPickerCell]? in
            guard case let .stickers(cells) = row.content else { return nil }
            return cells
        }
        navigationRows = selectableRows.map { $0.map(\.id) }
        selectableCells = selectableRows.flatMap(\.self)
        cellsByID = Dictionary(uniqueKeysWithValues: selectableCells.map { ($0.id, $0) })
    }

    private func documentRows(for section: StickerPickerSection) -> [StickerPickerDocumentRow] {
        var result = [
            StickerPickerDocumentRow(
                id: StickerPickerDocumentRow.headerID(for: section.id),
                section: section.id,
                content: .header(title: section.title, count: section.items.count)
            )
        ]
        guard !section.items.isEmpty else {
            result.append(
                StickerPickerDocumentRow(
                    id: "empty:\(section.id.id)",
                    section: section.id,
                    content: .empty(section.emptyMessage)
                )
            )
            return result
        }

        for start in stride(
            from: 0,
            to: section.items.count,
            by: StickerPickerMetrics.columns
        ) {
            let end = min(start + StickerPickerMetrics.columns, section.items.count)
            let items = Array(section.items[start ..< end])
            let rowID = "stickers:\(section.id.id):\(items[0].id)"
            let cells = items.map { item in
                StickerPickerCell(
                    id: "\(rowID):\(item.id)",
                    rowID: rowID,
                    item: item
                )
            }
            result.append(
                StickerPickerDocumentRow(
                    id: rowID,
                    section: section.id,
                    content: .stickers(cells)
                )
            )
        }
        return result
    }
}

@MainActor
@Observable
private final class StickerPickerInteractionModel {
    private(set) var selectedCellID: String?
    private(set) var selectedRowID: String?
    private(set) var item: StickerPickerItem?
    private var hasExplicitSelection = false

    func select(_ cell: StickerPickerCell) {
        hasExplicitSelection = true
        updateSelection(to: cell)
    }

    func synchronize(with cells: [StickerPickerCell]) {
        guard !cells.isEmpty else {
            selectedCellID = nil
            selectedRowID = nil
            item = nil
            return
        }
        guard hasExplicitSelection else {
            updateSelection(to: cells[0])
            return
        }
        if let selectedCellID, cells.contains(where: { $0.id == selectedCellID }) {
            return
        }
        updateSelection(to: cells.first { $0.item.id == item?.id } ?? cells[0])
    }

    private func updateSelection(to cell: StickerPickerCell) {
        selectedCellID = cell.id
        selectedRowID = cell.rowID
        item = cell.item
    }
}

struct StickerPickerView: View {
    let model: AppModel
    let dismiss: () -> Void
    @State private var document = StickerPickerDocumentStore()
    @State private var interaction = StickerPickerInteractionModel()
    @State private var searchIsFocused = false
    @FocusState private var keyboardNavigationIsFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                EmojiPickerSearchField(
                    text: $document.query,
                    isFocused: $searchIsFocused,
                    placeholder: "Search stickers"
                )
                Divider()
                HStack(spacing: 0) {
                    sidebar(proxy: proxy)
                    Divider()
                    VStack(spacing: 0) {
                        StickerPickerDocumentList(
                            document: document,
                            interaction: interaction,
                            model: model,
                            proxy: proxy,
                            activate: activate,
                            toggleFavorite: toggleFavorite,
                            becameVisible: { document.visibleSection = $0 }
                        )
                        Divider()
                        hoverPreview
                    }
                }
            }
            .focusable()
            .focused($keyboardNavigationIsFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press, proxy: proxy)
            }
            .task {
                document.synchronize(with: model)
                interaction.synchronize(with: document.selectableCells)
                searchIsFocused = true
                await model.loadStickerPicker()
                document.synchronize(with: model)
                interaction.synchronize(with: document.selectableCells)
                await Task.yield()
                proxy.scrollTo(
                    StickerPickerSectionID.favorites.contentID,
                    anchor: .top
                )
                searchIsFocused = true
            }
            .onChange(of: model.stickerUserSettings) { _, _ in
                document.synchronize(with: model)
                interaction.synchronize(with: document.selectableCells)
            }
            .onChange(of: model.standardStickerPacks) { _, _ in
                document.synchronize(with: model)
                interaction.synchronize(with: document.selectableCells)
            }
            .onChange(of: model.stickersByGuild) { _, _ in
                document.synchronize(with: model)
                interaction.synchronize(with: document.selectableCells)
            }
        }
        .frame(width: ChatChromeMetrics.emojiPickerWidth, height: 420)
        .onExitCommand {
            if document.query.isEmpty {
                dismiss()
            } else {
                document.query = ""
                searchIsFocused = true
            }
        }
    }

    private var hoverPreview: some View {
        HStack(spacing: 8) {
            if let item = interaction.item {
                StickerPreview(sticker: item.sticker)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.sticker.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Choose a sticker")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
    }

    private func sidebar(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                PickerSectionBookmark(
                    section: StickerPickerSectionID.favorites,
                    visibleSection: document.visibleSection,
                    help: "Favorites",
                    jump: { jump(to: $0, proxy: proxy) },
                    content: { Image(systemName: "star.fill") }
                )
                PickerSectionBookmark(
                    section: StickerPickerSectionID.frequent,
                    visibleSection: document.visibleSection,
                    help: "Frequently Used",
                    jump: { jump(to: $0, proxy: proxy) },
                    content: { Image(systemName: "clock.fill") }
                )
                if !document.guilds.isEmpty {
                    Divider().frame(width: 28).padding(.vertical, 2)
                    ForEach(document.guilds) { guild in
                        PickerSectionBookmark(
                            section: StickerPickerSectionID.guild(guild.id),
                            visibleSection: document.visibleSection,
                            help: guild.name,
                            jump: { jump(to: $0, proxy: proxy) },
                            content: { EmojiGuildBookmarkIcon(guild: guild) }
                        )
                    }
                }
                if !document.packs.isEmpty {
                    Divider().frame(width: 28).padding(.vertical, 2)
                    ForEach(document.packs) { pack in
                        PickerSectionBookmark(
                            section: StickerPickerSectionID.pack(pack.id),
                            visibleSection: document.visibleSection,
                            help: pack.name,
                            jump: { jump(to: $0, proxy: proxy) },
                            content: {
                                StickerPackBookmarkIcon(pack: pack)
                            }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(width: PickerSectionRailLayout.width)
    }

    private func jump(to section: StickerPickerSectionID, proxy: ScrollViewProxy) {
        document.query = ""
        interaction.synchronize(with: document.selectableCells)
        document.visibleSection = section
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(section.contentID, anchor: .top)
            searchIsFocused = true
        }
    }

    private func activate(_ cell: StickerPickerCell) {
        interaction.select(cell)
        StickerPreview.prepareTimelinePresentation(for: cell.item.sticker)
        dismiss()
        Task { @MainActor in
            await model.sendStickerFromPicker(cell.item.sticker)
        }
    }

    private func toggleFavorite(_ item: StickerPickerItem) {
        let isFavorite = document.isFavorite(item)
        Task { @MainActor in
            guard await model.setStickerFavorite(
                stickerID: item.id,
                isFavorite: !isFavorite
            ) else { return }
            document.synchronize(with: model)
            interaction.synchronize(with: document.selectableCells)
        }
    }

    private func handleKeyPress(
        _ press: KeyPress,
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            return navigate(.left, proxy: proxy)
        case .rightArrow:
            return navigate(.right, proxy: proxy)
        case .upArrow:
            return navigate(.up, proxy: proxy)
        case .downArrow:
            return navigate(.down, proxy: proxy)
        case .return:
            guard
                let selectedCellID = interaction.selectedCellID,
                let cell = document.selectableCells.first(where: { $0.id == selectedCellID })
            else { return .ignored }
            activate(cell)
            return .handled
        default: return .ignored
        }
    }

    private func navigate(
        _ direction: EmojiPickerGridDirection,
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        guard let cell = document.destinationCell(
            from: interaction.selectedCellID,
            direction: direction
        ) else { return .ignored }
        let previousRowID = interaction.selectedRowID
        interaction.select(cell)
        if EmojiPickerScrollPolicy.shouldReveal(
            previousRowID: previousRowID,
            destinationRowID: cell.rowID
        ) {
            proxy.scrollTo(cell.rowID)
        }
        return .handled
    }
}

private struct StickerPickerDocumentList: View {
    let document: StickerPickerDocumentStore
    let interaction: StickerPickerInteractionModel
    let model: AppModel
    let proxy: ScrollViewProxy
    let activate: (StickerPickerCell) -> Void
    let toggleFavorite: (StickerPickerItem) -> Void
    let becameVisible: (StickerPickerSectionID) -> Void

    var body: some View {
        List {
            if model.isLoadingStickerPicker, document.selectableCells.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading stickers…")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 70)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if let error = model.stickerPickerErrorMessage,
               document.selectableCells.isEmpty
            {
                VStack(spacing: 8) {
                    Label("Couldn’t load stickers.", systemImage: "wifi.exclamationmark")
                    Button("Retry") { Task { await model.loadStickerPicker() } }
                        .buttonStyle(.link)
                        .focusable(false)
                }
                .help(error)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(document.rows) { row in
                StickerPickerDocumentRowView(
                    row: row,
                    interaction: interaction,
                    isFavorite: document.isFavorite,
                    activate: activate,
                    toggleFavorite: toggleFavorite,
                    becameVisible: becameVisible
                )
                .id(row.id)
                .listRowInsets(row.listInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .onChange(of: document.query) { _, query in
            interaction.synchronize(with: document.selectableCells)
            guard !query.isEmpty else { return }
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo(StickerPickerDocumentRow.headerID(for: .search), anchor: .top)
            }
        }
    }
}

private struct StickerPickerDocumentRowView: View {
    let row: StickerPickerDocumentRow
    let interaction: StickerPickerInteractionModel
    let isFavorite: (StickerPickerItem) -> Bool
    let activate: (StickerPickerCell) -> Void
    let toggleFavorite: (StickerPickerItem) -> Void
    let becameVisible: (StickerPickerSectionID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row.content {
            case let .header(title, count):
                EmojiPickerHeader(title: title, count: count)
                    .padding(.top, 8)
                    .onAppear { becameVisible(row.section) }
            case let .stickers(cells):
                HStack(spacing: StickerPickerMetrics.gridSpacing) {
                    ForEach(cells) { cell in
                        StickerPickerButton(
                            item: cell.item,
                            isSelected: interaction.selectedCellID == cell.id,
                            isFavorite: isFavorite(cell.item),
                            select: { activate(cell) },
                            hover: { interaction.select(cell) },
                            toggleFavorite: { toggleFavorite(cell.item) }
                        )
                    }
                    if cells.count < StickerPickerMetrics.columns {
                        Spacer(minLength: 0)
                    }
                }
                .frame(
                    width: CGFloat(StickerPickerMetrics.columns) * StickerPickerMetrics.cellWidth
                        + CGFloat(StickerPickerMetrics.columns - 1)
                        * StickerPickerMetrics.gridSpacing,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .center)
            case let .empty(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
        }
    }
}

private struct StickerPackBookmarkIcon: View {
    let pack: StickerPack

    var body: some View {
        if let sticker = coverSticker {
            StickerPreview(sticker: sticker)
                .frame(
                    width: PickerSectionRailLayout.iconSize,
                    height: PickerSectionRailLayout.iconSize
                )
                .accessibilityHidden(true)
        } else {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var coverSticker: MessageSticker? {
        pack.coverStickerID.flatMap { coverID in
            pack.stickers.first { $0.id == coverID }
        } ?? pack.stickers.first
    }
}

private struct StickerPickerButton: View {
    let item: StickerPickerItem
    let isSelected: Bool
    let isFavorite: Bool
    let select: () -> Void
    let hover: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        Button(action: select) {
            StickerPreview(sticker: item.sticker)
                .frame(
                    width: StickerPickerMetrics.previewSize,
                    height: StickerPickerMetrics.previewSize
                )
            .frame(width: StickerPickerMetrics.cellWidth, height: StickerPickerMetrics.cellHeight)
            .background {
                ConcentricRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : .clear)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(Rectangle())
        .onHover { if $0 { hover() } }
        .help(item.sticker.name)
        .overlay {
            StickerPickerContextMenuBridge(
                sticker: item.sticker,
                isFavorite: isFavorite,
                toggleFavorite: toggleFavorite
            )
        }
        .accessibilityLabel(item.sticker.name)
        .accessibilityAction(
            named: Text(isFavorite ? "Remove from Favorites" : "Add to Favorites"),
            toggleFavorite
        )
        .accessibilityAction(named: Text("Copy Sticker ID")) {
            copy(item.sticker.id)
        }
        .accessibilityAction(named: Text("Copy Sticker Image Link")) {
            if let link = item.sticker.pickerImageLink?.absoluteString {
                copy(link)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct StickerPreview: View {
    let sticker: MessageSticker

    var body: some View {
        Group {
            if sticker.format == .lottie, let url = sticker.pickerMediaURL {
                StickerLottieView(url: url)
            } else if let url = sticker.pickerMediaURL {
                AnimatedRemoteImage(
                    url: url,
                    fallbackSystemImage: "face.smiling",
                    maximumPixelDimension: 240,
                    accessibilityCategory: .sticker
                )
            } else {
                Image(systemName: "face.smiling")
                    .resizable()
                    .scaledToFit()
                    .padding(15)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(sticker.name)
    }

    @MainActor
    static func prepareTimelinePresentation(for sticker: MessageSticker) {
        guard sticker.format != .lottie,
              let url = sticker.pickerMediaURL,
              let decoded = AnimatedRemoteImageDisplayCache.shared.image(
                  for: url,
                  maximumPixelDimension: 240
              )
        else { return }
        NativeTimelineMediaStore.shared.cacheDecodedImage(
            decoded,
            for: .media(url, maximumPixelDimension: 384)
        )
        NativeTimelineMediaStore.shared.cacheDecodedImage(
            decoded,
            for: .media(url)
        )
    }
}

private struct StickerLottieView: NSViewRepresentable {
    let url: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("settings.accessibility.reduceAnimatedStickers")
    private var reducesAnimatedStickers = false

    func makeNSView(context: Context) -> NativeTimelineLottieStickerOverlay {
        NativeTimelineLottieStickerOverlay(frame: .zero)
    }

    func updateNSView(
        _ nsView: NativeTimelineLottieStickerOverlay,
        context: Context
    ) {
        nsView.display(url, reduceMotion: reduceMotion || reducesAnimatedStickers)
    }

    static func dismantleNSView(
        _ nsView: NativeTimelineLottieStickerOverlay,
        coordinator: Void
    ) {
        nsView.stop()
    }
}
