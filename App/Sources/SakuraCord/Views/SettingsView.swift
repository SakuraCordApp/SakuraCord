import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController

    @Environment(\.locale) private var locale
    @SceneStorage("settings.selected-page") private var storedSelectedPage =
        SettingsPageID.myAccount.rawValue
    @SceneStorage("settings.selected-account") private var storedSelectedAccount = ""
    @State private var state = SettingsViewState()
    private let navigationRouter = SettingsNavigationRouter.shared

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SettingsSidebar(state: state)
        } detail: {
            SettingsDetailRouter(
                model: model,
                updateController: updateController,
                state: state,
                selectedAccountID: $storedSelectedAccount
            )
        }
        .searchable(
            text: $state.searchText,
            placement: .sidebar,
            prompt: LocalizedStringResource(
                "Search Settings",
                bundle: #bundle,
                comment: "Prompt for the Settings sidebar search field."
            )
        )
        .searchSuggestions {
            SettingsSearchSuggestions(state: state)
        }
        .task {
            state.restoreSelection(from: storedSelectedPage)
            state.updateLocale(locale)
        }
        .task(id: navigationRouter.request?.id) {
            guard let request = navigationRouter.request else { return }
            state.navigate(
                to: request.destination,
                controlID: request.controlID
            )
            navigationRouter.consume(request.id)
        }
        .onChange(of: state.selectedPage) { _, page in
            storedSelectedPage = page.rawValue
        }
        .onChange(of: locale) { _, locale in
            state.updateLocale(locale)
        }
        .frame(
            minWidth: 760,
            idealWidth: 920,
            minHeight: 520,
            idealHeight: 640
        )
    }
}

private struct SettingsDetailRouter: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState
    @Binding var selectedAccountID: String

    var body: some View {
        switch state.selectedPage {
        case .myAccount:
            MyAccountSettingsPage(
                model: model,
                state: state,
                selectedAccountID: $selectedAccountID
            )
        case .general:
            GeneralSettingsPage(state: state, updateController: updateController)
        case .interface:
            InterfaceSettingsPage(state: state)
        case .chat:
            ChatSettingsPage(state: state)
        case .notifications:
            NotificationsSettingsPage(model: model, state: state)
        case .voiceVideo:
            VoiceVideoSettingsPage(model: model, state: state)
        case .accessibility:
            AccessibilitySettingsPage(state: state)
        case .keyboardShortcuts:
            KeyboardShortcutsSettingsPage(state: state)
        case .privacySafety:
            PrivacySafetySettingsPage(state: state)
        case .storageDownloads:
            StorageDownloadsSettingsPage(state: state)
        case .diagnostics:
            DiagnosticsSettingsPage(state: state)
        case .softwareUpdates:
            SoftwareUpdatesSettingsPage(state: state)
        case .extensions:
            ExtensionsSettingsPage(state: state)
        case .about:
            AboutSettingsPage(state: state)
        }
    }
}
