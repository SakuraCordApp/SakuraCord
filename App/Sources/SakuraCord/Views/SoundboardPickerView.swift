import AppKit
import SakuraCordModels
import SwiftUI

private enum SoundboardSection: Hashable, Identifiable {
    case favorites
    case frequent
    case defaults
    case guild(GuildID)
    case search

    var id: String {
        switch self {
        case .favorites: "favorites"
        case .frequent: "frequent"
        case .defaults: "defaults"
        case .guild(let id): "guild:\(id)"
        case .search: "search"
        }
    }

    var contentID: String {
        "soundboard-content:\(id)"
    }
}

private struct SoundboardPickerSection {
    let id: SoundboardSection
    let title: String
    let sounds: [SoundboardSound]
}

nonisolated enum SoundboardPickerContentPolicy {
    static func guilds(
        railItems: [GuildRailItem],
        guildsByID: [GuildID: Guild],
        fallbackGuilds: [Guild],
        currentGuildID: GuildID?
    ) -> [Guild] {
        PickerSectionGuildOrdering.orderedGuilds(
            railItems: railItems,
            guildsByID: guildsByID,
            fallbackGuilds: fallbackGuilds,
            currentGuildID: currentGuildID
        )
    }

    static func favoriteSounds(
        ids: [String],
        soundsByID: [String: SoundboardSound]
    ) -> [SoundboardSound] {
        ids.compactMap { soundsByID[$0] }.sorted(by: discordSoundOrder)
    }

    static func frequentlyUsedSounds(
        ids: [String],
        favoriteIDs: Set<String>,
        soundsByID: [String: SoundboardSound]
    ) -> [SoundboardSound] {
        ids.lazy
            .filter { !favoriteIDs.contains($0) }
            .prefix(3)
            .compactMap { soundsByID[$0] }
    }

    private static func discordSoundOrder(
        _ left: SoundboardSound,
        _ right: SoundboardSound
    ) -> Bool {
        if left.isAvailable != right.isAvailable {
            return left.isAvailable
        }
        if let leftID = UInt64(left.id), let rightID = UInt64(right.id) {
            return leftID < rightID
        }
        return left.id < right.id
    }
}

struct SoundboardPickerView: View {
    let model: AppModel
    @State private var measurement = NativePickerRowMeasurement()
    @State private var query = ""
    @State private var searchIsFocused = false
    @State private var visibleSection: SoundboardSection = .favorites

