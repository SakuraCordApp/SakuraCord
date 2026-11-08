import SakuraCordModels
import SwiftUI

/// The Activity shelf: Discord's order and details in SakuraCord's picker
/// chrome. Choosing an Activity opens its details; Launch starts it here.
struct ActivityShelfView: View {
    let model: AppModel
    let channel: Channel
    /// Opened from a call's controls rather than the composer, which Discord's launch reports.
    let isFromCall: Bool
    let dismiss: () -> Void
    @State private var query = ""
    @State private var searchIsFocused = false
    @State private var selection: EmbeddedActivityApplication?
    /// The section the selection was chosen from, as Discord's launch reports it.
    @State private var selectionSection = "activities"
    /// The Activity under the pointer, whose details are prepared off-screen.
    @State private var warmed: EmbeddedActivityApplication?
    @State private var showsAllRecents = false

    var body: some View {
        let width = InterfaceScale.metric(520)
        ZStack {
            // The browser stays mounted under the details so going back
            // doesn't rebuild its grid mid-animation.
            browser
                .offset(x: selection == nil ? 0 : -width / 4)
                .opacity(selection == nil ? 1 : 0)
                .allowsHitTesting(selection == nil)
                .accessibilityHidden(selection != nil)
            if let selection {
                detail(selection)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                if let warmed {
                    // Decodes the hovered Activity's cover and lays out its
                    // details before the click, so the push moves on its first frame.
                    detail(warmed)
                        .hidden()
                        // Its Return and Escape shortcuts belong to the real details.
                        .disabled(true)
                        .accessibilityHidden(true)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: selection?.id)
        .frame(width: width, height: InterfaceScale.metric(600))
        .clipped()
        .task(id: channel.guildID) { await model.loadActivityShelf(guildID: channel.guildID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activities")
    }

    private var browser: some View {
        VStack(spacing: 0) {
            EmojiPickerSearchField(text: $query, isFocused: $searchIsFocused, placeholder: "Search Activities")
            Divider()
            let store = model.embeddedActivities
            if let shelf = store.shelves[channel.guildID] {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        sections(shelf)
                    }
                    .padding(.vertical, InterfaceScale.metric(12))
                }
                .scrollIndicators(.never)
            } else if let error = store.shelfErrors[channel.guildID] {
                VStack(spacing: InterfaceScale.metric(8)) {
                    Text("Couldn’t load Activities.")
                    Button("Retry") { Task { await model.loadActivityShelf(guildID: channel.guildID) } }
                        .buttonStyle(.link)
                }
                .help(error)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: InterfaceScale.metric(8)) {
                    ProgressView().controlSize(.small)
                    Text("Loading Activities…")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func sections(_ shelf: [EmbeddedActivityApplication]) -> some View {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            let recents = Self.recents(shelf, installed: model.embeddedActivities.installedActivities[channel.guildID] ?? [])
            if !recents.isEmpty {
                recentsHeader(count: recents.count)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(InterfaceScale.metric(44)), spacing: InterfaceScale.metric(10)), count: 8),
                    alignment: .leading, spacing: InterfaceScale.metric(10)
                ) {
                    ForEach(showsAllRecents ? recents : Array(recents.prefix(8))) { application in
                        Button {
                            select(application, section: "recent_apps")
                        } label: {
                            ActivityIcon(url: application.iconURL, size: 44)
                        }
                        .buttonStyle(ActivityShelfPressStyle())
                        .onModalHover { if $0 { warmed = application } }
                        .help(application.name)
                        .accessibilityLabel(application.name)
                    }
                }
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.bottom, InterfaceScale.metric(16))
            }
            grid(title: "Activities", section: "activities", shelf)
        } else {
            let matches = shelf.filter {
                $0.name.localizedStandardContains(query) || $0.tags.contains { $0.localizedStandardContains(query) }
            }
            if matches.isEmpty {
                Text("No Activities found.")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(120))
            } else {
                grid(title: "Search Results", section: "search", matches)
            }
        }
    }

    private func grid(title: String, section: String, _ applications: [EmbeddedActivityApplication]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            EmojiPickerHeader(title: title, count: applications.count)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: InterfaceScale.metric(12)), count: 2),
                spacing: InterfaceScale.metric(12)
            ) {
                ForEach(applications) { application in
                    ActivityShelfTile(
                        application: application, hover: { warmed = application },
                        action: { select(application, section: section) }
                    )
                }
            }
            .padding(.horizontal, InterfaceScale.metric(14))
        }
    }

    private func detail(_ application: EmbeddedActivityApplication) -> some View {
        ActivityShelfDetail(
            application: application,
            players: model.embeddedActivities.instances(in: channel.id)
                .first { $0.applicationID == application.id }?.participants.count,
            back: { selection = nil },
            launch: { launch(application) }
        )
    }

    /// Discord's Recents header: eight Activities, then View More.
    private func recentsHeader(count: Int) -> some View {
        HStack {
            Text("Recents").font(.interface(.headline))
            Spacer()
            if count > 8 {
                Button(showsAllRecents ? "View Less" : "View More") {
                    withAnimation(.smooth(duration: 0.25)) { showsAllRecents.toggle() }
                }
                .buttonStyle(.link)
                .font(.interface(.caption))
            } else {
                Text(count, format: .number).font(.interface(.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.bottom, InterfaceScale.metric(8))
    }

    private static func recents(
        _ shelf: [EmbeddedActivityApplication], installed: Set<ApplicationID>
    ) -> [EmbeddedActivityApplication] {
        shelf.filter { installed.contains($0.id) }.sorted { ($0.recentRank ?? 0) < ($1.recentRank ?? 0) }
    }

    private func select(_ application: EmbeddedActivityApplication, section: String) {
        selection = application
        selectionSection = section
    }

    private func launch(_ application: EmbeddedActivityApplication) {
        dismiss()
        Task {
            await model.startActivity(
                application, in: channel, launcher: .init(isFromCall: isFromCall, section: selectionSection)
            )
        }
    }
}

private struct ActivityShelfTile: View {
    let application: EmbeddedActivityApplication
    let hover: () -> Void
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ActivityCover(url: application.coverURL)
                    .overlay(alignment: .topTrailing) {
                        if application.isPromoted {
                            Text("Promoted")
                                .font(.interface(.caption2).weight(.semibold))
                                .padding(.horizontal, InterfaceScale.metric(7))
                                .padding(.vertical, InterfaceScale.metric(3))
                                .glassEffect(.regular, in: Capsule())
                                .padding(InterfaceScale.metric(7))
                        }
                    }
                HStack(spacing: InterfaceScale.metric(9)) {
                    ActivityIcon(url: application.iconURL, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(application.name)
                            .font(.interface(.callout).weight(.semibold))
                            .lineLimit(1)
                        Text(application.description)
                            .font(.interface(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(InterfaceScale.metric(9))
            }
            .background(PickerTileStyle.surface(colorScheme, isHovering: isHovering))
            .clipShape(ActivityShelfTile.shape)
            .overlay { ActivityShelfTile.shape.stroke(PickerTileStyle.outline(colorScheme, isHovering: isHovering), lineWidth: 0.5) }
            .contentShape(ActivityShelfTile.shape)
        }
        .onModalHover { hovering in
            isHovering = hovering
            if hovering { hover() }
        }
        .buttonStyle(ActivityShelfPressStyle())
        .help(application.description)
        .accessibilityLabel(application.isPromoted ? "\(application.name), promoted" : application.name)
    }

    static var shape: ConcentricRectangle {
        ConcentricRectangle(cornerRadius: InterfaceScale.metric(12), style: .continuous)
    }
}

/// One Activity's details, as the official shelf shows them before launch.
private struct ActivityShelfDetail: View {
    let application: EmbeddedActivityApplication
    /// People in this Activity in the channel, when it is running there.
    let players: Int?
    let back: () -> Void
    let launch: () -> Void
    @State private var expandsDescription = false
    @State private var descriptionHeights = (limited: CGFloat.zero, full: CGFloat.zero)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(12)) {
                    ActivityCover(url: application.coverURL)
                        .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(InterfaceScale.metric(12)))))
                        .overlay(alignment: .topLeading) {
                            Button(action: back) {
                                Image(systemName: "chevron.left")
                                    .font(.interface(.callout).weight(.semibold))
                                    .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .keyboardShortcut(.cancelAction)
                            .help("Back")
                            .accessibilityLabel("Back")
                            .padding(InterfaceScale.metric(10))
                        }
                        .overlay(alignment: .bottomLeading) {
                            ActivityIcon(url: application.iconURL, size: 56)
                                .padding(InterfaceScale.metric(3))
                                .background(.background, in: RoundedRectangle(
                                    cornerRadius: InterfaceScale.metric(17), style: .continuous
                                ))
                                .offset(x: InterfaceScale.metric(14), y: InterfaceScale.metric(28))
                        }
                        .padding(.bottom, InterfaceScale.metric(24))
                    Text(application.name)
                        .font(.interface(.title2).weight(.bold))
                    facts
                    if !application.description.isEmpty {
                        description
                    }
                    if application.hasInAppPurchases {
                        Label("In-App Purchases", systemImage: "bag")
                            .font(.interface(.callout))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(InterfaceScale.metric(14))
            }
            .scrollIndicators(.never)
            ModalGlassButton(
                symbol: "play.fill", label: players == nil ? "Launch" : "Join", primary: true, fillsWidth: true, action: launch
            )
            .keyboardShortcut(.defaultAction)
            .padding(InterfaceScale.metric(14))
        }
    }

    /// Three lines, with Show More only when the description runs longer.
    private var description: some View {
        let text = Text(application.description).font(.interface(.body))
        return VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            text
                .lineLimit(expandsDescription ? nil : 3)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { descriptionHeights.limited = $0 }
                .background {
                    text.fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { descriptionHeights.full = $0 }
                }
            if expandsDescription || descriptionHeights.full > descriptionHeights.limited + 1 {
                Button(expandsDescription ? "Show Less" : "Show More") {
                    withAnimation(.smooth(duration: 0.25)) { expandsDescription.toggle() }
                }
                .buttonStyle(.link)
            }
        }
    }

    private var facts: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            Label(participantsLabel, systemImage: "person.2.fill")
                .accessibilityLabel(application.maximumParticipants.map { "Up to \($0) participants" } ?? "Unlimited participants")
            if let players {
                Label("\(players) playing", systemImage: "gamecontroller.fill")
                    .foregroundStyle(.green)
            }
            if application.requiresAgeGate {
                Text("18+")
                    .padding(.horizontal, InterfaceScale.metric(6))
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(.secondary.opacity(0.6)))
            }
            ForEach(application.tags.prefix(4), id: \.self) { tag in
                Text(tag)
            }
        }
        .font(.interface(.callout).weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var participantsLabel: String {
        application.maximumParticipants.map { "1–\($0)" } ?? "Unlimited"
    }
}

/// An Activity's 16:9 shelf art, or a neutral placeholder while it loads.
private struct ActivityCover: View {
    let url: URL?

    var body: some View {
        Color.primary.opacity(0.06)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let url { StaticRemoteImage(url: url, maximumPixelDimension: 640, contentMode: .fill) }
            }
            .clipped()
    }
}

/// Presses a shelf control down like the soundboard's buttons.
private struct ActivityShelfPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// The soundboard and Activity shelf tiles' surface and hover outline.
enum PickerTileStyle {
    static func surface(_ scheme: ColorScheme, isHovering: Bool) -> Color {
        scheme == .dark
            ? Color(hex: isHovering ? 0x28292C : 0x202023)
            : Color(hex: isHovering ? 0xD8D7DC : 0xE2E1E6)
    }

    static func outline(_ scheme: ColorScheme, isHovering: Bool) -> Color {
        guard isHovering else { return .clear }
        return Color(hex: scheme == .dark ? 0x44454A : 0xAFAEB4)
    }
}
