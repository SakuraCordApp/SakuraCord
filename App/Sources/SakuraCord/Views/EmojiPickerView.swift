import AppKit
import Foundation
import Observation
import SakuraCordModels
import SwiftUI

enum EmojiPickerSelection {
    case native(String)
    case custom(DiscordEmoji)

    var usageKey: String {
        switch self {
        case let .native(value): "unicode:\(value)"
        case let .custom(emoji): "custom:\(emoji.name):\(emoji.id)"
        }
    }
}

struct EmojiPickerActivation {
    let selection: EmojiPickerSelection
    let keepsPickerPresented: Bool
}

enum EmojiPickerActivationPolicy {
    nonisolated static func keepsPickerPresented(
        allowsPersistentSelection: Bool,
        shiftPressed: Bool
    ) -> Bool {
        allowsPersistentSelection && shiftPressed
    }
}

struct EmojiPickerHeader: View {
    let title: String
    let count: Int
    var horizontalInset: CGFloat = 14

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(count, format: .number).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 8)
    }
}

@MainActor
@Observable
final class EmojiPickerInteractionModel {
    private(set) var selectedCellID: String?
    private(set) var selectedRowID: String?
    private(set) var item = NativeEmojiPickerIndex.allItems[0]
    private var hasExplicitSelection = false

    func select(_ cell: EmojiPickerCell) {
        hasExplicitSelection = true
        updateSelection(to: cell)
    }

    private func updateSelection(to cell: EmojiPickerCell) {
        selectedCellID = cell.id
        selectedRowID = cell.rowID
        item = cell.item
    }

    func synchronize(with cells: [EmojiPickerCell]) {
        guard !cells.isEmpty else { return }
        guard hasExplicitSelection else {
            updateSelection(to: cells[0])
            return
        }
        if let selectedCellID, cells.contains(where: { $0.id == selectedCellID }) {
            return
        }
        updateSelection(to: cells.first(where: { $0.item.id == item.id }) ?? cells[0])
    }

    func resetSelection(with cells: [EmojiPickerCell]) {
        hasExplicitSelection = false
        synchronize(with: cells)
    }
}

enum EmojiPickerScrollPolicy {
    nonisolated static func shouldReveal(
        previousRowID: String?,
        destinationRowID: String
    ) -> Bool {
        previousRowID != destinationRowID
    }
}

enum EmojiPickerItem: Identifiable {
    case native(NativeEmoji)
    case custom(DiscordEmoji)

    var id: String {
        usageKey
    }

    var usageKey: String {
        selection.usageKey
    }

    var discordKey: String {
        switch self {
        case let .native(emoji): emoji.discordKey
        case let .custom(emoji): emoji.id
        }
    }

    var selection: EmojiPickerSelection {
        selection(skinTone: .standard)
    }

    func selection(skinTone: NativeEmojiSkinTone) -> EmojiPickerSelection {
        switch self {
        case let .native(emoji): .native(emoji.value(for: skinTone))
        case let .custom(emoji): .custom(emoji)
        }
    }

    var name: String {
        switch self {
        case let .native(emoji): emoji.name
        case let .custom(emoji): emoji.name
        }
    }

    var shortcode: String {
        switch self {
        case let .native(emoji): ":\(emoji.discordKey):"
        case let .custom(emoji): ":\(emoji.name):"
        }
    }

