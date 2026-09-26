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
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if let error = entry.error {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).textSelection(.enabled)
                            Button("Try Again") { model.refreshGuildGuide(in: guildID) }.buttonStyle(.glass)
                        }
                    }
                    if let guide = entry.configuration, guide.enabled {
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: 24) {
                                mainColumn(guide).frame(minWidth: 340, maxWidth: .infinity)
                                sideColumn(guide).frame(width: 280)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 24) {
                                mainColumn(guide)
                                sideColumn(guide)
                            }
                        }
                    } else if entry.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(32)
                    } else {
                        ContentUnavailableView("Server Guide Unavailable", systemImage: "signpost.right")
                    }
                }
                .padding(24).frame(maxWidth: 1400).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(SakuraCordAccentColor.color)
        .inspector(isPresented: Binding(get: { entry.resource != nil }, set: { if !$0 { model.onboarding.guides[guildID]?.resource = nil } })) {
            if let resource = entry.resource {
                resourcePage(resource).inspectorColumnWidth(min: 320, ideal: 420, max: 600)
            }
        }
        .task(id: "\(guildID)-\(model.currentUser?.id.description ?? "")-\(scenePhase)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if model.mainWindowIsActive, entry.resource == nil { model.refreshGuildGuide(in: guildID) }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    @ViewBuilder private func mainColumn(_ guide: GuildGuide) -> some View {
        if showsTasks {
            VStack(alignment: .leading, spacing: 20) {
                welcome(guide)
                if !guide.newMemberActions.isEmpty { tasks(guide) }
            }
        } else {
            resources(guide, compact: false)
        }
    }

    private func sideColumn(_ guide: GuildGuide) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let profile = entry.profile { serverProfile(profile) }
            if showsTasks { resources(guide, compact: true) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = guild?.guideHeaderURL {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.primary.opacity(0.04) }
                    } else {
                        Image("GuildGuidePlaceholder", bundle: .module)
                            .resizable().scaledToFill()
                    }
                }
                .frame(height: 160).clipped().clipShape(.rect(cornerRadius: 16))
                serverIcon(size: 100).padding(.leading, 16).offset(y: 48)
            }
            Text(guild?.name ?? "Server")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 40).padding(.horizontal, 16)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(guide.welcomeMessage.authorIDs, id: \.self) { id in
                    if let author = model.membersByGuildID[guildID]?[id] ?? model.membersByID[id] {
                        AsyncImage(url: author.user.avatarURL) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill") }
                            .frame(width: 40, height: 40).clipShape(Circle())
                        Text(author.user.displayName).font(.callout.weight(.semibold))
                    }
                }
            }
            Text(DiscordMarkdown.attributed(guide.welcomeMessage.message.replacingOccurrences(of: "[@username]", with: "@" + (model.currentUser?.displayName ?? "you"))))
                .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 12))
    }

    private func tasks(_ guide: GuildGuide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Get Started").font(.title3.weight(.bold)).padding(.bottom, 4)
            ForEach(guide.newMemberActions) { task in
                GuideActionRow(item: task, channelName: model.snapshot?.channels.first { $0.id == task.channelID }?.name,
                               completed: entry.progress?.isCompleted(task.channelID) == true) {
                    model.visitGuideTask(task, guildID: guildID)
                }
                .disabled(entry.completing.contains(task.channelID) || ![0, 1].contains(task.actionType ?? -1))
            }
        }
    }

    private func resources(_ guide: GuildGuide, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if !guide.resourceChannels.isEmpty {
                Text("Resources").font(compact ? .headline : .title3.weight(.bold)).padding(.bottom, 4)
                ForEach(guide.resourceChannels) { resource in
                    GuideResourceRow(item: resource, compact: compact) {
                        model.openGuideResource(resource.channelID, guildID: guildID)
                    }
                }
            }
        }
        .padding(compact ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
    }

    private func serverProfile(_ profile: GuildGuideProfile) -> some View {
        let card = NativeTimelineInviteLayout(index: 0, origin: .zero, maximumWidth: 280,
            model: nil, isOwnMessage: false, fillsWidth: true,
            preview: NativeServerCardContent(profile: profile, iconURL: guild?.iconURL, adaptiveColor: previewColor))
        return NativeInvitePreview(card: card, isModalPreview: false)
            .frame(width: card.frame.width, height: card.frame.height)
            .task(id: guild?.iconURL) {
                previewColor = nil
                guard profile.brandColorPrimary == nil, let url = guild?.iconURL else { return }
                let color = try? await ProfileAvatarPaletteLoader.shared.colors(url).first
                guard !Task.isCancelled else { return }
                previewColor = color
            }
    }

    private func resourcePage(_ resource: GuildResourceState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(entry.configuration?.resourceChannels.first { $0.channelID == resource.channelID }?.title ?? "Resource")
                    .font(.headline).lineLimit(1)
                Spacer()
                Button("Close", systemImage: "xmark") { model.onboarding.guides[guildID]?.resource = nil }
                    .labelStyle(.iconOnly).buttonStyle(.glass).help("Close resource")
            }
            .padding(20)
            Divider()
            if let error = resource.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(.horizontal, 24) }
            if resource.loading, resource.messages.isEmpty {
                ProgressView("Loading resource…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if resource.messages.isEmpty {
                ContentUnavailableView("No Resource Content", systemImage: "doc.text", description: Text("This resource channel has no messages yet."))
            } else {
                NativeMessageTimelineView(
                    model: model, conversation: .resource(guildID, resource.channelID), beginning: nil,
                    firstMessageStartsDayOverride: false, hasMoreMessages: false,
                    hasMoreLaterMessages: resource.hasMore, isLoadingEarlier: false, isLoadingLater: resource.loading,
                    laterHistoryLoadFailed: resource.error != nil, bottomContentInset: 24, unreadMessageID: nil,
                    highlightedMessageID: nil, initialScrollTarget: resource.rows.first.map { .message($0.id, anchor: .top) },
                    scrollRequest: nil, runsPerformanceAutoScroll: false, loadEarlier: {},
                    loadLater: { model.loadGuideResource(guildID: guildID) }, openReply: { _ in },
                    onScrollActivityChange: { _ in }, onScrollStateChange: { _ in }, onUserScrollBegan: {}, onUserScrollEnded: { _ in }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            HStack(spacing: 12) {
                if let url = item.iconURL {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(width: 36, height: 36).clipShape(.rect(cornerRadius: 8))
                } else if item.emoji != nil {
                    OnboardingEmoji(emoji: item.emoji)
                } else {
                    Image(systemName: "number").font(.title3).foregroundStyle(.secondary).frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline)
                    if let channelName { Text("#" + channelName).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(completed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(hovered ? 0.06 : 0)) }
            .contentShape(.rect(cornerRadius: 12))
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if compact { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                    Text(item.title).font(.headline)
                }
                if !compact {
                    if let description = item.description, !description.isEmpty {
                        Text(DiscordMarkdown.attributed(description)).font(.body).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            .padding(compact ? 8 : 20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(hovered ? 0.06 : 0)) }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}