    var body: some View {
        VStack(spacing: 0) {
            EmojiPickerSearchField(
                text: $query,
                isFocused: $searchIsFocused,
                placeholder: "Search sounds"
            )
            Divider()
            if let error = model.soundboardErrorMessage,
               !model.allSoundboardSounds.isEmpty
            {
                soundboardErrorBanner(error)
                Divider()
            }
            NativePickerScrollReader { proxy in
                HStack(spacing: 0) {
                    sidebar(proxy: proxy)
                    Divider()
                    content(proxy: proxy)
                }
            }
        }
        .frame(width: ChatChromeMetrics.emojiPickerWidth, height: 420)
        .task {
            searchIsFocused = true
            await model.loadSoundboard()
        }
        .onChange(of: sections.map(\.id), initial: true) { _, sectionIDs in
            if !sectionIDs.contains(visibleSection), let first = sectionIDs.first {
                visibleSection = first
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Soundboard")
    }

    private func soundboardErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(hex: 0xF0B232))
            Text(error)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.soundboardErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Dismiss Error")
            .accessibilityLabel("Dismiss soundboard error")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(hex: 0xF0B232).opacity(0.1))
    }

    private func sidebar(proxy: NativePickerScrollPosition) -> some View {
        PickerSectionRail {
            if browsingSections.contains(where: { $0.id == .favorites }) {
                bookmark(.favorites, help: "Favorites", systemImage: "star.fill", proxy: proxy)
            }
            if browsingSections.contains(where: { $0.id == .frequent }) {
                bookmark(.frequent, help: "Frequently Used", systemImage: "clock.fill", proxy: proxy)
            }
            bookmark(.defaults, help: "Discord Sounds", systemImage: "waveform", proxy: proxy)

            if !guilds.isEmpty {
                Divider()
                    .frame(width: 28)
                    .padding(.vertical, 2)

                ForEach(guilds) { guild in
                    PickerSectionBookmark(
                        section: SoundboardSection.guild(guild.id),
                        visibleSection: visibleSection,
                        help: guild.name,
                        jump: { section in jump(to: section, proxy: proxy) },
                        content: { PickerGuildBookmarkIcon(guild: guild) }
                    )
                }
            }
        }
    }

    private func bookmark(
        _ section: SoundboardSection,
        help: String,
        systemImage: String,
        proxy: NativePickerScrollPosition
    ) -> some View {
        PickerSectionBookmark(
            section: section,
            visibleSection: visibleSection,
            help: help,
            jump: { jump(to: $0, proxy: proxy) },
            content: {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
            }
        )
    }

    private func content(proxy: NativePickerScrollPosition) -> some View {
        let rows = documentRows
        return NativePickerDocument(
            rows: rows,
            revision: rows.hashValue,
            position: proxy,
            showsIndicators: false,
            rowHeight: { row, width in
                switch row.content {
                case .sounds: return 48
                case .spacer: return 8
                default:
                    return measurement.height(key: "\(row.id):\(row.content)", width: width) { rowView(row) }
                }
            },
            becameVisible: { row in
                if case .header = row.content, let section = row.section { visibleSection = section }
            },
            didScrollTo: { row in
                if let section = row.section { visibleSection = section }
            },
            content: rowView
        )
        .onChange(of: query) { _, value in
            guard !value.isEmpty else { return }
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo(SoundboardSection.search.contentID, anchor: .top)
            }
        }
    }

    private var documentRows: [SoundboardDocumentRow] {
        var rows = [SoundboardDocumentRow(id: "top", section: nil, content: .spacer)]
        if model.isLoadingSoundboard, model.allSoundboardSounds.isEmpty {
            rows.append(.init(id: "loading", section: nil, content: .loading))
        } else if let error = model.soundboardErrorMessage, model.allSoundboardSounds.isEmpty {
            rows.append(.init(id: "failure", section: nil, content: .failure(error)))
        } else {
            for section in sections {
                rows.append(.init(id: section.id.contentID, section: section.id, content: .header(section.title, section.sounds.count)))
                if section.sounds.isEmpty {
                    let message = section.id == .search ? "No sounds found." : "No sounds here yet."
                    rows.append(.init(id: "empty:\(section.id.id)", section: section.id, content: .empty(message)))
                }
                for start in stride(from: 0, to: section.sounds.count, by: 3) {
                    let sounds = Array(section.sounds[start ..< min(start + 3, section.sounds.count)])
                    rows.append(.init(id: "sounds:\(section.id.id):\(sounds[0].id)", section: section.id, content: .sounds(sounds)))
                }
            }
        }
        rows.append(.init(id: "bottom", section: nil, content: .spacer))
        return rows
    }

    @ViewBuilder private func rowView(_ row: SoundboardDocumentRow) -> some View {
        switch row.content {
        case .spacer:
            Color.clear.frame(height: 8)
        case let .header(title, count):
            EmojiPickerHeader(title: title, count: count).padding(.top, 5)
        case let .empty(message):
            Text(message).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 38)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading sounds…")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
        case let .failure(error):
            VStack(spacing: 8) {
                Text("Couldn’t load the soundboard.")
                Button("Retry") { Task { await model.retrySoundboardLoad() } }.buttonStyle(.link)
            }
            .help(error).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 100)
        case let .sounds(sounds):
            HStack(spacing: 6) {
                ForEach(sounds) { sound in SoundboardButton(sound: sound, model: model) }
                ForEach(sounds.count ..< 3, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity).frame(height: 42)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private var guilds: [Guild] {
        let ordered = SoundboardPickerContentPolicy.guilds(
            railItems: model.serverRailItems,
            guildsByID: model.serverRailGuildsByID,
            fallbackGuilds: model.snapshot?.guilds ?? [],
            currentGuildID: model.selectedGuildID
        )
        return PickerSectionGuildOrdering.retainingNonemptyCatalogs(
            ordered, catalogs: model.soundboardSoundsByGuild, isAvailable: \.isAvailable
        )
    }

    private var sections: [SoundboardPickerSection] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedQuery.isEmpty {
            let matches = model.allSoundboardSounds.filter { sound in
                sound.name.localizedStandardContains(normalizedQuery)
                    || sound.emojiName?.localizedStandardContains(normalizedQuery) == true
                    || sound.guildID.flatMap { model.serverRailGuildsByID[$0]?.name }
                        .map { $0.localizedStandardContains(normalizedQuery) } == true
            }
            return [SoundboardPickerSection(id: .search, title: "Search Results", sounds: matches)]
        }
        return browsingSections
    }

    private var browsingSections: [SoundboardPickerSection] {
        let soundsByID = Dictionary(
            model.allSoundboardSounds.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let favoriteIDs = Set(model.soundboardUserSettings.favoriteSoundIDs)
        var result = [
            SoundboardPickerSection(
                id: .favorites,
                title: "Favorites",
                sounds: SoundboardPickerContentPolicy.favoriteSounds(
                    ids: model.soundboardUserSettings.favoriteSoundIDs,
                    soundsByID: soundsByID
                )
            ),
            SoundboardPickerSection(
                id: .frequent,
                title: "Frequently Used",
                sounds: SoundboardPickerContentPolicy.frequentlyUsedSounds(
                    ids: model.soundboardUserSettings.frequentlyUsedSoundIDs,
                    favoriteIDs: favoriteIDs,
                    soundsByID: soundsByID
                )
            ),
            SoundboardPickerSection(
                id: .defaults,
                title: "Discord Sounds",
                sounds: model.defaultSoundboardSounds
            ),
        ]
        result += guilds.map { guild in
            SoundboardPickerSection(
                id: .guild(guild.id),
                title: guild.name,
                sounds: model.soundboardSoundsByGuild[guild.id] ?? []
            )
        }
        return result.filter { section in
            switch section.id {
            case .favorites, .frequent: !section.sounds.isEmpty
            default: true
            }
        }
    }

    private func jump(to section: SoundboardSection, proxy: NativePickerScrollPosition) {
        query = ""
        visibleSection = section
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(section.contentID, anchor: .top)
            searchIsFocused = true
        }
    }
}

