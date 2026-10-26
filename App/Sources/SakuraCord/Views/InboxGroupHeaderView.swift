import AppKit
import SakuraCordModels
import SwiftUI

nonisolated struct InboxGroupHeaderPresentation: Equatable {
    let channelID: ChannelID
    let title: String
    let subtitle: String?
    let guildName: String?
    let guildIconURL: URL?
    let systemImage: String
    let mentionCount: Int
    let isCollapsed: Bool
    let isLoading: Bool
    let isAgeRestricted: Bool

    @MainActor
    init(_ group: InboxUnreadGroup, model: AppModel) {
        let channel = model.messagePresentationChannelsByID[group.channelID]
        let thread = model.inbox.threads[group.channelID]
            ?? model.activeJoinedThreads.first { $0.id == group.channelID }
        let parent = thread.flatMap { thread in
            thread.parentID.flatMap { model.messagePresentationChannelsByID[$0] }
        }
        let guild = group.guildID.flatMap { model.serverRailGuildsByID[$0] }
        guildName = guild?.name ?? group.subtitle
        guildIconURL = guild?.iconURL
        systemImage = group.isEvents ? "calendar" : parent?.kind == .forum ? "bubble.left.and.bubble.right"
            : thread != nil ? SakuraCordSystemSymbol.thread
            : ChannelIconPresentation.systemImage(for: channel?.kind ?? .text, isHidden: false)
        channelID = group.channelID
        title = group.title
        subtitle = [guildName, thread != nil ? parent?.name : channel?.category]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › ")
        mentionCount = group.mentionCount
        isCollapsed = group.isCollapsed
        isLoading = !group.isCollapsed && (!group.isLoaded || group.needsRevalidation)
        isAgeRestricted = group.isAgeRestricted
    }
}

struct InboxGroupHeaderView: View {
    let header: InboxGroupHeaderPresentation
    let model: AppModel
    let onToggle: (ChannelID) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            Button { model.openInboxGroup(header.channelID) } label: {
                HStack(spacing: InterfaceScale.metric(10)) {
                    if let guildName = header.guildName {
                        GuildIconView(name: guildName, iconURL: header.guildIconURL,
                                      size: 32, cornerRadius: InterfaceScale.metric(9), animates: false)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                        HStack(spacing: InterfaceScale.metric(5)) {
                            SakuraCordSystemSymbol.swiftUIImage(named: header.systemImage)
                                .font(.interface(.subheadline)).foregroundStyle(.secondary)
                            Text(header.title).font(.interface(.headline)).lineLimit(1)
                        }
                        if let subtitle = header.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.interface(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if header.mentionCount > 0 {
                        Text(header.mentionCount, format: .number)
                            .font(.interface(.caption2).bold())
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, InterfaceScale.metric(6))
                            .padding(.vertical, InterfaceScale.metric(2))
                            .background(Color(hex: 0xF23F43), in: Capsule())
                            .accessibilityLabel(header.mentionCount == 1 ? "1 mention" : "\(header.mentionCount) mentions")
                    }
                }
                .padding(.leading, InterfaceScale.metric(6))
                .padding(.trailing, InterfaceScale.metric(8))
                .padding(.vertical, InterfaceScale.metric(6))
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .help("Open conversation")
            HoverActionButton(systemImage: "envelope.open", help: "Mark as Read") {
                model.markInboxGroupRead(header.channelID)
            }
            .opacity(isHovered ? 1 : 0.55)
            Button { onToggle(header.channelID) } label: {
                HoverActionControlLabel {
                    ZStack {
                        if header.isAgeRestricted {
                            Image(systemName: "lock.fill")
                        } else if header.isLoading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(header.isCollapsed ? 0 : 90))
                        }
                    }
                    .font(.interface(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(header.isAgeRestricted ? "Unlock \(header.title)" : header.isCollapsed ? "Expand \(header.title)" : "Collapse \(header.title)")
            .accessibilityLabel(header.isAgeRestricted ? "Unlock \(header.title)" : header.isCollapsed ? "Expand \(header.title)" : "Collapse \(header.title)")
        }
        .animation(.snappy(duration: 0.28), value: header.isCollapsed)
        .animation(.easeOut(duration: 0.15), value: header.isLoading)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onModalHover { isHovered = $0 }
        .contextMenu {
            Button("View All Unread") { model.openInboxGroup(header.channelID) }
            Button(header.isCollapsed ? "Expand" : "Collapse") { onToggle(header.channelID) }
            if let group = model.inbox.groups.first(where: { $0.id == header.channelID }), let guildID = group.guildID {
                Button("Mark Server as Read") { model.markInboxGuildRead(guildID) }
            }
            if let channel = model.messagePresentationChannelsByID[header.channelID] {
                Menu("Notifications") {
                    ForEach([MessageNotificationLevel.inherit, .allMessages, .onlyMentions, .nothing], id: \.self) { level in
                        Button(level.menuTitle) { model.setChannelNotificationLevel(level, for: channel) }
                    }
                }
                .disabled(model.isChannelNotificationMutationPending(channel.id))
            }
        }
        .padding(.horizontal, InterfaceScale.metric(8))
        .frame(height: InboxRowMetrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator.opacity(header.isCollapsed ? 0.6 : 0)).frame(height: 1).padding(.horizontal, InterfaceScale.metric(14))
        }
    }
}

extension NativeTimelineCanvasView {
    // Only supplementary headers intersecting the viewport own native controls.
    // All message content remains in the existing virtualized drawing canvas.
    func reconcileInboxHeaders() {
        reconcileInboxForumPosts()
        reconcileInboxEventViews()
        var desired: [ChannelID: (InboxGroupHeaderPresentation, CGRect)] = [:]
        forEachDisplayedRow(in: visibleRect) { index in
            if case let .inboxGroup(header) = items[index] {
                desired[header.channelID] = (header, CGRect(x: 0, y: displayedRowOrigin(at: index), width: bounds.width, height: InboxRowMetrics.headerHeight))
            }
        }
        for id in Array(inboxHeaderHosts.keys) where desired[id] == nil {
            inboxHeaderHosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        guard let model else { return }
        for (id, value) in desired {
            let view = InboxGroupHeaderView(header: value.0, model: model) { [weak self] id in
                self?.toggleInboxGroup(id)
            }
            let host: NSHostingView<InboxGroupHeaderView>
            if let existing = inboxHeaderHosts[id] {
                host = existing
                if host.rootView.header != value.0 { host.rootView = view }
            } else {
                host = NSHostingView(rootView: view)
                inboxHeaderHosts[id] = host
                addSubview(host)
            }
            host.frame = value.1
        }
    }
}

/// Inbox row heights shared by the SwiftUI rows, their native hosts and the
/// timeline layout.
nonisolated enum InboxRowMetrics {
    static var headerHeight: CGFloat { InterfaceScale.metric(58) }
    static var forumPostHeight: CGFloat { InterfaceScale.metric(88) }
    static var scheduledEventHeight: CGFloat { InterfaceScale.metric(104) }
}
