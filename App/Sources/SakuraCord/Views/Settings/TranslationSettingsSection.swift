import SwiftUI

struct TranslationSettingsSection: View {
    let model: AppModel
    let state: SettingsViewState

    var body: some View {
        let value = Binding(get: { model.translation.settings }, set: { model.applyTranslationSettings($0) })
        let languages = model.translation.coordinator.languages
        Section {
            Toggle("Enable on-device translation", isOn: value.isEnabled)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.translationEnabled, state: state)
            languagePicker("Translate messages into", selection: value.messageLanguage, languages: languages.supported)
                .settingsControlAnchor(.translationMessageLanguage, state: state)
            languagePicker("Translate drafts into", selection: value.draftLanguage, languages: languages.supported)
                .settingsControlAnchor(.translationDraftLanguage, state: state)
        } header: {
            Text("Translation", bundle: #bundle)
        } footer: {
            Text("""
            Apple Translation processes text on this Mac. Translating may ask permission to download language models.
            Apple may collect framework usage and performance metrics, excluding the original and translated text.
            Nothing is translated merely by enabling this setting.
            """)
        }
        .task { await languages.refresh() }
    }

    private func languagePicker(_ title: LocalizedStringKey, selection: Binding<String>, languages: [TranslationLanguage]) -> some View {
        Picker(title, selection: selection) {
            Text("System Language").tag("")
            if !selection.wrappedValue.isEmpty, !languages.contains(where: { $0.id == selection.wrappedValue }) {
                let match = TranslationLanguages.match(selection.wrappedValue, supported: languages)
                Text(match?.displayName() ?? "Unavailable: \(selection.wrappedValue)").tag(selection.wrappedValue)
            }
            ForEach(languages) { language in
                Text(language.displayName()).tag(language.id)
            }
        }
    }
}