private struct SoundboardDocumentRow: Identifiable, Hashable {
    enum Content: Hashable {
        case spacer
        case header(String, Int)
        case sounds([SoundboardSound])
        case empty(String)
        case loading
        case failure(String)
    }

    let id: String
    let section: SoundboardSection?
    let content: Content
}

private struct SoundboardButton: View {
    let sound: SoundboardSound
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @GestureState private var isPressed = false

    var body: some View {
        ZStack {
            Button { Task { await model.playSound(sound) } } label: {
                SoundboardButtonLabel(sound: sound)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .opacity(isHovering ? 0.2 : 1)
            }
            .buttonStyle(SoundboardStaticButtonStyle())
            .help("Play \(sound.name)")
            .accessibilityLabel("Play \(sound.name)")
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
            )

            if isHovering {
                HStack(spacing: 0) {
                    SoundboardActionButton(
                        systemImage: "speaker.wave.2.fill",
                        help: "Preview \(sound.name) locally",
                        iconColor: .secondary
                    ) { Task { await model.previewSound(sound) } }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                    SoundboardActionButton(
                        systemImage: model.isFavoriteSound(sound) ? "star.fill" : "star",
                        help: model.isFavoriteSound(sound) ? "Remove from Favorites" : "Favorite"
                    ) { Task { await model.toggleFavoriteSound(sound) } }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(
            surfaceColor,
            in: ConcentricRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            ConcentricRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    outlineColor,
                    lineWidth: 0.5
                )
        }
        .contentShape(ConcentricRectangle(cornerRadius: 8, style: .continuous))
        .onModalHover { isHovering = $0 }
        .offset(y: isPressed ? 2 : 0)
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .overlay {
            SoundboardContextMenuBridge(
                isFavorite: model.isFavoriteSound(sound),
                toggleFavorite: { Task { await model.toggleFavoriteSound(sound) } },
                saveActions: saveActions,
                copyID: { MediaViewerActionService.copyText(sound.id) }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sound.name)
        .accessibilityAction(named: "Preview locally") {
            Task { await model.previewSound(sound) }
        }
        .accessibilityAction(named: model.isFavoriteSound(sound) ? "Remove from Favorites" : "Favorite") {
            Task { await model.toggleFavoriteSound(sound) }
        }
    }

    private var surfaceColor: Color {
        if colorScheme == .dark {
            return isHovering ? Color(hex: 0x28292C) : Color(hex: 0x202023)
        }
        return isHovering ? Color(hex: 0xD8D7DC) : Color(hex: 0xE2E1E6)
    }

    private var outlineColor: Color {
        if model.isSoundPlaying(sound), !isPressed {
            return Color(hex: 0x23A55A)
        }
        guard isHovering else { return .clear }
        return colorScheme == .dark
            ? Color(hex: 0x44454A)
            : Color(hex: 0xAFAEB4)
    }

    private var saveActions: MediaSaveMenuActions {
        MediaSaveMenuActions(
            saveAs: { download(to: .saveAs) },
            saveToDefaultFolder: { download(to: .defaultFolder) }
        )
    }

    private func download(to destination: MediaSaveDestination) {
        guard let item = RichMediaItem(soundboardSound: sound) else { return }
        Task { @MainActor in
            do {
                _ = try await MediaViewerActionService.save(
                    item,
                    to: destination
                )
            } catch {
                model.soundboardErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct SoundboardContextMenuBridge: NSViewRepresentable {
    let isFavorite: Bool
    let toggleFavorite: () -> Void
    let saveActions: MediaSaveMenuActions
    let copyID: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(from: self) }

    func makeNSView(context: Context) -> MediaImageContextMenuHitView {
        let view = MediaImageContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(
        _ nsView: MediaImageContextMenuHitView,
        context: Context
    ) {
        context.coordinator.update(from: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        private var isFavorite: Bool
        private var toggleFavorite: () -> Void
        private var saveActions: MediaSaveMenuActions
        private var copyID: () -> Void

        init(from bridge: SoundboardContextMenuBridge) {
            isFavorite = bridge.isFavorite
            toggleFavorite = bridge.toggleFavorite
            saveActions = bridge.saveActions
            copyID = bridge.copyID
        }

        func update(from bridge: SoundboardContextMenuBridge) {
            isFavorite = bridge.isFavorite
            toggleFavorite = bridge.toggleFavorite
            saveActions = bridge.saveActions
            copyID = bridge.copyID
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(menuItem(
                isFavorite ? "Remove from Favorites" : "Favorite",
                systemImage: isFavorite ? "star" : "star.fill",
                action: #selector(toggleFavoriteFromMenu)
            ))
            menu.addItem(
                MediaSaveMenuBuilder.submenuItem(
                    "Download Sound",
                    systemImage: "arrow.down.circle",
                    actions: saveActions
                )
            )
            menu.addItem(.separator())
            menu.addItem(menuItem(
                "Copy Sound ID",
                systemImage: "number.square.fill",
                action: #selector(copyIDFromMenu)
            ))
            return menu
        }

        private func menuItem(
            _ title: String,
            systemImage: String,
            action: Selector
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            ContextMenuItemSupport.configure(
                item,
                title: title,
                systemImage: systemImage
            )
            return item
        }

        @objc private func toggleFavoriteFromMenu() { toggleFavorite() }
        @objc private func copyIDFromMenu() { copyID() }
    }
}

private struct SoundboardActionButton: View {
    let systemImage: String
    let help: String
    var iconColor = Color.primary
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(
                    Color.primary.opacity(isHovering ? 0.14 : 0),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(SoundboardStaticButtonStyle())
        .contentShape(Circle())
        .onModalHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SoundboardStaticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct SoundboardButtonLabel: View {
    let sound: SoundboardSound

    var body: some View {
        if let emojiID = sound.emojiID,
           let url = URL(string: "https://cdn.discordapp.com/emojis/\(emojiID).webp?size=48&quality=lossless")
        {
            AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                switch phase {
                case .empty:
                    label {
                        Color.clear
                            .frame(width: 21, height: 21)
                    }
                case .success(let image):
                    label {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 21, height: 21)
                    }
                case .failure:
                    name
                @unknown default:
                    name
                }
            }
        } else if let emojiName = sound.emojiName, !emojiName.isEmpty {
            label {
                Text(emojiName)
                    .font(.system(size: 17))
                    .fixedSize()
                    .offset(y: -0.5)
                    .frame(width: 21, height: 21)
            }
        } else {
            name
        }
    }

    private var name: some View {
        Text(sound.name)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func label<Icon: View>(
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 6) {
            icon()
            name
        }
    }
}

private extension RichMediaItem {
    init?(soundboardSound sound: SoundboardSound) {
        guard let url = sound.mediaURL else { return nil }
        id = sound.id
        self.url = url
        previewURL = nil
        title = "\(sound.name).ogg"
        description = nil
        width = nil
        height = nil
        size = 0
        kind = .audio
        isSpoiler = false
        autoplaysInline = false
    }
}
