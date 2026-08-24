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
            .modifier(
                SettingsContrastModifier(
                    isEnabled: model.accessibilitySettings.increasesContrast
                        && systemColorSchemeContrast == .standard
                )
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
        .background(SettingsWindowBehaviorBridge())
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
            window.styleMask.insert(.resizable)
            window.contentMaxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            window.collectionBehavior.insert([.auxiliary, .moveToActiveSpace])
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

private struct SettingsContrastModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.contrast(1.12)
        } else {
            content
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
