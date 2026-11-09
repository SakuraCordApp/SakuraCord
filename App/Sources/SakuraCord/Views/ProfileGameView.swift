import AppKit
import DiscordProtocol
import SakuraCordModels
import SwiftUI

struct ProfileGameView: View {
    let model: AppModel
    @State private var game: ProfileGame
    @State private var editor: ProfileEditorState
    @State private var similar: [ProfileGame] = []
    @State private var announcements = ProfileGameAnnouncements()
    @State private var errors: [String: String] = [:]
    @State private var isLoading = true
    @State private var navigation: [ProfileGame] = []
    @State private var copiedLink = false
    @State private var mediaPresentation: NativeTimelineMediaViewerPresentation?
    @Environment(\.windowModalContext) private var dismiss

    init(model: AppModel, game: ProfileGame, editor: ProfileEditorState? = nil) {
        self.model = model
        _game = State(initialValue: game)
        if let editor, editor.scope == .main { _editor = State(initialValue: editor) } else { _editor = State(initialValue: ProfileEditorState(model: model)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ProfileGameMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 0) {
                    ProfileGameHero(game: game)
                    header
                        .padding(.top, -ProfileGameMetrics.coverOverlap)
                        .padding(.horizontal, ProfileGameMetrics.inset)
                }
                statusMessages.padding(.horizontal, ProfileGameMetrics.inset)
                if game.metadata?.isProfileAvailable == false {
                    ContentUnavailableView("Game Profile Unavailable", systemImage: "gamecontroller")
                } else {
                    overview
                    announcementSection
                    similarSection
                }
            }
            .padding(.bottom, ProfileGameMetrics.inset)
        }
        // Links in announcements, stores, reviews and the link row all go
        // through the app's own link handling.
        .environment(\.openURL, OpenURLAction { url in openLink(url); return .handled })
        .overlay(alignment: .top) { chrome }
        .background {
            // Hosted here rather than at the root so the viewer opens in the
            // window showing this profile, including Settings.
            MediaViewerWindowOverlay(presentation: mediaPresentation, animatesOverlays: { model.animates(.overlays) },
                                     dismiss: { mediaPresentation = nil })
                .environment(model.voiceMessagePlayback)
                .frame(width: 0, height: 0)
        }
        .clipShape(.rect(cornerRadius: WindowModalSurface.cornerRadius))
        .windowModalSize(width: 1180, height: 760)
        .task(id: game.id) { await load() }
        .windowModalDismissDisabled(editor.isSaving)
        .onChange(of: model.installedAccountSessionRevision) { _, _ in dismiss?() }
        .onChange(of: model.isSwitchingAccounts) { _, switching in if switching { dismiss?() } }
    }

    // MARK: Header

    private var chrome: some View {
        HStack {
            if !navigation.isEmpty {
                ProfileGameHeroButton(systemImage: "chevron.left", help: "Back") {
                    if let previous = navigation.popLast() { game = previous }
                }
                .disabled(editor.isSaving)
            }
            Spacer()
            ProfileGameHeroButton(systemImage: "xmark", help: "Close") { dismiss?() }
                .accessibilityIdentifier("profile-editor-close")
                .disabled(editor.isSaving)
        }
        .padding(InterfaceScale.metric(16))
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: InterfaceScale.metric(20)) {
            ProfileWidgetGameCover(game: game, animates: true)
                .frame(width: InterfaceScale.metric(108), height: InterfaceScale.metric(144))
                .overlay { RoundedRectangle(cornerRadius: InterfaceScale.metric(8)).strokeBorder(.white.opacity(0.12)) }
                .shadow(color: .black.opacity(0.35), radius: InterfaceScale.metric(16), y: InterfaceScale.metric(6))
            VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                Text(game.name)
                    .font(.interfaceSystem(size: 30, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.interfaceSystem(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.bottom, InterfaceScale.metric(4))
            Spacer(minLength: InterfaceScale.metric(16))
            actions.padding(.bottom, InterfaceScale.metric(6))
        }
    }

    private var subtitle: String {
        let genres = ProfileGameLabels.genres(game.metadata?.genres ?? [])
        let year = game.metadata?.releaseDate.map { $0.formatted(.dateTime.year()) }
        return [genres.isEmpty ? nil : genres, year].compactMap { $0 }.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            if editor.canEditWidgets { addToProfileMenu }
            Button {
                MediaViewerActionService.copyText("https://discord.com/games/\(game.id)")
                copiedLink = true
            } label: {
                Image(systemName: copiedLink ? "checkmark" : "link").contentTransition(.symbolEffect(.replace))
                    .profileGameActionLabel(isIcon: true)
            }
            .buttonStyle(.plain)
            .profileGameAction(.secondary)
            .help(copiedLink ? "Copied" : "Copy Link")
            .accessibilityLabel("Copy Link")
            .task(id: copiedLink) {
                guard copiedLink else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copiedLink = false
            }
            if editor.snapshot?.widgetEligibility.showsDeveloperWidgets == true {
                Menu {
                    Button("Copy Game ID") { MediaViewerActionService.copyText(game.id) }
                } label: {
                    Image(systemName: "ellipsis").profileGameActionLabel(isIcon: true)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .profileGameAction(.secondary)
                .help("More").accessibilityLabel("More")
            }
        }
    }

    private var addToProfileMenu: some View {
        let added = ProfileGameWidgetKind.allCases.filter { kind in widgetGames(kind).contains { $0.id == game.id } }
        return Menu {
            ForEach(ProfileGameWidgetKind.allCases, id: \.self) { kind in
                let entries = widgetGames(kind)
                let contains = added.contains(kind)
                Toggle(kind.title, isOn: Binding(get: { contains }, set: { _ in
                    Task { await editor.saveGameWidgetShortcut(gameID: game.id, kind: kind) }
                }))
                .disabled(!contains && entries.count >= kind.capacity)
            }
        } label: {
            Label(added.isEmpty ? "Add to Profile" : "On Your Profile", systemImage: added.isEmpty ? "plus" : "checkmark")
                .profileGameActionLabel()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .profileGameAction(added.isEmpty ? .prominent : .secondary)
        .disabled(editor.isSaving)
    }

    // MARK: Sections

    @ViewBuilder private var statusMessages: some View {
        if let error = editor.errorMessage {
            ProfileGameNotice(message: error, isError: true)
        }
        ForEach(errors.keys.sorted(), id: \.self) { key in
            ProfileGameNotice(message: errors[key] ?? "", isError: false) {
                Button { Task { await load() } } label: { Text("Retry").profileGameActionLabel() }
                    .buttonStyle(.plain)
                    .profileGameAction(.secondary)
                    .disabled(isLoading)
            }
        }
    }

    @ViewBuilder private var overview: some View {
        if let metadata = game.metadata {
            HStack(alignment: .top, spacing: ProfileGameMetrics.columnSpacing) {
                VStack(alignment: .leading, spacing: ProfileGameMetrics.sectionSpacing) {
                    ProfileGameGallery(game: game) { mediaPresentation = $0 }
                    if let description = metadata.description, !description.isEmpty {
                        ProfileGameSection("About") { ProfileGameDescription(text: description).id(game.id) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProfileGameDetails(metadata: metadata).frame(width: ProfileGameMetrics.sidebarWidth)
            }
            .padding(.horizontal, ProfileGameMetrics.inset)
        } else if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, InterfaceScale.metric(48))
        }
    }

    @ViewBuilder private var announcementSection: some View {
        if let channelID = announcements.channelID, let guildID = announcements.guildID, !announcements.messages.isEmpty {
            // Announcements usually come from a game's official server. Opening an
            // unjoined server's channel half-switches the workspace, so only joined
            // servers navigate.
            let opensChannel = model.snapshot?.guilds.contains { $0.id == guildID } == true
            ProfileGameSection("Announcements") {
                ProfileGameCarousel(spacing: InterfaceScale.metric(12)) {
                    ForEach(announcements.messages) { message in
                        if opensChannel {
                            Button { openAnnouncement(guildID: guildID, channelID: channelID, messageID: message.id) } label: {
                                ProfileGameAnnouncementCard(message: message)
                            }
                            .buttonStyle(.plain)
                        } else {
                            ProfileGameAnnouncementCard(message: message, isInteractive: false)
                        }
                    }
                }
            } accessory: {
                if opensChannel {
                    ProfileGameTextButton(title: "View All") { openAnnouncement(guildID: guildID, channelID: channelID, messageID: nil) }
                }
            }
            .padding(.horizontal, ProfileGameMetrics.inset)
        }
    }

    @ViewBuilder private var similarSection: some View {
        if !similar.isEmpty {
            ProfileGameSection("Similar Games") {
                ProfileGameCarousel(spacing: InterfaceScale.metric(16)) {
                    ForEach(similar) { suggestion in
                        Button { navigation.append(game); game = suggestion } label: { ProfileGameSimilarTile(game: suggestion) }
                            .buttonStyle(.plain).disabled(editor.isSaving)
                            .accessibilityLabel(suggestion.name)
                    }
                }
            }
            .padding(.horizontal, ProfileGameMetrics.inset)
        }
    }

    // MARK: Actions

    private func widgetGames(_ kind: ProfileGameWidgetKind) -> [ProfileWidgetGame] {
        for widget in editor.widgets {
            if case let .games(value, games) = widget.content, value == kind { return games }
        }
        return []
    }

    private func openLink(_ url: URL) {
        _ = MessageLinkActivator.activate(url, model: model, displayedText: url.absoluteString)
    }

    private func openAnnouncement(guildID: GuildID, channelID: ChannelID, messageID: MessageID?) {
        // Close the whole profile stack so the channel isn't left behind it.
        dismiss?()
        model.dismissExpandedProfile()
        if let messageID {
            model.navigateToSystemMessageTarget(guildID: guildID, channelID: channelID, messageID: messageID)
        } else {
            model.navigate(to: guildID, linkedChannelID: channelID)
        }
    }

    // MARK: Loading

    private func load() async {
        let session = model.accountSession()
        let id = game.id
        isLoading = true; errors = [:]; similar = []; announcements = ProfileGameAnnouncements()
        async let profile: Void = editor.loadIfNeeded(preferCached: true)
        async let details: Void = loadDetails(id: id, session: session)
        async let news: Void = loadAnnouncements(id: id, session: session)
        async let suggestions: Void = loadSimilar(id: id, session: session)
        _ = await (profile, details, news, suggestions)
        guard game.id == id, model.isCurrentAccountSession(session), !Task.isCancelled else { return }
        isLoading = false
    }

    private func loadDetails(id: String, session: AppModelAccountSession) async {
        do {
            let records = try await session.provider.profileWidgetGames(ids: [id])
            guard game.id == id, model.isCurrentAccountSession(session), !Task.isCancelled else { return }
            if let loaded = records.first(where: { $0.id == id }) { game = loaded } else { errors["details"] = String(localized: "This game profile is unavailable.", bundle: #bundle) }
        } catch { record(error, section: "details", id: id, session: session) }
    }

    private func loadAnnouncements(id: String, session: AppModelAccountSession) async {
        do {
            let value = try await session.provider.profileGameAnnouncements(gameID: id)
            guard game.id == id, model.isCurrentAccountSession(session), !Task.isCancelled else { return }
            announcements = value
        } catch { record(error, section: "announcements", id: id, session: session) }
    }

    private func loadSimilar(id: String, session: AppModelAccountSession) async {
        do {
            let value = try await session.provider.similarProfileGames(to: id)
            guard game.id == id, model.isCurrentAccountSession(session), !Task.isCancelled else { return }
            similar = value
        } catch { record(error, section: "similar", id: id, session: session) }
    }

    private func record(_ error: Error, section: String, id: String, session: AppModelAccountSession) {
        guard game.id == id, model.isCurrentAccountSession(session), !Task.isCancelled, !(error is CancellationError) else { return }
        DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
        errors[section] = error.localizedDescription
    }
}

struct ProfileGamePresentationModifier: ViewModifier {
    @Bindable var model: AppModel
    func body(content: Content) -> some View {
        content.windowModal(item: $model.presentedProfileGame) { game in
            ProfileGameView(model: model, game: game)
        }
    }
}
