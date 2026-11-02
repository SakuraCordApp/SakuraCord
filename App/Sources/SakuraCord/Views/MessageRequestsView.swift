import SakuraCordModels
import SwiftUI

/// Message Requests in the Direct Messages home: the chosen tab's
/// conversations, newest first. Opening one shows its messages.
struct MessageRequestsView: View {
    let model: AppModel

    var body: some View {
        let tab = model.friends.messageRequestsTab ?? .pending
        let channels = model.messageRequestChannels.filter { $0.messageRequest == tab }

        // A stack rather than a List, whose rows would flatten the buttons
        // into one accessibility label.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !channels.isEmpty {
                    Text(tab == .pending ? "Pending Requests — \(channels.count)" : "Spam — \(channels.count)")
                        .font(.interface(.subheadline).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, InterfaceScale.metric(4))
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(channels) { channel in
                    Divider()
                    MessageRequestRow(model: model, channel: channel)
                }
            }
            .padding(.horizontal, InterfaceScale.metric(20))
            .padding(.vertical, InterfaceScale.metric(12))
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if channels.isEmpty {
                // Official en-US empty-state copy.
                switch tab {
                case .pending:
                    ContentUnavailableView(
                        "No pending requests", systemImage: "envelope",
                        description: Text("There are no pending message requests. Here’s Wumpus for now.")
                    )
                case .spam:
                    ContentUnavailableView(
                        "No spam requests", systemImage: "xmark.bin",
                        description: Text("There are no spam requests. Here’s Wumpus for now.")
                    )
                }
            }
        }
    }
}

private struct MessageRequestRow: View {
    let model: AppModel
    let channel: Channel

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            Button { model.navigate(to: channel.id) } label: {
                HStack(spacing: InterfaceScale.metric(12)) {
                    DirectMessageAvatar(channel: channel, size: InterfaceScale.metric(40), status: nil, animates: false)
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                        Text(channel.name)
                            .fontWeight(.semibold)
                        if let recipient = channel.recipients.first, channel.kind == .directMessage {
                            Text(recipient.username)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(channel.lastActivityDate, format: .relative(presentation: .named))
                        .font(.interface(.caption))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Open")

            MessageRequestActions(model: model, channel: channel)
        }
        .padding(.vertical, InterfaceScale.metric(10))
    }
}

/// Discord's decisions for a request: Ignore or Accept DM. Spam offers only
/// Accept DM; its Report Spam flow is not implemented.
struct MessageRequestActions: View {
    let model: AppModel
    let channel: Channel

    var body: some View {
        let isDeciding = model.groupDirectMessageLeave.leaving.contains(channel.id)
        HStack(spacing: InterfaceScale.metric(8)) {
            if isDeciding { ProgressView().controlSize(.small) }
            if channel.messageRequest == .pending {
                Button("Ignore") { model.ignoreMessageRequest(channel) }
                    .buttonStyle(.glass)
            }
            Button("Accept DM") { model.acceptMessageRequest(channel) }
                .buttonStyle(.glassProminent)
                .tint(SakuraCordAccentColor.color)
        }
        .disabled(isDeciding)
    }
}
