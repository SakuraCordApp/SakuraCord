import AppKit
import SakuraCordModels
import SwiftUI

nonisolated enum DirectMessageMemberResolver {
    static func members(
        for channel: Channel,
        knownMembers: [Member],
        currentUser: User?,
        currentStatus: PresenceStatus
    ) -> [Member] {
        let knownMembersByID = Dictionary(
            knownMembers.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let currentUserID = currentUser?.id
        var resolved: [Member] = []
        var seen: Set<UserID> = []

        func append(_ member: Member) {
            guard seen.insert(member.id).inserted else { return }
            resolved.append(member)
        }

        for user in channel.recipients where user.id != currentUserID {
            append(
                knownMembersByID[user.id]
                    ?? Member(
                        user: user,
                        roleName: "Members",
                        status: .offline
                    )
            )
        }

        if channel.kind == .groupDirectMessage,
           let ownerID = channel.ownerID,
           ownerID != currentUserID,
           let owner = knownMembersByID[ownerID]
        {
            append(owner)
        }

        if let currentUser {
            append(
                knownMembersByID[currentUser.id]
                    ?? Member(
                        user: currentUser,
                        roleName: "You",
                        status: currentStatus
                    )
            )
        }
        return resolved
    }
}

struct MemberInspectorView: View {
    private let runsPerformanceAutoScroll =
        AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
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
    var nicknameActions: (Member) -> [NicknameMenuAction] = { _ in [] }
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
        nicknameActions: @escaping (Member) -> [NicknameMenuAction] = { _ in [] },
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
        self.nicknameActions = nicknameActions
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
            nicknameActions: nicknameActions
        )
    }
}

