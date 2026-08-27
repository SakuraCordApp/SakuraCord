import AppKit
import SwiftUI
import UserNotifications

struct NotificationsSettingsPage: View {
    private enum Confirmation {
        case reset
    }

    let model: AppModel
    let state: SettingsViewState

    @State private var authorizationStatus: UNAuthorizationStatus?
    @State private var confirmation: Confirmation?
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var operationMessage: String?

    var body: some View {
        let preferences = model.notificationPreferences
        SettingsPageForm(page: .notifications, state: state) {
            NotificationDeliverySettingsSection(
                preferences: preferences,
                authorizationStatus: authorizationStatus,
                state: state,
                requestPermission: requestPermission,
                openSystemSettings: openSystemSettings
            )
            NotificationEventSettingsSection(preferences: preferences, state: state)
            NotificationQuietHoursSettingsSection(preferences: preferences, state: state)
            Section {
                Button("Export Notification Settings…") { exportPreferences() }
                    .settingsControlAnchor(.notificationExport, state: state)
                Button("Reset Notification Settings…", role: .destructive) {
                    confirmation = .reset
                }
                .settingsControlAnchor(.notificationReset, state: state)
            } header: {
                Text("Local data", bundle: #bundle)
            }
        }
        .task { await updateAuthorizationStatus() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await updateAuthorizationStatus() }
        }
        .onChange(of: preferences.dockBadgeStyle) { model.refreshDockBadge() }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: "SakuraCord-Notification-Settings"
        ) { result in
            if case let .failure(error) = result {
                operationMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Reset Notification Settings?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reset Notification Settings", role: .destructive) { resetPreferences() }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text("This restores SakuraCord’s local notification preferences. macOS authorization and Discord’s server and channel settings are unchanged.")
        }
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
        Task {
            _ = await model.requestNotificationPermission()
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

    private func exportPreferences() {
        exportedPreferences = SettingsPreferenceExportFile(
            export: SettingsPreferenceStore.shared.export(
                scope: .appWide,
                page: .notifications
            )
        )
        isExporting = true
    }

    private func resetPreferences() {
        confirmation = nil
        SettingsPreferenceStore.shared.reset(scope: .appWide, page: .notifications)
        model.notificationPreferences.reload()
        model.refreshDockBadge()
        operationMessage = "Restored Notification settings to their defaults."
    }
}

private struct NotificationDeliverySettingsSection: View {
    let preferences: NotificationPreferences
    let authorizationStatus: UNAuthorizationStatus?
    let state: SettingsViewState
    let requestPermission: () -> Void
    let openSystemSettings: () -> Void

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            LabeledContent("System permission") {
                Text(permissionDescription)
                    .foregroundStyle(.secondary)
                if authorizationStatus == nil {
                    ProgressView()
                        .controlSize(.small)
                } else if authorizationStatus == .notDetermined {
                    Button("Request Permission", action: requestPermission)
                } else {
                    Button("Open System Settings", action: openSystemSettings)
                }
            }
            .settingsControlAnchor(.notificationPermission, state: state)

            Toggle("Enable native notifications", isOn: $preferences.isEnabled)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationEnabled, state: state)

            Picker("Notification previews", selection: $preferences.previewStyle) {
                ForEach(NotificationPreviewStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .settingsControlAnchor(.notificationPreview, state: state)

            Toggle("Play sound", isOn: $preferences.playsSound)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationSound, state: state)

            Picker("Dock badge", selection: $preferences.dockBadgeStyle) {
                ForEach(NotificationDockBadgeStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .settingsControlAnchor(.notificationDockBadge, state: state)

            LabeledContent("macOS Focus") {
                Text("Always respected")
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.notificationFocus, state: state)
        } header: {
            Text("System delivery", bundle: #bundle)
        } footer: {
            Text("Sounds and banners use standard active Notification Center delivery, so macOS notification and Focus settings remain authoritative.")
        }
    }

    private var permissionDescription: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: "Allowed"
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
            Group {
                Toggle("Direct messages", isOn: $preferences.notifiesDirectMessages)
                    .settingsControlAnchor(.notificationDirectMessages, state: state)
                Toggle("Group direct messages", isOn: $preferences.notifiesGroupDirectMessages)
                    .settingsControlAnchor(.notificationGroupDirectMessages, state: state)
                Toggle("Mentions", isOn: $preferences.notifiesMentions)
                    .settingsControlAnchor(.notificationMentions, state: state)
                Toggle("Replies", isOn: $preferences.notifiesReplies)
                    .settingsControlAnchor(.notificationReplies, state: state)
                Toggle("Incoming calls", isOn: $preferences.notifiesIncomingCalls)
                    .settingsControlAnchor(.notificationIncomingCalls, state: state)
                Toggle("Server activity", isOn: $preferences.notifiesServerActivity)
                    .settingsControlAnchor(.notificationServerActivity, state: state)
            }
            .tint(SakuraCordAccentColor.color)

            Divider()

            Group {
                Toggle("Notify only in the background", isOn: $preferences.notifiesOnlyInBackground)
                    .settingsControlAnchor(.notificationOnlyInBackground, state: state)
                Toggle(
                    "Suppress the current conversation",
                    isOn: $preferences.suppressesCurrentConversation
                )
                .settingsControlAnchor(.notificationSuppressCurrent, state: state)
                Toggle("Group bursts by conversation", isOn: $preferences.groupsByConversation)
                    .settingsControlAnchor(.notificationGroupBursts, state: state)
                Toggle("Clear notifications when read", isOn: $preferences.clearsWhenRead)
                    .settingsControlAnchor(.notificationClearWhenRead, state: state)
                Toggle(
                    "Let calls bypass message suppression",
                    isOn: $preferences.callsBypassMessageSuppression
                )
                .settingsControlAnchor(.notificationCallsBypassSuppression, state: state)
            }
            .tint(SakuraCordAccentColor.color)

            LabeledContent("Discord notification controls") {
                Text("Server and conversation context menus")
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.notificationDiscordOwnership, state: state)
        } header: {
            Text("Events and behavior", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("These controls only narrow events already eligible under Discord’s synchronized notification and mute settings.")
                Text("Change server, category, and channel controls from their existing right-click context menus.")
            }
        }
    }
}

private struct NotificationQuietHoursSettingsSection: View {
    private struct WeekdayDisplay: Identifiable {
        let value: Int
        let shortName: String
        let fullName: String

