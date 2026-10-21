import AppKit
import SwiftUI

nonisolated enum SessionLoadingSkeletonLayout {
    enum ChannelPlaceholder: Hashable, Sendable {
        case category(Int)
        case channel(section: Int, row: Int)

        var height: CGFloat {
            switch self {
            case .category: 28
            case .channel: 32
            }
        }
    }

    static let serverCount = 11
    static let channelSectionCounts = [3, 4, 4, 4]

    static func channelPlaceholdersFitting(height: CGFloat) -> [ChannelPlaceholder] {
        let availableHeight = max(0, height - ChatChromeMetrics.channelListTopPadding)
        var result: [ChannelPlaceholder] = []
        var usedHeight: CGFloat = 0

        for (section, rowCount) in channelSectionCounts.enumerated() {
            if section > 0 {
                let category = ChannelPlaceholder.category(section)
                let firstChannelHeight = ChannelPlaceholder
                    .channel(section: section, row: 0)
                    .height
                guard usedHeight + category.height + firstChannelHeight <= availableHeight
                else { break }
                result.append(category)
                usedHeight += category.height
            }

            for row in 0 ..< rowCount {
                let channel = ChannelPlaceholder.channel(section: section, row: row)
                guard usedHeight + channel.height <= availableHeight else {
                    return result
                }
                result.append(channel)
                usedHeight += channel.height
            }
        }
        return result
    }
}

struct ChannelListLoadingSkeleton: View {
    var body: some View {
        GeometryReader { geometry in
            let placeholders = SessionLoadingSkeletonLayout
                .channelPlaceholdersFitting(height: geometry.size.height)

            VStack(spacing: 0) {
                ForEach(placeholders, id: \.self) { placeholder in
                    switch placeholder {
                    case .category:
                        categoryRow
                            .frame(height: placeholder.height)
                    case .channel:
                        channelRow
                            .frame(height: placeholder.height)
                    }
                }
            }
            .padding(.top, ChatChromeMetrics.channelListTopPadding)
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .clipped()
        }
        .accessibilityHidden(true)
    }

    private var categoryRow: some View {
        HStack(spacing: InterfaceScale.metric(5)) {
            Image(systemName: "chevron.down")
                .font(.interface(.caption2).weight(.semibold))
                .foregroundStyle(.primary.opacity(0.12))
                .frame(width: InterfaceScale.metric(8))
            SkeletonShape(cornerRadius: InterfaceScale.metric(4))
                .frame(width: InterfaceScale.metric(86), height: InterfaceScale.metric(9))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InterfaceScale.metric(14))
    }

    private var channelRow: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Color.clear
                .frame(width: InterfaceScale.metric(8), height: InterfaceScale.metric(8))
            SkeletonShape(cornerRadius: InterfaceScale.metric(4))
                .frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(16))
            SkeletonShape(cornerRadius: InterfaceScale.metric(5.5))
                .frame(width: InterfaceScale.metric(112), height: InterfaceScale.metric(11))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InterfaceScale.metric(14))
    }
}