    func matches(normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return false }
        return switch self {
        case let .native(emoji):
            emoji.searchText.contains(normalizedQuery)
        case let .custom(emoji):
            emoji.name.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    @ViewBuilder func preview(
        skinTone: NativeEmojiSkinTone,
        dimension: CGFloat = 40,
        nativeFontSize: CGFloat = 38
    ) -> some View {
        switch self {
        case let .native(emoji):
            Text(emoji.value(for: skinTone))
                .font(.system(size: nativeFontSize))
                .fixedSize()
                .frame(width: dimension, height: dimension, alignment: .center)
                .offset(y: -1)
        case let .custom(emoji):
            if let url = emoji.imageURL {
                if emoji.isAnimated {
                    AnimatedRemoteImage(
                        url: url,
                    )
                        .frame(width: dimension - 2, height: dimension - 2)
                } else {
                    StaticEmojiImage(url: url)
                        .frame(width: dimension - 2, height: dimension - 2)
                }
            } else {
                Image(systemName: "face.dashed")
            }
        }
    }
}

enum EmojiPickerGridMetrics {
    static let columns = 9
    static let cellSize: CGFloat = 43
}

struct EmojiPickerCell: Identifiable {
    let id: String
    let rowID: String
    let item: EmojiPickerItem
}

enum EmojiPickerGridDirection {
    case left
    case right
    case up
    case down
}

enum EmojiPickerGridNavigation {
    nonisolated static func destinationID(
        rows: [[String]],
        currentID: String?,
        direction: EmojiPickerGridDirection
    ) -> String? {
        guard let firstID = rows.first?.first else { return nil }
        guard let currentID,
              let position = rows.enumerated().lazy.compactMap({ rowIndex, row -> (Int, Int)? in
                  row.firstIndex(of: currentID).map { (rowIndex, $0) }
              }).first
        else {
            return firstID
        }

        let rowIndex = position.0
        let columnIndex = position.1
        switch direction {
        case .left:
            if columnIndex > 0 {
                return rows[rowIndex][columnIndex - 1]
            }
            guard rowIndex > 0 else { return currentID }
            return rows[rowIndex - 1].last ?? currentID
        case .right:
            if columnIndex + 1 < rows[rowIndex].count {
                return rows[rowIndex][columnIndex + 1]
            }
            guard rowIndex + 1 < rows.count else { return currentID }
            return rows[rowIndex + 1].first ?? currentID
        case .up:
            guard rowIndex > 0 else { return currentID }
            return rows[rowIndex - 1][min(columnIndex, rows[rowIndex - 1].count - 1)]
        case .down:
            guard rowIndex + 1 < rows.count else { return currentID }
            return rows[rowIndex + 1][min(columnIndex, rows[rowIndex + 1].count - 1)]
        }
    }
}

struct StaticEmojiImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
            if case let .success(image) = phase {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
    }
}

nonisolated enum NativeEmojiSkinTone: String, CaseIterable, Identifiable, Sendable {
    case standard
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .standard: "Default"
        case .light: "Light"
        case .mediumLight: "Medium light"
        case .medium: "Medium"
        case .mediumDark: "Medium dark"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "👋"
        case .light: "👋🏻"
        case .mediumLight: "👋🏼"
        case .medium: "👋🏽"
        case .mediumDark: "👋🏾"
        case .dark: "👋🏿"
        }
    }

    var modifierCodePoint: UInt32? {
        switch self {
        case .standard: nil
        case .light: 0x1F3FB
        case .mediumLight: 0x1F3FC
        case .medium: 0x1F3FD
        case .mediumDark: 0x1F3FE
        case .dark: 0x1F3FF
        }
    }

    init?(modifierCodePoint: UInt32) {
        switch modifierCodePoint {
        case 0x1F3FB: self = .light
        case 0x1F3FC: self = .mediumLight
        case 0x1F3FD: self = .medium
        case 0x1F3FE: self = .mediumDark
        case 0x1F3FF: self = .dark
        default: return nil
        }
    }
}

struct EmojiPickerView: View {
    let model: AppModel
    let useCase: DiscordEmojiUseCase
    let allowsPersistentSelection: Bool
    let dismiss: () -> Void
    let select: (EmojiPickerActivation) -> Void
    @State private var document = EmojiPickerDocumentStore()
    @State private var interaction = EmojiPickerInteractionModel()
    @State private var nativeCategoriesAreVisibleInSidebar = false
    @State private var searchIsFocused = false
    @State private var pendingVisibleGuilds: [GuildID] = []
    @State private var visibleGuildLoadTask: Task<Void, Never>?
    @State private var emojiLockMessage: String?
    @FocusState private var keyboardNavigationIsFocused: Bool
    @AppStorage("emojiSkinTone") private var skinToneRawValue = NativeEmojiSkinTone.standard.rawValue

    init(
        model: AppModel,
        useCase: DiscordEmojiUseCase = .message,
        allowsPersistentSelection: Bool = false,
        dismiss: @escaping () -> Void,
        select: @escaping (EmojiPickerActivation) -> Void
    ) {
        self.model = model
        self.useCase = useCase
        self.allowsPersistentSelection = allowsPersistentSelection
        self.dismiss = dismiss
        self.select = select
    }

