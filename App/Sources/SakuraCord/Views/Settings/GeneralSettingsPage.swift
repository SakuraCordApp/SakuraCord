import SwiftUI

struct GeneralSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @Environment(\.scenePhase) private var scenePhase
    @State private var launchAtLogin = LaunchAtLoginController()
    @State private var launchDestination = SettingsLaunchDestination
        .preferredAccountLastLocation
    @State private var showsMainWindowAtLaunch = true
    @State private var remembersMemberListVisibility = true
    @State private var confirmsQuitActiveWork = true
    @State private var confirmsDiscardComposer = true

    var body: some View {
        SettingsPageForm(page: .general, state: state) {
            GeneralStartupRestorationSection(
                launchAtLogin: launchAtLogin,
                launchDestination: launchDestinationBinding,
                showsMainWindowAtLaunch: preferenceBinding(
                    $showsMainWindowAtLaunch,
                    id: .showMainWindowAtLaunch
                ),
                remembersMemberListVisibility: rememberMemberListBinding,
                state: state
            )
            GeneralConfirmationSection(
                confirmsQuitActiveWork: preferenceBinding(
                    $confirmsQuitActiveWork,
                    id: .confirmQuitActiveWork
                ),
                confirmsDiscardComposer: preferenceBinding(
                    $confirmsDiscardComposer,
                    id: .confirmDiscardComposer
                ),
                state: state
            )
        }
        .task {
            loadPreferences()
            launchAtLogin.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                launchAtLogin.refresh()
            }
        }
    }

    private var launchDestinationBinding: Binding<SettingsLaunchDestination> {
        Binding(
            get: { launchDestination },
            set: { value in
                launchDestination = value
                SettingsPreferenceStore.shared.set(
                    .string(value.rawValue),
                    for: .launchDestination
                )
            }
        )
    }

    private var rememberMemberListBinding: Binding<Bool> {
        Binding(
            get: { remembersMemberListVisibility },
            set: { value in
                remembersMemberListVisibility = value
                SettingsPreferenceStore.shared.set(
                    .bool(value),
                    for: .rememberMemberListVisibility
                )
                if value {
                    GeneralWindowRestorationStore.shared
                        .recordMemberListVisibility(model.showInspector)
                }
            }
        )
    }

    private func preferenceBinding(
        _ state: Binding<Bool>,
        id: SettingsControlID
    ) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue },
            set: { value in
                state.wrappedValue = value
                SettingsPreferenceStore.shared.set(.bool(value), for: id)
            }
        )
    }

    private func loadPreferences() {
        if case let .string(value) = SettingsPreferenceStore.shared.value(
            for: .launchDestination
        ) {
            launchDestination = SettingsLaunchDestination(rawValue: value)
                ?? .preferredAccountLastLocation
        }
        showsMainWindowAtLaunch = boolPreference(.showMainWindowAtLaunch)
        remembersMemberListVisibility = boolPreference(
            .rememberMemberListVisibility
        )
        confirmsQuitActiveWork = boolPreference(.confirmQuitActiveWork)
        confirmsDiscardComposer = boolPreference(.confirmDiscardComposer)
    }

    private func boolPreference(_ id: SettingsControlID) -> Bool {
        SettingsPreferenceStore.shared.value(for: id) != .bool(false)
    }
}

private struct GeneralStartupRestorationSection: View {
    let launchAtLogin: LaunchAtLoginController
    @Binding var launchDestination: SettingsLaunchDestination
    @Binding var showsMainWindowAtLaunch: Bool
    @Binding var remembersMemberListVisibility: Bool
    let state: SettingsViewState

    var body: some View {
        @Bindable var launchAtLogin = launchAtLogin
        Section {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            .disabled(launchAtLogin.isChanging || !launchAtLogin.isAvailable)
            .settingsControlAnchor(.launchAtLogin, state: state)

            LabeledContent("Login item status") {
                Text(launchAtLogin.statusDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if launchAtLogin.requiresApproval {
                Button("Open Login Items Settings…") {
                    launchAtLogin.openSystemSettings()
                }
            }

            if let errorMessage = launchAtLogin.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Launch destination", selection: $launchDestination) {
                ForEach(SettingsLaunchDestination.allCases) { destination in
                    Text(destination.title).tag(destination)
                }
            }
            .settingsControlAnchor(.launchDestination, state: state)

            Text(launchDestination.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                "Show the main window at launch",
                isOn: $showsMainWindowAtLaunch
            )
            .settingsControlAnchor(.showMainWindowAtLaunch, state: state)

            Toggle(
                "Remember member list visibility",
                isOn: $remembersMemberListVisibility
            )
            .settingsControlAnchor(.rememberMemberListVisibility, state: state)
        } header: {
            Text("Startup and restoration", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Window launch changes take effect the next time SakuraCord starts.")
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }
}

private struct GeneralConfirmationSection: View {
    @Binding var confirmsQuitActiveWork: Bool
    @Binding var confirmsDiscardComposer: Bool
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle(
                "Confirm quitting during active work",
                isOn: $confirmsQuitActiveWork
            )
            .settingsControlAnchor(.confirmQuitActiveWork, state: state)

            Toggle(
                "Confirm discarding composer changes",
                isOn: $confirmsDiscardComposer
            )
            .settingsControlAnchor(.confirmDiscardComposer, state: state)
        } header: {
            Text("Confirmations", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Ordinary quitting stays immediate. Saved message drafts are never discarded by these prompts."
                )
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }
}
