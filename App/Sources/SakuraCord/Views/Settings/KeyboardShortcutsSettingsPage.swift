import SwiftUI
import UniformTypeIdentifiers

struct KeyboardShortcutsSettingsPage: View {
    private struct Conflict: Identifiable {
        let action: KeyboardShortcutAction
        let existingAction: KeyboardShortcutAction
        let shortcut: KeyboardShortcutChord
        var id: String { "\(action.rawValue):\(existingAction.rawValue)" }
    }

    private enum ResetRequest: Identifiable {
        case group(KeyboardShortcutGroup)
        case all

        var id: String {
            switch self {
            case let .group(group): "group:\(group.rawValue)"
            case .all: "all"
            }
        }
    }

    let state: SettingsViewState
    private let shortcuts = KeyboardShortcutSettingsStore.shared
    @State private var messages: [KeyboardShortcutAction: String] = [:]
    @State private var conflict: Conflict?
    @State private var resetRequest: ResetRequest?
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var operationMessage: String?

    var body: some View {
        SettingsPageForm(page: .keyboardShortcuts, state: state) {
            ForEach(KeyboardShortcutGroup.allCases) { group in
                shortcutSection(group)
            }
            localDataSection
        }
        .alert(
            "Shortcut Already Used",
            isPresented: Binding(
                get: { conflict != nil },
                set: { if !$0 { conflict = nil } }
            ),
            presenting: conflict
        ) { conflict in
            Button("Replace \(conflict.existingAction.localizedTitle)") {
                replaceConflict(conflict)
            }
            Button("Cancel", role: .cancel) {
                self.conflict = nil
            }
        } message: { conflict in
            Text("\(conflict.shortcut.displayName) is assigned to \(conflict.existingAction.localizedTitle). Replacing it will clear that action and assign it to \(conflict.action.localizedTitle).")
        }
        .confirmationDialog(
            resetTitle,
            isPresented: Binding(
                get: { resetRequest != nil },
                set: { if !$0 { resetRequest = nil } }
            )
        ) {
            Button(resetButtonTitle, role: .destructive) {
                performReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores the selected app-wide shortcuts. macOS keyboard settings are not changed.")
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: "SakuraCord-Keyboard-Shortcuts-v1"
        ) { result in
            switch result {
            case .success:
                operationMessage = "Exported Keyboard Shortcuts."
            case let .failure(error):
                operationMessage = "Export failed: \(error.localizedDescription)"
            }
            exportedPreferences = nil
        } onCancellation: {
            exportedPreferences = nil
        }
    }

    private func shortcutSection(_ group: KeyboardShortcutGroup) -> some View {
        Section {
            ForEach(actions(in: group)) { action in
                shortcutRow(action)
            }
        } header: {
            HStack {
                Text(group.title)
                Spacer()
                Button("Reset Section…") {
                    resetRequest = .group(group)
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .accessibilityLabel("Reset \(String(localized: group.title)) shortcuts…")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if group == .messaging {
                    Text("Send Message and Insert Newline apply only inside SakuraCord's composer. Return behavior remains controlled by Chat settings.")
                } else if group == .voiceVideo {
                    Text("Voice and video commands are unavailable until a call is active.")
                }
            }
        }
    }

    private func shortcutRow(_ action: KeyboardShortcutAction) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                KeyboardShortcutRecorder(
                    actionTitle: action.localizedTitle,
                    shortcut: shortcuts.shortcut(for: action),
                    capture: { assign($0, to: action) },
                    clear: { clear(action) },
                    cancel: {}
                )
                .frame(width: 142)

                Button {
                    shortcuts.reset(action)
                    messages[action] = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset \(action.localizedTitle)")
                .accessibilityLabel("Reset \(action.localizedTitle)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text(rowDetail(action))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = messages[action] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Shortcut error: \(message)")
                }
            }
        }
        .settingsControlAnchor(action.controlID, state: state)
    }

    private var localDataSection: some View {
        Section {
            HStack {
                Button("Export Shortcuts…") {
                    exportedPreferences = SettingsPreferenceExportFile(
                        export: SettingsPreferenceStore.shared.export(
                            scope: .appWide,
                            page: .keyboardShortcuts
                        )
                    )
                    isExporting = true
                }
                .settingsControlAnchor(.shortcutExport, state: state)

                Button("Reset All…", role: .destructive) {
                    resetRequest = .all
                }
                .settingsControlAnchor(.shortcutReset, state: state)
            }
            if let operationMessage {
                Text(operationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(operationMessage)
            }
        } header: {
            Text("Local Data", bundle: #bundle)
        } footer: {
            Text("Shortcuts work only while SakuraCord is active. Global system-wide shortcuts are not registered.")
        }
    }

    private func actions(
        in group: KeyboardShortcutGroup
    ) -> [KeyboardShortcutAction] {
        KeyboardShortcutAction.allCases.filter { $0.group == group }
    }

    private func rowDetail(_ action: KeyboardShortcutAction) -> String {
        if action.registersMenuShortcut {
            return shortcuts.shortcut(for: action) == nil
                ? "Unassigned; its menu command remains available."
                : "The corresponding menu command updates immediately."
        }
        return "Composer only; not registered as an app-wide menu equivalent."
    }

    private func assign(
        _ shortcut: KeyboardShortcutChord,
        to action: KeyboardShortcutAction
    ) {
        switch KeyboardShortcutValidator.validate(
            shortcut,
            for: action,
            shortcuts: shortcuts.shortcuts
        ) {
        case .valid:
            shortcuts.set(shortcut, for: action)
            messages[action] = nil
        case let .conflict(existingAction):
            conflict = Conflict(
                action: action,
                existingAction: existingAction,
                shortcut: shortcut
            )
        case let .invalid(message):
            messages[action] = message
        }
    }

    private func clear(_ action: KeyboardShortcutAction) {
        shortcuts.set(nil, for: action)
        messages[action] = nil
    }

    private func replaceConflict(_ conflict: Conflict) {
        shortcuts.set(nil, for: conflict.existingAction)
        shortcuts.set(conflict.shortcut, for: conflict.action)
        messages[conflict.existingAction] = nil
        messages[conflict.action] = nil
        self.conflict = nil
    }

    private var resetTitle: String {
        switch resetRequest {
        case let .group(group): "Reset \(String(localized: group.title)) Shortcuts?"
        case .all: "Reset All Keyboard Shortcuts?"
        case nil: "Reset Keyboard Shortcuts?"
        }
    }

    private var resetButtonTitle: String {
        switch resetRequest {
        case let .group(group): "Reset \(String(localized: group.title))"
        case .all: "Reset All Shortcuts"
        case nil: "Reset"
        }
    }

    private func performReset() {
        let request = resetRequest
        resetRequest = nil
        switch request {
        case let .group(group):
            shortcuts.reset(group)
            for action in actions(in: group) { messages[action] = nil }
            operationMessage = "Restored \(String(localized: group.title)) shortcuts."
        case .all:
            shortcuts.resetAll()
            messages = [:]
            operationMessage = "Restored all keyboard shortcuts."
        case nil:
            break
        }
    }
}
