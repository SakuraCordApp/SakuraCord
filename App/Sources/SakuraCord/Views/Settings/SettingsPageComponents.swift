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
        .overlayPreferenceValue(SettingsControlBoundsPreferenceKey.self) { controls in
            SettingsControlHighlightOverlay(
                controls: controls,
                highlightedControlID: state.highlightedControlID
            )
        }
    }
}

private extension SettingsPageID {
    var showsConstructionNotice: Bool {
        switch self {
        case .appearance, .storageDownloads, .diagnostics, .softwareUpdates, .extensions, .about:
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
            .anchorPreference(
                key: SettingsControlBoundsPreferenceKey.self,
                value: .bounds
            ) { bounds in
                [
                    SettingsControlBounds(
                        controlID: id,
                        sectionID: state.sectionID(for: id),
                        bounds: bounds
                    ),
                ]
            }
    }
}

private struct SettingsControlBounds {
    let controlID: SettingsControlID
    let sectionID: SettingsSectionID?
    let bounds: Anchor<CGRect>
}

private struct SettingsControlBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [SettingsControlBounds] = []

    static func reduce(
        value: inout [SettingsControlBounds],
        nextValue: () -> [SettingsControlBounds]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct SettingsControlHighlightOverlay: View {
    let controls: [SettingsControlBounds]
    let highlightedControlID: SettingsControlID?

    var body: some View {
        GeometryReader { proxy in
            if let bounds = highlightedControlBounds(in: proxy) {
                let highlightedBounds = bounds.insetBy(dx: -16, dy: -10)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SakuraCordAccentColor.color, lineWidth: 2)
                    .frame(
                        width: highlightedBounds.width,
                        height: highlightedBounds.height
                    )
                    .position(
                        x: highlightedBounds.midX,
                        y: highlightedBounds.midY
                    )
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func highlightedControlBounds(in proxy: GeometryProxy) -> CGRect? {
        guard let highlightedControlID,
              let target = controls.first(where: {
                  $0.controlID == highlightedControlID
              }),
              let sectionID = target.sectionID
        else { return nil }

        let targetBounds = proxy[target.bounds]
        let sectionBounds = controls.lazy
            .filter { $0.sectionID == sectionID }
            .reduce(targetBounds) { bounds, control in
                bounds.union(proxy[control.bounds])
            }
        return CGRect(
            x: sectionBounds.minX,
            y: targetBounds.minY,
            width: sectionBounds.width,
            height: targetBounds.height
        )
    }
}
