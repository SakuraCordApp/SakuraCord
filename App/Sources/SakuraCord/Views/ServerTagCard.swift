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
    private static var width: CGFloat { InterfaceScale.metric(300) }
    private static var bannerHeight: CGFloat { InterfaceScale.metric(120) }
    private static var iconSize: CGFloat { InterfaceScale.metric(72) }

    let model: AppModel
    let guildID: GuildID
    let dismiss: () -> Void
    private let account: AppModelAccountSession
    @Environment(\.colorScheme) private var colorScheme

    init(model: AppModel, guildID: GuildID, dismiss: @escaping () -> Void) {
        self.model = model
        self.guildID = guildID
        self.dismiss = dismiss
        account = model.accountSession()
    }

    var body: some View {
        let store = model.serverTagCards
        let entry = store.entries[guildID]
        Group {
            switch entry?.content {
            case let .loaded(profile):
                content(profile, entry: entry ?? .init(), isJoining: model.serverInvites.joining.contains(guildID))
            case .restricted:
                restricted
            case let .failed(error):
                ContentUnavailableView {
                    Label("Server Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        guard model.isCurrentAccountSession(account) else { dismiss(); return }
                        model.loadServerTagCard(guildID)
                    }
                }
                .padding(.vertical, InterfaceScale.metric(12))
            case nil:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(180))
                    .accessibilityLabel("Loading server")
            }
        }
        .frame(width: Self.width)
        .task(id: guildID) {
            guard model.isCurrentAccountSession(account) else { dismiss(); return }
            model.loadServerTagCard(guildID)
        }
    }

    private func content(_ profile: GuildProfile, entry: ServerTagCardStore.Entry, isJoining: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(color: profile.brandColor ?? entry.adaptiveColor, bannerURL: profile.bannerURL,
                   iconURL: profile.iconURL, name: profile.name)
            VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
                    HStack(spacing: InterfaceScale.metric(6)) {
                        Text(profile.name).font(.interface(.title3).weight(.bold)).lineLimit(2)
                        ServerTagStatusBadge(profile: profile)
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
                    Text(error).font(.interface(.callout)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let action = model.serverTagCardAction(for: profile) {
                    Button {
                        guard model.isCurrentAccountSession(account) else { dismiss(); return }
                        model.startAccountChildTask(account: account) { model, _ in
                            if await model.activateServerTagCard(guildID) { dismiss() }
                        }
                    } label: {
                        Group {
                            if isJoining { ProgressView().controlSize(.small) } else {
                                Text(action.title)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SakuraCordAccentColor.color)
                    .controlSize(.large)
                    .disabled(isJoining)
                    .padding(.top, InterfaceScale.metric(4))
                }
            }
            .padding(EdgeInsets(top: Self.iconSize / 2 + 10, leading: InterfaceScale.metric(16), bottom: InterfaceScale.metric(16), trailing: InterfaceScale.metric(16)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profile.name)
    }

    /// Matches the first-party card for servers that answer their profile with Missing Access.
    private var restricted: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(color: nil, bannerURL: nil, iconURL: nil, name: "?")
            VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                Text("Private Server").font(.interface(.title2).weight(.semibold))
                Text("The server has limited who can see this profile.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: Self.iconSize / 2 + 10, leading: InterfaceScale.metric(16), bottom: InterfaceScale.metric(16), trailing: InterfaceScale.metric(16)))
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
                .offset(x: InterfaceScale.metric(16), y: Self.iconSize / 2)
        }
        .accessibilityHidden(true)
    }

    private func icon(url: URL?, name: String) -> some View {
        Group {
            if let url {
                StaticRemoteImage(url: url, maximumPixelDimension: 256, contentMode: .fill)
            } else {
                Text(name.split(separator: " ").prefix(3).compactMap(\.first).map(String.init).joined())
                    .font(.interface(.title2).weight(.semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: Self.iconSize, height: Self.iconSize)
        .clipShape(.rect(cornerRadius: InterfaceScale.metric(20)))
        .padding(InterfaceScale.metric(4))
        .background(.background, in: .rect(cornerRadius: InterfaceScale.metric(24)))
    }

    private func counts(_ profile: GuildProfile) -> some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            HStack(spacing: InterfaceScale.metric(5)) {
                Circle().fill(.green).frame(width: InterfaceScale.metric(8), height: InterfaceScale.metric(8))
                Text("\(profile.onlineCount.formatted()) Online")
            }
            HStack(spacing: InterfaceScale.metric(5)) {
                Circle().fill(.secondary).frame(width: InterfaceScale.metric(8), height: InterfaceScale.metric(8))
                Text("\(profile.memberCount.formatted()) \(profile.memberCount == 1 ? "Member" : "Members")")
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func games(_ games: [ProfileGame]) -> some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            ForEach(games) { game in
                Group {
                    if let url = game.iconURL {
                        StaticRemoteImage(url: url, maximumPixelDimension: 64, contentMode: .fill)
                    } else {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
                    }
                }
                .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
                .clipShape(.rect(cornerRadius: InterfaceScale.metric(7)))
                .overlay { RoundedRectangle(cornerRadius: InterfaceScale.metric(7)).strokeBorder(.primary.opacity(0.1)) }
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
        ProfileRoleFlowLayout(spacing: InterfaceScale.metric(6), constrainsChildren: true, alignment: .center) {
            ForEach(Array(profile.traits.enumerated()), id: \.offset) { _, trait in
                HStack(spacing: InterfaceScale.metric(4)) {
                    if let url = trait.emojiURL {
                        StaticRemoteImage(url: url, maximumPixelDimension: 32).frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(16))
                    } else if let emoji = trait.emojiName {
                        Text(NativeEmojiCatalogMetadata.value(forShortcode: emoji) ?? emoji)
                    }
                    Text(trait.label).lineLimit(1)
                }
                .font(.interface(.callout))
                .padding(.horizontal, InterfaceScale.metric(8))
                .frame(height: InterfaceScale.metric(26))
                .overlay { Capsule().strokeBorder(.primary.opacity(0.13)) }
            }
        }
    }
}

/// Server status belongs beside its name; the custom clan badge belongs on the user's tag.
private struct ServerTagStatusBadge: View {
    let profile: GuildProfile

    private struct Status {
        let symbol: String
        let label: LocalizedStringKey
        let color: Color
    }

    private var status: Status? {
        let features = profile.features
        if features.contains("STAFF") {
            return Status(symbol: "wrench.and.screwdriver.fill", label: "Staff Server", color: .green)
        }
        if features.contains("VERIFIED") {
            return Status(symbol: "checkmark", label: features.contains("PARTNERED") ? "Verified and Partnered Server" : "Verified Server", color: .green)
        }
        if features.contains("PARTNERED") {
            return Status(symbol: "link", label: "Partnered Server", color: .indigo)
        }
        guard features.contains("COMMUNITY") else { return nil }
        let boosted = profile.premiumSubscriptionCount > 0 || profile.premiumTier > 0
        return features.contains("DISCOVERABLE")
            ? Status(symbol: "globe", label: boosted ? "Boosted Discoverable Server" : "Discoverable Server", color: boosted ? .pink : .secondary)
            : Status(symbol: "house.fill", label: boosted ? "Boosted Community Server" : "Community Server", color: boosted ? .pink : .secondary)
    }

    var body: some View {
        if let status {
            Image(systemName: "seal.fill")
                .font(.interfaceSystem(size: 18))
                .foregroundStyle(status.color)
                .overlay {
                    Image(systemName: status.symbol)
                        .font(.interfaceSystem(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: InterfaceScale.metric(18), height: InterfaceScale.metric(18))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(status.label))
                .help(Text(status.label))
        }
    }
}
