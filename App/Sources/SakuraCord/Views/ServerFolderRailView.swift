import SakuraCordModels
import SwiftUI

struct ServerFolderRailView: View {
    let entry: ServerRailFolderEntry
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    let expansionChanged: () -> Void

    @AppStorage private var isExpanded: Bool
    @State private var isAnimatingFolder = false
    @State private var animationGeneration = 0
    @State private var pointerLocation: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion
    private var reduceMotion: Bool { systemReducesMotion || reducesSidebarMotion }
    @Environment(ServerRailDragController.self) private var drag
    @Environment(\.displayScale) private var displayScale
    @Environment(\.windowModalInputAllowed) private var inputAllowed

    init(
        entry: ServerRailFolderEntry,
        selectGuild: @escaping (GuildID?) -> Void,
        contextMenuActions: ServerRailContextMenuActions,
        expansionChanged: @escaping () -> Void
    ) {
        self.entry = entry
        self.selectGuild = selectGuild
        self.contextMenuActions = contextMenuActions
        self.expansionChanged = expansionChanged
        _isExpanded = AppStorage(
            wrappedValue: false,
            Self.expansionKey(entry.folder.id),
            store: PRBuildProfile.defaults
        )
    }

    static func expansionKey(_ folderID: Int64) -> String {
        "GuildFolders.\(folderID).isExpanded"
    }

