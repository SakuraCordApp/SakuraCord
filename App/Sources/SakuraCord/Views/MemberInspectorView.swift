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
    let sections: [MemberSection]
    let profilePresentation: ProfilePresentationState?
    let isProfilePresented: Bool
    let selectMember: (Member) -> Void
    let dismissProfile: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sections) { section in
                    MemberSectionHeader(section: section)
                    ForEach(section.members) { member in
                        MemberRow(
                            member: member,
                            isSelected:
                                profilePresentation?.member.id
                                    == member.id,
                            isProfilePresented:
                                isProfilePresented
                                && profilePresentation?.member.id
                                    == member.id,
                            profilePresentation:
                                profilePresentation?.member.id == member.id
                                    ? profilePresentation
                                    : nil,
                            select: { selectMember(member) },
                            dismissProfile: dismissProfile
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}

struct MemberSection: Identifiable, Equatable {
    enum ID: Hashable {
        case role(name: String, position: Int)
        case online
        case offline
    }

    let id: ID
    let title: String
    let colorHex: UInt32?
    let totalCount: Int
    let members: [Member]

    static func make(
        from members: [Member],
        groups: [GuildMemberListGroup] = [],
        roles: [GuildRole] = []
    ) -> [MemberSection] {
        if !groups.isEmpty {
            return makeServerOrderedSections(members: members, groups: groups, roles: roles)
        }
        var roleMembers: [ID: [Member]] = [:]
        var ungroupedOnline: [Member] = []
        var offlineMembers: [Member] = []
        ungroupedOnline.reserveCapacity(members.count)
        offlineMembers.reserveCapacity(members.count)

        for member in members {
            guard member.isOnline else {
                offlineMembers.append(member)
                continue
            }
            if member.isRoleCategory == true {
                let id = ID.role(
                    name: member.roleName,
                    position: member.rolePosition ?? 0
                )
                roleMembers[id, default: []].append(member)
            } else {
                ungroupedOnline.append(member)
            }
        }

        var sections = makeRoleSections(roleMembers)

        if !ungroupedOnline.isEmpty {
            ungroupedOnline.sort(by: memberNameSort)
            sections.append(MemberSection(
                id: .online,
                title: "Online",
                colorHex: nil,
                totalCount: ungroupedOnline.count,
                members: ungroupedOnline
            ))
        }

        if !offlineMembers.isEmpty {
            offlineMembers.sort(by: memberNameSort)
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

    private static func makeRoleSections(_ roleMembers: [ID: [Member]]) -> [MemberSection] {
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
                members: members.sorted(by: memberNameSort)
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
        let membersByGroup = Dictionary(grouping: members) { member in
            member.roleID?.description ?? (member.isOnline ? "online" : "offline")
        }
        return groups.compactMap { group in
            let loadedMembers = membersByGroup[group.id] ?? []
            if group.id == "online" || group.id == "offline" {
                return MemberSection(
                    id: group.id == "online" ? .online : .offline,
                    title: group.id == "online" ? "Online" : "Offline",
                    colorHex: nil,
                    totalCount: group.count,
                    members: loadedMembers
                )
            }
            guard let roleID = RoleID(group.id) else { return nil }
            let role = rolesByID[roleID]
            let title = role?.name ?? loadedMembers.first?.roleName ?? "Members"
            return MemberSection(
                id: .role(name: title, position: role?.position ?? 0),
                title: title,
                colorHex: role?.colorHex,
                totalCount: group.count,
                members: loadedMembers
            )
        }
    }

    private static func memberNameSort(_ lhs: Member, _ rhs: Member) -> Bool {
        lhs.user.displayName.localizedStandardCompare(rhs.user.displayName)
            == .orderedAscending
    }
}

private struct MemberSectionHeader: View {
    let section: MemberSection

    var body: some View {
        Text("\(section.title) — \(section.totalCount)")
            .font(.body.weight(.semibold))
            .foregroundStyle(section.colorHex.map(Color.init(hex:)) ?? .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 5)
    }
}

private struct MemberRow: View {
    let member: Member
    let isSelected: Bool
    let isProfilePresented: Bool
    let profilePresentation: ProfilePresentationState?
    let select: () -> Void
    let dismissProfile: () -> Void
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
                    ConcentricRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected && !isHovered ? Color.primary.opacity(0.07) : .clear)
                }
                if isHovered {
                    Color.gray.opacity(0.2)
                } else if isSelected, member.user.nameplate != nil {
                    Color.primary.opacity(0.07)
                }

                HStack(spacing: 8) {
                    MemberAvatar(member: member)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(member.user.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(nameColor)
                                .lineLimit(1)
                            if member.user.isBot {
                                Text("APP")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(.white)
                                    .background(.indigo, in: ConcentricRectangle(cornerRadius: 4))
                            }
                            if let identity = member.user.primaryGuild, let tag = identity.tag {
                                PrimaryGuildTag(identity: identity, tag: tag)
                            }
                        }
                        if let activity = member.activityText, !activity.isEmpty {
                            ProfileStatusTextView(
                                source: activity,
                                isExpanded: false,
                                fontSize: 12,
                                usesSecondaryColor: true
                            )
                            .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 16, alignment: .leading)
                            .allowsHitTesting(false)
                        }
                    }
                    .opacity(member.isOnline ? 1 : 0.55)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 44)
            .padding(.vertical, 1)
            .clipShape(ConcentricRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(ConcentricRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(
            isPresented: Binding(
                get: { isSelected && isProfilePresented },
                set: {
                    if !$0 {
                        dismissProfile()
                    }
                }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .trailing
        ) {
            if let profilePresentation {
                ProfilePresentationContent(presentation: profilePresentation)
            }
        }
        .help(member.user.username)
    }

    private var nameColor: Color {
        MessageAuthorPresentation.topRoleColor(in: member.roles).map(Color.init(hex:)) ?? .primary
    }
}

private struct MemberAvatar: View {
    let member: Member

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DecoratedAvatarView(
                name: member.user.displayName,
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL,
                decorationURL: member.user.avatarDecorationURL,
                size: 34
            )
            PresenceIndicator(status: member.status, size: 11)
                .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                .offset(x: 1, y: 1)
        }
    }
}