/// A data-free representation of the complete chat chrome. Startup owns a
/// standalone navigation container; account switching overlays these same
/// placeholders inside the already-mounted workspace navigation container.
struct SakuraCordSessionLoadingView: View {
    let state: AppModel.SessionState
    let isOfflineTesting: Bool
    var isAccountSwitch = false
    var isEmbeddedInWorkspace = false
    var embeddedSidebarWidth = ChatChromeMetrics.serverRailWidth + 230

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        SkeletonShimmerTimeline {
            if isEmbeddedInWorkspace {
                embeddedChrome
            } else {
                sessionChrome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening SakuraCord. \(detail)")
    }

    private var sessionChrome: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HStack(spacing: 0) {
                serverRail
                channelSidebar
            }
            .navigationSplitViewColumnWidth(
                min: ChatChromeMetrics.serverRailWidth + 190,
                ideal: ChatChromeMetrics.serverRailWidth + 230,
                max: ChatChromeMetrics.serverRailWidth + 310
            )
        } detail: {
            workspace
                .navigationTitle("")
                .toolbar { detailToolbar }
        }
        .toolbar {
            if !isAccountSwitch {
                conversationToolbar
            }
        }
        .overlay(alignment: .topLeading) {
            SkeletonShape(cornerRadius: InterfaceScale.metric(4))
                .frame(width: InterfaceScale.metric(132), height: InterfaceScale.metric(14))
                .offset(
                    x: ChatChromeMetrics.sidebarTitleLeadingOffset,
                    y: ChatChromeMetrics.sidebarTitleTopOffset(height: InterfaceScale.metric(14))
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private var embeddedChrome: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                serverRail
                channelSidebar
            }
            .frame(width: embeddedSidebarWidth)
            workspace
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serverRail: some View {
        ScrollView {
            VStack(spacing: InterfaceScale.metric(10)) {
                railItem(cornerRadius: InterfaceScale.metric(14))
                Divider().padding(.horizontal, InterfaceScale.metric(12))
                ForEach(0 ..< SessionLoadingSkeletonLayout.serverCount, id: \.self) { _ in
                    railItem(cornerRadius: InterfaceScale.metric(14))
                }
            }
            .padding(
                .top,
                isAccountSwitch && !isEmbeddedInWorkspace
                    ? ChatChromeMetrics.controlHeight
                    : 0
            )
            .padding(.bottom, InterfaceScale.metric(12))
        }
        .scrollIndicators(.hidden)
        .frame(width: ChatChromeMetrics.serverRailWidth)
    }

    private func railItem(cornerRadius: CGFloat) -> some View {
        HStack(spacing: InterfaceScale.metric(5)) {
            Color.clear.frame(width: InterfaceScale.metric(7), height: InterfaceScale.metric(40))
            SkeletonShape(cornerRadius: cornerRadius)
                .frame(width: InterfaceScale.metric(44), height: InterfaceScale.metric(44))
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .leading)
    }

    private var channelSidebar: some View {
        let appearance = AppearanceSettingsStore.shared.load().composerBarAppearance

        return VStack(spacing: 0) {
            ChannelListLoadingSkeleton()

            GlassEffectContainer(spacing: SidebarAccountControlMetrics.surfaceSpacing) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    SkeletonShape(Circle())
                        .frame(
                            width: SidebarAccountControlMetrics.avatarSize,
                            height: SidebarAccountControlMetrics.avatarSize
                        )
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
                        SkeletonShape(cornerRadius: InterfaceScale.metric(4))
                            .frame(width: InterfaceScale.metric(82), height: InterfaceScale.metric(10))
                        SkeletonShape(cornerRadius: InterfaceScale.metric(3))
                            .frame(width: InterfaceScale.metric(52), height: InterfaceScale.metric(7))
                    }
                    Spacer(minLength: 0)
                    SkeletonShape(Circle())
                        .frame(
                            width: SidebarAccountControlMetrics.settingsDiameter,
                            height: SidebarAccountControlMetrics.settingsDiameter
                        )
                }
                .padding(.leading, SidebarAccountControlMetrics.contentInset)
                .padding(.trailing, SidebarAccountControlMetrics.settingsInset)
                .frame(height: SidebarAccountControlMetrics.capsuleHeight)
                .glassEffect(
                    .regular,
                    in: SidebarAccountControlMetrics.shape(for: appearance)
                )
            }
            .padding(.horizontal, InterfaceScale.metric(8))
            .padding(.top, SidebarAccountControlMetrics.surfaceSpacing)
            .padding(.bottom, SidebarAccountControlMetrics.bottomInset(for: appearance))
        }
        .overlay {
            SidebarChromeSeparator(
                cornerRadius: ChatChromeMetrics.sidebarContentCornerRadius,
                strokeInset: 0.5
            )
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            .allowsHitTesting(false)
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            messageTimeline
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            memberList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageTimeline: some View {
        MessageTimelineLoadingSkeleton(
            bottomContentInset: ChatDetailLayoutPolicy.defaultFloatingFooterHeight
        )
        .overlay(alignment: .bottom) {
            composerLoadingSkeleton
                .padding(.horizontal, ChatChromeMetrics.composerWindowInset)
                .padding(.bottom, ChatChromeMetrics.composerWindowInset)
        }
    }

    @ViewBuilder
    private var composerLoadingSkeleton: some View {
        switch AppearanceSettingsStore.shared.load().composerBarAppearance {
        case .defaultStyle:
            HStack(spacing: ChatChromeMetrics.composerSegmentSpacing) {
                SkeletonShape(Circle())
                    .frame(
                        width: ChatChromeMetrics.composerControlHeight,
                        height: ChatChromeMetrics.composerControlHeight
                    )
                SkeletonShape(cornerRadius: ChatChromeMetrics.composerCornerRadius)
                    .frame(height: ChatChromeMetrics.composerControlHeight)
                SkeletonShape(Circle())
                    .frame(
                        width: ChatChromeMetrics.composerControlHeight,
                        height: ChatChromeMetrics.composerControlHeight
                    )
            }
        case .legacy:
            SkeletonShape(
                ConcentricRectangle(
                    corners: .concentric(
                        minimum: .fixed(ChatChromeMetrics.composerMinimumCornerRadius)
                    ),
                    isUniform: true
                )
            )
            .frame(height: ChatChromeMetrics.controlHeight)
        }
    }

    private var memberList: some View {
        MemberListLoadingSkeleton()
        .frame(width: ChatChromeMetrics.memberListWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                SkeletonShape(cornerRadius: 4)
                    .frame(width: 16, height: 16)
                SkeletonShape(cornerRadius: 4)
                    .frame(width: 112, height: 13)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .visibilityPriority(.high)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItem {
            HStack(spacing: 0) {
                SkeletonShape(cornerRadius: 6)
                    .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .fixedSize()
        }
        .visibilityPriority(.high)
    }

    private var detail: String {
        if isOfflineTesting {
            return "Loading offline testing data…"
        }
        switch state {
        case .restoring: return "Checking your saved session…"
        case .connecting: return "Loading your chats…"
        case .signedOut, .workspace: return "Getting things ready…"
        }
    }
}

struct SkeletonShape: View {
    private let shape: AnyShape

    init(cornerRadius: CGFloat) {
        shape = AnyShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    init(_ shape: some Shape) {
        self.shape = AnyShape(shape)
    }

    var body: some View {
        shape
            .fill(.primary.opacity(SkeletonShimmerStyle.baseOpacity))
            .skeletonShimmer(mask: shape)
    }
}