        var id: Int { value }
    }

    let preferences: NotificationPreferences
    let state: SettingsViewState

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Toggle("Quiet hours", isOn: $preferences.quietHoursEnabled)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationQuietHours, state: state)

            if preferences.quietHoursEnabled {
                LabeledContent("Enabled days") {
                    HStack(spacing: 4) {
                        ForEach(orderedWeekdays) { day in
                            Toggle(
                                day.shortName,
                                isOn: quietDayBinding(day.value)
                            )
                            .tint(SakuraCordAccentColor.color)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .accessibilityLabel(day.fullName)
                        }
                    }
                }
                .settingsControlAnchor(.notificationQuietDays, state: state)

                DatePicker(
                    "Weekdays start",
                    selection: timeBinding(\.weekdayQuietStartMinutes),
                    displayedComponents: .hourAndMinute
                )
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationQuietStart, state: state)
                DatePicker(
                    "Weekdays end",
                    selection: timeBinding(\.weekdayQuietEndMinutes),
                    displayedComponents: .hourAndMinute
                )
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationQuietEnd, state: state)
                DatePicker(
                    "Weekends start",
                    selection: timeBinding(\.weekendQuietStartMinutes),
                    displayedComponents: .hourAndMinute
                )
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationWeekendQuietStart, state: state)
                DatePicker(
                    "Weekends end",
                    selection: timeBinding(\.weekendQuietEndMinutes),
                    displayedComponents: .hourAndMinute
                )
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationWeekendQuietEnd, state: state)

                Toggle(
                    "Allow direct messages",
                    isOn: $preferences.allowsDirectMessagesDuringQuietHours
                )
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationAllowDirectMessages, state: state)
                Toggle(
                    "Allow incoming calls",
                    isOn: $preferences.allowsCallsDuringQuietHours
                )
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.notificationAllowCalls, state: state)
            }
        } header: {
            Text("Quiet hours", bundle: #bundle)
        } footer: {
            Text("Ranges use the Mac’s current calendar and time zone. Overnight ranges continue into the following day; matching start and end means quiet for the entire enabled day.")
        }
    }

    private var orderedWeekdays: [WeekdayDisplay] {
        let calendar = Calendar.autoupdatingCurrent
        let indexes = (0 ..< 7).map { offset in
            ((calendar.firstWeekday - 1 + offset) % 7) + 1
        }
        return indexes.map { weekday in
            WeekdayDisplay(
                value: weekday,
                shortName: calendar.veryShortWeekdaySymbols[weekday - 1],
                fullName: calendar.weekdaySymbols[weekday - 1]
            )
        }
    }

    private func quietDayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { preferences.quietDays.contains(weekday) },
            set: { isEnabled in
                if isEnabled {
                    preferences.quietDays.insert(weekday)
                } else {
                    preferences.quietDays.remove(weekday)
                }
            }
        )
    }

    private func timeBinding(
        _ keyPath: ReferenceWritableKeyPath<NotificationPreferences, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                Self.date(minutes: preferences[keyPath: keyPath])
            },
            set: { date in
                let components = Calendar.autoupdatingCurrent.dateComponents(
                    [.hour, .minute],
                    from: date
                )
                preferences[keyPath: keyPath] =
                    (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private static func date(minutes: Int) -> Date {
        Calendar.autoupdatingCurrent.date(
            from: DateComponents(hour: minutes / 60, minute: minutes % 60)
        ) ?? .now
    }
}
