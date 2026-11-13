import SwiftUI

struct GeneralSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState
    let launchAtLogin: LaunchAtLoginController

    @Environment(\.scenePhase) private var scenePhase
    @State private var launchDestination: SettingsLaunchDestination
    @State private var confirmsQuitActiveWork: Bool

    init(model: AppModel, state: SettingsViewState, launchAtLogin: LaunchAtLoginController) {
        self.model = model
        self.state = state
        self.launchAtLogin = launchAtLogin
        let preferences = SettingsPreferenceStore.shared
        let destination = if case let .string(value) = preferences.value(for: .launchDestination) {
            SettingsLaunchDestination(rawValue: value) ?? .lastVisitedConversation
        } else {
            SettingsLaunchDestination.lastVisitedConversation
        }
        _launchDestination = State(initialValue: destination)
        _confirmsQuitActiveWork = State(
            initialValue: preferences.value(for: .confirmQuitActiveWork) != .bool(false)
        )
    }

    var body: some View {
        SettingsPageForm(page: .general, state: state) {
            GeneralStartupSection(
                launchAtLogin: launchAtLogin,
                launchDestination: $launchDestination,
                state: state
            )
            GeneralInputSettingsSection(
                value: Binding(
                    get: { model.generalInputSettings },
                    set: { model.applyGeneralInputSettings($0) }
                ),
                state: state
            )
            Section {
                Toggle("Confirm quitting during calls or uploads", isOn: $confirmsQuitActiveWork)
                    .settingsControlAnchor(.confirmQuitActiveWork, state: state)
            } header: {
                Text("Confirmation", bundle: #bundle)
            }
        }
        .task { await launchAtLogin.refreshIfNeeded() }
        .onChange(of: launchDestination) { _, value in
            SettingsPreferenceStore.shared.set(.string(value.rawValue), for: .launchDestination)
        }
        .onChange(of: confirmsQuitActiveWork) { _, value in
            SettingsPreferenceStore.shared.set(.bool(value), for: .confirmQuitActiveWork)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await launchAtLogin.refresh() }
            }
        }
    }
}

private struct GeneralStartupSection: View {
    let launchAtLogin: LaunchAtLoginController
    @Binding var launchDestination: SettingsLaunchDestination
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { enabled in
                        Task { await launchAtLogin.setEnabled(enabled) }
                    }
                )
            )
            .disabled(launchAtLogin.isChanging || !launchAtLogin.isAvailable)
            .settingsControlAnchor(.launchAtLogin, state: state)

            if launchAtLogin.requiresApproval {
                Button("Approve in Login Items Settings…") {
                    launchAtLogin.openSystemSettings()
                }
            }
            if let errorMessage = launchAtLogin.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            Picker("Launch destination", selection: $launchDestination) {
                ForEach(SettingsLaunchDestination.allCases) { destination in
                    Text(destination.title).tag(destination)
                }
            }
            .settingsControlAnchor(.launchDestination, state: state)
        } header: {
            Text("Startup", bundle: #bundle)
        }
    }
}
