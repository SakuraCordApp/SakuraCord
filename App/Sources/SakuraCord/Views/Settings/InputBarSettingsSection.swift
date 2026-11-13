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

    @State private var previewText = ""
    @State private var selection: NSRange?
    @State private var isFocused = false

    private var showsVoiceButton: Bool {
        previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ComposerChromeLayout(
            appearance: appearance,
            focus: { isFocused = true },
            header: { EmptyView() },
            leading: { ComposerAttachmentButton(appearance: appearance, action: nil) },
            input: {
                ZStack(alignment: .leading) {
                    ComposerTextView(
                        text: previewText,
                        placeholder: String(localized: "Message", bundle: #bundle),
                        sendWithReturn: true,
                        onTextChange: { previewText = $0 },
                        onSubmit: { previewText = "" },
                        canReceiveAttachments: { false },
                        verticalContentInset: appearance == .defaultStyle
                            ? ChatChromeMetrics.composerTextVerticalInset : 0,
                        selection: $selection,
                        isFocused: $isFocused
                    )
                    if previewText.isEmpty {
                        Text("Message")
                            .font(.interfaceSystem(size: 15))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .transition(.identity)
                    }
                }
                .frame(minHeight: ChatChromeMetrics.composerControlHeight)
                .layoutPriority(1)
            },
            accessories: {
                HStack(spacing: 1) {
                    ForEach(layout.order) { icon in
                        ComposerIconView(icon: icon, appearance: appearance)
                            .drawingGroup()
                    }
                    .reorderable()
                }
                .reorderContainer(for: ComposerIcon.self) { difference in
                    let before: ComposerIcon?
                    switch difference.destination.position {
                    case let .before(icon): before = icon
                    case .end: before = nil
                    }
                    layout.move(difference.sources, before: before)
                }
                .frame(height: ChatChromeMetrics.composerControlHeight)
            },
            send: {
                ComposerSendSlot(
                    mode: showsVoiceButton ? .voice : .send,
                    appearance: appearance,
                    send: { previewText = "" },
                    startRecording: {},
                    stopRecording: {}
                )
            },
            overlay: { EmptyView() }
        )
        .animation(.smooth(duration: 0.3), value: showsVoiceButton)
        .padding(ChatChromeMetrics.composerWindowInset)
    }
}
