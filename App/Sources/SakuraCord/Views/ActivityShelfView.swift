import SakuraCordModels
import SwiftUI

/// The Activity shelf: Discord's order and details in SakuraCord's picker
/// chrome. Choosing an Activity opens its details; Launch starts it here.
struct ActivityShelfView: View {
    let model: AppModel
    let channel: Channel
    let dismiss: () -> Void
    @State private var query = ""
    @State private var searchIsFocused = false
    @State private var selection: EmbeddedActivityApplication?

    var body: some View {
        ZStack {
            if let selection {
                ActivityShelfDetail(
                    application: selection,
                    players: model.embeddedActivities.instances(in: channel.id)
                        .first { $0.applicationID == selection.id }?.participants.count,
                    back: { self.selection = nil },
                    launch: { launch(selection) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                browser
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: selection?.id)
        .frame(width: InterfaceScale.metric(520), height: InterfaceScale.metric(600))
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
            } else if store.shelfError != nil {
                VStack(spacing: InterfaceScale.metric(8)) {
                    Text("Couldn’t load Activities.")
                    Button("Retry") { Task { await model.loadActivityShelf(guildID: channel.guildID) } }
                        .buttonStyle(.link)
                }
                .help(store.shelfError ?? "")
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
            let recents = Self.recents(shelf)
            if !recents.isEmpty {
                EmojiPickerHeader(title: "Recents", count: recents.count)
                HStack(spacing: InterfaceScale.metric(10)) {
                    ForEach(recents) { application in
                        Button { selection = application } label: {
                            ActivityIcon(url: application.iconURL, size: 44)
                        }
                        .buttonStyle(ActivityShelfPressStyle())
                        .help(application.name)
                        .accessibilityLabel(application.name)
                    }
                }
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.bottom, InterfaceScale.metric(16))
            }
            grid(title: "Activities", shelf)
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
                grid(title: "Search Results", matches)
            }
        }
    }

    private func grid(title: String, _ applications: [EmbeddedActivityApplication]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            EmojiPickerHeader(title: title, count: applications.count)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: InterfaceScale.metric(12)), count: 2),
                spacing: InterfaceScale.metric(12)
            ) {
                ForEach(applications) { application in
                    ActivityShelfTile(application: application) { selection = application }
                }
            }
            .padding(.horizontal, InterfaceScale.metric(14))
        }
    }

    private static func recents(_ shelf: [EmbeddedActivityApplication]) -> [EmbeddedActivityApplication] {
        shelf.filter { $0.recentRank != nil }.sorted { ($0.recentRank ?? 0) < ($1.recentRank ?? 0) }
    }

    private func launch(_ application: EmbeddedActivityApplication) {
        dismiss()
        Task { await model.startActivity(application, in: channel) }
    }
}

private struct ActivityShelfTile: View {
    let application: EmbeddedActivityApplication
    let action: () -> Void

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
            .background(Color.primary.opacity(0.05))
            .clipShape(ActivityShelfTile.shape)
            .contentShape(ActivityShelfTile.shape)
        }
        .buttonStyle(ActivityShelfPressStyle())
        .help(application.description)
        .accessibilityLabel(application.isPromoted ? "\(application.name), promoted" : application.name)
    }

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: InterfaceScale.metric(12), style: .continuous)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(12)) {
                    ActivityCover(url: application.coverURL)
                        .clipShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))
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
                        Text(application.description)
                            .font(.interface(.body))
                            .lineLimit(expandsDescription ? nil : 3)
                            .textSelection(.enabled)
                        Button(expandsDescription ? "Show Less" : "Show More") {
                            withAnimation(.smooth(duration: 0.25)) { expandsDescription.toggle() }
                        }
                        .buttonStyle(.link)
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
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button("Back", systemImage: "chevron.left", action: back)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                }
                .padding(InterfaceScale.metric(10))
            }
            Button(action: launch) {
                Text(players == nil ? "Launch" : "Join")
                    .font(.interface(.body).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, InterfaceScale.metric(4))
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(InterfaceScale.metric(14))
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

/// Scales a shelf control down slightly while pressed.
private struct ActivityShelfPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}
