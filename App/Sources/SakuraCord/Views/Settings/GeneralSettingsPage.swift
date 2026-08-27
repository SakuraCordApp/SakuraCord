import SwiftUI

struct GeneralSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState
    let launchAtLogin: LaunchAtLoginController

    @Environment(\.scenePhase) private var scenePhase
    @State private var launchDestination: SettingsLaunchDestination
    @State private var showsMainWindowAtLaunch: Bool
    @State private var remembersMemberListVisibility: Bool
    @State private var confirmsQuitActiveWork: Bool
    @State private var confirmsDiscardComposer: Bool

    init(
        model: AppModel,
        state: SettingsViewState,
        launchAtLogin: LaunchAtLoginController
    ) {
        self.model = model
        self.state = state
        self.launchAtLogin = launchAtLogin
        let preferences = SettingsPreferenceStore.shared
        let launchDestination = if case let .string(value) = preferences.value(
            for: .launchDestination
        ) {
            SettingsLaunchDestination(rawValue: value) ?? .preferredAccountLastLocation
        } else {
            SettingsLaunchDestination.preferredAccountLastLocation
        }
        _launchDestination = State(initialValue: launchDestination)
        _showsMainWindowAtLaunch = State(
            initialValue: preferences.value(for: .showMainWindowAtLaunch) != .bool(false)
        )
        _remembersMemberListVisibility = State(
            initialValue: preferences.value(for: .rememberMemberListVisibility) != .bool(false)
        )
        _confirmsQuitActiveWork = State(
            initialValue: preferences.value(for: .confirmQuitActiveWork) != .bool(false)
        )
        _confirmsDiscardComposer = State(
            initialValue: preferences.value(for: .confirmDiscardComposer) != .bool(false)
        )
    }

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
        .task { await launchAtLogin.refreshIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await launchAtLogin.refresh() }
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
                    set: { enabled in
                        Task { await launchAtLogin.setEnabled(enabled) }
                    }
                )
            )
            .tint(SakuraCordAccentColor.color)
            .disabled(launchAtLogin.isChanging || !launchAtLogin.isAvailable)
            .settingsControlAnchor(.launchAtLogin, state: state)

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
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.showMainWindowAtLaunch, state: state)

            Toggle(
                "Remember member list visibility",
                isOn: $remembersMemberListVisibility
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.rememberMemberListVisibility, state: state)
        } header: {
            Text("Startup and restoration", bundle: #bundle)
        } footer: {
            Text("Window launch changes take effect the next time SakuraCord starts.")
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
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.confirmQuitActiveWork, state: state)

            Toggle(
                "Confirm discarding composer changes",
                isOn: $confirmsDiscardComposer
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.confirmDiscardComposer, state: state)
        } header: {
            Text("Confirmations", bundle: #bundle)
        } footer: {
            Text(
                "Ordinary quitting stays immediate. Saved message drafts are never discarded by these prompts."
            )
        }
    }
}