    var body: some View {
        GeometryReader { _ in
            NativePickerScrollReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    EmojiPickerSearchField(
                        text: searchQuery,
                        isFocused: $searchIsFocused,
                        placeholder: "Search emojis"
                    )

                    Divider()

                    HStack(spacing: 0) {
                        EmojiDocumentSidebar(
                            guilds: document.guilds,
                            showsFavorites: document.showsFavorites,
                            showsFrequentlyUsed: document.showsFrequentlyUsed,
                            visibleSection: document.visibleSection,
                            nativeCategoriesAreVisible: $nativeCategoriesAreVisibleInSidebar,
                            showsNativeJumpButton: !nativeCategoriesAreVisibleInSidebar,
                            jump: {
                                jump(to: $0, proxy: proxy)
                                requestSearchFocus()
                            },
                            jumpToNative: {
                                jumpToNative(proxy: proxy)
                                requestSearchFocus()
                            }
                        )
                        Divider()
                        VStack(spacing: 0) {
                            EmojiPickerDocumentView(
                                document: document,
                                interaction: interaction,
                                skinTone: selectedSkinTone,
                                proxy: proxy,
                                choose: choose,
                                toggleFavorite: toggleFavorite,
                                retry: retry,
                                becameVisible: sectionBecameVisible,
                                lockReason: lockReason
                            )
                            Divider()
                            EmojiHoverPreviewBar(
                                interaction: interaction,
                                skinTone: selectedSkinTone
                            )
                            .frame(height: 38)
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
                    document.synchronize(with: model, useCase: useCase)
                    interaction.synchronize(with: document.selectableCells)
                    searchIsFocused = true
                    await Task.yield()
                    await model.loadDiscordEmojiSettings()
                    if let guildID = model.selectedGuildID {
                        await model.loadEmojis(for: guildID)
                    }
                    document.synchronize(with: model, useCase: useCase)
                    interaction.synchronize(with: document.selectableCells)
                    if let firstSection = document.rows.first?.section {
                        document.visibleSection = firstSection
                        await Task.yield()
                        proxy.scrollTo(EmojiDocumentRow.headerID(for: firstSection), anchor: .top)
                    }
                    await Task.yield()
                    searchIsFocused = true
                }
            }
        }
        .frame(width: ChatChromeMetrics.emojiPickerWidth, height: 420)
        .onExitCommand(perform: handleEscapeCommand)
        .alert("Emoji Unavailable", isPresented: Binding(get: { emojiLockMessage != nil }, set: { if !$0 { emojiLockMessage = nil } })) {
            Button("OK", role: .cancel) { emojiLockMessage = nil }
        } message: { Text(emojiLockMessage ?? "") }
        .onChange(of: skinToneRawValue) { _, _ in
            requestSearchFocus()
        }
        .onChange(of: model.discordFavoriteEmojiKeys) { _, _ in
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
        }
        .onChange(of: model.emojisByGuild) { _, _ in
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
        }
        .onDisappear {
            visibleGuildLoadTask?.cancel()
            visibleGuildLoadTask = nil
            pendingVisibleGuilds.removeAll()
        }
    }

    private var searchQuery: Binding<String> {
        Binding(
            get: { document.query },
            set: { query in
                let clearsSearch = !document.query.isEmpty && query.isEmpty
                document.setQuery(query)
                guard clearsSearch else { return }
                interaction.resetSelection(with: document.selectableCells)
            }
        )
    }

    private var selectedSkinTone: NativeEmojiSkinTone {
        NativeEmojiSkinTone(rawValue: skinToneRawValue) ?? .standard
    }

    private func handleEscapeCommand() {
        guard !document.query.isEmpty else {
            dismiss()
            return
        }
        searchQuery.wrappedValue = ""
        requestSearchFocus()
    }

    private func requestSearchFocus() {
        searchIsFocused = false
        Task { @MainActor in
            await Task.yield()
            searchIsFocused = true
        }
    }

    private func choose(_ cell: EmojiPickerCell, shiftPressed: Bool) {
        interaction.select(cell)
        activate(cell.item, shiftPressed: shiftPressed)
    }

    private func activate(_ item: EmojiPickerItem, shiftPressed: Bool) {
        if let reason = lockReason(item) { emojiLockMessage = reason; return }
        let selection = item.selection(skinTone: selectedSkinTone)
        model.recordEmojiUse(selection.usageKey)
        let keepsPickerPresented = EmojiPickerActivationPolicy.keepsPickerPresented(
            allowsPersistentSelection: allowsPersistentSelection,
            shiftPressed: shiftPressed
        )
        select(
            EmojiPickerActivation(
            selection: selection,
            keepsPickerPresented: keepsPickerPresented
            )
        )
        guard keepsPickerPresented else { return }
        document.synchronize(with: model, useCase: useCase)
        interaction.synchronize(with: document.selectableCells)
        keyboardNavigationIsFocused = true
    }