struct DecoratedAvatarView: View {
    let name: String
    let avatarURL: URL?
    let decorationURL: URL?
    let size: CGFloat

    var body: some View {
        ZStack {
            AvatarView(name: name, url: avatarURL, size: size)
            if let decorationURL {
                AnimatedRemoteImage(
                    url: decorationURL,
                    maximumPixelDimension: decorationPixelDimension
                )
                    .frame(width: size * 1.22, height: size * 1.22)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size * 1.12, height: size * 1.12)
    }

    var decorationPixelDimension: Int {
        max(1, Int((size * 1.22 * 2).rounded(.up)))
    }
}

struct PresenceIndicator: View {
    let status: PresenceStatus
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if status == .dnd {
                    Capsule().fill(.white).frame(width: size * 0.55, height: 2)
                } else if status == .idle {
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: size * 0.62, height: size * 0.62)
                        .offset(x: -size * 0.18, y: -size * 0.18)
                }
            }
    }

    private var color: Color {
        switch status {
        case .online: Color(hex: 0x23A55A)
        case .idle: Color(hex: 0xF0B232)
        case .dnd: Color(hex: 0xF23F43)
        case .invisible, .offline: Color(hex: 0x80848E)
        }
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

private struct NameplateBackground: View {
    let nameplate: Nameplate
    let isAnimated: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            paletteGradient
            staticAsset
            if isAnimated, let url = nameplate.animatedURL {
                AnimatedRemoteImage(
                    url: url,
                    maximumPixelDimension: 512,
                    contentMode: .fill
                )
            }
        }
            .clipped()
            .accessibilityLabel(nameplate.label)
    }

    @ViewBuilder
    private var staticAsset: some View {
        if let url = nameplate.staticURL {
            AnimatedRemoteImage(
                url: url,
                animates: false,
                maximumPixelDimension: 512,
                contentMode: .fill
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
    let tag: String

    var body: some View {
        HStack(spacing: 3) {
            if let badgeURL = identity.badgeURL {
                AnimatedRemoteImage(
                    url: badgeURL,
                    animates: false,
                    maximumPixelDimension: 32
                )
                .frame(width: 14, height: 14)
            }
            Text(tag)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.32), in: ConcentricRectangle(cornerRadius: 5))
    }
}
