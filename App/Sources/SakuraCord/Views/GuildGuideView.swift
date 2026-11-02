import MessageRendering
import SakuraCordModels
import SwiftUI

struct GuildGuideView: View {
    let model: AppModel
    let guildID: GuildID
    @Environment(\.scenePhase) private var scenePhase
    @State private var previewColor: UInt32?
    private var entry: GuildGuideEntry { model.onboarding.guides[guildID] ?? .init() }
    private var guild: Guild? { model.serverRailGuildsByID[guildID] }
    private var showsTasks: Bool { model.hasPendingGuildGuideActions(in: guildID) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(28)) {
                    header
                    if let error = entry.error {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.interface(.callout)).textSelection(.enabled)
                            Button("Try Again") { model.refreshGuildGuide(in: guildID) }.buttonStyle(.glass)
                        }
                    }
                    if let guide = entry.configuration, guide.enabled {
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: InterfaceScale.metric(24)) {
                                mainColumn(guide).frame(minWidth: InterfaceScale.metric(340), maxWidth: .infinity)
                                sideColumn(guide).frame(width: InterfaceScale.metric(280))
                            }
                        } else {
                            VStack(alignment: .leading, spacing: InterfaceScale.metric(24)) {
                                mainColumn(guide)
                                sideColumn(guide)
                            }
                        }
                    } else if entry.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(InterfaceScale.metric(32))
                    } else {
                        ContentUnavailableView("Server Guide Unavailable", systemImage: "signpost.right")
                    }
                }
                .padding(InterfaceScale.metric(24)).frame(maxWidth: InterfaceScale.metric(1400)).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.always, axes: .vertical)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(SakuraCordAccentColor.color)
        .task(id: guild?.iconURL) {
            previewColor = nil
            guard let url = guild?.iconURL else { return }
            let color = try? await ProfileAvatarPaletteLoader.shared.colors(url).first
            guard !Task.isCancelled else { return }
            previewColor = color
        }
        .task(id: "\(guildID)-\(model.currentUser?.id.description ?? "")-\(scenePhase)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if model.mainWindowIsActive, model.presentedGuideResource == nil { model.refreshGuildGuide(in: guildID) }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    @ViewBuilder private func mainColumn(_ guide: GuildGuide) -> some View {
        if showsTasks {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(20)) {
                welcome(guide)
                if !guide.newMemberActions.isEmpty { tasks(guide) }
            }
        } else {
            resources(guide, compact: false)
        }
    }

    private func sideColumn(_ guide: GuildGuide) -> some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(12)) {
            if let profile = entry.profile { serverProfile(profile) }
            if showsTasks { resources(guide, compact: true) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = guild?.guideHeaderURL {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.primary.opacity(0.04) }
                    } else {
                        LinearGradient(
                            colors: ProfilePalette.banner(themeHexes: [], accentHex: bannerColor),
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .overlay {
                            RadialGradient(colors: [.white.opacity(0.18), .clear],
                                           center: .topTrailing, startRadius: 0, endRadius: 600)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: InterfaceScale.metric(160)).clipped().clipShape(.rect(cornerRadius: InterfaceScale.metric(16)))
                serverIcon(size: 100).padding(.leading, InterfaceScale.metric(16)).offset(y: InterfaceScale.metric(48))
            }
            Text(guild?.name ?? "Server")
                .font(.interfaceSystem(size: 28, weight: .bold))
                .padding(.top, InterfaceScale.metric(40)).padding(.horizontal, InterfaceScale.metric(16))
        }
    }

    private var bannerColor: UInt32? {
        entry.profile?.brandColor ?? previewColor
    }

    private func serverIcon(size: CGFloat) -> some View {
        AsyncImage(url: guild?.iconURL) { image in image.resizable().scaledToFill() } placeholder: {
            Text(String(guild?.name.prefix(1) ?? "")).font(.system(size: size * 0.4)).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.25))
        .overlay { RoundedRectangle(cornerRadius: size * 0.25).stroke(.background, lineWidth: 4) }
        .accessibilityHidden(true)
    }

    private func welcome(_ guide: GuildGuide) -> some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            HStack(spacing: InterfaceScale.metric(8)) {
                ForEach(guide.welcomeMessage.authorIDs, id: \.self) { id in
                    if let author = model.membersByGuildID[guildID]?[id] ?? model.membersByID[id] {
                        AsyncImage(url: author.user.avatarURL) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill") }
                            .frame(width: InterfaceScale.metric(40), height: InterfaceScale.metric(40)).clipShape(Circle())
                        Text(author.user.displayName).font(.interface(.callout).weight(.semibold))
                    }
                }
            }
            Text(DiscordMarkdown.attributed(guide.welcomeMessage.message.replacingOccurrences(of: "[@username]", with: "@" + (model.currentUser?.displayName ?? "you"))))
                .font(.interface(.body)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(InterfaceScale.metric(16)).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: InterfaceScale.metric(12)))
    }

    private func tasks(_ guide: GuildGuide) -> some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text("Get Started").font(.interface(.title3).weight(.bold)).padding(.bottom, InterfaceScale.metric(4))
            ForEach(guide.newMemberActions) { task in
                GuideActionRow(item: task, channelName: model.messagePresentationChannelsByID[task.channelID]?.name,
                               completed: entry.progress?.isCompleted(task.channelID) == true) {
                    model.visitGuideTask(task, guildID: guildID)
                }
                .disabled(entry.completing.contains(task.channelID) || ![0, 1].contains(task.actionType ?? -1))
            }
        }
    }

    private func resources(_ guide: GuildGuide, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? InterfaceScale.metric(8) : InterfaceScale.metric(12)) {
            if !guide.resourceChannels.isEmpty {
                Text("Resources").font(compact ? .interface(.headline) : .interface(.title3).weight(.bold)).padding(.bottom, InterfaceScale.metric(4))
                ForEach(guide.resourceChannels) { resource in
                    GuideResourceRow(item: resource, compact: compact) {
                        model.openGuideResource(resource.channelID, guildID: guildID)
                    }
                }
            }
        }
        .padding(compact ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: .rect(cornerRadius: InterfaceScale.metric(12)))
    }

    private func serverProfile(_ profile: GuildProfile) -> some View {
        let card = NativeTimelineInviteLayout(index: 0, origin: .zero, maximumWidth: 280,
            source: nil, isOwnMessage: false, fillsWidth: true,
            preview: NativeServerCardContent(profile: profile, iconURL: guild?.iconURL, adaptiveColor: previewColor))
        return NativeInvitePreview(card: card, isModalPreview: false)
            .frame(width: card.frame.width, height: card.frame.height)

    }

}

