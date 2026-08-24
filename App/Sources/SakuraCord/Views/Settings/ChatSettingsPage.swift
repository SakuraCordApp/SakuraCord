import SwiftUI
import UniformTypeIdentifiers

struct ChatSettingsPage: View {
    private enum Confirmation: String, Identifiable {
        case clearRecents
        case clearRanking
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
                .settingsControlAnchor(.sendWithReturn, state: state)

            Text(
                value.sendsWithReturn
                    ? "Return sends; Shift-Return inserts a newline."
                    : "Return inserts a newline; Command-Return sends."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Check spelling while typing", isOn: $value.checksSpelling)
                .settingsControlAnchor(.chatSpellCheck, state: state)
            Toggle(
                "Correct spelling automatically",
                isOn: $value.correctsSpellingAutomatically
            )
            .settingsControlAnchor(.chatAutomaticCorrection, state: state)
            Toggle("Smart quotes", isOn: $value.usesSmartQuotes)
                .settingsControlAnchor(.chatSmartQuotes, state: state)
            Toggle("Smart dashes", isOn: $value.usesSmartDashes)
                .settingsControlAnchor(.chatSmartDashes, state: state)
            Toggle("Send typing indicators", isOn: $value.sendsTypingIndicators)
                .settingsControlAnchor(.chatTypingIndicators, state: state)
            Toggle(
                "Focus composer when printable typing begins",
                isOn: $value.focusesComposerOnTyping
            )
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Drafts remain saved by the existing conversation draft store.")
                SettingsScopeFooter(scope: .appWideLocal)
            }
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
                .settingsControlAnchor(.chatEditedMarkers, state: state)
            Toggle("Expand embeds by default", isOn: $value.expandsEmbedsByDefault)
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
            .settingsControlAnchor(.chatInternalDiscordLinks, state: state)
        } header: {
            Text("Messages", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Read acknowledgements synchronize through Discord and affect unread state in other clients.")
                SettingsScopeFooter(scope: .mixed)
            }
        }
    }

    private var mediaSection: some View {
        Section {
            Toggle("Autoplay GIFs", isOn: $value.autoplaysGIFs)
                .disabled(reducesGIFPlaybackForAccessibility)
                .settingsControlAnchor(.chatAutoplayGIFs, state: state)
            Toggle(
                "Autoplay animated stickers",
                isOn: $value.autoplaysAnimatedStickers
            )
            .disabled(reducesStickerPlaybackForAccessibility)
            .settingsControlAnchor(.chatAutoplayStickers, state: state)
            Toggle("Autoplay inline videos", isOn: $value.autoplaysInlineVideos)
                .disabled(reducesAllOptionalMotionForAccessibility)
                .settingsControlAnchor(.chatAutoplayVideos, state: state)
            Toggle(
                "Show automatic link previews",
                isOn: $value.showsAutomaticLinkPreviews
            )
            .settingsControlAnchor(.chatLinkPreviews, state: state)
            Picker("Inline media size", selection: $value.inlineMediaSize) {
                ForEach(ChatInlineMediaSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .settingsControlAnchor(.chatInlineMediaSize, state: state)
            Toggle("Reduce animated media", isOn: $value.reducesAnimatedMedia)
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
                SettingsScopeFooter(scope: .appWideLocal)
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

            HStack {
                Button("Clear Local Recents…") {
                    confirmation = .clearRecents
                }
                .settingsControlAnchor(.chatClearEmojiRecents, state: state)
                Button("Reset Learned Ranking…") {
                    confirmation = .clearRanking
                }
                .settingsControlAnchor(.chatClearEmojiRanking, state: state)
            }
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
        case .clearRecents: "Clear Local Emoji Recents?"
        case .clearRanking: "Reset Learned Emoji Ranking?"
        case .reset: "Reset Chat Settings?"
        case nil: "Confirm Chat Action"
        }
    }

    private var confirmationButtonTitle: String {
        switch confirmation {
        case .clearRecents: "Clear Local Recents"
        case .clearRanking: "Reset Learned Ranking"
        case .reset: "Reset Chat Settings"
        case nil: "Confirm"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .clearRecents:
            "This clears only the ordered local recent-emoji list on this Mac."
        case .clearRanking:
            "This clears only SakuraCord’s local emoji usage counts."
        case .reset:
            "This restores registered Chat preferences. Drafts, credentials, local emoji history, and Discord data are unchanged."
        case nil:
            "No action has been selected."
        }
    }

    private func perform(_ confirmation: Confirmation) {
        self.confirmation = nil
        switch confirmation {
        case .clearRecents:
            model.clearLocalEmojiRecents()
            operationMessage = "Cleared local emoji recents."
        case .clearRanking:
            model.resetLocalEmojiRanking()
            operationMessage = "Reset local emoji ranking."
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
