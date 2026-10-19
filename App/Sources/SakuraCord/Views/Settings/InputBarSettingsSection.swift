import SwiftUI

struct InputBarSettingsSection: View {
    @Binding var value: AppearanceSettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            LabeledContent("Appearance") {
                Picker("Input bar", selection: $value.composerBarAppearance) {
                    ForEach(ComposerBarAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .tint(SakuraCordAccentColor.color)
            }
            .settingsControlAnchor(.composerBarAppearance, state: state)

            ComposerIconEditor(layout: $value.composerIcons, appearance: value.composerBarAppearance)
                .settingsControlAnchor(.composerIcons, state: state)
        } header: {
            Text("Input bar", bundle: #bundle)
        } footer: {
            Text("Drag icons to rearrange them.")
        }
    }
}

private struct ComposerIconEditor: View {
    @Binding var layout: ComposerIconLayout
    let appearance: ComposerBarAppearance

    var body: some View {
        ComposerChromeLayout(
            appearance: appearance,
            focus: {},
            header: { EmptyView() },
            leading: { ComposerAttachmentButton(appearance: appearance, action: nil) },
            input: {
                Text("Message")
                    .font(.interfaceSystem(size: 15))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: ChatChromeMetrics.composerControlHeight, alignment: .leading)
            },
            accessories: {
                HStack(spacing: 1) {
                    ForEach(layout.order) { icon in
                        ComposerIconView(icon: icon, appearance: appearance)
                            .drawingGroup()
                    }
#if compiler(>=6.4)
                    .reorderable()
#endif
                }
#if compiler(>=6.4)
                .reorderContainer(for: ComposerIcon.self) { difference in
                    let before: ComposerIcon?
                    switch difference.destination.position {
                    case let .before(icon): before = icon
                    case .end: before = nil
                    }
                    layout.move(difference.sources, before: before)
                }
#endif
                .frame(height: ChatChromeMetrics.composerControlHeight)
            },
            send: { ComposerSendButton(action: nil, appearance: appearance) },
            overlay: { EmptyView() }
        )
        .padding(ChatChromeMetrics.composerWindowInset)
    }
}
