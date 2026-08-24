import SwiftUI

struct AboutSettingsPage: View {
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState

    @Environment(\.openURL) private var openURL
    @State private var navigationPath: [AboutDestination] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            aboutOverview
                .navigationDestination(for: AboutDestination.self) { destination in
                    switch destination {
                    case .changelog:
                        AboutChangelogPage(
                            releaseNotes: AboutResources.packagedReleaseNotes
                        )
                    case .acknowledgements:
                        AboutAcknowledgementsPage(
                            acknowledgements: AboutResources.packagedAcknowledgements
                        )
                    }
                }
        }
        .onChange(of: state.revealRequest?.id) {
            guard state.revealRequest?.destination.page == .about else { return }
            navigationPath.removeAll()
        }
    }

    private var aboutOverview: some View {
        ScrollViewReader { proxy in
            Form {
                aboutHeader
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                updates
                projectLinks
                acknowledgements
            }
            .formStyle(.grouped)
            .task(id: state.revealRequest?.id) {
                guard let request = state.revealRequest,
                      request.destination.page == .about
                else { return }
                await Task.yield()
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(request.controlID, anchor: .center)
                }
            }
        }
        .navigationTitle(state.catalog.page(.about).title)
    }

    private var versionInformation: AboutVersionInformation {
        AboutVersionInformation()
    }

    private var aboutHeader: some View {
        VStack(spacing: 6) {
            Image("SakuraCordAboutLogo", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .accessibilityLabel("SakuraCord logo")

            Text("SakuraCord")
                .font(.title.bold())
                .foregroundStyle(.primary.opacity(0.86))

            Text(versionInformation.semanticVersionDisplay)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .settingsControlAnchor(.aboutVersionInformation, state: state)
    }

    private var updates: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SakuraCord Version", bundle: #bundle)
                        .font(.headline)

                    Text(updateVersionDisplay)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button("Check Now") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
                .accessibilityHint(updateController.availabilityDescription)
                .help(updateController.availabilityDescription)
                .settingsControlAnchor(.aboutCheckForUpdates, state: state)
            }

            NavigationLink(value: AboutDestination.changelog) {
                Label("Open Changelog", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityHint("Shows the release notes included with SakuraCord.")
            .settingsControlAnchor(.aboutChangelog, state: state)
        } header: {
            Text("Updates", bundle: #bundle)
        }
    }

    private var updateVersionDisplay: String {
        guard let semanticVersion = versionInformation.semanticVersion else {
            return versionInformation.semanticVersionDisplay
        }
        return "v\(semanticVersion)"
    }

    private var projectLinks: some View {
        Section {
            ForEach(AboutProjectLink.allCases) { link in
                Button {
                    openURL(link.url)
                } label: {
                    externalLinkLabel(link)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .settingsControlAnchor(link.controlID, state: state)
            }
        } header: {
            Text("External Links", bundle: #bundle)
        }
    }

    private func externalLinkLabel(_ link: AboutProjectLink) -> some View {
        HStack {
            Label {
                Text(link.title)
            } icon: {
                externalLinkIcon(link)
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func externalLinkIcon(_ link: AboutProjectLink) -> some View {
        switch link {
        case .website:
            Image(systemName: "globe")
        case .roadmap:
            Image(systemName: "map")
        case .source:
            Image("github", bundle: .module)
        case .support:
            Image("discord", bundle: .module)
        }
    }

    private var acknowledgements: some View {
        Section {
            NavigationLink(value: AboutDestination.acknowledgements) {
                Label("Third-Party Acknowledgements", systemImage: "doc.text")
            }
            .settingsControlAnchor(.aboutAcknowledgements, state: state)
        } footer: {
            disclaimer
        }
    }

    private var disclaimer: some View {
        Text(
            "SakuraCord is an independent project, is not affiliated with Discord, "
                + "and connects through an unsupported third-party client."
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .settingsControlAnchor(.aboutDisclaimer, state: state)
    }

}

private enum AboutDestination: Hashable {
    case changelog
    case acknowledgements
}
