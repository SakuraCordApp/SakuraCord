import SwiftUI

struct SoftwareUpdatesSettingsPage: View {
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState
    @State private var navigationPath: [SoftwareUpdatesDestination] = []
    @State private var presentsBuildBrowser = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SettingsPageForm(page: .softwareUpdates, state: state) {
                SoftwareUpdateOverviewSection(
                    updateController: updateController,
                    state: state,
                    checkForUpdatesControlID: .checkForUpdates,
                    changelogControlID: .updateChangelog,
                    changelogDestination: SoftwareUpdatesDestination.changelog
                )

                Section {
                    if let buildID = updateController.installedPullRequestBuildID {
                        CurrentPullRequestBuildRow(buildID: buildID, updateController: updateController)
                    }
                    Button {
                        presentsBuildBrowser = true
                    } label: {
                        PullRequestBuildBrowseRow(isPullRequestBuild: updateController.installedPullRequestBuildID != nil)
                    }
                    .buttonStyle(.plain)
                    .settingsControlAnchor(.pullRequestBuilds, state: state)
                } header: {
                    Text("Try a pull request")
                }

                Section {
                    if updateController.installedPullRequestBuildID != nil {
                        LabeledContent("Release track", value: updateController.activeTrackTitle)
                            .settingsControlAnchor(.updateReleaseTrack, state: state)
                    } else {
                    Picker(
                        "Release track",
                        selection: Binding(
                            get: { updateController.releaseTrack },
                            set: { updateController.setReleaseTrack($0) }
                        )
                    ) {
                        ForEach(AppUpdateReleaseTrack.allCases) { track in
                            Label(track.title, systemImage: track.systemImage)
                                .tag(track)
                        }
                    }
                    .disabled(!updateController.isEnabled)
                    .settingsControlAnchor(.updateReleaseTrack, state: state)
                    }

                    Toggle(
                        "Automatically check for updates",
                        isOn: Binding(
                            get: { updateController.automaticallyChecksForUpdates },
                            set: { updateController.setAutomaticallyChecksForUpdates($0) }
                        )
                    )
                    .disabled(!updateController.isEnabled)
                    .settingsControlAnchor(.updateAutomaticChecks, state: state)

                    Toggle(
                        "Automatically download updates",
                        isOn: Binding(
                            get: { updateController.automaticallyDownloadsUpdates },
                            set: { updateController.setAutomaticallyDownloadsUpdates($0) }
                        )
                    )
                    .disabled(
                        !updateController.isEnabled
                            || !updateController.allowsAutomaticUpdates
                    )
                    .settingsControlAnchor(.updateAutomaticDownloads, state: state)
                } header: {
                    Text("Update preferences", bundle: #bundle)
                }

                if let reason = updateController.unavailabilityDescription {
                    Section {
                        UpdatesUnavailableNotice(reason: reason)
                    }
                }
            }
            .navigationDestination(for: SoftwareUpdatesDestination.self) { destination in
                switch destination {
                case .changelog:
                    AboutChangelogPage(
                        releaseNotes: AboutResources.packagedReleaseNotes
                    )
                }
            }
        }
        .onChange(of: state.revealRequest?.id) {
            guard state.revealRequest?.destination.page == .softwareUpdates else { return }
            navigationPath.removeAll()
        }
        .windowModal(isPresented: $presentsBuildBrowser, cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular) {
            PullRequestBuildBrowser(
                isPreview: ProcessInfo.processInfo.arguments.contains("--offline"),
                installedBuildID: updateController.installedPullRequestBuildID,
                updateController: updateController
            ) { build in
                Task { await updateController.installPullRequestBuild(build) }
            }
        }
        .alert("Build Switching", isPresented: Binding(
            get: { updateController.buildSwitchError != nil },
            set: { if !$0 { updateController.buildSwitchError = nil } }
        )) {
            Button("OK", role: .cancel) { updateController.buildSwitchError = nil }
        } message: {
            Text(updateController.buildSwitchError ?? "")
        }
    }
}

private enum SoftwareUpdatesDestination: Hashable {
    case changelog
}

/// Settings-row summary of the current PR track. The 32-point capsules sit on the
/// row's inset so they stay concentric with the grouped form's rounded rows.
private struct CurrentPullRequestBuildRow: View {
    let buildID: String
    @ObservedObject var updateController: AppUpdateController

    private struct BuildComponents {
        let pullRequest: String
        let run: String
        let attempt: String
    }

    private var components: BuildComponents? {
        guard let match = buildID.wholeMatch(of: /pr-(\d+)-run-(\d+)-attempt-(\d+)/) else { return nil }
        return BuildComponents(pullRequest: String(match.1), run: String(match.2), attempt: String(match.3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(12)) {
            HStack(spacing: InterfaceScale.metric(12)) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.interface(.body).weight(.semibold))
                    .foregroundStyle(SakuraCordAccentColor.labelOnFill)
                    .frame(width: InterfaceScale.metric(36), height: InterfaceScale.metric(36))
                    .glassEffect(.regular.tint(SakuraCordAccentColor.color), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                    if let components {
                        Text("Running PR #\(components.pullRequest)").font(.interface(.headline))
                        Text("Run \(components.run) · Attempt \(components.attempt)")
                            .font(.interface(.caption).monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("Running a PR build").font(.interface(.headline))
                        Text(buildID).font(.interface(.caption).monospaced()).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                Spacer(minLength: InterfaceScale.metric(8))
                Button {
                    Task { await updateController.revealRecoveryCopy() }
                } label: {
                    Image(systemName: "folder")
                        .font(.interface(.callout).weight(.medium))
                        .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .help("Show Recovery Copy in Finder")
                .accessibilityLabel("Show Recovery Copy in Finder")
            }
            GlassEffectContainer(spacing: InterfaceScale.metric(8)) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    ForEach(AppUpdateReleaseTrack.allCases) { track in
                        Button {
                            updateController.returnToRelease(track)
                        } label: {
                            Label("Return to \(track.title)…", systemImage: track.systemImage)
                                .font(.interface(.callout).weight(.semibold))
                                .padding(.horizontal, InterfaceScale.metric(12))
                                .frame(height: InterfaceScale.metric(32))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
            }
            .disabled(!updateController.canSwitchBuilds)
        }
        .padding(.vertical, InterfaceScale.metric(4))
    }
}

private struct PullRequestBuildBrowseRow: View {
    let isPullRequestBuild: Bool

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            Image(systemName: "arrow.triangle.branch")
                .font(.interface(.body).weight(.semibold))
                .foregroundStyle(SakuraCordAccentColor.color)
                .frame(width: InterfaceScale.metric(36), height: InterfaceScale.metric(36))
                .glassEffect(.regular, in: Circle())
                .accessibilityHidden(true)
            Text(isPullRequestBuild ? "Switch Pull Request Build…" : "Browse Pull Request Builds…")
                .font(.interface(.body).weight(.medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.interface(.caption).weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, InterfaceScale.metric(2))
        .contentShape(.rect)
    }
}

private struct UpdatesUnavailableNotice: View {
    let reason: String

    var body: some View {
        HStack(alignment: .center, spacing: InterfaceScale.metric(12)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.interface(.title3))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                Text("Updates Unavailable", bundle: #bundle)
                    .font(.interface(.headline))

                Text(reason)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, InterfaceScale.metric(4))
        .accessibilityElement(children: .combine)
    }
}
