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

/// The voice-channel stage for an Activity: the running app, its launch
/// state, or an offer to join one already running in the channel.
struct EmbeddedActivityStage: View {
    let model: AppModel
    let channel: Channel

    var body: some View {
        let store = model.embeddedActivities
        if let session = store.session, session.location.channelID == channel.id {
            VStack(spacing: 0) {
                header(session)
                switch session.phase {
                case .running:
                    if let host = store.host {
                        EmbeddedActivityView(host: host)
                            .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous))
                    }
                case .launching:
                    status(ProgressView(), "Starting \(session.application.name)…")
                case .failed(let message):
                    status(Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange), message)
                }
            }
            .padding(InterfaceScale.metric(14))
        }
    }

    private func header(_ session: EmbeddedActivityStore.Session) -> some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            ActivityIcon(url: session.application.iconURL, size: 24)
            Text(session.application.name)
                .font(.interface(.headline))
            if let count = session.instance?.participants.count {
                Text(count == 1 ? "1 playing" : "\(count) playing")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Leave Activity", systemImage: "xmark") {
                model.leaveActivity()
            }
            .buttonStyle(.glass)
        }
        .padding(.bottom, InterfaceScale.metric(10))
    }

    private func status(_ icon: some View, _ text: String) -> some View {
        VStack(spacing: InterfaceScale.metric(10)) {
            icon
            Text(text)
                .font(.interface(.callout))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text(instance.participants.count == 1 ? "1 playing" : "\(instance.participants.count) playing")
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

/// The Activity shelf, opened from the voice controls.
struct ActivityShelfView: View {
    let model: AppModel
    let channel: Channel
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        let store = model.embeddedActivities
        let shelf = store.shelves[channel.guildID]
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            HStack {
                Text("Start an Activity")
                    .font(.interface(.title3).weight(.semibold))
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            TextField("Search Activities", text: $query)
                .textFieldStyle(.roundedBorder)
            if let shelf {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: InterfaceScale.metric(200)), spacing: InterfaceScale.metric(10))],
                        spacing: InterfaceScale.metric(10)
                    ) {
                        ForEach(filtered(shelf)) { application in
                            ActivityShelfTile(application: application) {
                                dismiss()
                                Task { await model.startActivity(application, in: channel) }
                            }
                        }
                    }
                }
            } else if let error = store.shelfError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(InterfaceScale.metric(14))
        .frame(width: InterfaceScale.metric(560), height: InterfaceScale.metric(560))
        .task(id: channel.guildID) { await model.loadActivityShelf(guildID: channel.guildID) }
    }

    private func filtered(_ shelf: [EmbeddedActivityApplication]) -> [EmbeddedActivityApplication] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return shelf }
        return shelf.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

private struct ActivityShelfTile: View {
    let application: EmbeddedActivityApplication
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Color.primary.opacity(0.06)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let cover = application.coverURL {
                            StaticRemoteImage(url: cover, maximumPixelDimension: 512, contentMode: .fill)
                        }
                    }
                    .clipped()
                HStack(spacing: InterfaceScale.metric(8)) {
                    ActivityIcon(url: application.iconURL, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(application.name)
                            .font(.interface(.callout).weight(.semibold))
                            .lineLimit(1)
                        Text(application.description)
                            .font(.interface(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(InterfaceScale.metric(8))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.04))
        .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(12), style: .continuous))
        .help(application.description)
        .accessibilityLabel(application.name)
    }
}

private struct ActivityIcon: View {
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
            Button(prompt.isAuthorization ? "Authorize" : "Open Link") { prompt.resolve(true) }
            Button("Cancel", role: .cancel) { prompt.resolve(false) }
        } message: { prompt in
            switch prompt.kind {
            case .authorize(let scopes):
                Text("\(prompt.applicationName) wants to access your Discord account: \(scopes.joined(separator: ", ")).")
            case .openLink(let url):
                Text(url.absoluteString)
            }
        }
    }

    private func title(_ prompt: EmbeddedActivityStore.Prompt) -> String {
        prompt.isAuthorization ? "Authorize \(prompt.applicationName)?" : "Open a link from \(prompt.applicationName)?"
    }
}

private extension EmbeddedActivityStore.Prompt {
    var isAuthorization: Bool {
        if case .authorize = kind { return true }
        return false
    }
}
