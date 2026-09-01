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
        HStack(spacing: 5) {
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.12))
                .frame(width: 8)
            SkeletonShape(cornerRadius: 4)
                .frame(width: 86, height: 9)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    private var channelRow: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 8, height: 8)
            SkeletonShape(cornerRadius: 4)
                .frame(width: 16, height: 16)
            SkeletonShape(cornerRadius: 5.5)
                .frame(width: 112, height: 11)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
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
            SkeletonShape(cornerRadius: 4)
                .frame(width: 132, height: 14)
                .offset(
                    x: ChatChromeMetrics.sidebarTitleLeadingOffset,
                    y: ChatChromeMetrics.sidebarTitleTopOffset + 7
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
            VStack(spacing: 10) {
                railItem(cornerRadius: 14)
                Divider().padding(.horizontal, 12)
                ForEach(0 ..< SessionLoadingSkeletonLayout.serverCount, id: \.self) { _ in
                    railItem(cornerRadius: 14)
                }
            }
            .padding(
                .top,
                isAccountSwitch && !isEmbeddedInWorkspace
                    ? ChatChromeMetrics.controlHeight
                    : 0
            )
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .frame(width: ChatChromeMetrics.serverRailWidth)
    }

    private func railItem(cornerRadius: CGFloat) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 7, height: 40)
            SkeletonShape(cornerRadius: cornerRadius)
                .frame(width: 44, height: 44)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: 46, alignment: .leading)
    }

    private var channelSidebar: some View {
        VStack(spacing: 0) {
            ChannelListLoadingSkeleton()

            GlassEffectContainer(spacing: SidebarAccountControlMetrics.surfaceSpacing) {
                HStack(spacing: 8) {
                    SkeletonShape(Circle())
                        .frame(
                            width: SidebarAccountControlMetrics.avatarSize,
                            height: SidebarAccountControlMetrics.avatarSize
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        SkeletonShape(cornerRadius: 4)
                            .frame(width: 82, height: 10)
                        SkeletonShape(cornerRadius: 3)
                            .frame(width: 52, height: 7)
                    }
                    Spacer(minLength: 0)
                    SkeletonShape(Circle())
                        .frame(
                            width: SidebarAccountControlMetrics.settingsDiameter,
                            height: SidebarAccountControlMetrics.settingsDiameter
                        )
                }
                .padding(.horizontal, SidebarAccountControlMetrics.contentInset)
                .frame(height: SidebarAccountControlMetrics.capsuleHeight)
                .glassEffect(
                    .regular,
                    in: ConcentricRectangle(
                        cornerRadius: SidebarAccountControlMetrics.cornerRadius,
                        style: .continuous
                    )
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, SidebarAccountControlMetrics.surfaceSpacing)
            .padding(.bottom, 8)
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
            .fill(.primary.opacity(0.09))
            .skeletonShimmer()
    }
}

// Shared by the signed-out login surface. The session-loading surface above
// intentionally uses only structural placeholders.
struct SakuraCordAuroraBackdrop: View {
    let elapsed: TimeInterval
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = SakuraCordThemeStore.shared.activeTheme
        let colors = theme.colors(for: colorScheme)
        let firstColor = colors[0]
        let lastColor = colors[colors.count - 1]
        let middleColor = colors[colors.count / 2]
        ZStack {
            SakuraCordThemeBackground(emphasizesGradient: true)

            GeometryReader { geometry in
                Ellipse()
                    .fill(firstColor.opacity(colorScheme == .dark ? 0.24 : 0.18))
                    .frame(width: geometry.size.width * 0.72, height: geometry.size.height * 0.68)
                    .blur(radius: 110)
                    .offset(
                        x: -geometry.size.width * 0.2 + sin(elapsed * 0.16) * 34,
                        y: geometry.size.height * 0.48 + cos(elapsed * 0.13) * 28
                    )

                Ellipse()
                    .fill(lastColor.opacity(colorScheme == .dark ? 0.18 : 0.14))
                    .frame(width: geometry.size.width * 0.64, height: geometry.size.height * 0.58)
                    .blur(radius: 120)
                    .offset(
                        x: geometry.size.width * 0.6 + cos(elapsed * 0.12) * 38,
                        y: -geometry.size.height * 0.18 + sin(elapsed * 0.15) * 24
                    )

                Ellipse()
                    .fill(middleColor.mix(with: lastColor, by: 0.5).opacity(0.10))
                    .frame(width: geometry.size.width * 0.48, height: geometry.size.height * 0.48)
                    .blur(radius: 100)
                    .offset(
                        x: geometry.size.width * 0.52 + sin(elapsed * 0.1) * 30,
                        y: geometry.size.height * 0.58 + cos(elapsed * 0.11) * 24
                    )
            }

            RadialGradient(
                colors: [
                    .clear,
                    colorScheme == .dark
                        ? Color.black.opacity(0.30)
                        : Color.white.opacity(0.22),
                ],
                center: .center,
                startRadius: 180,
                endRadius: 800
            )
        }
    }
}

