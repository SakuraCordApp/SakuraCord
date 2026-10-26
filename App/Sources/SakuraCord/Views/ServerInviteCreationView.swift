import SakuraCordModels
import SwiftUI

struct ServerInviteCreationView: View {
    let model: AppModel
    let presentation: ServerInviteCreationStore.Presentation
    @Environment(\.windowModalContext) private var dismiss
    @Environment(\.windowModalAvailableSize) private var availableSize

    var body: some View {
        let store = model.serverInvites.creation
        let guild = model.serverRailGuildsByID[presentation.guildID]
        VStack(spacing: 0) {
            ServerInviteCreationHeader(guild: guild, channel: channel(presentation.channelID))
            Divider()
            Group {
                if store.isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: InterfaceScale.metric(96))
                } else if store.page == .list {
                    ScrollView(.vertical) {
                        GlassEffectContainer(spacing: 0) {
                            VStack(spacing: InterfaceScale.metric(8)) {
                                ForEach(store.invites) { invite in
                                    ServerInviteLinkRow(invite: invite, channelName: channel(invite.channelID)?.name,
                                                        isCopied: store.copiedCode == invite.reference.code) {
                                        model.copyServerInvite(invite)
                                    }
                                }
                            }
                            .padding(InterfaceScale.metric(8))
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: min(320, max(120, availableSize.height - 180)))
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
                } else {
                    ServerInviteSettingsForm(settings: Bindable(store).settings,
                                             allowsNever: guild?.features.contains("COMMUNITY") == true)
                        .disabled(store.isCreating)
                }
            }
            if let error = store.error {
                Text(error).font(.interface(.callout)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InterfaceScale.metric(20)).padding(.bottom, InterfaceScale.metric(12))
            }
            Divider()
            footer(store)
        }
        .frame(width: min(400, availableSize.width))
        .animation(.snappy(duration: 0.2), value: store.page)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Invite to Server")
    }

    @ViewBuilder
    private func footer(_ store: ServerInviteCreationStore) -> some View {
        HStack {
            if store.page == .create, !store.invites.isEmpty {
                ModalGlassButton(symbol: "chevron.left", label: "Back") {
                    store.error = nil
                    store.page = .list
                }
            } else {
                ModalGlassButton(symbol: "xmark", label: "Close") { dismiss?() }
            }
            Spacer(minLength: InterfaceScale.metric(16))
            if store.page == .list {
                ModalGlassButton(symbol: "plus", label: "New Invite", primary: true) {
                    store.error = nil
                    store.page = .create
                }
                .disabled(store.isLoading)
            } else {
                ModalGlassButton(symbol: "link", label: "Create Invite", primary: true) { model.createServerInvite() }
                    .disabled(store.isCreating || store.isLoading)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(InterfaceScale.metric(12))
    }

    private func channel(_ id: ChannelID) -> Channel? {
        model.messagePresentationChannelsByID[id]
    }
}

private struct ServerInviteCreationHeader: View {
    let guild: Guild?
    let channel: Channel?

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            GuildIconView(name: guild?.name ?? "Server", iconURL: guild?.iconURL, size: InterfaceScale.metric(40), cornerRadius: InterfaceScale.metric(12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                Text("Invite to \(guild?.name ?? "Server")").font(.interface(.headline)).lineLimit(1)
                if let channel {
                    Text("New members land in #\(channel.name)").font(.interface(.callout)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(InterfaceScale.metric(20))
    }
}

private struct ServerInviteLinkRow: View {
    let invite: CreatedServerInvite
    let channelName: String?
    let isCopied: Bool
    let copy: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                Text("discord.gg/\(invite.reference.code)")
                    .font(.interface(.body).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(details).font(.interface(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: InterfaceScale.metric(8))
            // 8-point insets keep this 32-point capsule concentric with the row and panel.
            Button(action: copy) {
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.interface(.callout).weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.horizontal, InterfaceScale.metric(12))
                    .frame(height: InterfaceScale.metric(32))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(isCopied ? .green : SakuraCordAccentColor.color).interactive(), in: Capsule())
            .help("Copy Invite Link")
            .accessibilityLabel(isCopied ? "Copied" : "Copy Invite Link")
        }
        .padding(.leading, InterfaceScale.metric(14))
        .padding([.vertical, .trailing], InterfaceScale.metric(8))
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: InterfaceScale.metric(24), style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts: [String] = []
        if let channelName { parts.append("#\(channelName)") }
        if let expiresAt = invite.expiresAt {
            parts.append("Expires \(expiresAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide)))")
        } else {
            parts.append("Never expires")
        }
        parts.append(invite.maxUses == 0 ? "No use limit" : invite.maxUses == 1 ? "1 use" : "\(invite.maxUses) uses")
        return parts.joined(separator: " · ")
    }
}

private struct ServerInviteSettingsForm: View {
    @Binding var settings: ServerInviteSettings
    let allowsNever: Bool

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: InterfaceScale.metric(16), verticalSpacing: InterfaceScale.metric(14)) {
            GridRow {
                Text("Expire After").gridColumnAlignment(.trailing)
                Picker("Expire After", selection: $settings.maxAge) {
                    ForEach(ServerInviteMaxAge.allCases.filter { allowsNever || $0 != .never }, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Text("Max Number of Uses")
                Picker("Max Number of Uses", selection: $settings.maxUses) {
                    ForEach(ServerInviteMaxUses.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(InterfaceScale.metric(20))
        .onChange(of: allowsNever, initial: true) { _, allowed in
            if !allowed, settings.maxAge == .never { settings.maxAge = .sevenDays }
        }
    }
}