    var body: some View {
        VStack(spacing: isExpanded ? InterfaceScale.metric(ServerFolderRailMetrics.guildSpacing) : 0) {
            ServerFolderRailHeader(
                entry: entry,
                isExpanded: isExpanded,
                contextMenuActions: contextMenuActions,
                drawsCollapsedBackground: false,
                morphsInFolder: !reduceMotion && !renderableGuildEntries.isEmpty,
                isPointerOverHeader: pointerIsOverHeader
            ) {
                guard !drag.swallowsClick else { return }
                animationGeneration += 1
                let generation = animationGeneration
                withAnimation(reduceMotion ? nil : ServerRailAnimations.folderExpansion, completionCriteria: .logicallyComplete) {
                    isAnimatingFolder = true
                    isExpanded.toggle()
                    expansionChanged()
                } completion: {
                    if animationGeneration == generation { isAnimatingFolder = false }
                }
            }
            .modifier(ServerRailDraggableRow(id: entry.id, isExpandedFolder: isExpanded))

            ExpandedFolderGuilds(
                folderID: entry.folder.id,
                guildEntries: renderableGuildEntries,
                selectGuild: selectGuild,
                contextMenuActions: contextMenuActions,
                morphsInFolder: !reduceMotion,
                previewIDs: Set(entry.previewGuilds.map(\.id)),
                isExpanded: isExpanded
            )
            .environment(\.serverRailFolderIndicatorsInOverlay, true)
            .transformPreference(ServerRailHoverPreferenceKey.self) { hover in
                if isAnimatingFolder || !isExpanded || pointerIsOverHeader { hover = nil }
            }

        }
        .padding(.vertical, isExpanded ? InterfaceScale.metric(ServerFolderRailMetrics.expandedPadding) : 0)
        .background {
            GeometryReader { geometry in
                let verticalInset = 3 / displayScale
                let radius = InterfaceScale.metric(13 + (ServerFolderRailMetrics.containerSize - 44) / 2)
                ConcentricRectangle(cornerRadius: radius, style: .continuous)
                    .fill(folderColor.opacity(isExpanded ? 0.12 : 0.18))
                    .overlay {
                        ConcentricRectangle(cornerRadius: radius - 0.5, style: .continuous)
                            .stroke(folderColor.opacity(0.25), lineWidth: 1)
                            .padding(0.5)
                            .opacity(isExpanded ? 1 : 0)
                    }
                    .frame(
                        width: InterfaceScale.metric(ServerFolderRailMetrics.containerSize),
                        height: isExpanded ? max(0, geometry.size.height - verticalInset * 2) : InterfaceScale.metric(ServerFolderRailMetrics.containerSize)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if entry.mentionCount > 0 {
                            ServerRailMentionBadge(count: entry.mentionCount)
                                .padding(InterfaceScale.metric(2))
                                .background(.black, in: Capsule())
                                .offset(x: InterfaceScale.metric(3), y: InterfaceScale.metric(3))
                                .blendMode(.destinationOut)
                                .opacity(isExpanded ? 0 : 1)
                        }
                    }
                    .compositingGroup()
                    .offset(
                        x: (geometry.size.width - InterfaceScale.metric(ServerFolderRailMetrics.containerSize)) / 2,
                        y: isExpanded ? verticalInset : InterfaceScale.metric(1)
                    )
                    .opacity(collapsedSourceOpacity)
            }
            .allowsHitTesting(false)
        }
        .overlay { folderIndicators }
        .overlayPreferenceValue(ServerFolderIconBounds.self) { anchors in
            ZStack {
                if !reduceMotion { morphingIcons(anchors) }
                folderMentionBadges(anchors)
            }
        }
        .environment(\.serverRailMentionBadgesInOverlay, true)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): pointerLocation = inputAllowed ? location : nil
            case .ended: pointerLocation = nil
            }
        }
        .onChange(of: inputAllowed) { _, allowed in
            if !allowed { pointerLocation = nil }
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }

    }

    private var renderableGuildEntries: [ServerRailGuildEntry] {
        entry.guildEntries.filter { $0.presentation != nil }
    }

    private var folderIndicators: some View {
        let guildEntries = renderableGuildEntries
        let rowHeight = InterfaceScale.metric(ServerFolderRailMetrics.guildRowHeight)
        let rowSpacing = InterfaceScale.metric(ServerFolderRailMetrics.guildSpacing)
        // Match the layout's individually rounded dimensions at fractional interface scales.
        let firstRowTop = InterfaceScale.metric(ServerFolderRailMetrics.expandedPadding) + rowHeight + rowSpacing
        let hoverCarrierID = guildEntries.first(where: \.isSelected)?.id
            ?? guildEntries.first(where: { ($0.presentation?.guild.unreadCount ?? 0) > 0 })?.id
            ?? guildEntries.first?.id
        return GeometryReader { _ in
            ForEach(Array(guildEntries.enumerated()), id: \.element.id) { index, guildEntry in
                let rowTop = firstRowTop + CGFloat(index) * (rowHeight + rowSpacing)
                let rowBounds = CGRect(x: 0, y: rowTop, width: ChatChromeMetrics.serverRailWidth, height: rowHeight)
                let hidesIndicator = drag.draggedID == entry.id || drag.flight?.id == entry.id
                    || drag.draggedID == .guild(guildEntry.id) || drag.flight?.id == .guild(guildEntry.id)
                ServerRailSelectionIndicator(
                    isSelected: guildEntry.isSelected,
                    isHovering: isExpanded
                        ? !isAnimatingFolder && pointerLocation.map { rowBounds.contains($0) } == true
                        : guildEntry.id == hoverCarrierID && pointerIsOverHeader,
                    hasNotification: (guildEntry.presentation?.guild.unreadCount ?? 0) > 0,
                    isVisible: !hidesIndicator && (isExpanded || !reduceMotion),
                    animatesStateChanges: !isAnimatingFolder || guildEntry.id == hoverCarrierID
                )
                .modifier(ServerFolderIndicatorMotion(
                    centerY: isExpanded ? rowBounds.midY : InterfaceScale.metric(ServerFolderRailMetrics.collapsedRowHeight) / 2
                ))
                .transition(.opacity)
                .animation(reduceMotion ? nil : ServerRailAnimations.folderExpansion, value: isExpanded)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func folderMentionBadges(_ anchors: [GuildID: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            ForEach(entry.guildEntries) { guildEntry in
                if let anchor = anchors[guildEntry.id], let guild = guildEntry.presentation?.guild, guild.mentionCount > 0 {
                    let bounds = geometry[anchor]
                    let hidesBadge = drag.draggedID == entry.id || drag.flight?.id == entry.id
                        || drag.draggedID == .guild(guild.id) || drag.flight?.id == .guild(guild.id)
                    ServerRailMentionBadge(count: guild.mentionCount)
                        .fixedSize()
                        .compositingGroup()
                        .transaction { $0.animation = nil }
                        .frame(width: 0, height: 0, alignment: .bottomTrailing)
                        .scaleEffect(isExpanded ? 1 : 0.5, anchor: .bottomTrailing)
                        .opacity(isExpanded && !hidesBadge ? 1 : 0)
                        .position(x: bounds.maxX + InterfaceScale.metric(5), y: bounds.maxY + InterfaceScale.metric(5))
                }
            }
            if entry.mentionCount > 0, !isExpanded {
                let mentionedIndex = entry.guildEntries.firstIndex { ($0.presentation?.guild.mentionCount ?? 0) > 0 } ?? 0
                let badgeTravel = ServerFolderRailMetrics.firstGuildBadgeY - ServerFolderRailMetrics.collapsedBadgeY
                    + CGFloat(mentionedIndex) * ServerFolderRailMetrics.guildStride
                ServerRailMentionBadge(count: entry.mentionCount)
                    .fixedSize()
                    .compositingGroup()
                    .transaction { $0.animation = nil }
                    .frame(width: 0, height: 0, alignment: .bottomTrailing)
                    .opacity(drag.draggedID != entry.id && drag.flight?.id != entry.id ? 1 : 0)
                    .position(x: InterfaceScale.metric(ServerFolderRailMetrics.collapsedBadgeX), y: InterfaceScale.metric(ServerFolderRailMetrics.collapsedBadgeY))
                    .transition(.asymmetric(
                        insertion: .offset(y: InterfaceScale.metric(badgeTravel)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))
                    ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func morphingIcons(_ anchors: [GuildID: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            ForEach(entry.previewGuilds) { guild in
                if let anchor = anchors[guild.id] {
                    let bounds = geometry[anchor]
                    let previewScale = isExpanded ? 1 : bounds.width / InterfaceScale.metric(ServerFolderRailMetrics.previewIconSize)
                    ServerFolderMorphingIcon(
                        guild: guild,
                        size: bounds.width,
                        cornerRadius: InterfaceScale.metric(isExpanded ? 13 : 6),
                        isSelected: isExpanded && entry.guildEntries.first { $0.id == guild.id }?.isSelected == true,
                        animates: isExpanded && !isAnimatingFolder && pointerLocation.map { bounds.contains($0) } == true
                    )
                    .mask {
                        ConcentricRectangle(cornerRadius: InterfaceScale.metric(13) * previewScale, style: .continuous)
                            .frame(
                                width: isExpanded ? bounds.width : InterfaceScale.metric(44) * previewScale,
                                height: isExpanded ? bounds.height : InterfaceScale.metric(44) * previewScale
                            )
                            .position(
                                x: isExpanded ? bounds.width / 2 : InterfaceScale.metric(34) - bounds.minX,
                                y: isExpanded ? bounds.height / 2 : InterfaceScale.metric(27) - bounds.minY
                            )
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if guild.mentionCount > 0 {
                            ServerRailMentionBadge(count: guild.mentionCount)
                                .padding(InterfaceScale.metric(2))
                                .background(.black, in: Capsule())
                                .offset(x: InterfaceScale.metric(7), y: InterfaceScale.metric(7))
                                .blendMode(.destinationOut)
                                .opacity(isExpanded ? 1 : 0)
                        }
                    }
                    .compositingGroup()
                    .frame(width: bounds.width, height: bounds.height)
                    .position(x: bounds.midX, y: bounds.midY)
                    .opacity(drag.flight?.id == .guild(guild.id) ? 0 : drag.draggedID == .guild(guild.id) ? 0.3 : 1)
                    .transition(ServerRailAnimations.membershipTransition)
                }
            }

        }
        .overlay(alignment: .topLeading) {
            if entry.mentionCount > 0 {
                ServerRailMentionBadge(count: entry.mentionCount)
                    .padding(InterfaceScale.metric(2))
                    .background(.black, in: Capsule())
                    .frame(width: InterfaceScale.metric(ServerFolderRailMetrics.containerSize), height: InterfaceScale.metric(ServerFolderRailMetrics.containerSize), alignment: .bottomTrailing)
                    .offset(x: InterfaceScale.metric(11), y: InterfaceScale.metric(4))
                    .blendMode(.destinationOut)
                    .opacity(isExpanded ? 0 : 1)
            }
        }
        .compositingGroup()
        .opacity(collapsedSourceOpacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var collapsedSourceOpacity: Double {
        guard !isExpanded else { return 1 }
        if drag.flight?.id == entry.id { return 0 }
        return drag.draggedID == entry.id ? 0.3 : 1
    }

    private var folderColor: Color {
        Color(hex: entry.folder.colorHex ?? ServerFolderSettingsView.defaultColor)
    }

    private var pointerIsOverHeader: Bool {
        guard let pointerLocation else { return false }
        let top = isExpanded ? InterfaceScale.metric(ServerFolderRailMetrics.expandedPadding) : 0
        return CGRect(
            x: 0, y: top, width: ChatChromeMetrics.serverRailWidth,
            height: InterfaceScale.metric(isExpanded ? ServerFolderRailMetrics.guildRowHeight : ServerFolderRailMetrics.collapsedRowHeight)
        ).contains(pointerLocation)
    }

}

/// A folder's button. It is also drawn on its own while the folder is dragged.
struct ServerFolderRailHeader: View {
    let entry: ServerRailFolderEntry
    let isExpanded: Bool
    let contextMenuActions: ServerRailContextMenuActions
    var drawsCollapsedBackground = true
    var morphsInFolder = false
    var isPointerOverHeader: Bool?
    let toggle: () -> Void
    var loadsImageWhenOffscreen = false
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion
    private var reduceMotion: Bool { systemReducesMotion || reducesSidebarMotion }
    @State private var isHovering = false
    @State private var iconIsVisible = false
    @Environment(ServerRailDragController.self) private var drag
    @Environment(\.serverRailIsDragPreview) private var isDragPreview

    var body: some View {
        let hidesIndicator = isDragPreview || drag.draggedID == entry.id || drag.flight?.id == entry.id
        Button(action: toggle) {
            HStack(spacing: InterfaceScale.metric(4)) {
                ServerRailSelectionIndicator(
                    isSelected: !isExpanded && entry.containsSelectedGuild,
                    isHovering: isHovering && !isExpanded,
                    hasNotification: showsUnreadIndicators && entry.hasUnreadGuild
                )
                .opacity(hidesIndicator || (morphsInFolder && !reduceMotion) ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: hidesIndicator)
                ServerRailBadgedIcon(
                    mentionCount: showsUnreadIndicators ? entry.mentionCount : 0,
                    badgeOffset: isExpanded ? 4 : 1
                ) {
                    Group {
                        if isExpanded {
                            Image(systemName: "folder.fill")
                                .font(.interfaceSystem(size: 19, weight: .semibold))
                                .foregroundStyle(folderColor.opacity(0.8))
                                .frame(width: InterfaceScale.metric(44), height: InterfaceScale.metric(44))
                        } else {
                            collapsedPreview
                                .mask {
                                    ConcentricRectangle(cornerRadius: InterfaceScale.metric(13), style: .continuous)
                                        .padding(InterfaceScale.metric(4))
                                }
                        }
                    }
                    .background {
                        if !isExpanded, drawsCollapsedBackground {
                        ConcentricRectangle(cornerRadius: InterfaceScale.metric(17), style: .continuous)
                            .fill(folderColor)
                            .overlay {
                                if !isExpanded {
                                    ConcentricRectangle(cornerRadius: InterfaceScale.metric(15), style: .continuous)
                                        .stroke(folderColor, lineWidth: InterfaceScale.metric(4))
                                        .padding(InterfaceScale.metric(2))
                                }
                            }
                            .compositingGroup()
                            .opacity(0.18)
                        } else {
                            folderColor.opacity(isExpanded && isHovering ? 0.18 : 0)
                        }
                    }
                    .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(isExpanded ? 13 : 17), style: .continuous))
                    .frame(
                        width: InterfaceScale.metric(isExpanded ? 46 : ServerFolderRailMetrics.containerSize),
                        height: InterfaceScale.metric(isExpanded ? ServerFolderRailMetrics.guildRowHeight : ServerFolderRailMetrics.containerSize)
                    )
                }
                .contentShape(Rectangle())
                .frame(width: InterfaceScale.metric(ServerFolderRailMetrics.containerSize))
                .offset(x: InterfaceScale.metric(-3))
            }
            .frame(
                width: ChatChromeMetrics.serverRailWidth,
                height: InterfaceScale.metric(isExpanded ? ServerFolderRailMetrics.guildRowHeight : ServerFolderRailMetrics.collapsedRowHeight),
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ServerRailButtonStyle())
        .overlay {
            ServerFolderContextMenuBridge(
                isUnread: entry.hasUnreadGuild || entry.mentionCount > 0,
                markRead: { contextMenuActions.markFolderRead(entry.guildEntries.map(\.id)) },
                openSettings: { contextMenuActions.openFolderSettings(entry.folder) }
            )
        }
        .accessibilityLabel(displayName)
        .accessibilityValue(
            "\(isExpanded ? "Expanded" : "Collapsed")"
                + (showsUnreadIndicators && entry.mentionCount > 0
                    ? ", \(entry.mentionCount) unread mentions" : "")
                + (showsUnreadIndicators && entry.mentionCount == 0
                    && entry.hasUnreadGuild ? ", Unread" : "")
        )
        .accessibilityHint("Toggles the server folder")
        .help(displayName)
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            (isPointerOverHeader ?? isHovering) ? ServerRailHoverItem(name: displayName, bounds: bounds) : nil
        }
        .onScrollVisibilityChange(threshold: 0.01) { iconIsVisible = $0 }
        .onModalHover {
            isHovering = $0
        }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }

    private var collapsedPreview: some View {
        let preview = entry.previewGuilds
        return VStack(spacing: InterfaceScale.metric(2)) {
            HStack(spacing: InterfaceScale.metric(2)) {
                previewIcon(preview[safe: 0])
                previewIcon(preview[safe: 1])
            }
            HStack(spacing: InterfaceScale.metric(2)) {
                previewIcon(preview[safe: 2])
                previewIcon(preview[safe: 3])
            }
        }
        .frame(width: InterfaceScale.metric(ServerFolderRailMetrics.containerSize), height: InterfaceScale.metric(ServerFolderRailMetrics.containerSize))
    }

    @ViewBuilder
    private func previewIcon(_ guild: Guild?) -> some View {
        if let guild {
            GuildIconView(
                name: guild.name,
                iconURL: guild.iconURL,
                size: InterfaceScale.metric(ServerFolderRailMetrics.previewIconSize),
                cornerRadius: InterfaceScale.metric(6),
                animates: false,
                loadsImage: !morphsInFolder && (loadsImageWhenOffscreen || iconIsVisible),
                morphsInFolder: morphsInFolder && !reduceMotion,
                morphID: guild.id
            )
        } else {
            Color.clear.frame(width: InterfaceScale.metric(ServerFolderRailMetrics.previewIconSize), height: InterfaceScale.metric(ServerFolderRailMetrics.previewIconSize))
        }
    }

    private var displayName: String {
        guard let name = entry.folder.name, !name.isEmpty else { return "Server Folder" }
        return name
    }

    private var showsUnreadIndicators: Bool {
        !isExpanded
    }

    private var folderColor: Color {
        Color(hex: entry.folder.colorHex ?? ServerFolderSettingsView.defaultColor)
    }
}

private struct ExpandedFolderGuilds: View {
    let folderID: Int64
    let guildEntries: [ServerRailGuildEntry]
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    let morphsInFolder: Bool
    let previewIDs: Set<GuildID>
    let isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion
    private var reduceMotion: Bool { systemReducesMotion || reducesSidebarMotion }
    @State private var extraRowsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: isExpanded && guildEntries.count > previewIDs.count ? InterfaceScale.metric(ServerFolderRailMetrics.guildSpacing) : 0) {
            if isExpanded {
                VStack(spacing: InterfaceScale.metric(ServerFolderRailMetrics.guildSpacing)) {
                    ForEach(guildEntries.filter { previewIDs.contains($0.id) }) { entry in
                        guildRow(entry)
                    }
                }
                .transition(morphsInFolder ? .identity : .opacity)
            }
            VStack(spacing: InterfaceScale.metric(ServerFolderRailMetrics.guildSpacing)) {
                ForEach(guildEntries.filter { !previewIDs.contains($0.id) }) { entry in
                    guildRow(entry)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                withAnimation(reduceMotion ? nil : ServerRailAnimations.reorder) {
                    extraRowsHeight = height
                }
            }
            .frame(height: isExpanded ? extraRowsHeight : 0, alignment: .bottom)
            .opacity(isExpanded ? 1 : 0)
            .mask {
                GeometryReader { geometry in
                    let fadeHeight = InterfaceScale.metric(16)
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: fadeHeight)
                        Rectangle().fill(.black)
                    }
                    .frame(height: geometry.size.height + fadeHeight)
                    .offset(y: isExpanded ? -fadeHeight : 0)
                }
            }
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
        .transformPreference(ServerRailRowsPreferenceKey.self) { rows in
            // Collapsed rows retain layout for the morph, but are not drop targets.
            if !isExpanded { rows.removeAll() }
        }
    }

    private func guildRow(_ entry: ServerRailGuildEntry) -> some View {
        ServerRailGuildItemView(
            entry: entry,
            selectGuild: selectGuild,
            contextMenuActions: contextMenuActions,
            morphsInFolder: previewIDs.contains(entry.id) && morphsInFolder
        )
        .modifier(ServerRailDraggableRow(id: .guild(entry.id), folderID: folderID))
        .geometryGroup()
        .transition(ServerRailAnimations.membershipTransition)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Owns loading for the visible image, independently of its hidden layout slot.
private struct ServerFolderMorphingIcon: View {
    let guild: Guild
    let size: CGFloat
    let cornerRadius: CGFloat
    let isSelected: Bool
    let animates: Bool
    @State private var isVisible = false

    var body: some View {
        // Keep glyph layout stable and scale the letters with the icon’s background.
        let referenceSize = InterfaceScale.metric(44)
        GuildIconView(
            name: guild.name,
            iconURL: guild.iconURL,
            size: referenceSize,
            cornerRadius: cornerRadius * referenceSize / max(size, 1),
            animates: animates && isVisible,
            isSelected: isSelected,
            loadsImage: isVisible,
            maximumPixelDimension: Int((InterfaceScale.metric(46) * 2).rounded(.up))
        )
        .scaleEffect(size / referenceSize)
        .frame(width: size, height: size)
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
    }
}

nonisolated private struct ServerFolderIndicatorMotion: GeometryEffect {
    var centerY: CGFloat

    var animatableData: CGFloat {
        get { centerY }
        set { centerY = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: centerY - size.height / 2))
    }
}

private enum ServerFolderRailMetrics {
    static let containerSize: CGFloat = 52
    static let previewIconSize: CGFloat = 21
    static let guildSpacing: CGFloat = 8
    static let guildRowHeight: CGFloat = 46
    static let collapsedRowHeight: CGFloat = 54
    static let expandedPadding: CGFloat = 5
    static let firstGuildTop: CGFloat = expandedPadding + guildRowHeight + guildSpacing
    static let guildStride: CGFloat = guildRowHeight + guildSpacing
    static let firstGuildBadgeY: CGFloat = firstGuildTop + guildRowHeight + 4
    static let collapsedBadgeX: CGFloat = 61
    static let collapsedBadgeY: CGFloat = 54
}

/// Hides the layout slot while the folder overlay draws its persistent icon.
struct ServerFolderIconMorph: ViewModifier {
    let isEnabled: Bool
    let guildID: GuildID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled, let guildID {
            content
                .opacity(0)
                .anchorPreference(key: ServerFolderIconBounds.self, value: .bounds) { [guildID: $0] }
        } else {
            content
        }
    }
}

struct ServerFolderIconBounds: PreferenceKey {
    static var defaultValue: [GuildID: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [GuildID: Anchor<CGRect>], nextValue: () -> [GuildID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
