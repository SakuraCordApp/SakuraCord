import SakuraCordModels
import SwiftUI

nonisolated enum RoleMembersPopoverMetrics {
    static let width: CGFloat = 330
    static let height: CGFloat = 390
}

struct RoleMembersPopover: View {
    let model: AppModel
    let roleID: RoleID

    private var role: GuildRole? {
        model.guildRoles.first { $0.id == roleID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoleColorIndicator(colorHex: role?.colorHex, size: 10)
                Text(role.map { "@\($0.name)" } ?? "Role members")
                    .font(.headline)
                Spacer()
                if let result = model.roleMemberResult {
                    Text("\(result.totalCount)")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

            Divider()

            if model.isLoadingRoleMembers {
                RoleMembersLoadingState()
            } else if let error = model.roleMemberErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(14)
            } else if let result = model.roleMemberResult {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(result.members) { member in
                            Button {
                                model.showProfile(for: member.user)
                            } label: {
                                HStack(spacing: 9) {
                                    AvatarView(
                                        name: member.user.displayName,
                                        url: member.guildAvatarURL ?? member.user.avatarURL,
                                        size: 28
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(member.user.displayName).lineLimit(1)
                                        Text("@\(member.user.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 42)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if result.isTruncated {
                            Text("Showing the first \(result.members.count) members.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                    .padding(5)
                }
            } else {
                Text("No members found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
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