    private func lockReason(_ item: EmojiPickerItem) -> String? {
        guard case let .custom(emoji) = item else { return nil }
        if useCase == .message, !model.canComposeEmoji(emoji) {
            return String(localized: "Enable FakeNitro emojis in Features to send this emoji as an image link.", bundle: #bundle)
        }
        guard DiscordEmojiPermissionPolicy.isPremiumLocked(emoji, for: useCase, premiumType: model.snapshot?.currentUser.premiumType ?? 0) else { return nil }
        return String(localized: "Using this emoji in your profile requires Nitro.", bundle: #bundle)
    }

    private func toggleFavorite(_ item: EmojiPickerItem) {
        let isFavorite = document.isFavorite(item)
        Task { @MainActor in
            guard await model.setEmojiFavorite(
                discordKey: item.discordKey,
                isFavorite: !isFavorite
            ) else { return }
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
        }
    }

    private func retry(_ guildID: GuildID) {
        Task { @MainActor in
            await model.retryEmojis(for: guildID)
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
        }
    }

    private func sectionBecameVisible(_ section: EmojiDocumentSection) {
        guard case let .guild(guildID) = section,
              model.emojisByGuild[guildID] == nil,
              !model.loadingEmojiGuildIDs.contains(guildID),
              !pendingVisibleGuilds.contains(guildID)
        else { return }
        pendingVisibleGuilds.append(guildID)
        startVisibleGuildLoaderIfNeeded()
    }

    private func startVisibleGuildLoaderIfNeeded() {
        guard visibleGuildLoadTask == nil else { return }
        visibleGuildLoadTask = Task { @MainActor in
            while !Task.isCancelled, let guildID = pendingVisibleGuilds.first {
                pendingVisibleGuilds.removeFirst()
                await model.loadEmojis(for: guildID)
                guard !Task.isCancelled else { break }
                document.synchronize(with: model, useCase: useCase)
                interaction.synchronize(with: document.selectableCells)
            }
            visibleGuildLoadTask = nil
        }
    }

    private func jump(to section: EmojiDocumentSection, proxy: NativePickerScrollPosition) {
        document.setQuery("")
        interaction.synchronize(with: document.selectableCells)
        document.visibleSection = section
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(EmojiDocumentRow.headerID(for: section), anchor: .top)
            guard case let .guild(guildID) = section else { return }
            await model.loadEmojis(for: guildID)
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
            await Task.yield()
            proxy.scrollTo(EmojiDocumentRow.headerID(for: section), anchor: .top)
        }
    }

    private func jumpToNative(proxy: NativePickerScrollPosition) {
        let section = EmojiDocumentSection.native(.smileys)
        document.setQuery("")
        interaction.synchronize(with: document.selectableCells)
        document.visibleSection = section
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(EmojiDocumentRow.headerID(for: section), anchor: .top)
        }
    }

    private func handleKeyPress(
        _ press: KeyPress,
        proxy: NativePickerScrollPosition
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
            activate(
                interaction.item,
                shiftPressed: press.modifiers.contains(.shift)
            )
            return .handled
        default:
            return .ignored
        }
    }

    private func navigate(
        _ direction: EmojiPickerGridDirection,
        proxy: NativePickerScrollPosition
    ) -> KeyPress.Result {
        guard
            let cell = document.destinationCell(
            from: interaction.selectedCellID,
            direction: direction
            )
        else { return .ignored }
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

private struct EmojiPickerDocumentView: View {
    let document: EmojiPickerDocumentStore
    let interaction: EmojiPickerInteractionModel
    let skinTone: NativeEmojiSkinTone
    let proxy: NativePickerScrollPosition
    let choose: (EmojiPickerCell, Bool) -> Void
    let toggleFavorite: (EmojiPickerItem) -> Void
    let retry: (GuildID) -> Void
    let becameVisible: (EmojiDocumentSection) -> Void
    let lockReason: (EmojiPickerItem) -> String?

    @State private var measurement = NativePickerRowMeasurement()

    private func rowView(_ row: EmojiDocumentRow) -> EmojiDocumentRowView {
        EmojiDocumentRowView(
            row: row, skinTone: skinTone, interaction: interaction,
            isFavorite: document.isFavorite, choose: choose,
            toggleFavorite: toggleFavorite, retry: retry,
            lockReason: lockReason
        )
    }

    var body: some View {
        // Native rows participate in the same observable keyboard/hover selection.
        _ = interaction.selectedCellID
        return NativePickerDocument(
            rows: document.rows,
            revision: document.revision,
            position: proxy,
            rowHeight: { row, width in
                if case .emojis = row.content { return EmojiPickerGridMetrics.cellSize }
                return measurement.height(key: "\(row.id):\(row.content)", width: width) { rowView(row) }
            },
            becameVisible: { row in
                if case .header = row.content { document.markVisible(row.section) }
                becameVisible(row.section)
            },
            didScrollTo: { document.markVisible($0.section) },
            nativeContent: { row, reused, environment in
                rowView(row).makeNativeView(reusing: reused, environment: environment)
            },
            content: rowView
        )
        .onChange(of: document.query) { _, query in
            interaction.synchronize(with: document.selectableCells)
            guard !query.isEmpty else { return }
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo(EmojiDocumentRow.headerID(for: .search), anchor: .top)
            }
        }
    }
}

