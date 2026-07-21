import SakuraCordModels
import SwiftUI

struct QuickSwitcherView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Where would you like to go?", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(16)
            Divider()
            List(filteredChannels) { channel in
                Button {
                    model.selectGuild(channel.guildID)
                    model.selectedChannelID = channel.id
                    dismiss()
                } label: {
                    Label(channel.name, systemImage: channel.guildID == nil ? "person.fill" : "number")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 520, height: 430)
    }

    private var filteredChannels: [Channel] {
        let channels = model.snapshot?.channels ?? []
        return query.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
