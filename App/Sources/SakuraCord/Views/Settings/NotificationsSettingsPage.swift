import SwiftUI

struct NotificationsSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var notificationPermission = "Checking…"

    var body: some View {
        let preferences = model.notificationPreferences
        SettingsPageForm(page: .notifications, state: state) {
            NotificationDeliverySettingsSection(
                model: model,
                preferences: preferences,
                permissionDescription: $notificationPermission,
                state: state
            )
            NotificationQuietHoursSettingsSection(
                preferences: preferences,
                state: state
            )
        }
        .task { await updateNotificationPermission() }
        .onChange(of: preferences.showsDockBadge) {
            model.refreshDockBadge()
        }
    }

    private func updateNotificationPermission() async {
        notificationPermission = await Self.permissionDescription(model: model)
    }

    private static func permissionDescription(model: AppModel) async -> String {
        switch await model.notificationAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Denied in System Settings"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
}

private struct NotificationDeliverySettingsSection: View {
    let model: AppModel
    let preferences: NotificationPreferences
    @Binding var permissionDescription: String
    let state: SettingsViewState

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            LabeledContent("System permission") {
                Text(permissionDescription)
                    .foregroundStyle(.secondary)
                Button("Request Permission") {
                    Task {
                        _ = await model.requestNotificationPermission()
                        permissionDescription =
                            switch await model.notificationAuthorizationStatus() {
                            case .authorized, .provisional, .ephemeral: "Allowed"
                            case .denied: "Denied in System Settings"
                            case .notDetermined: "Not requested"
                            @unknown default: "Unknown"
                            }
                    }
                }
            }
            .settingsControlAnchor(.notificationPermission, state: state)

            Toggle("Enable native notifications", isOn: $preferences.isEnabled)
                .settingsControlAnchor(.notificationEnabled, state: state)

            Picker("Notification previews", selection: $preferences.previewStyle) {
                ForEach(NotificationPreviewStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .settingsControlAnchor(.notificationPreview, state: state)

            Toggle("Play sound", isOn: $preferences.playsSound)
                .settingsControlAnchor(.notificationSound, state: state)

            Toggle("Show unread mentions in Dock", isOn: $preferences.showsDockBadge)
                .settingsControlAnchor(.notificationDockBadge, state: state)
        } header: {
            Text("System delivery", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                SettingsScopeFooter(scope: .appWideLocal)
                Text("Discord’s server and channel notification settings remain authoritative. These controls only narrow local macOS presentation.")
            }
        }
    }
}

private struct NotificationQuietHoursSettingsSection: View {
    let preferences: NotificationPreferences
    let state: SettingsViewState

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Toggle("Quiet hours", isOn: $preferences.quietHoursEnabled)
                .settingsControlAnchor(.notificationQuietHours, state: state)

            if preferences.quietHoursEnabled {
                Stepper(
                    "Start: \(preferences.quietStartHour):00",
                    value: $preferences.quietStartHour,
                    in: 0 ... 23
                )
                .settingsControlAnchor(.notificationQuietStart, state: state)

                Stepper(
                    "End: \(preferences.quietEndHour):00",
                    value: $preferences.quietEndHour,
                    in: 0 ... 23
                )
                .settingsControlAnchor(.notificationQuietEnd, state: state)
            }
        } header: {
            Text("Quiet hours", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }
}
