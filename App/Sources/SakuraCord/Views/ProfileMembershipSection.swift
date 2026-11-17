import SakuraCordModels
import SwiftUI

struct ProfileMembershipSection: View {
    private static let dateFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).year()

    let createdAt: Date
    var guild: Guild?
    var guildJoinedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text("Member Since", bundle: #bundle).font(.interfaceSystem(size: 12, weight: .medium))
            // Discord shows the icon pair only when the server and the member both resolve.
            if let guild, let guildJoinedAt {
                HStack(spacing: InterfaceScale.metric(8)) {
                    badge(date: createdAt) {
                        Image("discord.fill", bundle: .module)
                            .resizable()
                            .foregroundStyle(.secondary)
                            .help("Discord")
                    }
                    .accessibilityLabel(Text("Discord member since \(createdAt, format: Self.dateFormat)", bundle: #bundle))
                    Circle()
                        .fill(.secondary)
                        .frame(width: InterfaceScale.metric(4), height: InterfaceScale.metric(4))
                        .accessibilityHidden(true)
                    badge(date: guildJoinedAt) {
                        GuildIconView(name: guild.name, iconURL: guild.iconURL, size: InterfaceScale.metric(16),
                                      cornerRadius: InterfaceScale.metric(4), animates: false)
                            .help(guild.name)
                    }
                    .accessibilityLabel(Text("\(guild.name) member since \(guildJoinedAt, format: Self.dateFormat)", bundle: #bundle))
                }
            } else {
                dateText(createdAt)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(16)).padding(.vertical, InterfaceScale.metric(12))
    }

    private func badge(date: Date, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            icon().frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(16))
            dateText(date)
        }
        .accessibilityElement(children: .ignore)
    }

    private func dateText(_ date: Date) -> some View {
        Text(date, format: Self.dateFormat).font(.interfaceSystem(size: 14))
    }
}