struct EmojiPickerSearchField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    var body: some View {
        HStack(spacing: ChatChromeMetrics.pickerSearchHeaderSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(
                    size: ChatChromeMetrics.pickerSearchHeaderIconSize,
                    weight: .medium
                ))
                .foregroundStyle(.secondary)
            PickerSearchTextField(
                text: $text,
                isFocused: $isFocused,
                placeholder: placeholder
            )
                .frame(maxWidth: .infinity)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, ChatChromeMetrics.pickerSearchHeaderInset)
        .frame(height: ChatChromeMetrics.pickerSearchHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .accessibilityIdentifier("picker-search")
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}

private struct PickerSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> EmojiSearchNSTextField {
        let textField = EmojiSearchNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: ChatChromeMetrics.pickerSearchHeaderFontSize)
        textField.textColor = .labelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.isAutomaticTextCompletionEnabled = false
        textField.contentType = NSTextContentType(rawValue: "dev.sakuracord.emoji-search")
        textField.allowsWritingTools = false
        textField.allowsWritingToolsAffordance = false
        textField.setAccessibilityLabel(placeholder)
        return textField
    }

    func updateNSView(_ textField: EmojiSearchNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        if textField.stringValue != text {
            textField.stringValue = text
        }

        if isFocused {
            textField.requestFirstResponderWhenReady()
            Self.disableCompletionFeatures(in: textField.currentEditor() as? NSTextView)
        } else if textField.window?.firstResponder === textField.currentEditor() {
            textField.window?.makeFirstResponder(nil)
        }
    }

    private static func disableCompletionFeatures(in editor: NSTextView?) {
        guard let editor else { return }
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
            Self.configureEditor(from: notification)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        private static func configureEditor(from notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            let editor = textField.currentEditor() as? NSTextView
            PickerSearchTextField.disableCompletionFeatures(in: editor)
            editor?.applySakuraCordTextSelectionAppearance()
        }
    }
}

private final class EmojiSearchNSTextField: NSTextField {
    private var focusRequestIsScheduled = false
    private var didAutofocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            didAutofocus = false
            focusRequestIsScheduled = false
            return
        }
        guard !didAutofocus else { return }
        requestFirstResponderWhenReady()
    }

    func requestFirstResponderWhenReady() {
        guard let window, !focusRequestIsScheduled else { return }
        if window.firstResponder === currentEditor() {
            didAutofocus = true
            return
        }
        focusRequestIsScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [0, 80, 140, 220] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard let window = self.window else { break }
                window.makeKey()
                _ = window.makeFirstResponder(self)
                await Task.yield()
                if window.firstResponder === currentEditor() {
                    didAutofocus = true
                    break
                }
            }
            focusRequestIsScheduled = false
        }
    }
}

enum EmojiDocumentSection: Hashable, Identifiable {
    case favorites
    case frequent
    case native(NativeEmojiCategory)
    case guild(GuildID)
    case search

    var id: String {
        switch self {
        case .favorites: "favorites"
        case .frequent: "frequent"
        case let .native(category): "native:\(category.rawValue)"
        case let .guild(id): "guild:\(id)"
        case .search: "search"
        }
    }

    var isNative: Bool {
        if case .native = self {
            return true
        }
        return false
    }
}

struct EmojiDocumentRow: Identifiable {
    enum Content {
        case header(title: String, count: Int)
        case emojis([EmojiPickerCell])
        case empty(String)
        case loading
        case failure(guildID: GuildID, details: String)
    }

    let id: String
    let section: EmojiDocumentSection
    let content: Content

    static func headerID(for section: EmojiDocumentSection) -> String {
        "header:\(section.id)"
    }
}

