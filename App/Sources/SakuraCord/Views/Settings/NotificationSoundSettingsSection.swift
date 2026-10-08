import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotificationSoundSettingsSection: View {
    @Bindable var preferences: NotificationPreferences
    let soundPlayer: any AppSoundPlaying
    let state: SettingsViewState

    @State private var messageSelection = NotificationSoundLibrary.bundledID
    @State private var ringtoneSelection = NotificationSoundLibrary.bundledID
    @State private var systemSounds = NotificationSoundLibrary.systemAlertSoundNames
    @State private var previewingEffect: AppSoundEffect?
    @State private var previewResetTask: Task<Void, Never>?

    var body: some View {
        Section {
            HStack {
                Picker("Message sound", selection: $messageSelection) {
                    Text("Default").tag(NotificationSoundLibrary.bundledID)
                    ForEach(systemSounds, id: \.self) { name in
                        Text(name).tag(NotificationSoundLibrary.systemID(for: name))
                    }
                    if preferences.messageSoundBookmark != nil {
                        Text(
                            NotificationSoundLibrary.displayName(
                                soundID: NotificationSoundLibrary.customID,
                                customName: preferences.messageSoundName
                            )
                        )
                        .tag(NotificationSoundLibrary.customID)
                    }
                    Text("Choose File…").tag(NotificationSoundLibrary.chooseFileID)
                }
                previewButton(.message, help: "message sound")
            }
            .settingsControlAnchor(.notificationMessageSound, state: state)
            .onChange(of: messageSelection) { _, newValue in
                guard newValue != preferences.messageSoundID else { return }
                if newValue == NotificationSoundLibrary.chooseFileID {
                    chooseFile(for: .message)
                } else {
                    preferences.messageSoundID = newValue
                }
            }

            HStack {
                Picker("Call ringtone", selection: $ringtoneSelection) {
                    Text("Default").tag(NotificationSoundLibrary.bundledID)
                    ForEach(systemSounds, id: \.self) { name in
                        Text(name).tag(NotificationSoundLibrary.systemID(for: name))
                    }
                    if preferences.callRingtoneBookmark != nil {
                        Text(
                            NotificationSoundLibrary.displayName(
                                soundID: NotificationSoundLibrary.customID,
                                customName: preferences.callRingtoneName
                            )
                        )
                        .tag(NotificationSoundLibrary.customID)
                    }
                    Text("Choose File…").tag(NotificationSoundLibrary.chooseFileID)
                }
                previewButton(.callRinging, help: "call ringtone")
            }
            .settingsControlAnchor(.notificationCallRingtone, state: state)
            .onChange(of: ringtoneSelection) { _, newValue in
                guard newValue != preferences.callRingtoneID else { return }
                if newValue == NotificationSoundLibrary.chooseFileID {
                    chooseFile(for: .call)
                } else {
                    preferences.callRingtoneID = newValue
                }
            }
        } header: {
            Text("Sounds", bundle: #bundle)
        }
        .disabled(!preferences.playsSound)
        .onAppear {
            messageSelection = displayTag(
                stored: preferences.messageSoundID,
                bookmark: preferences.messageSoundBookmark
            )
            ringtoneSelection = displayTag(
                stored: preferences.callRingtoneID,
                bookmark: preferences.callRingtoneBookmark
            )
        }
        .onChange(of: preferences.messageSoundID) { _, newValue in
            let tag = displayTag(stored: newValue, bookmark: preferences.messageSoundBookmark)
            if messageSelection != tag { messageSelection = tag }
        }
        .onChange(of: preferences.callRingtoneID) { _, newValue in
            let tag = displayTag(stored: newValue, bookmark: preferences.callRingtoneBookmark)
            if ringtoneSelection != tag { ringtoneSelection = tag }
        }
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

    private func displayTag(stored: String, bookmark: Data?) -> String {
        if stored == NotificationSoundLibrary.bundledID {
            return stored
        }
        if stored == NotificationSoundLibrary.customID, bookmark != nil {
            return stored
        }
        if systemSounds.contains(where: { NotificationSoundLibrary.systemID(for: $0) == stored }) {
            return stored
        }
        return NotificationSoundLibrary.bundledID
    }

    private func revertSelection(for kind: NotificationSoundKind) {
        switch kind {
        case .message:
            messageSelection = displayTag(
                stored: preferences.messageSoundID,
                bookmark: preferences.messageSoundBookmark
            )
        case .call:
            ringtoneSelection = displayTag(
                stored: preferences.callRingtoneID,
                bookmark: preferences.callRingtoneBookmark
            )
        }
    }

    private func chooseFile(for kind: NotificationSoundKind) {
        Task {
            let panel = NSOpenPanel()
            panel.title = kind == .message ? "Choose Message Sound" : "Choose Call Ringtone"
            panel.prompt = "Choose"
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.audio]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            let response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
            guard response == .OK, let url = panel.url else {
                revertSelection(for: kind)
                return
            }
            do {
                let bookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                switch kind {
                case .message:
                    preferences.messageSoundBookmark = bookmark
                    preferences.messageSoundName = url.lastPathComponent
                    preferences.messageSoundID = NotificationSoundLibrary.customID
                    messageSelection = NotificationSoundLibrary.customID
                case .call:
                    preferences.callRingtoneBookmark = bookmark
                    preferences.callRingtoneName = url.lastPathComponent
                    preferences.callRingtoneID = NotificationSoundLibrary.customID
                    ringtoneSelection = NotificationSoundLibrary.customID
                }
            } catch {
                revertSelection(for: kind)
            }
        }
    }
}