/// A viewport-sized, non-scrolling startup surface. Its row and header views
/// are also hosted over unloaded native member-list ranges.
struct MemberListLoadingSkeleton: View {
    var body: some View {
        SkeletonShimmerTimeline {
            ZStack {
                Color(nsColor: .controlBackgroundColor).opacity(0.45)
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

nonisolated struct MemberSection: Identifiable, Equatable, Sendable {
    nonisolated enum SectionIdentifier: Hashable, Sendable {
        case role(name: String, position: Int)
        case online
        case offline
    }

    let id: SectionIdentifier
    let title: String
    let colorHex: UInt32?
    let totalCount: Int
    let members: [Member]
    let gatewayStartIndex: Int?
    let isLoadingSkeleton: Bool

    init(
        id: SectionIdentifier,
        title: String,
        colorHex: UInt32?,
        totalCount: Int,
        members: [Member],
        gatewayStartIndex: Int? = nil,
        isLoadingSkeleton: Bool = false
    ) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.totalCount = totalCount
        self.members = members
        self.gatewayStartIndex = gatewayStartIndex
        self.isLoadingSkeleton = isLoadingSkeleton
    }

    static var loadingSkeletonSections: [MemberSection] {
        let memberCounts = [5, 6, 7]
        var gatewayStartIndex = 0
        return memberCounts.enumerated().map { index, count in
            defer { gatewayStartIndex += count + 1 }
            return MemberSection(
                id: .role(name: "Loading members \(index)", position: index),
                title: "",
                colorHex: nil,
                totalCount: count,
                members: [],
                gatewayStartIndex: gatewayStartIndex,
                isLoadingSkeleton: true
            )
        }
    }

    static func make(
        from members: [Member],
        groups: [GuildMemberListGroup] = [],
        roles: [GuildRole] = [],
        forThread: Bool = false
    ) -> [MemberSection] {
        if !groups.isEmpty {
            return makeServerOrderedSections(members: members, groups: groups, roles: roles)
        }
        var roleMembers: [SectionIdentifier: [Member]] = [:]
        var ungroupedOnline: [Member] = []
        var offlineMembers: [Member] = []
        ungroupedOnline.reserveCapacity(members.count)
        offlineMembers.reserveCapacity(members.count)

        for member in members {
            guard forThread ? member.isOnline : member.isListedOnline else {
                offlineMembers.append(member)
                continue
            }
            if member.isRoleCategory == true {
                let id = SectionIdentifier.role(
                    name: member.roleName,
                    position: member.rolePosition ?? 0
                )
                roleMembers[id, default: []].append(member)
            } else {
                ungroupedOnline.append(member)
            }
        }

        let sort = forThread ? threadMemberNameSort : memberNameSort
        var sections = makeRoleSections(roleMembers, sort: sort)

        if !ungroupedOnline.isEmpty {
            ungroupedOnline.sort(by: sort)
            sections.append(MemberSection(
                id: .online,
                title: "Online",
                colorHex: nil,
                totalCount: ungroupedOnline.count,
                members: ungroupedOnline
            ))
        }

        if !offlineMembers.isEmpty {
            offlineMembers.sort(by: sort)
            sections.append(MemberSection(
                id: .offline,
                title: "Offline",
                colorHex: nil,
                totalCount: offlineMembers.count,
                members: offlineMembers
            ))
        }
        return sections
    }

    private static func makeRoleSections(_ roleMembers: [SectionIdentifier: [Member]], sort: (Member, Member) -> Bool) -> [MemberSection] {
        return roleMembers.map { id, members in
            let name = switch id {
            case let .role(name, _): name
            case .online, .offline: ""
            }
            return MemberSection(
                id: id,
                title: name,
                colorHex: members.lazy.compactMap { member in
                    member.roles.first {
                        $0.name == member.roleName && $0.position == member.rolePosition
                    }?.colorHex
                }.first,
                totalCount: members.count,
                members: members.sorted(by: sort)
            )
        }
        .sorted { lhs, rhs in
            let lhsPosition = lhs.members.first?.rolePosition ?? 0
            let rhsPosition = rhs.members.first?.rolePosition ?? 0
            if lhsPosition != rhsPosition {
                return lhsPosition > rhsPosition
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func makeServerOrderedSections(
        members: [Member],
        groups: [GuildMemberListGroup],
        roles: [GuildRole]
    ) -> [MemberSection] {
        let rolesByID = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, $0) })
        let inferredMembersByGroup = Dictionary(grouping: members.lazy.filter {
            $0.memberListIndex == nil
        }) { member in
            member.roleID?.description ?? (member.isListedOnline ? "online" : "offline")
        }
        let indexedMembers = members.lazy.compactMap { member -> (Int, Member)? in
            member.memberListIndex.map { ($0, member) }
        }.sorted { lhs, rhs in
            lhs.0 < rhs.0
        }
        var indexedMemberCursor = 0
        var startIndex = 0
        var sections: [MemberSection] = []
        sections.reserveCapacity(groups.count)
        for group in groups {
            defer { startIndex += group.count + 1 }
            let memberRange: ClosedRange<Int>? = if group.count > 0 {
                (startIndex + 1) ... (startIndex + group.count)
            } else {
                nil
            }
            var membersInRange: [Member] = []
            if let memberRange {
                while indexedMemberCursor < indexedMembers.count,
                      indexedMembers[indexedMemberCursor].0 < memberRange.lowerBound
                {
                    indexedMemberCursor += 1
                }
                let rangeStart = indexedMemberCursor
                while indexedMemberCursor < indexedMembers.count,
                      indexedMembers[indexedMemberCursor].0 <= memberRange.upperBound
                {
                    indexedMemberCursor += 1
                }
                membersInRange.reserveCapacity(indexedMemberCursor - rangeStart)
                membersInRange.append(contentsOf: indexedMembers[
                    rangeStart ..< indexedMemberCursor
                ].map(\.1))
            }
            let loadedMembers = membersInRange
                + (inferredMembersByGroup[group.id] ?? [])
            if group.id == "online" || group.id == "offline" {
                sections.append(MemberSection(
                    id: group.id == "online" ? .online : .offline,
                    title: group.id == "online" ? "Online" : "Offline",
                    colorHex: nil,
                    totalCount: group.count,
                    members: loadedMembers,
                    gatewayStartIndex: startIndex
                ))
                continue
            }
            guard let roleID = RoleID(group.id) else { continue }
            let role = rolesByID[roleID]
            let title = role?.name ?? loadedMembers.first?.roleName ?? "Members"
            sections.append(MemberSection(
                id: .role(name: title, position: role?.position ?? 0),
                title: title,
                colorHex: role?.colorHex,
                totalCount: group.count,
                members: loadedMembers,
                gatewayStartIndex: startIndex
            ))
        }
        return sections
    }

    private static func threadMemberNameSort(_ lhs: Member, _ rhs: Member) -> Bool {
        let left = lhs.user.displayName.lowercased()
        let right = rhs.user.displayName.lowercased()
        return left == right ? lhs.id < rhs.id : left < right
    }

    private static func memberNameSort(_ lhs: Member, _ rhs: Member) -> Bool {
        lhs.user.displayName.localizedStandardCompare(rhs.user.displayName)
            == .orderedAscending
    }
}

private struct MemberSectionHeader: View {
    let section: MemberSection

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            if case .role = section.id {
                RoleColorIndicator(colorHex: section.colorHex, size: InterfaceScale.metric(8))
            }
            Text("\(section.title) — \(section.totalCount)")
                .font(.interface(.body).weight(.semibold))
                .foregroundStyle(headerColor)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, InterfaceScale.metric(10))
            .padding(.top, InterfaceScale.metric(12))
            .padding(.bottom, InterfaceScale.metric(5))
    }

    private var headerColor: Color {
        guard case .role = section.id else { return .secondary }
        return SakuraCordAccentColor.color(forRoleColorHex: section.colorHex)
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
                                    ProfileDisplayName(name: member.user.displayName, style: style, size: 13,
                                                       showsEffects: false, plainColor: nameColor)
                                        .allowsHitTesting(false)
                                } else {
                                    Text(member.user.displayName)
                                        .font(.interface(.body).weight(.semibold))
                                        .foregroundStyle(nameColor)
                                        .lineLimit(1)
                                }
                                if member.user.isBot {
                                    AppIdentityBadge()
                                }
                                if !cosmeticPolicy.disables(.serverTag, for: member.id),
                                   let identity = member.user.primaryGuild, identity.tag != nil {
                                    PrimaryGuildTag(identity: identity)
                                }
                            }
                            if let activity = member.memberListActivityText, !activity.isEmpty {
                                HStack(spacing: InterfaceScale.metric(4)) {
                                    if member.isListeningToMusic {
                                        Image(systemName: "music.note")
                                            .foregroundStyle(Color(hex: 0x1DB954))
                                        if member.memberListShowsMusicSeparator {
                                            Text("·")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    ProfileStatusTextView(
                                        source: activity,
                                        isExpanded: false,
                                        fontSize: 12,
                                        usesSecondaryColor: true
                                    )
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
            .padding(.vertical, 1)
            .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
            .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
        }
        .buttonStyle(.plain)
        .onModalHover { isHovered = $0 }
        .help(member.user.username)
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
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL,
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

nonisolated struct NameplatePaletteColors: Equatable {
    let light: UInt32
    let dark: UInt32
}

nonisolated enum NameplatePresentationPolicy {
    static func opacity(isHovered: Bool) -> Double {
        isHovered ? 0.8 : 0.5
    }

    static func colors(for palette: String) -> NameplatePaletteColors? {
        switch palette {
        case "crimson": .init(light: 0xE7040F, dark: 0x900007)
        case "berry": .init(light: 0xB11FCF, dark: 0x893A99)
        case "sky": .init(light: 0x56CCFF, dark: 0x0080B7)
        case "teal": .init(light: 0x7DEED7, dark: 0x086460)
        case "forest": .init(light: 0x6AA624, dark: 0x2D5401)
        case "bubble_gum": .init(light: 0xF957B3, dark: 0xDC3E97)
        case "violet": .init(light: 0x972FED, dark: 0x730BC8)
        case "cobalt": .init(light: 0x4278FF, dark: 0x0131C2)
        case "clover": .init(light: 0x63CD5A, dark: 0x047B20)
        case "lemon": .init(light: 0xFED400, dark: 0xF6CD12)
        case "white": .init(light: 0xFFFFFF, dark: 0xFFFFFF)
        default: nil
        }
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

private struct PrimaryGuildTag: View {
    let identity: PrimaryGuildIdentity

    var body: some View {
        InteractiveProfileServerTag(identity: identity)
    }
}