private struct EmojiDocumentSectionData {
    enum State {
        case ready
        case loading
        case failure(String)
    }

    let id: EmojiDocumentSection
    let title: String
    let items: [EmojiPickerItem]
    let emptyMessage: String
    var state: State = .ready
}

@MainActor
@Observable
final class EmojiPickerDocumentStore {
    static let itemsPerRow = EmojiPickerGridMetrics.columns

    private struct PreparedDocument {
        let rows: [EmojiDocumentRow]
        let selectableRows: [[EmojiPickerCell]]
        let navigationRows: [[String]]
        let selectableCells: [EmojiPickerCell]
        let cellsByID: [String: EmojiPickerCell]
    }

    private static let initialDocument: PreparedDocument = {
        let store = EmojiPickerDocumentStore(empty: ())
        store.rebuild()
        return PreparedDocument(
            rows: store.rows,
            selectableRows: store.selectableRows,
            navigationRows: store.navigationRows,
            selectableCells: store.selectableCells,
            cellsByID: store.cellsByID
        )
    }()

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild()
        }
    }

    private(set) var revision = 0
    private(set) var rows: [EmojiDocumentRow] = []
    private(set) var selectableCells: [EmojiPickerCell] = []
    private(set) var guilds: [Guild] = []
    private(set) var showsFavorites = false
    private(set) var showsFrequentlyUsed = false
    var visibleSection: EmojiDocumentSection = .native(.smileys)

    private var emojisByGuild: [GuildID: [DiscordEmoji]] = [:]
    private var loadingGuilds: Set<GuildID> = []
    private var errorsByGuild: [GuildID: String] = [:]
    private var localUsage: [String: Int] = [:]
    private var localRecents: [String] = []
    private var discordFavorites: [String] = []
    private var discordFavoriteCandidates: Set<String> = []
    private var discordFrequentlyUsed: [String] = []
    private var discordUsage: [String: Int] = [:]
    private var selectableRows: [[EmojiPickerCell]] = []
    private var navigationRows: [[String]] = []
    private var cellsByID: [String: EmojiPickerCell] = [:]

    init() {
        let initialDocument = Self.initialDocument
        rows = initialDocument.rows
        selectableRows = initialDocument.selectableRows
        navigationRows = initialDocument.navigationRows
        selectableCells = initialDocument.selectableCells
        cellsByID = initialDocument.cellsByID
    }

    private init(empty: Void) {}

    func synchronize(with model: AppModel, useCase: DiscordEmojiUseCase) {
        let premiumType = model.snapshot?.currentUser.premiumType ?? 0
        let eligibleGuilds = PickerSectionGuildOrdering.orderedGuilds(
            railItems: model.serverRailItems,
            guildsByID: model.serverRailGuildsByID,
            fallbackGuilds: model.snapshot?.guilds ?? [],
            currentGuildID: model.selectedGuildID
        ).filter {
            DiscordEmojiPermissionPolicy.canShowGuild(
                $0.id,
                for: useCase,
                premiumType: premiumType
            )
        }
        let eligibleGuildIDs = Set(eligibleGuilds.map(\.id))
        let emojisByGuild = model.emojisByGuild.reduce(into: [GuildID: [DiscordEmoji]]()) { result, entry in
            guard eligibleGuildIDs.contains(entry.key) else { return }
            result[entry.key] = entry.value.filter {
                DiscordEmojiPermissionPolicy.canShow(
                    $0,
                    for: useCase,
                    premiumType: premiumType
                )
            }
        }
        // Unresolved guilds stay visible so their sections can load or retry.
        let guilds = PickerSectionGuildOrdering.retainingNonemptyCatalogs(
            eligibleGuilds, catalogs: emojisByGuild, isAvailable: \.isAvailable
        )
        let visibleGuildIDs = Set(guilds.map(\.id))
        let loadingGuilds = model.loadingEmojiGuildIDs.intersection(visibleGuildIDs)
        let errorsByGuild = model.emojiLoadErrorsByGuild.filter {
            visibleGuildIDs.contains($0.key)
        }
        let localUsage = model.emojiUsageCounts
        let localRecents = model.emojiRecentKeys
        let discordFavorites = model.discordFavoriteEmojiKeys
        let discordFrequentlyUsed = model.discordFrequentlyUsedEmojiKeys
        let discordUsage = model.discordEmojiUsageScores
        guard self.guilds != guilds
            || self.emojisByGuild != emojisByGuild
            || self.loadingGuilds != loadingGuilds
            || self.errorsByGuild != errorsByGuild
            || self.localUsage != localUsage
            || self.localRecents != localRecents
            || self.discordFavorites != discordFavorites
            || self.discordFrequentlyUsed != discordFrequentlyUsed
            || self.discordUsage != discordUsage
        else { return }

        self.guilds = guilds
        self.emojisByGuild = emojisByGuild
        self.loadingGuilds = loadingGuilds
        self.errorsByGuild = errorsByGuild
        self.localUsage = localUsage
        self.localRecents = localRecents
        self.discordFavorites = discordFavorites
        discordFavoriteCandidates = discordFavorites.reduce(into: []) { values, key in
            values.formUnion(settingsKeyCandidates(key))
        }
        self.discordFrequentlyUsed = discordFrequentlyUsed
        self.discordUsage = discordUsage
        rebuild()
    }

    func setQuery(_ value: String) {
        query = value
    }

    func destinationCell(
        from currentID: String?,
        direction: EmojiPickerGridDirection
    ) -> EmojiPickerCell? {
        let destinationID = EmojiPickerGridNavigation.destinationID(
            rows: navigationRows,
            currentID: currentID,
            direction: direction
        )
        return destinationID.flatMap { cellsByID[$0] }
    }

    func markVisible(_ section: EmojiDocumentSection) {
        guard section != .search else { return }
        visibleSection = section
    }

    func isFavorite(_ item: EmojiPickerItem) -> Bool {
        !item.discordKeys.isDisjoint(with: discordFavoriteCandidates)
    }

    private func rebuild() {
        revision &+= 1
        rows = sections().flatMap(rows(for:))
        if !rows.contains(where: { $0.section == visibleSection }), let first = rows.first {
            visibleSection = first.section
        }
        selectableRows = rows.compactMap { row in
            guard case let .emojis(cells) = row.content else { return nil }
            return cells
        }
        navigationRows = selectableRows.map { $0.map(\.id) }
        selectableCells = selectableRows.flatMap(\.self)
        cellsByID = Dictionary(uniqueKeysWithValues: selectableCells.map { ($0.id, $0) })
    }

    private func sections() -> [EmojiDocumentSectionData] {
        let allItems = allItems()
        let favoriteItems = orderedItems(for: discordFavorites, in: allItems)
        let frequentItems: [EmojiPickerItem]
        if discordFrequentlyUsed.isEmpty {
            frequentItems = Array(
                orderedItems(for: localRecents, in: allItems).prefix(18)
            )
        } else {
            frequentItems = Array(
                orderedItems(for: discordFrequentlyUsed, in: allItems).prefix(18)
            )
        }
        showsFavorites = !favoriteItems.isEmpty
        showsFrequentlyUsed = !frequentItems.isEmpty
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            let normalizedQuery = EmojiSearchMatcher.normalized(trimmedQuery)
            let matches = allItems.filter { $0.matches(normalizedQuery: normalizedQuery) }
            return [
                .init(
                id: .search,
                title: "Search Results",
                items: matches,
                emptyMessage: "No emojis match “\(trimmedQuery)”."
                )
            ]
        }

        var sections: [EmojiDocumentSectionData] = [
            .init(
                id: .favorites,
                title: "Favorites",
                items: favoriteItems,
                emptyMessage: "Your favorite emojis will appear here."
            ),
            .init(
                id: .frequent,
                title: "Frequently Used",
                items: frequentItems,
                emptyMessage: "Emojis you use will appear here."
            )
        ].filter { !$0.items.isEmpty }

        sections.append(
            contentsOf: guilds.map { guild in
                let state: EmojiDocumentSectionData.State =
                    if loadingGuilds.contains(guild.id)
                        || emojisByGuild[guild.id] == nil && errorsByGuild[guild.id] == nil
                    {
                .loading
            } else if let error = errorsByGuild[guild.id] {
                .failure(error)
            } else {
                .ready
            }
            return EmojiDocumentSectionData(
                id: .guild(guild.id),
                title: guild.name,
                items: (emojisByGuild[guild.id] ?? [])
                    .filter(\.isAvailable)
                    .map(EmojiPickerItem.custom),
                emptyMessage: "This server has no custom emojis.",
                state: state
            )
            }
        )

        sections.append(
            contentsOf: NativeEmojiCategory.allCases.map { category in
            EmojiDocumentSectionData(
                id: .native(category),
                title: category.title,
                items: NativeEmojiPickerIndex.itemsByCategory[category] ?? [],
                emptyMessage: "No emojis are available in this category."
            )
            }
        )
        return sections
    }

    private func rows(for section: EmojiDocumentSectionData) -> [EmojiDocumentRow] {
        var result = [
            EmojiDocumentRow(
            id: EmojiDocumentRow.headerID(for: section.id),
            section: section.id,
            content: .header(title: section.title, count: section.items.count)
            )
        ]

        switch section.state {
        case .loading where section.items.isEmpty:
            result.append(
                .init(
                id: "loading:\(section.id.id)", section: section.id, content: .loading
                )
            )
            return result
        case let .failure(details) where section.items.isEmpty:
            if case let .guild(guildID) = section.id {
                result.append(
                    .init(
                    id: "failure:\(section.id.id)",
                    section: section.id,
                    content: .failure(guildID: guildID, details: details)
                    )
                )
            }
            return result
        default:
            break
        }

        guard !section.items.isEmpty else {
            result.append(
                .init(
                id: "empty:\(section.id.id)",
                section: section.id,
                content: .empty(section.emptyMessage)
                )
            )
            return result
        }

        for start in stride(from: 0, to: section.items.count, by: Self.itemsPerRow) {
            let end = min(start + Self.itemsPerRow, section.items.count)
            let items = Array(section.items[start ..< end])
            let rowID = "emojis:\(section.id.id):\(items[0].id)"
            let cells = items.map { item in
                EmojiPickerCell(
                    id: "\(rowID):\(item.id)",
                    rowID: rowID,
                    item: item
                )
            }
            result.append(
                .init(
                id: rowID,
                section: section.id,
                content: .emojis(cells)
                )
            )
        }
        return result
    }

    private func allItems() -> [EmojiPickerItem] {
        let loadedCustom = emojisByGuild.values
            .flatMap(\.self)
            .filter(\.isAvailable)
            .map(EmojiPickerItem.custom)
        let loadedIDs = Set(loadedCustom.map(\.discordKey))
        return NativeEmojiPickerIndex.allItems
            + loadedCustom
            + unresolvedSettingsCustomItems(excluding: loadedIDs)
    }

    private func orderedItems(
        for keys: [String],
        in items: [EmojiPickerItem]
    ) -> [EmojiPickerItem] {
        var itemsByDiscordKey: [String: EmojiPickerItem] = [:]
        for item in items {
            for key in item.discordKeys where itemsByDiscordKey[key] == nil {
                itemsByDiscordKey[key] = item
            }
        }
        var seen: Set<String> = []
        return keys.compactMap { key in
            let item = settingsKeyCandidates(key).lazy.compactMap { itemsByDiscordKey[$0] }.first
            guard let item, seen.insert(item.id).inserted else { return nil }
            return item
        }
    }

    private func settingsKeyCandidates(_ key: String) -> Set<String> {
        var candidates: Set<String> = [key]
        if let finalComponent = key.split(separator: ":").last,
           finalComponent.allSatisfy(\.isNumber)
        {
            candidates.insert(String(finalComponent))
        }
        if key.hasPrefix("custom:") {
            candidates.insert(String(key.dropFirst("custom:".count)))
        }
        return candidates
    }

    private func unresolvedSettingsCustomItems(excluding loadedIDs: Set<String>) -> [EmojiPickerItem] {
        var keys = Set(discordFavorites)
        keys.formUnion(discordFrequentlyUsed)
        keys.formUnion(discordUsage.keys)
        keys.formUnion(
            localUsage.keys.compactMap { key in
                key.hasPrefix("custom:") ? String(key.dropFirst("custom:".count)) : nil
            }
        )
        keys.formUnion(
            localRecents.compactMap { key in
                key.hasPrefix("custom:") ? String(key.dropFirst("custom:".count)) : nil
            }
        )

        return keys.compactMap { key in
            let candidate = key.split(separator: ":").last.map(String.init) ?? key
            guard !candidate.isEmpty,
                  candidate.allSatisfy(\.isNumber),
                  !loadedIDs.contains(candidate)
            else { return nil }
            let components = key.split(separator: ":")
            guard components.count >= 3 else { return nil }
            let name = String(components[components.count - 2]).trimmingCharacters(
                in: CharacterSet(charactersIn: "<>")
            )
            guard !name.isEmpty, name != "emoji", !name.allSatisfy(\.isNumber) else { return nil }
            return .custom(
                DiscordEmoji(
                    id: candidate,
                    name: name,
                    guildID: GuildID(rawValue: 0)
                )
            )
        }
    }
}
