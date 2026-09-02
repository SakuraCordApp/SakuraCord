import SwiftUI

struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

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
        return SettingsForm {
            if page.showsConstructionNotice {
                Section {
                    SettingsConstructionNotice()
                }
            }

            content
        }
        .navigationTitle(metadata.title)
    }
}

private extension SettingsPageID {
    var showsConstructionNotice: Bool {
        switch self {
        case .appearance, .diagnostics, .softwareUpdates, .extensions, .about:
            false
        default:
            true
        }
    }
}

private struct SettingsConstructionNotice: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("This Settings Page Is Under Construction", bundle: #bundle)
                    .font(.headline)

                Text(
                    "Some features may be unfinished or nonfunctional. Proceed with care.",
                    bundle: #bundle
                )
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
                        .stroke(SakuraCordAccentColor.color, lineWidth: 2)
                        .padding(-5)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
