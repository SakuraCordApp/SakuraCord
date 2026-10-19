import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController

    @Environment(\.locale) private var locale
    @State private var state = SettingsViewState()
    @State private var launchAtLogin = LaunchAtLoginController()
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchPresented = false
    @State private var profileEditor: ProfileEditorState?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingNavigation: SettingsNavigationRequest?
    private let navigationRouter = SettingsNavigationRouter.shared

    init(model: AppModel, updateController: AppUpdateController) {
        self.model = model
        self.updateController = updateController
        _profileEditor = State(initialValue: ProfileEditorState(model: model))
    }

    private var currentAccount: SavedAccount? {
        if let user = model.snapshot?.currentUser {
            return SavedAccount(user: user)
        }
        return model.savedAccounts.first { $0.accountID == model.activeAccountID }
    }

    var body: some View {
        @Bindable var state = state
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(
                account: currentAccount,
                state: state,
                onSearchResultActivated: dismissSearchFocus
            )
            // Content follows the interface size; the window toolbar and its
            // items are system chrome and keep their native sizing.
            .interfaceScaleRoot()
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            SettingsDetailRouter(
                model: model,
                updateController: updateController,
                state: state,
                launchAtLogin: launchAtLogin,
                account: currentAccount,
                profileEditor: profileEditor
            )
        }
        .searchable(
            text: $state.searchText,
            isPresented: $isSearchPresented,
            placement: .sidebar,
            prompt: LocalizedStringResource(
                "Search Settings",
                bundle: #bundle,
                comment: "Prompt for the Settings sidebar search field."
            )
        )
        .searchFocused($isSearchFocused)
        .focusedSceneValue(\.shortcutCommandContext, .settings(model: model) {
            columnVisibility = .all
            isSearchPresented = true
            isSearchFocused = true
        })
        .background {
            ZStack {
                SettingsWindowBehaviorBridge()
                SakuraCordTextInputAccentBridge()
            }
        }
        .modifier(SakuraCordWindowBackground(opacity: model.appearanceSettings.windowOpacity))
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleSearchKeyPress(press)
        }
        .task {
            state.updateLocale(locale)
            let navigationEditor = profileEditor
            let navigationConfirmation = $pendingNavigation
            state.allowsNavigation = { [weak navigationEditor] destination, controlID in
                guard let profileEditor = navigationEditor, profileEditor.hasChanges || profileEditor.isSaving else { return true }
                guard destination.page != .profiles else { return true }
                navigationConfirmation.wrappedValue = SettingsNavigationRequest(id: UUID(), destination: destination, controlID: controlID)
                return false
            }
            await profileEditor?.loadIfNeeded()
        }
        .windowResizeBehavior(.enabled)
        .dismissalConfirmationDialog("Profile Changes", shouldPresent: profileEditor?.hasChanges == true || profileEditor?.isSaving == true) {
            if profileEditor?.isSaving != true {
                Button("Discard Changes", role: .destructive) { profileEditor?.resetDraft() }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(profileEditor?.isSaving == true ? "Wait for your profile changes to finish saving." : "Your profile has unsaved changes.", bundle: #bundle)
        }
        .confirmationDialog("Profile Changes", isPresented: Binding(get: { pendingNavigation != nil }, set: { if !$0 { pendingNavigation = nil } }), titleVisibility: .visible, presenting: pendingNavigation) { request in
            if profileEditor?.isSaving != true {
                Button("Discard Changes", role: .destructive) {
                    guard let profileEditor, !profileEditor.isSaving else { return }
                    profileEditor.resetDraft()
                    state.navigate(to: request.destination, controlID: request.controlID)
                }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: { _ in
            Text(profileEditor?.isSaving == true ? "Wait for your profile changes to finish saving." : "Your profile has unsaved changes.", bundle: #bundle)
        }
        .environment(\.profileCosmeticPolicy, model.cosmeticPolicy)
        .task(id: navigationRouter.request?.id) {
            guard let request = navigationRouter.request else { return }
            state.searchText = ""
            dismissSearchFocus()
            state.navigate(
                to: request.destination,
                controlID: request.controlID
            )
            // The profile picker likewise switches scope without saving a draft.
            // Consuming the request first would cancel this task mid-load.
            if let scope = request.profileScope, let profileEditor, !profileEditor.isSaving, profileEditor.scope != scope {
                await profileEditor.load(scope)
            }
            navigationRouter.consume(request.id)
        }
        .onChange(of: locale) { _, locale in
            state.updateLocale(locale)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshProfileAfterExternalChange()
        }
        .onChange(of: model.profileInvalidationRevision) { _, _ in
            refreshProfileAfterExternalChange()
        }
        .frame(
            minWidth: InterfaceScale.windowLength(1060, axis: .horizontal),
            idealWidth: InterfaceScale.windowLength(1060, axis: .horizontal),
            maxWidth: InterfaceScale.windowLength(1060, axis: .horizontal),
            minHeight: InterfaceScale.windowLength(520, axis: .vertical),
            idealHeight: InterfaceScale.windowLength(760, axis: .vertical),
            maxHeight: .infinity
        )
    }

    private func dismissSearchFocus() {
        isSearchFocused = false
        isSearchPresented = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func refreshProfileAfterExternalChange() {
        profileEditor?.invalidateSnapshot()
        guard state.selectedPage == .profiles else { return }
        Task { await profileEditor?.refreshIfNeeded() }
    }

    private func handleSearchKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard isSearchPresented else { return .ignored }
        switch press.key {
        case .escape:
            state.searchText = ""
            dismissSearchFocus()
            return .handled
        case .return:
            guard state.activateSelectedSearchResult() else { return .ignored }
            dismissSearchFocus()
            return .handled
        case .downArrow:
            guard !state.searchText.isEmpty else { return .ignored }
            state.moveSearchSelection(by: 1)
            return .handled
        case .upArrow:
            guard !state.searchText.isEmpty else { return .ignored }
            state.moveSearchSelection(by: -1)
            return .handled
        default:
            guard press.modifiers.contains(.control) else { return .ignored }
            switch press.characters.lowercased() {
            case "n":
                state.moveSearchSelection(by: 1)
                return .handled
            case "p":
                state.moveSearchSelection(by: -1)
                return .handled
            default:
                return .ignored
            }
        }
    }
}

/// Applies the Settings-specific behavior that SwiftUI doesn't expose.
private struct SettingsWindowBehaviorBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowBehaviorView {
        WindowBehaviorView()
    }

    func updateNSView(_ view: WindowBehaviorView, context: Context) {
        view.applyWindowBehavior()
    }

    final class WindowBehaviorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowBehavior()
            DispatchQueue.main.async { [weak self] in
                self?.applyWindowBehavior()
                self?.centerWindow()
            }
        }

        func applyWindowBehavior() {
            guard let window else { return }
            window.toolbarStyle = .unified
        }

        private func centerWindow() {
            guard let window else { return }
            let screen = NSApp.windows.first {
                $0 !== window
                    && $0.isVisible
                    && $0.styleMask.contains(.fullScreen)
            }?.screen ?? NSScreen.main ?? window.screen
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let origin = NSPoint(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2
            )
            window.setFrameOrigin(origin)
        }
    }
}

private struct SettingsDetailRouter: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState
    let launchAtLogin: LaunchAtLoginController
    let account: SavedAccount?
    let profileEditor: ProfileEditorState?

    var body: some View {
        switch state.selectedPage {
        case .myAccount:
            MyAccountSettingsPage(
                model: model,
                account: account,
                state: state
            )
            .id(model.activeAccountID)
        case .profiles:
            if let profileEditor { ProfilesSettingsPage(model: model, state: state, editor: profileEditor) } else { ProgressView() }
        case .general:
            GeneralSettingsPage(
                model: model,
                state: state,
                launchAtLogin: launchAtLogin
            )
        case .features:
            FeaturesSettingsPage(model: model, state: state)
        case .appearance:
            AppearanceSettingsPage(model: model, state: state)
        case .interface:
            InterfaceSettingsPage(model: model, state: state)
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
        case .importExport:
            ImportExportSettingsPage(model: model, updateController: updateController, state: state, launchAtLogin: launchAtLogin)
        case .about:
            AboutSettingsPage(
                updateController: updateController,
                state: state
            )
        }
    }
}