struct SakuraCordSakuraPetalField: View {
    let elapsed: TimeInterval
    let size: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = SakuraCordThemeStore.shared.activeTheme
        let colors = theme.colors(for: colorScheme)
        Canvas(rendersAsynchronously: true) { context, _ in
            for index in 0 ..< 24 {
                let petal = SakuraPetal.motion(
                    index: index,
                    elapsed: elapsed,
                    canvasSize: size,
                    colors: colors
                )
                context.drawLayer { layer in
                    layer.translateBy(x: petal.position.x, y: petal.position.y)
                    layer.rotate(by: petal.rotation)
                    layer.scaleBy(x: petal.scale, y: petal.scale)
                    layer.opacity = petal.opacity
                    layer.fill(SakuraPetal.path, with: .color(petal.color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private enum SakuraPetal {
    struct Motion {
        let position: CGPoint
        let rotation: Angle
        let scale: CGFloat
        let opacity: Double
        let color: Color
    }

    static let path: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -9))
        path.addCurve(
            to: CGPoint(x: 0, y: 10),
            control1: CGPoint(x: 8, y: -6),
            control2: CGPoint(x: 8, y: 5)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: -9),
            control1: CGPoint(x: -8, y: 5),
            control2: CGPoint(x: -8, y: -6)
        )
        return path
    }()

    static func motion(
        index: Int,
        elapsed: TimeInterval,
        canvasSize: CGSize,
        colors: [Color]
    ) -> Motion {
        let seed = fraction(sin(Double(index + 1) * 12.9898) * 43_758.5453)
        let secondarySeed = fraction(sin(Double(index + 7) * 78.233) * 19_341.274)
        let duration = 10 + seed * 9
        let progress = fraction(elapsed / duration + secondarySeed)
        let baseX = seed * max(canvasSize.width, 1)
        let sway = sin(elapsed * (0.45 + secondarySeed * 0.25) + seed * 12)
            * (22 + seed * 34)
        let width = max(canvasSize.width, 1)
        let horizontalPosition = wrapped(baseX + sway, limit: width)
        let verticalPosition = -30 + progress * (canvasSize.height + 60)
        let depth = 0.45 + secondarySeed * 0.75

        return Motion(
            position: CGPoint(x: horizontalPosition, y: verticalPosition),
            rotation: .radians(elapsed * (0.3 + seed * 0.75) + secondarySeed * .pi * 2),
            scale: depth,
            opacity: 0.18 + seed * 0.38,
            color: colors[index % colors.count]
        )
    }

    private static func fraction(_ value: Double) -> Double {
        value - floor(value)
    }

    private static func wrapped(_ value: Double, limit: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: limit)
        return remainder < 0 ? remainder + limit : remainder
    }
}
