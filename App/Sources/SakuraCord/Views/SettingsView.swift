import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController

    @Environment(\.locale) private var locale
    @Environment(\.colorSchemeContrast) private var systemColorSchemeContrast
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
            .contrast(
                model.accessibilitySettings.increasesContrast
                    && systemColorSchemeContrast == .standard
                    ? 1.12
                    : 1
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
        .background(SettingsWindowToolbarStyleBridge())
        .onKeyPress(.return) {
            state.activateFirstSearchResult() ? .handled : .ignored
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

/// Keeps the SwiftUI Settings scene on AppKit's standard unified toolbar.
private struct SettingsWindowToolbarStyleBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarStyleView {
        ToolbarStyleView()
    }

    func updateNSView(_ view: ToolbarStyleView, context: Context) {
        view.applyToolbarStyle()
    }

    final class ToolbarStyleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToolbarStyle()
            DispatchQueue.main.async { [weak self] in
                self?.applyToolbarStyle()
            }
        }

        func applyToolbarStyle() {
            guard window?.toolbarStyle != .unified else { return }
            window?.toolbarStyle = .unified
        }
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
            GeneralSettingsPage(
                model: model,
                state: state
            )
        case .interface:
            InterfaceSettingsPage(model: model, state: state)
        case .chat:
            ChatSettingsPage(model: model, state: state)
        case .notifications:
            NotificationsSettingsPage(model: model, state: state)
        case .voiceVideo:
            VoiceVideoSettingsPage(model: model, state: state)
        case .accessibility:
            AccessibilitySettingsPage(model: model, state: state)
        case .keyboardShortcuts:
            KeyboardShortcutsSettingsPage(state: state)
        case .privacySafety:
            PrivacySafetySettingsPage(model: model, state: state)
        case .storageDownloads:
            StorageDownloadsSettingsPage(model: model, state: state)
        case .diagnostics:
            DiagnosticsSettingsPage(
                model: model,
                updateController: updateController,
                state: state
            )
        case .softwareUpdates:
            SoftwareUpdatesSettingsPage(
                updateController: updateController,
                state: state
            )
        case .extensions:
            ExtensionsSettingsPage(state: state)
        case .about:
            AboutSettingsPage(
                updateController: updateController,
                state: state
            )
        }
    }
}
