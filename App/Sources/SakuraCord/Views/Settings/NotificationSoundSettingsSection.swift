import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotificationSoundSettingsSection: View {
    @Bindable var preferences: NotificationPreferences
    let soundPlayer: any AppSoundPlaying
    let state: SettingsViewState

    @State private var selections: [NotificationSoundKind: String] = [:]
    @State private var previewingEffect: AppSoundEffect?
    @State private var previewResetTask: Task<Void, Never>?
    @State private var unplayableFileName: String?
    private let systemSounds = NotificationSoundLibrary.systemAlertSoundNames

    var body: some View {
        Section {
            soundPicker(.message, title: "Message sound", help: "message sound", control: .notificationMessageSound)
            soundPicker(.call, title: "Call ringtone", help: "call ringtone", control: .notificationCallRingtone)
        } header: {
            Text("Sounds", bundle: #bundle)
        }
        .disabled(!preferences.playsSound)
        .onAppear {
            for kind in NotificationSoundKind.allCases { syncSelection(kind) }
        }
        .onChange(of: preferences.playsSound) { _, playsSound in
            if !playsSound { stopPreview() }
        }
        .onDisappear { stopPreview() }
        // Covers Reset and Import as well as the pickers.
        .onChange(of: preferences.soundChoice(for: .message)) { choiceChanged(.message) }
        .onChange(of: preferences.soundChoice(for: .call)) { choiceChanged(.call) }
        .alert(
            "Can’t Use “\(unplayableFileName ?? "")”",
            isPresented: Binding(
                get: { unplayableFileName != nil },
                set: { if !$0 { unplayableFileName = nil } }
            )
        ) {
            Button("OK") { unplayableFileName = nil }
        } message: {
            Text("SakuraCord can’t play this file. Choose a different sound.", bundle: #bundle)
        }
    }

    private func soundPicker(
        _ kind: NotificationSoundKind,
        title: LocalizedStringKey,
        help: String,
        control: SettingsControlID
    ) -> some View {
        let selection = Binding(
            get: { selections[kind] ?? NotificationSoundLibrary.bundledID },
            set: { newValue in
                selections[kind] = newValue
                if newValue == NotificationSoundLibrary.chooseFileID {
                    chooseFile(for: kind)
                } else {
                    preferences.setSoundID(newValue, for: kind)
                }
            }
        )
        let customName = preferences.soundName(for: kind)
        return HStack {
            Picker(title, selection: selection) {
                Text("Default").tag(NotificationSoundLibrary.bundledID)
                ForEach(systemSounds, id: \.self) { name in
                    Text(name).tag(NotificationSoundLibrary.systemID(for: name))
                }
                if preferences.soundChoice(for: kind).bookmark != nil {
                    Text(customName.isEmpty ? "Custom file" : customName)
                        .tag(NotificationSoundLibrary.customID)
                }
                Text("Choose File…").tag(NotificationSoundLibrary.chooseFileID)
            }
            previewButton(kind.defaultEffect, help: help)
        }
        .settingsControlAnchor(control, state: state)
    }

    private func previewButton(_ effect: AppSoundEffect, help: String) -> some View {
        let isPreviewing = previewingEffect == effect
        return Button {
            togglePreview(effect)
        } label: {
            Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderless)
        .help(isPreviewing ? "Stop \(help)" : "Preview \(help)")
    }

    private func togglePreview(_ effect: AppSoundEffect) {
        previewResetTask?.cancel()
        guard let duration = soundPlayer.togglePreview(effect) else {
            previewingEffect = nil
            return
        }
        previewingEffect = effect
        previewResetTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            previewingEffect = nil
        }
    }

    private func stopPreview() {
        previewResetTask?.cancel()
        soundPlayer.stopPreview()
        previewingEffect = nil
    }

    private func choiceChanged(_ kind: NotificationSoundKind) {
        if previewingEffect == kind.defaultEffect { stopPreview() }
        syncSelection(kind)
    }

    /// Points the picker at the stored choice, or Default when the picker has no row for it.
    private func syncSelection(_ kind: NotificationSoundKind) {
        let choice = preferences.soundChoice(for: kind)
        let hasRow =
            choice.soundID == NotificationSoundLibrary.bundledID
            || (choice.soundID == NotificationSoundLibrary.customID && choice.bookmark != nil)
            || systemSounds.contains { NotificationSoundLibrary.systemID(for: $0) == choice.soundID }
        selections[kind] = hasRow ? choice.soundID : NotificationSoundLibrary.bundledID
    }

    private func chooseFile(for kind: NotificationSoundKind) {
        Task {
            let panel = NSOpenPanel()
            panel.title = kind == .message ? "Choose Message Sound" : "Choose Call Ringtone"
            panel.prompt = "Choose"
            panel.allowsMultipleSelection = false
            // Movies are allowed for their audio track.
            panel.allowedContentTypes = [.audio, .audiovisualContent]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            if await panel.begin() == .OK, let url = panel.url {
                if NotificationSoundLibrary.makePlayer(at: url) == nil {
                    unplayableFileName = url.lastPathComponent
                } else if let bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    preferences.setCustomSound(bookmark: bookmark, name: url.lastPathComponent, for: kind)
                }
            }
            syncSelection(kind)
        }
    }
}
