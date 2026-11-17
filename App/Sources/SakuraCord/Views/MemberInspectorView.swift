import AppKit
import SakuraCordModels
import SwiftUI

struct MemberInspectorView: View {
    private let runsPerformanceAutoScroll =
        AppLaunchConfiguration.current
        .runsMemberListPerformanceAutoScroll
    let sections: [MemberSection]
    let customEmojiURLsByID: CustomEmojiImageURLs
    let profilePresentation: ProfilePresentationState?
    let isProfilePresented: Bool
    let selectMember: (Member) -> Void
    let dismissProfile: () -> Void
    let viewportIdentity: ChannelID?
    let updateViewport: (ClosedRange<Int>) -> Void
    var openProfile: ((ProfilePresentationState) -> Void)?
    var sendProfileMessage: ((UserID, String, String) async -> Bool)?
    var userMenu: (Member) -> NSMenu? = { _ in nil }
    var userAccessibilityActions: (Member) -> [NSAccessibilityCustomAction] = { _ in [] }
    var presentation = NativeMemberListPresentation()

    init(
        sections: [MemberSection],
        customEmojiURLsByID: CustomEmojiImageURLs = [:],
        profilePresentation: ProfilePresentationState?,
        isProfilePresented: Bool,
        selectMember: @escaping (Member) -> Void,
        dismissProfile: @escaping () -> Void,
        viewportIdentity: ChannelID? = nil,
        presentation: NativeMemberListPresentation = .init(),
        openProfile: ((ProfilePresentationState) -> Void)? = nil,
        sendProfileMessage: ((UserID, String, String) async -> Bool)? = nil,
        userMenu: @escaping (Member) -> NSMenu? = { _ in nil },
        userAccessibilityActions: @escaping (Member) -> [NSAccessibilityCustomAction] = { _ in [] },
        updateViewport: @escaping (ClosedRange<Int>) -> Void = { _ in }
    ) {
        self.sections = sections
        self.customEmojiURLsByID = customEmojiURLsByID
        self.profilePresentation = profilePresentation
        self.isProfilePresented = isProfilePresented
        self.selectMember = selectMember
        self.dismissProfile = dismissProfile
        self.viewportIdentity = viewportIdentity
        self.presentation = presentation
        self.updateViewport = updateViewport
        self.openProfile = openProfile
        self.sendProfileMessage = sendProfileMessage
        self.userMenu = userMenu
        self.userAccessibilityActions = userAccessibilityActions
    }

