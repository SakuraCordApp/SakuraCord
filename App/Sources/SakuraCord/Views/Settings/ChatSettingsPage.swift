import SwiftUI
import UniformTypeIdentifiers

struct ChatSettingsPage: View {
    private enum Confirmation: String, Identifiable {
        case reset

        var id: String { rawValue }
    }

    let model: AppModel
    let state: SettingsViewState

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var value = ChatSettingsSnapshot.defaults
    @State private var confirmation: Confirmation?
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var operationMessage: String?

    var body: some View {
        SettingsPageForm(page: .chat, state: state) {
            composerSection
            messagesSection
            mediaSection
            emojiSection
            localDataSection
        }
        .task {
            value = model.chatSettings
        }
        .onChange(of: value) { _, newValue in
            model.applyChatSettings(newValue)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            )
        ) {
            if let confirmation {
                Button(confirmationButtonTitle, role: .destructive) {
                    perform(confirmation)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: "SakuraCord-Chat-Settings-v1"
        ) { result in
            switch result {
            case .success:
                operationMessage = "Exported Chat settings."
            case let .failure(error):
                operationMessage = "Export failed: \(error.localizedDescription)"
            }
            exportedPreferences = nil
        } onCancellation: {
            exportedPreferences = nil
        }
    }

    private var composerSection: some View {
        Section {
            Toggle("Press Return to send messages", isOn: $value.sendsWithReturn)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.sendWithReturn, state: state)

            Text(
                value.sendsWithReturn
                    ? "Return sends; Shift-Return inserts a newline."
                    : "Return inserts a newline; Command-Return sends."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Check spelling while typing", isOn: $value.checksSpelling)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.chatSpellCheck, state: state)
            Toggle(
                "Correct spelling automatically",
                isOn: $value.correctsSpellingAutomatically
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.chatAutomaticCorrection, state: state)
            Toggle("Smart quotes", isOn: $value.usesSmartQuotes)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.chatSmartQuotes, state: state)
            Toggle("Smart dashes", isOn: $value.usesSmartDashes)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.chatSmartDashes, state: state)
            Toggle("Send typing indicators", isOn: $value.sendsTypingIndicators)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.chatTypingIndicators, state: state)
            Toggle(
                "Focus composer when printable typing begins",
                isOn: $value.focusesComposerOnTyping
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.chatFocusComposerOnTyping, state: state)

            LabeledContent("Character limit") {
                Text("Shown only within 200 characters of Discord’s effective limit")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .settingsControlAnchor(.chatCharacterCounter, state: state)

            Button("Open Discard Confirmation in General…") {
                state.navigate(
                    to: SettingsDestination(page: .general, section: .confirmations),
                    controlID: .confirmDiscardComposer
                )
            }
            .settingsControlAnchor(.chatDiscardConfirmationLink, state: state)
        } header: {
            Text("Composer", bundle: #bundle)
        } footer: {
            Text("Drafts remain saved by the existing conversation draft store.")
        }
    }

