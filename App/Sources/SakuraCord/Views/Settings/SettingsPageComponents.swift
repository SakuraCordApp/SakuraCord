import SwiftUI

struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Every settings page and destination follows the interface size;
        // toolbars declared by the pages stay outside this root.
        .interfaceScaleRoot()
    }
}

struct SettingsPermissionRow<Action: View>: View {
    let title: LocalizedStringKey
    let status: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(10)) {
            Text(title, bundle: #bundle)
            Spacer()
            Text(status)
                .foregroundStyle(.secondary)
            action
        }
        .accessibilityElement(children: .contain)
    }
}

struct SettingsPageForm<Content: View>: View {
    let page: SettingsPageID
    let state: SettingsViewState
    @ViewBuilder let content: Content

    var body: some View {
        SettingsForm {
            content
        }
        .navigationTitle(state.catalog.page(page).title)
        .modifier(SettingsPageNavigation(page: page, state: state))
    }
}

extension EnvironmentValues {
    @Entry var settingsNavigationState: SettingsViewState?
}

struct SettingsPageNavigation: ViewModifier {
    let page: SettingsPageID
    let state: SettingsViewState

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(\.settingsNavigationState, state)
                .task(id: state.revealRequest?.id) {
                    guard let request = state.revealRequest, request.destination.page == page else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    // Ask lazy containers to materialize a target outside the viewport.
                    proxy.scrollTo(request.controlID, anchor: .center)
                }
                .overlayPreferenceValue(SettingsControlBoundsPreferenceKey.self) { controls in
                    let request = state.revealRequest
                    let canReveal = request?.destination.page == page
                        && controls.contains { $0.controlID == request?.controlID }
                    SettingsControlHighlightOverlay(controls: controls, highlightedControlID: state.highlightedControlID)
                        .allowsHitTesting(false)
                        // Wait for the target to exist, including asynchronously loaded account/profile fields.
                        .task(id: canReveal ? request?.id : nil) {
                            guard canReveal, let request else { return }
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(request.controlID, anchor: .center)
                            }
                            state.emphasize(request.controlID)
                        }
                }
        }
    }
}

extension View {
    /// Returns a page's navigation stack to its root when a search result reveals a control on `page`.
    func settingsNavigationPathResetOnReveal<Destination>(
        _ path: Binding<[Destination]>,
        page: SettingsPageID,
        state: SettingsViewState
    ) -> some View {
        onChange(of: state.revealRequest?.id) {
            guard state.revealRequest?.destination.page == page else { return }
            path.wrappedValue.removeAll()
        }
    }

    func settingsResetConfirmation(
        _ title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        resetTitle: LocalizedStringKey,
        message: LocalizedStringKey,
        reset: @escaping () -> Void
    ) -> some View {
        alert(Text(title, bundle: #bundle), isPresented: isPresented) {
            Button(role: .destructive, action: reset) {
                Text(resetTitle, bundle: #bundle)
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", bundle: #bundle)
            }
        } message: {
            Text(message, bundle: #bundle)
        }
    }

    func settingsControlAnchor(
        _ id: SettingsControlID,
        state: SettingsViewState
    ) -> some View {
        modifier(SettingsControlAnchorModifier(id: id, state: state))
    }

    /// A precise target inside a composite editor, using the enclosing settings page's navigation.
    func settingsControlAnchor(_ id: SettingsControlID) -> some View {
        modifier(SettingsControlAnchorModifier(id: id, state: nil))
    }
}

private struct SettingsControlAnchorModifier: ViewModifier {
    let id: SettingsControlID
    let state: SettingsViewState?
    @Environment(\.settingsNavigationState) private var navigationState

    func body(content: Content) -> some View {
        let state = state ?? navigationState
        return content
            .id(id)
            .anchorPreference(
                key: SettingsControlBoundsPreferenceKey.self,
                value: .bounds
            ) { bounds in
                guard let state else { return [] }
                return [
                    SettingsControlBounds(
                        controlID: id,
                        sectionID: self.state == nil ? nil : state.sectionID(for: id),
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
                let highlightedBounds = bounds.insetBy(dx: -InterfaceScale.metric(16), dy: -InterfaceScale.metric(10))
                RoundedRectangle(cornerRadius: InterfaceScale.metric(12), style: .continuous)
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
              })
        else { return nil }

        let targetBounds = proxy[target.bounds]
        guard let sectionID = target.sectionID else { return targetBounds }
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
