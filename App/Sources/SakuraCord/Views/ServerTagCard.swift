import SakuraCordModels
import SwiftUI

extension EnvironmentValues {
    /// Enables server tag cards in profile presentations hosted outside the root window hierarchy.
    @Entry var serverTagCardModel: AppModel?
}

/// A server tag that opens its server's profile card.
struct InteractiveProfileServerTag: View {
    let identity: PrimaryGuildIdentity
    @Environment(\.serverTagCardModel) private var model
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        if let model, let guildID = identity.guildID {
            Button { isPresented.toggle() } label: {
                ProfileServerTag(identity: identity, isHighlighted: isHovered || isPresented)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("View Server")
            .accessibilityLabel("Server Tag \(identity.tag ?? "")")
            .accessibilityHint("Shows the server’s profile")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ServerTagCard(model: model, guildID: guildID) { isPresented = false }
            }
        } else {
            ProfileServerTag(identity: identity)
        }
    }
}

struct ServerTagCard: View {
    private static let width: CGFloat = 300
    private static let bannerHeight: CGFloat = 120
    private static let iconSize: CGFloat = 72

    let model: AppModel
    let guildID: GuildID
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let store = model.serverTagCards
        let entry = store.entries[guildID]
        Group {
            switch entry?.content {
            case let .loaded(profile):
                content(profile, entry: entry ?? .init(), isJoining: store.joining.contains(guildID))
            case .restricted:
                restricted
            case let .failed(error):
                ContentUnavailableView {
                    Label("Server Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { model.loadServerTagCard(guildID) }
                }
                .padding(.vertical, 12)
            case nil:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .accessibilityLabel("Loading server")
            }
        }
        .frame(width: Self.width)
        .task(id: guildID) { model.loadServerTagCard(guildID) }
    }

    private func content(_ profile: GuildProfile, entry: ServerTagCardStore.Entry, isJoining: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(color: profile.brandColor ?? entry.adaptiveColor, bannerURL: profile.bannerURL,
                   iconURL: profile.iconURL, name: profile.name)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.name).font(.title3.weight(.bold)).lineLimit(2)
                        if let url = profile.badgeURL {
                            StaticRemoteImage(url: url, maximumPixelDimension: 32)
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                        }
                    }
                    counts(profile)
                    Text("Est. \(profile.id.createdAt.formatted(.dateTime.month(.abbreviated).year()))")
                        .foregroundStyle(.secondary)
                }
                if let description = profile.description, !description.isEmpty {
                    Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !entry.games.isEmpty { games(entry.games) }
                if !profile.traits.isEmpty { traits(profile) }
                if let error = entry.actionError {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let action = model.serverTagCardAction(for: profile) {
                    Button {
                        model.startAccountChildTask(account: model.accountSession()) { model, _ in
                            if await model.activateServerTagCard(guildID) { dismiss() }
                        }
                    } label: {
                        Group {
                            if isJoining { ProgressView().controlSize(.small) } else {
                                Text(action == .join ? "Join" : "Go to Server")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SakuraCordAccentColor.color)
                    .controlSize(.large)
                    .disabled(isJoining)
                    .padding(.top, 4)
                }
            }
            .padding(EdgeInsets(top: Self.iconSize / 2 + 10, leading: 16, bottom: 16, trailing: 16))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profile.name)
    }

    /// Matches the first-party card for servers that answer their profile with Missing Access.
    private var restricted: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(color: nil, bannerURL: nil, iconURL: nil, name: "?")
            VStack(alignment: .leading, spacing: 6) {
                Text("Private Server").font(.title2.weight(.semibold))
                Text("The server has limited who can see this profile.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: Self.iconSize / 2 + 10, leading: 16, bottom: 16, trailing: 16))
        }
        .accessibilityElement(children: .combine)
    }

    private func header(color: UInt32?, bannerURL: URL?, iconURL: URL?, name: String) -> some View {
        // The first-party default banner uses NEUTRAL_40 in light and NEUTRAL_92 in dark appearances.
        let color = color ?? (colorScheme == .dark ? 0x121214 : 0x70717a)
        return Canvas { context, size in
            context.withCGContext { context in
                NativeTimelineRowPainter.inviteGradient(color, in: CGRect(origin: .zero, size: size), context: context)
            }
        }
        .overlay {
            if let bannerURL {
                StaticRemoteImage(url: bannerURL, maximumPixelDimension: 1024, contentMode: .fill)
            }
        }
        .frame(height: Self.bannerHeight)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            icon(url: iconURL, name: name)
                .offset(x: 16, y: Self.iconSize / 2)
        }
        .accessibilityHidden(true)
    }

    private func icon(url: URL?, name: String) -> some View {
        Group {
            if let url {
                StaticRemoteImage(url: url, maximumPixelDimension: 256, contentMode: .fill)
            } else {
                Text(name.split(separator: " ").prefix(3).compactMap(\.first).map(String.init).joined())
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: Self.iconSize, height: Self.iconSize)
        .clipShape(.rect(cornerRadius: 20))
        .padding(4)
        .background(.background, in: .rect(cornerRadius: 24))
    }

    private func counts(_ profile: GuildProfile) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("\(profile.onlineCount.formatted()) Online")
            }
            HStack(spacing: 5) {
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text("\(profile.memberCount.formatted()) \(profile.memberCount == 1 ? "Member" : "Members")")
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func games(_ games: [ProfileGame]) -> some View {
        HStack(spacing: 8) {
            ForEach(games) { game in
                Group {
                    if let url = game.iconURL {
                        StaticRemoteImage(url: url, maximumPixelDimension: 64, contentMode: .fill)
                    } else {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(.rect(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.1)) }
                .help(game.name)
            }
            if games.count == 1, let game = games.first {
                Text(game.name).fontWeight(.semibold).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(games.map(\.name).formatted(.list(type: .and)))
    }

    private func traits(_ profile: GuildProfile) -> some View {
        ProfileRoleFlowLayout(spacing: 6, constrainsChildren: true, alignment: .center) {
            ForEach(Array(profile.traits.enumerated()), id: \.offset) { _, trait in
                HStack(spacing: 4) {
                    if let url = trait.emojiURL {
                        StaticRemoteImage(url: url, maximumPixelDimension: 32).frame(width: 16, height: 16)
                    } else if let emoji = trait.emojiName {
                        Text(NativeEmojiCatalogMetadata.value(forShortcode: emoji) ?? emoji)
                    }
                    Text(trait.label).lineLimit(1)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .overlay { Capsule().strokeBorder(.primary.opacity(0.13)) }
            }
        }
    }
}
