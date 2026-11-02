import AppKit
import SwiftUI
import UserNotifications

struct NotificationsSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var authorizationStatus: UNAuthorizationStatus?
    @State private var isRequestingPermission = false
    @State private var showsResetConfirmation = false
    @State private var operationMessage: String?

    var body: some View {
        let preferences = model.notificationPreferences
        SettingsPageForm(page: .notifications, state: state) {
            NotificationDeliverySettingsSection(
                preferences: preferences,
                state: state,
                requestPermission: requestPermission,
                authorizationStatus: authorizationStatus
            )
            NotificationSoundSettingsSection(
                preferences: preferences,
                soundPlayer: model.soundPlayer,
                state: state
            )
            NotificationEventSettingsSection(preferences: preferences, state: state)
            NotificationPermissionSettingsSection(
                authorizationStatus: authorizationStatus,
                isRequestingPermission: isRequestingPermission,
                state: state,
                requestPermission: requestPermission,
                openSystemSettings: openSystemSettings
            )
            Section {
                Button("Reset All…", role: .destructive) {
                    showsResetConfirmation = true
                }
                .settingsControlAnchor(.notificationReset, state: state)
            }
        }
        .task { await updateAuthorizationStatus() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await updateAuthorizationStatus() }
        }
        .onChange(of: preferences.dockBadgeStyle) { model.refreshDockBadge() }
        .onChange(of: [
            preferences.isEnabled, preferences.playsSound, preferences.notifiesIncomingCalls,
        ]) { model.reconcilePrivateCallSounds() }
        .settingsResetConfirmation(
            "Reset Notification Settings?",
            isPresented: $showsResetConfirmation,
            resetTitle: "Reset Notification Settings",
            message: "This restores SakuraCord’s local notification preferences. macOS authorization and Discord’s server and channel settings are unchanged.",
            reset: resetPreferences
        )
        .alert(
            "Notifications",
            isPresented: Binding(
                get: { operationMessage != nil },
                set: { if !$0 { operationMessage = nil } }
            )
        ) {
            Button("OK") { operationMessage = nil }
        } message: {
            Text(operationMessage ?? "")
        }
    }

    private func updateAuthorizationStatus() async {
        authorizationStatus = await model.notificationAuthorizationStatus()
    }

    private func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        Task {
            defer { isRequestingPermission = false }
            do {
                _ = try await model.requestNotificationPermission()
            } catch {
                operationMessage = error.localizedDescription
            }
            await updateAuthorizationStatus()
        }
    }

    private func openSystemSettings() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let url = URL(
                  string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)"
              ),
              NSWorkspace.shared.open(url)
        else {
            operationMessage = "System Settings could not be opened. Open Notifications in System Settings manually."
            return
        }
    }

    private func resetPreferences() {
        SettingsPreferenceStore.shared.reset(scope: .appWide, page: .notifications)
        model.notificationPreferences.reload()
        model.refreshDockBadge()
    }
}

private struct NotificationDeliverySettingsSection: View {
    let preferences: NotificationPreferences
    let state: SettingsViewState
    let requestPermission: () -> Void
    let authorizationStatus: UNAuthorizationStatus?

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Toggle("Desktop notifications", isOn: Binding(
                get: { preferences.isEnabled },
                set: { enabled in
                    preferences.isEnabled = enabled
                    if enabled, authorizationStatus == .notDetermined {
                        requestPermission()
                    }
                }
            ))
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationEnabled, state: state)

            Toggle("Notification sound", isOn: $preferences.playsSound)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationSound, state: state)

            Picker("Notification previews", selection: $preferences.previewStyle) {
                ForEach(NotificationPreviewStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .disabled(!preferences.isEnabled)
            .settingsControlAnchor(.notificationPreview, state: state)

            Picker("Dock badge", selection: $preferences.dockBadgeStyle) {
                ForEach(NotificationDockBadgeStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .settingsControlAnchor(.notificationDockBadge, state: state)
        } header: {
            Text("Notifications", bundle: #bundle)
        }
        .help("macOS notification permissions and Focus settings also apply.")
    }

}

private struct NotificationPermissionSettingsSection: View {
    let authorizationStatus: UNAuthorizationStatus?
    let isRequestingPermission: Bool
    let state: SettingsViewState
    let requestPermission: () -> Void
    let openSystemSettings: () -> Void

    var body: some View {
        Section {
            SettingsPermissionRow(title: "Notifications", status: permissionDescription) {
                if authorizationStatus == nil || isRequestingPermission {
                    ProgressView().controlSize(.small)
                } else if authorizationStatus == .notDetermined {
                    Button("Allow Notifications…", action: requestPermission)
                } else {
                    Button("Open System Settings…", action: openSystemSettings)
                }
            }
            .settingsControlAnchor(.notificationPermission, state: state)
        } header: {
            Text("Permissions", bundle: #bundle)
        }
    }

    private var permissionDescription: String {
        switch authorizationStatus {
        case .authorized, .ephemeral: "Allowed"
        case .provisional: "Deliver quietly"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case nil: "Checking…"
        @unknown default: "Unknown"
        }
    }
}

private struct NotificationEventSettingsSection: View {
    let preferences: NotificationPreferences
    let state: SettingsViewState

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Grid(alignment: .leading, horizontalSpacing: InterfaceScale.metric(24), verticalSpacing: InterfaceScale.metric(10)) {
                GridRow {
                    Toggle("Direct messages", isOn: $preferences.notifiesDirectMessages)
                        .settingsControlAnchor(.notificationDirectMessages, state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Group messages", isOn: $preferences.notifiesGroupDirectMessages)
                        .settingsControlAnchor(.notificationGroupDirectMessages, state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Toggle("Server mentions", isOn: $preferences.notifiesMentions)
                        .settingsControlAnchor(.notificationMentions, state: state)
                    Toggle("Server replies", isOn: $preferences.notifiesReplies)
                        .settingsControlAnchor(.notificationReplies, state: state)
                }
                GridRow {
                    Toggle("Server messages", isOn: $preferences.notifiesServerActivity)
                        .help("Other server messages, following each server and channel’s Discord notification settings.")
                        .settingsControlAnchor(.notificationServerActivity, state: state)
                    Toggle("Incoming calls", isOn: $preferences.notifiesIncomingCalls)
                        .settingsControlAnchor(.notificationIncomingCalls, state: state)
                }
            }
            .toggleStyle(.checkbox)
            .tint(SakuraCordAccentColor.color)
        } header: {
            Text("Notify About", bundle: #bundle)
        }
        .disabled(!preferences.isEnabled && !preferences.playsSound)

        Section {
            Group {
                Toggle(
                    "Skip the conversation I’m reading",
                    isOn: $preferences.suppressesCurrentConversation
                )
                .settingsControlAnchor(.notificationSuppressCurrent, state: state)
                Toggle("Group notifications by conversation", isOn: $preferences.groupsByConversation)
                    .disabled(!preferences.isEnabled)
                    .settingsControlAnchor(.notificationGroupBursts, state: state)
                Toggle("Clear notifications when read", isOn: $preferences.clearsWhenRead)
                    .disabled(!preferences.isEnabled)
                    .settingsControlAnchor(.notificationClearWhenRead, state: state)

            }
            .tint(SakuraCordAccentColor.color)
        } header: {
            Text("Delivery", bundle: #bundle)
        }
        .disabled(!preferences.isEnabled && !preferences.playsSound)
    }
}
