import SwiftUI

struct TranslationSettingsSection: View {
    let model: AppModel
    let state: SettingsViewState
    @State private var server = ""
    @State private var apiKey = ""
    @State private var apiKeyError: String?
    @State private var isSavingAPIKey = false

    var body: some View {
        let value = Binding(
            get: { model.translation.settings },
            set: { model.applyTranslationSettings($0) }
        )
        let provider = value.wrappedValue.provider
        Section {
            Picker("Translation provider", selection: value.provider) {
                ForEach(TranslationProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .settingsControlAnchor(.translationProvider, state: state)
            if provider == .libreTranslate {
                TextField("LibreTranslate server", text: $server, prompt: Text(TranslationServerAddress.defaultLibreTranslate))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit { value.wrappedValue.libreTranslateServer = normalizedServer }
                    .settingsControlAnchor(.translationServer, state: state)
            }
            if provider != .off {
                apiKeyField(for: provider)
                    .settingsControlAnchor(.translationAPIKey, state: state)
            }
            languagePicker("Translate messages into", selection: value.messageLanguage)
                .disabled(provider == .off)
                .settingsControlAnchor(.translationMessageLanguage, state: state)
            languagePicker("Translate drafts into", selection: value.draftLanguage)
                .disabled(provider == .off)
                .settingsControlAnchor(.translationDraftLanguage, state: state)
        } header: {
            Text("Translation", bundle: #bundle)
        } footer: {
            Text(footer(for: provider))
        }
        .task {
            server = model.translation.settings.libreTranslateServer
            await model.translation.refreshSavedAPIKeys()
        }
        .onDisappear {
            if model.translation.settings.libreTranslateServer != normalizedServer {
                value.wrappedValue.libreTranslateServer = normalizedServer
            }
        }
    }

    private var normalizedServer: String {
        server.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func apiKeyField(for provider: TranslationProvider) -> some View {
        let isSaved = model.translation.savedAPIKeyProviders.contains(provider)
        return LabeledContent {
            HStack(spacing: 8) {
                SecureField(
                    "API key",
                    text: $apiKey,
                    prompt: Text(isSaved ? "Saved in Keychain" : provider.requiresAPIKey ? "Required" : "Optional")
                )
                .labelsHidden()
                .onSubmit { saveAPIKey(for: provider) }
                Button("Save") { saveAPIKey(for: provider) }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingAPIKey)
                if isSaved {
                    Button("Remove", role: .destructive) {
                        apiKey = ""
                        saveAPIKey(for: provider)
                    }
                    .disabled(isSavingAPIKey)
                }
            }
        } label: {
            Text("\(provider.displayName) API key")
            if let apiKeyError {
                Text(apiKeyError).foregroundStyle(.red)
            }
        }
    }

    private func languagePicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("System Language (\(TranslationLanguage.resolved("").displayName()))").tag("")
            Divider()
            ForEach(TranslationLanguage.sortedCases) { language in
                Text(language.displayName()).tag(language.rawValue)
            }
        }
    }

    private func saveAPIKey(for provider: TranslationProvider) {
        let key = apiKey
        isSavingAPIKey = true
        apiKeyError = nil
        Task {
            do {
                try await model.saveTranslationAPIKey(key, for: provider)
                apiKey = ""
            } catch {
                apiKeyError = error.localizedDescription
            }
            isSavingAPIKey = false
        }
    }

    private func footer(for provider: TranslationProvider) -> String {
        switch provider {
        case .off:
            "Translate messages from their context menu and drafts from the + menu or Message menu."
        case .deepL:
            "Text is sent to DeepL only when you choose Translate. Free API keys ending in “:fx” use DeepL’s free endpoint automatically."
        case .libreTranslate:
            "Text is sent to your LibreTranslate server only when you choose Translate. Leave the address empty to use a server on this Mac."
        }
    }
}
