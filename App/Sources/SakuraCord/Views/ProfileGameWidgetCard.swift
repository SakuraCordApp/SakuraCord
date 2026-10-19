import SakuraCordModels
import SwiftUI

struct ProfileGameWidgetCard: View {
    let widgetID: String
    let kind: ProfileGameWidgetKind
    let games: [ProfileWidgetGame]
    let records: [ProfileGame]
    let animates: Bool
    var editor: ProfileEditorState?
    var displayName = ""
    var openGame: ((ProfileGame) -> Void)?
    @State private var selectedGame: ProfileGame?
    @State private var expanded = false
    @State private var showsPicker = false
    @State private var isExpansionHovered = false
    private var isGrid: Bool { kind == .liked || kind == .wanted }
    private var visibleGames: [ProfileWidgetGame] {
        editor != nil || expanded ? games : Array(games.prefix(isGrid ? 8 : 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(12)) {
            HStack {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                    Text(kind.title).font(.interfaceSystem(size: 14, weight: .medium))
                    if editor != nil {
                        Text(kind == .favorite ? "Choose 1 game" : "Add up to \(kind.capacity) games").font(.interfaceSystem(size: 12))
                    }
                }
                Spacer()

            }
            .padding(.trailing, editor == nil ? 0 : InterfaceScale.metric(24))
            if isGrid, !games.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: InterfaceScale.metric(16)), count: 4), spacing: InterfaceScale.metric(16)) {
                    ForEach(visibleGames) { game in
                        ProfileWidgetGameLink(game: records.first { $0.id == game.id }, animates: animates, open: gameAction)
                            .aspectRatio(3 / 4, contentMode: .fit)
                            .modifier(gameActions(game))
                            .contentShape(.interaction, .rect(cornerRadius: InterfaceScale.metric(8)))
                    }
                    if editor != nil, games.count < kind.capacity {
                        addGameButton.aspectRatio(3 / 4, contentMode: .fit)
                    }
                }
                if editor == nil, games.count > 8 {
                    expansionButton.font(.interfaceSystem(size: 12, weight: .medium))
                }
            } else if kind == .favorite, let game = games.first {
                gameRow(game)
            } else if !games.isEmpty {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(12)) {
                    ForEach(visibleGames) { game in
                        gameRow(game)
                            .contentShape(.interaction, .rect(cornerRadius: InterfaceScale.metric(8)))
                    }
                }
                if editor != nil, kind == .rotation, !games.isEmpty, games.count < kind.capacity {
                    addGameButton.frame(width: InterfaceScale.metric(88), height: InterfaceScale.metric(116))
                }
                if editor == nil, kind == .rotation, games.count > 2 {
                    expansionButton.font(.interfaceSystem(size: 14, weight: .medium))
                }
            }
            if editor != nil, games.isEmpty {
                ProfileWidgetEmptyGameLayout(isGrid: isGrid) {
                    addGameButton
                    Text(emptyMessage).font(.interfaceSystem(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        }
        .padding(InterfaceScale.metric(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(16)))
        .windowModal(item: $selectedGame) { game in
            if let editor { ProfileGameView(model: editor.model, game: game, editor: editor) }
        }
        .onChange(of: editor?.draftGeneration) { _, _ in showsPicker = false }
        .onChange(of: editor?.isResolvingScope) { _, resolving in if resolving == true { showsPicker = false } }
    }

    private func gameRow(_ game: ProfileWidgetGame) -> some View {
        ProfileWidgetGameRow(
            game: game, record: records.first { $0.id == game.id }, kind: kind,
            animates: animates, displayName: displayName,
            isInEditor: editor != nil, editable: editor?.canEditWidgets == true,
            update: { editor?.updateWidgetGame(widgetID: widgetID, game: $0) },
            actions: gameActions(game),
            openGame: gameAction
        )
    }

    private func gameActions(_ game: ProfileWidgetGame) -> ProfileWidgetGameActions {
        let index = games.firstIndex { $0.id == game.id }
        return ProfileWidgetGameActions(
            isEnabled: editor?.canEditWidgets == true,
            backward: index.flatMap { $0 > 0 ? { moveGame(game, by: -1) } : nil },
            forward: index.flatMap { $0 < games.count - 1 ? { moveGame(game, by: 1) } : nil },
            remove: { editor?.removeWidgetGame(widgetID: widgetID, gameID: game.id) }
        )
    }

    private func moveGame(_ game: ProfileWidgetGame, by offset: Int) {
        guard let index = games.firstIndex(where: { $0.id == game.id }), games.indices.contains(index + offset) else { return }
        let beforeIndex = offset < 0 ? index - 1 : index + 2
        let before = games.indices.contains(beforeIndex) ? games[beforeIndex].id : nil
        withAnimation(.snappy(duration: 0.2)) {
            editor?.moveWidgetGames(widgetID: widgetID, ids: [game.id], before: before)
        }
    }

    private var addGameButton: some View {
        Button { showsPicker = true } label: {
            Image(systemName: "plus").font(.interfaceSystem(size: 24))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(CompactProfileWidgetHover(backgroundOpacity: 0.05, cornerRadius: InterfaceScale.metric(8)))
                .contentShape(.rect(cornerRadius: InterfaceScale.metric(8)))
        }
        .buttonStyle(.plain)
        .disabled(editor?.canEditWidgets != true || games.count >= kind.capacity)
        .accessibilityLabel("Add Game")
        .escapeDismissiblePopover(isPresented: $showsPicker) { gamePicker }
    }

    private var emptyMessage: String {
        switch kind {
        case .favorite: String(localized: "Pick your all-time favourite game.", bundle: #bundle)
        case .rotation: String(localized: "Show the games you're playing lately.", bundle: #bundle)
        case .liked: String(localized: "Add games you've enjoyed.", bundle: #bundle)
        case .wanted: String(localized: "Add games you'd like to play next.", bundle: #bundle)
        }
    }

    @ViewBuilder private var gamePicker: some View {
        if let editor {
            ProfileWidgetGamePicker(editor: editor, selectedIDs: Set(games.map(\.id)), dismiss: { showsPicker = false }, select: {
                editor.addWidgetGame(widgetID: widgetID, gameID: $0.id)
            })
        }
    }

    private var gameAction: ((ProfileGame) -> Void)? {
        if let editor { return { game in guard !editor.isSaving else { return }; selectedGame = game } }
        return openGame
    }

    private var expansionButton: some View {
        Button { expanded.toggle() } label: {
            Text(expanded ? "Show Less" : "Show More").underline(isExpansionHovered)
        }
        .buttonStyle(.plain)
        .onModalHover { isExpansionHovered = $0 }
    }

}

private struct ProfileWidgetGameRow: View {
    let game: ProfileWidgetGame
    let record: ProfileGame?
    let kind: ProfileGameWidgetKind
    let animates: Bool
    let displayName: String
    let isInEditor: Bool
    let editable: Bool
    let update: (ProfileWidgetGame) -> Void
    let actions: ProfileWidgetGameActions
    var openGame: ((ProfileGame) -> Void)?
    @State private var isNameHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: InterfaceScale.metric(16)) {
            ProfileWidgetGameLink(game: record, animates: animates, open: openGame)
                .frame(width: InterfaceScale.metric(88), height: InterfaceScale.metric(116))
                .modifier(actions)
            VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                HStack(alignment: .top) {
                    if let record, let openGame, record.metadata?.isProfileAvailable != false {
                        Button { openGame(record) } label: {
                            Text(record.name).underline(isNameHovered)
                        }
                        .buttonStyle(.plain).font(.interfaceSystem(size: 14, weight: .medium))
                        .onModalHover { isNameHovered = $0 }
                    } else { Text(record?.name ?? "Game").font(.interfaceSystem(size: 14, weight: .medium)) }
                    Spacer(minLength: 0)
                }
                ProfileWidgetGameComment(comment: game.comment, displayName: displayName, editable: editable && kind == .favorite) { value in
                    var updated = game
                    updated.comment = value
                    updated.includesComment = value != nil
                    update(updated)
                }
                ProfileWidgetGameTags(tags: game.tags ?? [], alwaysExpanded: isInEditor, update: editable ? { tags in
                    var updated = game
                    updated.tags = tags; updated.includesTags = true
                    update(updated)
                } : nil)
            }
        }
    }
}

private struct ProfileWidgetGameComment: View {
    let comment: String?
    let displayName: String
    let editable: Bool
    let update: (String?) -> Void
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editable || !(comment ?? "").isEmpty {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                HStack {
                    Label {
                        Text("\(displayName) says:")
                    } icon: { Image(systemName: "quote.opening") }
                    .font(.interfaceSystem(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                if isEditing {
                    TextField("Add a comment", text: Binding(get: { draft }, set: { updateDraft($0) }), axis: .vertical)
                        .lineLimit(3 ... 3).textFieldStyle(.plain).focused($focused)
                        .profileEditorTextHover(isEditing: true)
                        .onSubmit(commit)
                        .onKeyPress(.return, phases: .down) { event in
                            guard !event.modifiers.contains(.shift) else { return .ignored }
                            commit(); return .handled
                        }
                        .onChange(of: focused) { _, value in if !value { commit() } }
                        .onDisappear { commit() }
                } else if editable {
                    Button(action: beginEditing) { Text((comment ?? "").isEmpty ? "Add a comment" : comment ?? "") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .profileEditorTextHover()
                } else if let comment { Text(comment).foregroundStyle(.secondary) }
            }
            .font(.interfaceSystem(size: 12))
            .onChange(of: editable) { _, available in
                if !available { isEditing = false; focused = false }
            }
            .onChange(of: comment) { _, value in
                guard isEditing, value ?? "" != draft.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                draft = value ?? ""
                isEditing = false; focused = false
            }
        }
    }

    private func beginEditing() {
        draft = comment ?? ""; isEditing = true; focused = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false; focused = false
    }

    private func updateDraft(_ value: String) {
        guard isEditing else { return }
        var length = 0
        draft = String(value.prefix { length += $0.utf16.count; return length <= 200 })
        let comment = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        update(comment.isEmpty ? nil : comment)
    }
}

private struct ProfileWidgetGameActions: ViewModifier {
    let isEnabled: Bool
    var backward: (() -> Void)?
    var forward: (() -> Void)?
    let remove: () -> Void
    @State private var isHovered = false

    private var showsReordering: Bool { backward != nil || forward != nil }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if isEnabled, isHovered {
                    HoverActionPill(padding: showsReordering ? 3 : 4) {
                        if showsReordering {
                            HoverActionButton(systemImage: "chevron.left", help: String(localized: "Move Game Backward", bundle: #bundle), diameter: InterfaceScale.metric(22)) { backward?() }
                                .disabled(backward == nil)
                            HoverActionButton(systemImage: "chevron.right", help: String(localized: "Move Game Forward", bundle: #bundle), diameter: InterfaceScale.metric(22)) { forward?() }
                                .disabled(forward == nil)
                        }
                        HoverActionButton(systemImage: "trash", help: String(localized: "Remove Game", bundle: #bundle), role: .destructive, diameter: showsReordering ? 22 : nil, action: remove)
                    }.padding(InterfaceScale.metric(4))
                }
            }
            .onModalHover { isHovered = $0 }
    }
}

struct ProfileWidgetGameCover: View {
    let game: ProfileGame?
    let animates: Bool

    var body: some View {
        ProfileWidgetImageView(url: game?.coverURL, animates: animates, contentMode: .fill)
            .clipShape(.rect(cornerRadius: InterfaceScale.metric(8))).accessibilityLabel(game?.name ?? String(localized: "Game", bundle: #bundle))
            .help(game?.name ?? "")
    }
}

private struct ProfileWidgetGameLink: View {
    let game: ProfileGame?
    let animates: Bool
    let open: ((ProfileGame) -> Void)?
    var body: some View {
        Group {
            if let game, let open, game.metadata?.isProfileAvailable != false {
                Button { open(game) } label: { cover }
                    .buttonStyle(.plain)
                    .accessibilityLabel(game.name)
            } else { cover }
        }
        .modifier(ProfileWidgetHover(tilts: true))
    }

    private var cover: some View {
        Color.clear
            .overlay { ProfileWidgetGameCover(game: game, animates: animates) }
            .clipShape(.rect(cornerRadius: InterfaceScale.metric(8)))
    }
}
