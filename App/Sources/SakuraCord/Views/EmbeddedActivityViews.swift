import AppKit
import SakuraCordModels
import SwiftUI

/// The running Activity's web view, kept alive by its host across navigation.
struct EmbeddedActivityView: NSViewRepresentable {
    let host: EmbeddedActivityHost

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if host.webView.superview !== container { install(in: container) }
    }

    private func install(in container: NSView) {
        host.webView.removeFromSuperview()
        host.webView.frame = container.bounds
        host.webView.autoresizingMask = [.width, .height]
        container.addSubview(host.webView)
    }
}

/// The hosted Activity's stage, in a call or docked above a channel's chat:
/// the running app, its launch progress, or why it stopped.
struct EmbeddedActivityStage: View {
    let model: AppModel

    var body: some View {
        let store = model.embeddedActivities
        if let session = store.session {
            VStack(spacing: 0) {
                header(session)
                ZStack {
                    switch session.phase {
                    case .running:
                        if let host = store.host {
                            EmbeddedActivityView(host: host)
                                .clipShape(Self.contentShape)
                                .transition(.opacity)
                        }
                    case .launching:
                        status(session) {
                            ProgressView().controlSize(.small)
                            Text("Starting \(session.application.name)…")
                        }
                    case .failed(let message):
                        status(session) {
                            Text(message).multilineTextAlignment(.center)
                            Button("Try Again") {
                                Task { await model.retryActivity() }
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.smooth(duration: 0.3), value: session.phase)
            }
            .padding(InterfaceScale.metric(12))
        }
    }

    private static var contentShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
    }

    private func header(_ session: EmbeddedActivityStore.Session) -> some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            ActivityIcon(url: session.application.iconURL, size: 26)
            Text(session.application.name)
                .font(.interface(.headline))
            if let count = session.instance?.participants.count {
                Text("\(count) playing")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button("Leave Activity", systemImage: "rectangle.portrait.and.arrow.right") {
                model.leaveActivity()
            }
            .buttonStyle(.glass)
            .tint(.red)
        }
        .padding(.bottom, InterfaceScale.metric(10))
    }

    private func status(
        _ session: EmbeddedActivityStore.Session,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(spacing: InterfaceScale.metric(12)) {
            ActivityIcon(url: session.application.iconURL, size: 56)
            content()
        }
        .font(.interface(.callout))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.04), in: Self.contentShape)
        .transition(.opacity)
    }
}

/// Docks the hosted Activity above a text channel's or DM's chat, which stays
/// beside it as Discord's client keeps it.
struct EmbeddedActivityChatWorkspace: View {
    let model: AppModel

    var body: some View {
        DockedRegionChatWorkspace(model: model, heightKey: "embeddedActivityRegionHeight", defaultHeight: 420) {
            EmbeddedActivityStage(model: model)
        }
    }
}

/// While the hosted Activity runs outside a call, the sidebar shows it with a
/// way back to its channel and out of it, like the voice panel.
struct EmbeddedActivitySidebarPanel: View {
    let model: AppModel
    let session: EmbeddedActivityStore.Session

    var body: some View {
        HStack(spacing: InterfaceScale.metric(9)) {
            Button {
                model.navigate(to: session.channel.id)
            } label: {
                HStack(spacing: InterfaceScale.metric(9)) {
                    ActivityIcon(url: session.application.iconURL, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.application.name)
                            .font(.interfaceSystem(size: 12, weight: .bold))
                            .lineLimit(1)
                        Text(location)
                            .font(.interface(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(session.application.name)")
            Button {
                model.leaveActivity()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.interface(.callout).weight(.semibold))
                    .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(Color(hex: 0xDA373C)).interactive(), in: Circle())
            .help("Leave Activity")
            .accessibilityLabel("Leave Activity")
        }
        .padding(.leading, InterfaceScale.metric(12))
        .padding(.trailing, InterfaceScale.metric(8))
        .frame(minHeight: InterfaceScale.metric(50))
        .glassEffect(.regular, in: ConcentricRectangle(
            cornerRadius: SidebarAccountControlMetrics.cornerRadius, style: .continuous
        ))
    }

    private var location: String {
        let channel = session.channel
        guard let guildID = channel.guildID, let guild = model.serverRailGuildsByID[guildID] else {
            return channel.name
        }
        return "\(channel.name) / \(guild.name)"
    }
}

/// Activities others are running in this channel that the account can join.
struct EmbeddedActivityJoinBanner: View {
    let model: AppModel
    let channel: Channel

    var body: some View {
        let store = model.embeddedActivities
        let running = store.instances(in: channel.id).filter {
            store.session?.instance?.compositeInstanceID != $0.compositeInstanceID
        }
        if !running.isEmpty {
            VStack(spacing: InterfaceScale.metric(8)) {
                ForEach(running, id: \.compositeInstanceID) { instance in
                    row(instance, application: store.application(instance.applicationID))
                }
            }
            .padding(.horizontal, InterfaceScale.metric(14))
            .padding(.top, InterfaceScale.metric(10))
            .task(id: channel.guildID) {
                if store.shelves[channel.guildID] == nil { await model.loadActivityShelf(guildID: channel.guildID) }
            }
        }
    }

    private func row(_ instance: EmbeddedActivityInstance, application: EmbeddedActivityApplication?) -> some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            ActivityIcon(url: application?.iconURL, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(application?.name ?? "Activity")
                    .font(.interface(.callout).weight(.semibold))
                Text("\(instance.participants.count) playing")
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Join Activity") {
                guard let application else { return }
                Task { await model.startActivity(application, in: channel) }
            }
            .buttonStyle(.glassProminent)
            .disabled(application == nil)
        }
        .padding(InterfaceScale.metric(10))
        .glassEffect(.regular, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))
    }
}

struct ActivityIcon: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Color.primary.opacity(0.08)
            .overlay {
                if let url { StaticRemoteImage(url: url, maximumPixelDimension: 128, contentMode: .fill) }
            }
            .frame(width: InterfaceScale.metric(size), height: InterfaceScale.metric(size))
            .clipShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(size / 4), style: .continuous))
    }
}

extension View {
    /// Questions an Activity's host asks before acting for it.
    func embeddedActivityPrompts(_ store: EmbeddedActivityStore) -> some View {
        alert(
            store.prompt.map(title) ?? "",
            isPresented: Binding(get: { store.prompt != nil }, set: { if !$0 { store.prompt?.resolve(false) } }),
            presenting: store.prompt
        ) { prompt in
            Button(prompt.confirmTitle) { prompt.resolve(true) }
            Button("Cancel", role: .cancel) { prompt.resolve(false) }
        } message: { prompt in
            switch prompt.kind {
            case .authorize(let scopes):
                Text("\(prompt.applicationName) wants to access your Discord account: \(scopes.joined(separator: ", ")).")
            case .openLink(let url):
                Text(url.absoluteString)
            case .confirmAge:
                Text("\(prompt.applicationName) is age-restricted. Confirm that you are 18 or older to continue.")
            }
        }
    }

    private func title(_ prompt: EmbeddedActivityStore.Prompt) -> String {
        switch prompt.kind {
        case .authorize: "Authorize \(prompt.applicationName)?"
        case .openLink: "Open a link from \(prompt.applicationName)?"
        case .confirmAge: "Start \(prompt.applicationName)?"
        }
    }
}

private extension EmbeddedActivityStore.Prompt {
    var confirmTitle: String {
        switch kind {
        case .authorize: "Authorize"
        case .openLink: "Open Link"
        case .confirmAge: "I’m 18 or Older"
        }
    }
}