    var body: some View {
        NativeMemberListView(
            sections: sections,
            customEmojiURLsByID: customEmojiURLsByID,
            profilePresentation: profilePresentation,
            isProfilePresented: isProfilePresented,
            selectMember: selectMember,
            dismissProfile: dismissProfile,
            runsPerformanceAutoScroll: runsPerformanceAutoScroll,
            viewportIdentity: viewportIdentity,
            presentation: presentation,
            onViewportRange: updateViewport,
            openProfile: openProfile,
            sendProfileMessage: sendProfileMessage,
            rowMenu: userMenu,
            rowAccessibilityActions: userAccessibilityActions
        )
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// A viewport-sized, non-scrolling startup surface. Its row and header views
/// are also hosted over unloaded native member-list ranges.
struct MemberListLoadingSkeleton: View {
    var body: some View {
        SkeletonShimmerTimeline {
            ZStack {
                // The list scrolls beneath the toolbar; its rows start below it.
                Color(nsColor: .controlBackgroundColor).opacity(0.45)
                    .ignoresSafeArea(.container, edges: .top)
                GeometryReader { geometry in
                    let items = MemberListSkeletonLayout.itemsFitting(
                        height: geometry.size.height,
                        memberCounts: MemberSection.loadingSkeletonSections.map(\.totalCount)
                    )
                    VStack(spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            switch item {
                            case .header:
                            MemberListSkeletonHeader()
                                .frame(height: NativeMemberListMetrics.sectionHeaderHeight)
                            case .member:
                                MemberListSkeletonRow()
                                    .padding(.horizontal, NativeMemberListMetrics.horizontalInset)
                                    .frame(height: NativeMemberListMetrics.memberRowHeight)
                            }
                        }
                    }
                    .padding(.vertical, NativeMemberListMetrics.verticalInset)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .topLeading
                    )
                    .clipped()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading members")
    }
}

struct MemberRow: View {
    @Environment(\.roleColorDisplay) private var roleColorDisplay
    @Environment(\.profileCosmeticPolicy) private var cosmeticPolicy
    let member: Member
    let isSelected: Bool
    var showsContents = true
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            ZStack {
                if let nameplate = member.user.nameplate {
                    NameplateBackground(
                        nameplate: nameplate,
                        isAnimated: isHovered
                    )
                    .opacity(NameplatePresentationPolicy.opacity(isHovered: isHovered))
                } else {
                    ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous)
                        .fill(isSelected && !isHovered ? Color.primary.opacity(0.07) : .clear)
                }
                if isHovered {
                    Color.gray.opacity(0.2)
                } else if isSelected, member.user.nameplate != nil {
                    Color.primary.opacity(0.07)
                }

                if showsContents {
                    HStack(spacing: InterfaceScale.metric(8)) {
                        MemberAvatar(member: member, isHovered: isHovered)
                        VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                            HStack(spacing: InterfaceScale.metric(5)) {
                                NameRoleColorIndicator(colorHex: MessageAuthorPresentation.topRoleColor(in: member.roles))
                                if let style = member.user.displayNameStyle {
                                    ProfileDisplayName(name: member.user.displayName, style: style, size: NSFont.authorNameSize,
                                                       showsEffects: false, plainColor: nameColor)
                                        .allowsHitTesting(false)
                                } else {
                                    Text(member.user.displayName)
                                        .font(.interfaceSystem(size: NSFont.authorNameSize, weight: .medium))
                                        .foregroundStyle(nameColor)
                                        .lineLimit(1)
                                }
                                if member.user.isBot {
                                    AppIdentityBadge(isVerified: member.user.isVerifiedBot)
                                }
                                if !cosmeticPolicy.disables(.serverTag, for: member.id),
                                   let identity = member.user.primaryGuild, identity.tag != nil {
                                    InteractiveProfileServerTag(identity: identity)
                                }
                            }
                            let activityContent = member.memberListActivityContent
                            if let activity = activityContent.text, !activity.isEmpty {
                                HStack(spacing: InterfaceScale.metric(4)) {
                                    if member.isListeningToMusic {
                                        Image(systemName: "music.note")
                                            .foregroundStyle(Color(nsColor: NativeMemberActivityPresentation.iconColor))
                                    }
                                    if activityContent.separatesMusicIcon {
                                        activitySeparator
                                    }
                                    ProfileStatusTextView(
                                        source: activity,
                                        isExpanded: false,
                                        fontSize: 12,
                                        usesSecondaryColor: true
                                    )
                                    if let emoji = activityContent.trailingEmoji {
                                        activitySeparator
                                        ProfileStatusTextView(source: emoji, isExpanded: false, fontSize: 12, usesSecondaryColor: true)
                                    }
                                }
                                .font(.interfaceSystem(size: 12))
                                .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(14), maxHeight: InterfaceScale.metric(16), alignment: .leading)
                                .allowsHitTesting(false)
                            }
                        }
                        .opacity(member.isListedOnline ? 1 : 0.55)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, InterfaceScale.metric(4))
                }
            }
            .frame(height: InterfaceScale.metric(44))
            .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
            .padding(.vertical, 1)
            .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
        }
        .buttonStyle(.plain)
        .onModalHover { isHovered = $0 }
        .help(member.memberListTooltip)
    }

    private var activitySeparator: some View {
        Text("·").fontWeight(.bold).foregroundStyle(.primary.opacity(0.5))
    }

    private var nameColor: Color {
        roleColorDisplay == .inNames ? MessageAuthorPresentation.topRoleColor(in: member.roles).map(Color.init(hex:)) ?? .primary : .primary
    }
}

