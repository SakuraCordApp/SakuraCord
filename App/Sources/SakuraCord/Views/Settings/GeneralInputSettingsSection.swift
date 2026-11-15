import SwiftUI

struct GeneralInputSettingsSection: View {
    @Binding var value: GeneralInputSettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        textInputSection
        emojiSection
    }

    private var textInputSection: some View {
        Section {
            Picker("Send messages with", selection: $value.sendsWithReturn) {
                Text("Return", bundle: #bundle).tag(true)
                Text("⌘Return", bundle: #bundle).tag(false)
            }
            .settingsControlAnchor(.sendWithReturn, state: state)
            Toggle("Check spelling while typing", isOn: $value.checksSpelling)
                .settingsControlAnchor(.spellCheck, state: state)
            Toggle(
                "Correct spelling automatically",
                isOn: $value.correctsSpellingAutomatically
            )
            .settingsControlAnchor(.automaticCorrection, state: state)
            Toggle("Smart quotes", isOn: $value.usesSmartQuotes)
                .settingsControlAnchor(.smartQuotes, state: state)
            Toggle("Smart dashes", isOn: $value.usesSmartDashes)
                .settingsControlAnchor(.smartDashes, state: state)
        } header: {
            Text("Text Input", bundle: #bundle)
        }
    }

    private var emojiSection: some View {
        Section {
            Picker("Default emoji skin tone", selection: $value.emojiSkinTone) {
                ForEach(NativeEmojiSkinTone.allCases) { tone in
                    Text("\(tone.symbol)  \(tone.title)").tag(tone)
                }
            }
            .settingsControlAnchor(.emojiSkinTone, state: state)
        } header: {
            Text("Emoji", bundle: #bundle)
        }
    }
}
