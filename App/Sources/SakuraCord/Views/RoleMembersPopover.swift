import SakuraCordModels
import SwiftUI

nonisolated enum RoleMembersPopoverMetrics {
    static var width: CGFloat { InterfaceScale.metric(330) }
    static var height: CGFloat { InterfaceScale.metric(390) }
}

struct RoleMembersPopover: View {
    let model: AppModel
    let roleID: RoleID
    let guildID: GuildID?

    private var role: GuildRole? {
        let roles = guildID.flatMap { model.guildRolesByGuildID[$0] }
            ?? (guildID == model.selectedGuildID ? model.guildRoles : [])
        return roles.first { $0.id == roleID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: InterfaceScale.metric(8)) {
                if let role, role.hasIcon {
                    RoleIconView(role: role, size: InterfaceScale.metric(16))
                } else {
                    RoleColorIndicator(
                        colorHex: role?.colorHex,
                        secondaryColorHex: role?.secondaryColorHex,
                        tertiaryColorHex: role?.tertiaryColorHex,
                        size: InterfaceScale.metric(10)
                    )
                }
                Text(role.map { "@\($0.name)" } ?? "Role members")
                    .font(.interface(.headline))
                Spacer()
                if let result = model.roleMemberResult {
                    Text("\(result.totalCount)")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(InterfaceScale.metric(12))

            Divider()

            if model.isLoadingRoleMembers {
                RoleMembersLoadingState()
            } else if let error = model.roleMemberErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(InterfaceScale.metric(14))
            } else if let result = model.roleMemberResult {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                        ForEach(result.members) { member in
                            Button {
                                model.presentProfile(for: member, in: guildID, destination: .contextual)
                            } label: {
                                HStack(spacing: InterfaceScale.metric(9)) {
                                    AvatarView(
                                        name: member.user.displayName,
                                        url: member.guildAvatarURL ?? member.user.avatarURL,
                                        size: InterfaceScale.metric(28)
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(member.user.displayName).lineLimit(1)
                                        Text("@\(member.user.username)")
                                            .font(.interface(.caption))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, InterfaceScale.metric(10))
                                .frame(height: InterfaceScale.metric(42))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .overlay {
                                UserContextMenuBridge {
                                    UserContextMenu.make(for: member.user, context: .init(guildID: guildID), model: model)
                                }
                            }
                        }
                        if result.isTruncated {
                            Text("Showing the first \(result.members.count) members.")
                                .font(.interface(.caption))
                                .foregroundStyle(.secondary)
                                .padding(InterfaceScale.metric(10))
                        }
                    }
                    .padding(InterfaceScale.metric(5))
                }
            } else {
                Text("No members found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(100))
            }
        }
        .frame(
            width: RoleMembersPopoverMetrics.width,
            height: RoleMembersPopoverMetrics.height,
            alignment: .top
        )
    }
}

private struct RoleMembersLoadingState: View {
    var body: some View {
        ProgressView("Loading members…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
