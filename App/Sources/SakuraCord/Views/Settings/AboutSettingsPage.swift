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
        .settingsNavigationPathResetOnReveal($navigationPath, page: .about, state: state)
    }

    private var aboutOverview: some View {
        SettingsPageForm(page: .about, state: state) {
            aboutHeader
                .padding(.horizontal, InterfaceScale.metric(32))
                .padding(.vertical, InterfaceScale.metric(8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            SoftwareUpdateOverviewSection(
                updateController: updateController,
                state: state,
                checkForUpdatesControlID: .aboutCheckForUpdates,
                changelogControlID: .aboutChangelog,
                changelogDestination: AboutDestination.changelog
            )
            projectLinks
            acknowledgements
        }
    }

    private var versionInformation: AboutVersionInformation {
        AboutVersionInformation()
    }

    private var aboutHeader: some View {
        VStack(spacing: InterfaceScale.metric(6)) {
            Image("SakuraCordAboutLogo", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: InterfaceScale.metric(80), height: InterfaceScale.metric(80))
                .accessibilityLabel("SakuraCord logo")

            Text("SakuraCord")
                .font(.interface(.title).bold())
                .foregroundStyle(.primary.opacity(0.86))

            Text(versionInformation.prefixedDisplay)
                .font(.interface(.subheadline).weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .settingsControlAnchor(.aboutVersionInformation, state: state)
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
                .font(.interface(.caption).weight(.semibold))
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
        case .sponsor:
            Image(systemName: "heart")
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
        .font(.interface(.caption))
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