struct MemberAvatar: View {
    let member: Member
    var isHovered = false
    var showsPresence = true

    var body: some View {
        AvatarPresenceView(
            status: showsPresence ? member.memberListStatus : nil,
            avatarSize: InterfaceScale.metric(34),
            indicatorSize: InterfaceScale.metric(11),
            isMobile: member.showsMobileIndicator
        ) {
            DecoratedAvatarView(
                name: member.user.displayName,
                avatarURL: member.avatarURL,
                decorationURL: member.user.avatarDecorationURL,
                size: InterfaceScale.metric(34),
                playback: .hover(isHovered)
            )
        }
    }
}

enum AvatarDecorationPlayback {
    case continuous
    case paused
    case hover(Bool)

    var isPlaying: Bool {
        switch self {
        case .continuous: true
        case .paused: false
        case let .hover(isHovered): isHovered
        }
    }

    var resetsWhenStopped: Bool {
        if case .hover = self { return true }
        return false
    }
}

struct DecoratedAvatarView: View {
    let name: String
    let avatarURL: URL?
    let decorationURL: URL?
    let size: CGFloat
    var playback: AvatarDecorationPlayback = .continuous

    var body: some View {
        ZStack {
            AvatarView(
                name: name,
                url: avatarURL,
                size: size,
                animates: avatarAnimationEnabled,
                isHovered: avatarHover
            )
            if let decorationURL {
                AnimatedRemoteImage(
                    url: decorationURL,
                    animates: playback.isPlaying,
                    maximumPixelDimension: decorationPixelDimension,
                    resetsWhenStopped: playback.resetsWhenStopped
                )
                    .id(decorationURL)
                    .frame(width: size * 1.22, height: size * 1.22)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size * 1.12, height: size * 1.12)
    }

    var decorationPixelDimension: Int {
        // Reuse the same decoded frames between nearby avatar sizes (picker,
        // profile and customization card) instead of decoding again on selection.
        let requested = max(1, Int((size * 1.22 * 2).rounded(.up)))
        var bucket = 64
        while bucket < requested { bucket *= 2 }
        return bucket
    }

    private var avatarAnimationEnabled: Bool {
        if case .paused = playback { return false }
        return true
    }

    private var avatarHover: Bool? {
        if case let .hover(isHovered) = playback { return isHovered }
        return nil
    }
}

struct NameplateBackground: View {
    let nameplate: Nameplate
    let isAnimated: Bool
    var preservesTrailingArtwork = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                paletteGradient
                staticAsset
                    .frame(width: geometry.size.width, height: geometry.size.height,
                           alignment: preservesTrailingArtwork ? .trailing : .center)
                if isAnimated, let url = nameplate.animatedURL {
                    AnimatedRemoteImage(
                        url: url,
                        maximumPixelDimension: 512,
                        contentMode: .fill,
                        usesSwiftUIRendering: preservesTrailingArtwork
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height,
                           alignment: preservesTrailingArtwork ? .trailing : .center)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityLabel(nameplate.label)
    }

    @ViewBuilder
    private var staticAsset: some View {
        if let url = nameplate.staticURL {
            AnimatedRemoteImage(
                url: url,
                animates: false,
                maximumPixelDimension: 512,
                contentMode: .fill,
                usesSwiftUIRendering: preservesTrailingArtwork
            )
        }
    }

    @ViewBuilder
    private var paletteGradient: some View {
        if let colors = NameplatePresentationPolicy.colors(for: nameplate.palette) {
            let hex = colorScheme == .dark ? colors.dark : colors.light
            LinearGradient(
                stops: [
                    .init(color: Color(hex: hex).opacity(0.1), location: 0),
                    .init(color: Color(hex: hex).opacity(0.4), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}
