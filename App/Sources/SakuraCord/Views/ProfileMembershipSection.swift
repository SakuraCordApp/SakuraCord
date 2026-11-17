import SakuraCordModels
import SwiftUI

struct ProfileMembershipSection: View {
    let createdAt: Date
    var guildJoinedAt: Date?
    var guildName: String?
    var guildIconURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text("Member Since", bundle: #bundle)
                .font(.interfaceSystem(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    discordBadge
                    if let guildJoinedAt {
                        Text("•")
                            .font(.interfaceSystem(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        serverBadge(joinedAt: guildJoinedAt)
                    }
                }

                VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                    discordBadge
                    if let guildJoinedAt {
                        serverBadge(joinedAt: guildJoinedAt)
                    }
                }
            }
        }
        .padding(.horizontal, InterfaceScale.metric(16))
        .padding(.vertical, InterfaceScale.metric(12))
    }

    private var discordBadge: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            Image("discord.fill", bundle: .module)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(16))
                .foregroundStyle(.primary)
            Text(createdAt, format: .dateTime.month(.abbreviated).day().year())
                .font(.interfaceSystem(size: 13))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Discord member since \(createdAt.formatted(.dateTime.month(.abbreviated).day().year()))", bundle: #bundle))
    }

    private func serverBadge(joinedAt: Date) -> some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            GuildIconView(
                name: guildName ?? "",
                iconURL: guildIconURL,
                size: InterfaceScale.metric(16),
                cornerRadius: InterfaceScale.metric(4),
                animates: false
            )
            Text(joinedAt, format: .dateTime.month(.abbreviated).day().year())
                .font(.interfaceSystem(size: 13))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(guildName ?? "Server") member since \(joinedAt.formatted(.dateTime.month(.abbreviated).day().year()))", bundle: #bundle))
    }
}
