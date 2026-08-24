import AppKit
import SwiftUI

struct AboutSettingsPage: View {
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState

    @State private var versionCopyMessage: String?
    @State private var acknowledgementsMessage: String?

    var body: some View {
        SettingsPageForm(page: .about, state: state) {
            aboutHeader
            versionActions
            projectLinks
            acknowledgements
            disclaimer
        }
    }

    private var versionInformation: AboutVersionInformation {
        AboutVersionInformation(releaseTrack: updateController.releaseTrack)
    }

    private var acknowledgementsURL: URL? {
        AboutResources.acknowledgementsURL(
            resourceURL: Bundle.main.resourceURL
        )
    }

    private var applicationIcon: NSImage {
        NSApp.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage(size: NSSize(width: 128, height: 128))
    }

    private var aboutHeader: some View {
        Section {
            HStack(spacing: 20) {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .accessibilityLabel("SakuraCord app icon")

                VStack(alignment: .leading, spacing: 5) {
                    Text("SakuraCord")
                        .font(.largeTitle.bold())
                    Text("Version \(versionInformation.semanticVersionDisplay)")
                    Text("Build \(versionInformation.buildNumberDisplay)")
                    Text("\(updateController.releaseTrack.title) release track")
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsControlAnchor(.aboutVersionInformation, state: state)
        }
    }

    private var versionActions: some View {
        Section {
            Button("Copy Version Information") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                versionCopyMessage = pasteboard.setString(
                    versionInformation.copyText,
                    forType: .string
                )
                    ? "Copied version information."
                    : "Version information could not be copied."
            }
            .settingsControlAnchor(.aboutCopyVersionInformation, state: state)

            LabeledContent("Update checking") {
                Text(updateController.availabilityDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button("Check for Updates…") {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
            .accessibilityHint(updateController.availabilityDescription)
            .settingsControlAnchor(.aboutCheckForUpdates, state: state)

            if let versionCopyMessage {
                Text(versionCopyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(versionCopyMessage)
            }
        } header: {
            Text("Version and updates", bundle: #bundle)
        } footer: {
            Text(
                "The copied format contains only SakuraCord’s semantic version, build number, and selected release track."
            )
        }
    }

    private var projectLinks: some View {
        Section {
            ForEach(AboutProjectLink.allCases) { link in
                Button {
                    ExternalLinkConfirmationPresenter.shared.present(
                        ExternalLinkSafetyPolicy.assess(link.url)
                    )
                } label: {
                    Label(link.title, systemImage: link.systemImage)
                }
                .buttonStyle(.link)
                .settingsControlAnchor(link.controlID, state: state)
            }
        } header: {
            Text("Project links", bundle: #bundle)
        } footer: {
            Text("SakuraCord shows and confirms each external destination before opening it.")
        }
    }

    private var acknowledgements: some View {
        Section {
            Button("Open Third-Party Acknowledgements…") {
                openAcknowledgements()
            }
            .disabled(acknowledgementsURL == nil)
            .accessibilityHint(
                acknowledgementsURL == nil
                    ? "The packaged acknowledgements resource is unavailable in this build."
                    : "Opens the notices file included in this app package."
            )
            .settingsControlAnchor(.aboutAcknowledgements, state: state)

            if let acknowledgementsMessage {
                Text(acknowledgementsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(acknowledgementsMessage)
            }
        } header: {
            Text("Acknowledgements", bundle: #bundle)
        } footer: {
            if acknowledgementsURL == nil {
                Text(
                    "The acknowledgements resource is unavailable in this build. Assembled SakuraCord app packages include it."
                )
            } else {
                Text("Opens the third-party notices included in this app package.")
            }
        }
    }

    private var disclaimer: some View {
        Section {
            Text(
                "SakuraCord is an independent project and is not affiliated with Discord. "
                    + "Discord does not provide a supported third-party platform for "
                    + "normal-account clients, so compatibility can change as Discord evolves."
            )
            .settingsControlAnchor(.aboutDisclaimer, state: state)
        } header: {
            Text("Independence", bundle: #bundle)
        }
    }

    private func openAcknowledgements() {
        guard let acknowledgementsURL else {
            acknowledgementsMessage =
                "Third-party acknowledgements are unavailable in this build."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            acknowledgementsURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                acknowledgementsMessage = error == nil
                    ? "Opened third-party acknowledgements."
                    : "Third-party acknowledgements could not be opened."
            }
        }
    }
}