private struct GuideActionRow: View {
    let item: GuildGuideChannel
    let channelName: String?
    let completed: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(12)) {
                if let url = item.iconURL {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(width: InterfaceScale.metric(36), height: InterfaceScale.metric(36)).clipShape(.rect(cornerRadius: InterfaceScale.metric(8)))
                } else if item.emoji != nil {
                    OnboardingEmoji(emoji: item.emoji)
                } else {
                    Image(systemName: "number").font(.interface(.title3)).foregroundStyle(.secondary).frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                }
                VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                    Text(item.title).font(.interface(.headline))
                    if let channelName { Text("#" + channelName).font(.interface(.caption)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: InterfaceScale.metric(8))
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .font(.interface(.title3)).foregroundStyle(completed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            .padding(InterfaceScale.metric(16)).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: InterfaceScale.metric(12)))
            .overlay { RoundedRectangle(cornerRadius: InterfaceScale.metric(12)).fill(.primary.opacity(hovered ? 0.06 : 0)) }
            .contentShape(.rect(cornerRadius: InterfaceScale.metric(12)))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityValue(completed ? "Completed" : "Not completed")
    }
}

private struct GuideResourceRow: View {
    let item: GuildGuideChannel
    let compact: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    if compact { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                    Text(item.title).font(.interface(.headline))
                }
                if !compact {
                    if let description = item.description, !description.isEmpty {
                        Text(DiscordMarkdown.attributed(description)).font(.interface(.body)).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            .padding(compact ? 8 : 20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: InterfaceScale.metric(12)))
            .overlay { RoundedRectangle(cornerRadius: InterfaceScale.metric(12)).fill(.primary.opacity(hovered ? 0.06 : 0)) }
            .contentShape(.rect(cornerRadius: InterfaceScale.metric(12)))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}
