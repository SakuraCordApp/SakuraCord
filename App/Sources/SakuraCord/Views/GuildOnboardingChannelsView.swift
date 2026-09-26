import SakuraCordModels
import SwiftUI

struct GuildOnboardingChannelsView: View {
    let model: AppModel
    let guildID: GuildID
    let configuration: GuildOnboarding
    @State private var search = ""

    var body: some View {
        let settings = model.presentedGuildChannelSettings(in: guildID)
        let resourceIDs = Set(model.onboarding.guides[guildID]?.configuration?.resourceChannels.map(\.channelID) ?? [])
        let channels = (model.snapshot?.channels ?? []).filter {
            $0.guildID == guildID && !resourceIDs.contains($0.id) && model.conversationAccess(for: $0).isReadable
                && (search.isEmpty || $0.name.localizedStandardContains(search))
        }
        VStack(alignment: .leading, spacing: 20) {
            TextField("Search Channels", text: $search).textFieldStyle(.roundedBorder)
            ForEach(ChannelGroup.make(from: channels)) { group in
                let followingCategory = group.categoryID.map { GuildChannelSelection.isSelected($0, settings: settings) } ?? false
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(group.name ?? "Uncategorized").font(.headline)
                        Spacer()
                        if let categoryID = group.categoryID {
                            Toggle("Follow Category", isOn: Binding(
                                get: { followingCategory },
                                set: { model.setChannelSelected($0, channelID: categoryID, guildID: guildID) }
                            ))
                            .toggleStyle(.switch).controlSize(.small).fixedSize()
                        }
                    }
                    ForEach(group.channels) { channel in
                        HStack(spacing: 16) {
                            Button { model.navigate(to: channel.id) } label: {
                                Label(channel.name, systemImage: channel.kind == .voice ? "speaker.wave.2.fill" : "number")
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Toggle(channel.name, isOn: Binding(
                                get: { followingCategory || GuildChannelSelection.isSelected(channel.id, settings: settings) },
                                set: { model.setChannelSelected($0, channelID: channel.id, guildID: guildID) }
                            ))
                            .toggleStyle(.checkbox).labelsHidden().disabled(followingCategory)
                            .help(followingCategory ? "Unfollow the category to choose individual channels." : "Show \(channel.name) in the channel list")
                        }
                        .padding(16)
                        .background(.primary.opacity(0.025), in: ConcentricRectangle(cornerRadius: 16))
                        .overlay { ConcentricRectangle(cornerRadius: 16).stroke(.primary.opacity(0.1)) }
                    }
                }
            }
            if channels.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }
}