    private var messagesSection: some View {
        Section {
            Picker("Mark messages read", selection: $value.readAcknowledgementMode) {
                ForEach(ChatReadAcknowledgementMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .settingsControlAnchor(.chatReadAcknowledgement, state: state)

            Text(
                value.readAcknowledgementMode == .automatic
                    ? "SakuraCord acknowledges content only after the active timeline is meaningfully visible."
                    : "Unread state remains until you use an explicit Mark Read action."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Show edited markers", isOn: $value.showsEditedMarkers)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.chatEditedMarkers, state: state)
            Toggle("Expand embeds by default", isOn: $value.expandsEmbedsByDefault)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.chatExpandEmbeds, state: state)
            Picker("Reveal spoilers", selection: $value.spoilerRevealMode) {
                ForEach(ChatSpoilerRevealMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .settingsControlAnchor(.chatSpoilerReveal, state: state)
            Toggle(
                "Open Discord channel links in SakuraCord",
                isOn: $value.opensDiscordLinksInternally
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.chatInternalDiscordLinks, state: state)
        } header: {
            Text("Messages", bundle: #bundle)
        } footer: {
            Text("Read acknowledgements synchronize through Discord and affect unread state in other clients.")
        }
    }

    private var mediaSection: some View {
        Section {
            Toggle("Autoplay GIFs", isOn: $value.autoplaysGIFs)
                .tint(SakuraCordAccentColor.color)
                .disabled(reducesGIFPlaybackForAccessibility)
                .settingsControlAnchor(.chatAutoplayGIFs, state: state)
            Toggle(
                "Autoplay animated stickers",
                isOn: $value.autoplaysAnimatedStickers
            )
            .tint(SakuraCordAccentColor.color)
            .disabled(reducesStickerPlaybackForAccessibility)
            .settingsControlAnchor(.chatAutoplayStickers, state: state)
            Toggle("Autoplay inline videos", isOn: $value.autoplaysInlineVideos)
                .tint(SakuraCordAccentColor.color)
                .disabled(reducesAllOptionalMotionForAccessibility)
                .settingsControlAnchor(.chatAutoplayVideos, state: state)
            Toggle(
                "Show automatic link previews",
                isOn: $value.showsAutomaticLinkPreviews
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.chatLinkPreviews, state: state)
            Picker("Inline media size", selection: $value.inlineMediaSize) {
                ForEach(ChatInlineMediaSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .settingsControlAnchor(.chatInlineMediaSize, state: state)
            Toggle("Reduce animated media", isOn: $value.reducesAnimatedMedia)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.reduceAnimatedMedia, state: state)
        } header: {
            Text("Media", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS Reduce Motion—and the broader SakuraCord Accessibility reduction when enabled—takes precedence over autoplay choices.")
                if reducesGIFPlaybackForAccessibility
                    || reducesStickerPlaybackForAccessibility
                    || reducesAllOptionalMotionForAccessibility
                {
                    Text("One or more autoplay choices are unavailable while the stronger Accessibility motion reduction is active.")
                }
            }
        }
    }

    private var reducesGIFPlaybackForAccessibility: Bool {
        model.accessibilitySettings.reducesAnimation(
            .gif,
            systemReduceMotion: systemReduceMotion
        )
    }

    private var reducesStickerPlaybackForAccessibility: Bool {
        model.accessibilitySettings.reducesAnimation(
            .sticker,
            systemReduceMotion: systemReduceMotion
        )
    }

    private var reducesAllOptionalMotionForAccessibility: Bool {
        model.accessibilitySettings.reducesAllOptionalMotion(
            systemReduceMotion: systemReduceMotion
        )
    }

    private var emojiSection: some View {
        Section {
            Picker("Default emoji skin tone", selection: $value.emojiSkinTone) {
                ForEach(NativeEmojiSkinTone.allCases) { tone in
                    Text("\(tone.symbol)  \(tone.title)").tag(tone)
                }
            }
            .settingsControlAnchor(.chatEmojiSkinTone, state: state)

            LabeledContent("Favorites and frequency") {
                Text(emojiSourceDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .settingsControlAnchor(.chatEmojiSource, state: state)

            Button("Manage Local Emoji Data in Privacy & Safety…") {
                state.navigate(
                    to: SettingsDestination(
                        page: .privacySafety,
                        section: .privacyLocalData
                    ),
                    controlID: .clearEmojiRanking
                )
            }
            .settingsControlAnchor(.chatEmojiPrivacyLink, state: state)
        } header: {
            Text("Emoji", bundle: #bundle)
        } footer: {
            Text("Discord favorites and frequency remain untouched by the two local cleanup actions.")
        }
    }

    private var localDataSection: some View {
        Section {
            HStack {
                Button("Export Chat Settings…", action: exportPreferences)
                    .settingsControlAnchor(.chatExport, state: state)
                Button("Reset Chat Settings…", role: .destructive) {
                    confirmation = .reset
                }
                .settingsControlAnchor(.chatReset, state: state)
            }
            if let operationMessage {
                Text(operationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Local data", bundle: #bundle)
        } footer: {
            Text("Reset and export cover registered app-wide Chat preferences only. Drafts, emoji history, and Discord data are separate.")
        }
    }

    private var emojiSourceDescription: String {
        if model.hasLoadedDiscordEmojiSettings,
           !model.discordFavoriteEmojiKeys.isEmpty
                || !model.discordFrequentlyUsedEmojiKeys.isEmpty
        {
            return "Discord, with local recents as a fallback"
        }
        if model.hasLoadedDiscordEmojiSettings {
            return "Local fallback; Discord returned no saved ordering"
        }
        return "Local fallback; Discord settings are not loaded"
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .reset: "Reset Chat Settings?"
        case nil: "Confirm Chat Action"
        }
    }

    private var confirmationButtonTitle: String {
        switch confirmation {
        case .reset: "Reset Chat Settings"
        case nil: "Confirm"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .reset:
            "This restores registered Chat preferences. Drafts, credentials, local emoji history, and Discord data are unchanged."
        case nil:
            "No action has been selected."
        }
    }

    private func perform(_ confirmation: Confirmation) {
        self.confirmation = nil
        switch confirmation {
        case .reset:
            SettingsPreferenceStore.shared.reset(scope: .appWide, page: .chat)
            value = ChatSettingsStore.shared.load()
            model.applyChatSettings(value, persists: false)
            operationMessage = "Restored Chat settings to their defaults."
        }
    }

    private func exportPreferences() {
        exportedPreferences = SettingsPreferenceExportFile(
            export: SettingsPreferenceStore.shared.export(
                scope: .appWide,
                page: .chat
            )
        )
        isExporting = true
    }
}
