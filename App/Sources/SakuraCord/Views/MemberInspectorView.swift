import AppKit
import SakuraCordModels
import SwiftUI

struct MemberInspectorView: View {
    let sections: [MemberSection]
    let profilePresentation: ProfilePresentationState?
    let isProfilePresented: Bool
    let selectMember: (Member) -> Void
    let dismissProfile: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    switch item {
                    case let .header(section):
                        MemberSectionHeader(section: section)
                    case let .member(member):
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

    private var items: [MemberInspectorItem] {
        sections.flatMap { section in
            [.header(section)] + section.members.map(MemberInspectorItem.member)
        }
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
    let members: [Member]

    static func make(from members: [Member]) -> [MemberSection] {
        let onlineMembers = members.filter(\.isOnline)
        let roleMembers = Dictionary(grouping: onlineMembers.filter { $0.isRoleCategory == true }) {
            ID.role(name: $0.roleName, position: $0.rolePosition ?? 0)
        }

        var sections = roleMembers.map { id, members in
            let name = switch id {
            case let .role(name, _): name
            case .online, .offline: ""
            }
            return MemberSection(id: id, title: name, members: sortedByName(members))
        }
        .sorted { lhs, rhs in
            let lhsPosition = lhs.members.first?.rolePosition ?? 0
            let rhsPosition = rhs.members.first?.rolePosition ?? 0
            if lhsPosition != rhsPosition {
                return lhsPosition > rhsPosition
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        let ungroupedOnline = onlineMembers.filter { $0.isRoleCategory != true }
        if !ungroupedOnline.isEmpty {
            sections.append(MemberSection(id: .online, title: "Online", members: sortedByName(ungroupedOnline)))
        }

        let offlineMembers = members.filter { !$0.isOnline }
        if !offlineMembers.isEmpty {
            sections.append(MemberSection(id: .offline, title: "Offline", members: sortedByName(offlineMembers)))
        }
        return sections
    }

    private static func sortedByName(_ members: [Member]) -> [Member] {
        members.sorted {
            $0.user.displayName.localizedStandardCompare($1.user.displayName) == .orderedAscending
        }
    }
}

private enum MemberInspectorItem: Identifiable {
    enum ID: Hashable {
        case header(MemberSection.ID)
        case member(UserID)
    }

    case header(MemberSection)
    case member(Member)

    var id: ID {
        switch self {
        case let .header(section): .header(section.id)
        case let .member(member): .member(member.id)
        }
    }
}

private struct MemberSectionHeader: View {
    let section: MemberSection

    var body: some View {
        Text("\(section.title) — \(section.members.count)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.top, 9)
            .padding(.bottom, 3)
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
                    NameplateBackground(nameplate: nameplate)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isHovered || isSelected ? Color.primary.opacity(0.07) : .clear)
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
                                    .background(.indigo, in: RoundedRectangle(cornerRadius: 4))
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
                .padding(.horizontal, 6)
            }
            .frame(height: 44)
            .padding(.vertical, 1)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                ProfilePresentationContent(
                    presentation: profilePresentation
                )
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
                AnimatedRemoteImage(url: decorationURL)
                    .frame(width: size * 1.22, height: size * 1.22)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size * 1.12, height: size * 1.12)
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

private struct NameplateBackground: View {
    let nameplate: Nameplate

    var body: some View {
        staticBackground
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .mask(nameplateMask)
            .accessibilityLabel(nameplate.label)
    }

    private var staticBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(paletteGradient)
            .overlay {
                if let url = nameplate.staticURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
            }
    }

    private var nameplateMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.42),
                .init(color: .black.opacity(0.18), location: 0.52),
                .init(color: .black.opacity(0.72), location: 0.66),
                .init(color: .black, location: 0.76)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var paletteGradient: LinearGradient {
        let colors: [Color] = switch nameplate.palette {
        case "crimson": [Color(hex: 0x7F1D1D), Color(hex: 0xE11D48)]
        case "berry": [Color(hex: 0x701A75), Color(hex: 0xDB2777)]
        case "sky": [Color(hex: 0x075985), Color(hex: 0x38BDF8)]
        case "teal": [Color(hex: 0x115E59), Color(hex: 0x2DD4BF)]
        case "forest": [Color(hex: 0x14532D), Color(hex: 0x22C55E)]
        case "bubble_gum": [Color(hex: 0x9D174D), Color(hex: 0xF9A8D4)]
        case "violet": [Color(hex: 0x4C1D95), Color(hex: 0x8B5CF6)]
        case "cobalt": [Color(hex: 0x172554), Color(hex: 0x2563EB)]
        case "clover": [Color(hex: 0x166534), Color(hex: 0x4ADE80)]
        case "lemon": [Color(hex: 0x854D0E), Color(hex: 0xFACC15)]
        case "white": [Color.white.opacity(0.3), Color.white.opacity(0.08)]
        default: [Color.primary.opacity(0.1), Color.primary.opacity(0.03)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

private struct PrimaryGuildTag: View {
    let identity: PrimaryGuildIdentity
    let tag: String

    var body: some View {
        HStack(spacing: 3) {
            if let badgeURL = identity.badgeURL {
                AsyncImage(url: badgeURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 14, height: 14)
            }
            Text(tag)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 5))
    }
}
