import SwiftUI

struct SettingsPageForm<Content: View>: View {
    let page: SettingsPageID
    let state: SettingsViewState
    @ViewBuilder let content: Content

    @ViewBuilder
    var body: some View {
        if let request = state.revealRequest,
           request.destination.page == page
        {
            ScrollViewReader { proxy in
                pageForm
                    .task(id: request.id) {
                        await Task.yield()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(request.controlID, anchor: .center)
                        }
                    }
            }
        } else {
            pageForm
        }
    }

    private var pageForm: some View {
        let metadata = state.catalog.page(page)
        return Form {
            content
        }
        .formStyle(.grouped)
        .navigationTitle(metadata.title)
    }
}

struct SettingsScopeFooter: View {
    let scope: SettingsValueScope

    var body: some View {
        Label(scope.title, systemImage: "externaldrive.badge.checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(scope.title)
    }
}

extension View {
    func settingsControlAnchor(
        _ id: SettingsControlID,
        state: SettingsViewState
    ) -> some View {
        modifier(SettingsControlAnchorModifier(id: id, state: state))
    }
}

private struct SettingsControlAnchorModifier: ViewModifier {
    let id: SettingsControlID
    let state: SettingsViewState

    func body(content: Content) -> some View {
        content
            .id(id)
            .overlay {
                if state.highlightedControlID == id {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.tint, lineWidth: 2)
                        .padding(-5)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
