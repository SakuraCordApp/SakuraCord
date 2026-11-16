import SakuraCordModels
import SwiftUI

struct ProfileCustomStatusControl: View {
    let editor: ProfileEditorState
    let profile: UserProfile
    let surfaceColor: Color
    let width: CGFloat
    var isExpandedProfile = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        let showsEditAffordance = isHovered && isEnabled && editor.canEditWidgets

        Button { isPresented = true } label: {
            ProfileStatusBubble(
                text: profile.customStatus ?? String(localized: "Add Status", bundle: #bundle),
                surfaceColor: surfaceColor, width: width,
                keepsExpanded: isHovered || isPresented,
                isExpandedProfile: isExpandedProfile
            )
                .brightness(showsEditAffordance ? -0.45 : 0)
                .animation(.easeOut(duration: 0.12), value: showsEditAffordance)
                .allowsHitTesting(false)
                .contentShape(Rectangle())
        }
        .buttonStyle(ProfileStatusButtonStyle())
        .settingsControlAnchor(.profileStatus)
        .accessibilityLabel(profile.customStatus == nil ? "Add custom status" : "Edit custom status")
        .overlay(alignment: .topTrailing) {
            HoverActionPill {
                HoverActionControlLabel(diameter: InterfaceScale.metric(20)) {
                    Image(systemName: "pencil").font(.interface(.callout).weight(.medium))
                }
            }
            // A 28-point glass circle sits concentrically inside the 36-point pill.
            .padding(InterfaceScale.metric(4))
            .opacity(showsEditAffordance ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.easeOut(duration: 0.12), value: showsEditAffordance)
        }
        .contextMenu {
            if profile.customStatus != nil {
                Button("Clear Status", role: .destructive) { editor.setCustomStatusDraft(nil) }
            }
        }
        .onModalHover { isHovered = $0 }
        .disabled(!editor.canEditWidgets)
        .overlay {
            StableAnchoredPopoverPresenter(isPresented: isPresented, configuration: .toolbarPanel, onDismiss: { isPresented = false }, content: {
                ProfileCustomStatusEditor(editor: editor, profile: profile)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.locale, locale)
            })
        }
        .onChange(of: editor.draftGeneration) { _, _ in isPresented = false }
        .onChange(of: editor.isResolvingScope) { _, resolving in if resolving { isPresented = false } }
    }
}

private struct ProfileStatusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct ProfileCustomStatusEditor: View {
    let editor: ProfileEditorState
    let profile: UserProfile
    @Environment(\.stablePopoverPresentationContext) private var popover
    @State private var draft: ProfileStatusDraft
    @State private var showsEmojiPicker = false
    @State private var errorMessage: String?
    @FocusState private var isTextFocused: Bool

    init(editor: ProfileEditorState, profile: UserProfile) {
        self.editor = editor
        self.profile = profile
        _draft = State(initialValue: editor.customStatusDraft ?? .empty)
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
                .padding(.horizontal, InterfaceScale.metric(10))
                .padding(.vertical, InterfaceScale.metric(8))
            Divider().padding(.horizontal, InterfaceScale.metric(12))
            HStack {
                expirationMenu
                Spacer(minLength: 0)
            }
            .font(.interface(.callout))
            .foregroundStyle(.secondary)
            .padding(.horizontal, InterfaceScale.metric(16))
            .padding(.vertical, InterfaceScale.metric(10))
            if let errorMessage {
                Text(errorMessage).font(.interface(.caption)).foregroundStyle(.red).padding([.horizontal, .bottom], InterfaceScale.metric(12))
            }
        }
        .frame(width: InterfaceScale.metric(320))
        .disabled(!editor.canEditWidgets)
        .onChange(of: draft) { _, value in editor.setCustomStatusDraft(value) }
        .onChange(of: showsEmojiPicker, initial: true) { _, presented in
            popover?.escapeAction = presented ? { showsEmojiPicker = false } : nil
            if !presented { isTextFocused = true }
        }
        .onChange(of: popover?.hasFinishedPresenting, initial: true) { _, presented in
            if presented == true { isTextFocused = true }
        }
        .onDisappear { popover?.escapeAction = nil }
    }

    private var inputRow: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            ProfileStatusEmojiButton(status: draft.status) { showsEmojiPicker.toggle() }
                .overlay {
                    StableAnchoredPopoverPresenter(isPresented: showsEmojiPicker, configuration: .toolbarPanel,
                                                   onDismiss: { showsEmojiPicker = false }, content: {
                        EmojiPickerView(model: editor.model, useCase: .customStatus, dismiss: { showsEmojiPicker = false }, select: selectEmoji)
                    })
                }
            TextField("Add Status", text: $draft.status.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.interface(.body))
                .lineLimit(1 ... 3)
                .focused($isTextFocused)
                .onKeyPress(.return) {
                    popover?.dismiss?()
                    return .handled
                }
                .onChange(of: draft.status.text) { _, _ in
                    while draft.status.text.utf16.count > 128 { draft.status.text.removeLast() }
                }
            if !draft.status.displayText.isEmpty {
                ComposerActionButton(icon: Image(systemName: "xmark"), help: String(localized: "Clear Status", bundle: #bundle), iconSize: 12, size: InterfaceScale.metric(28)) {
                    draft.status.text = ""
                    draft.status.emojiID = nil
                    draft.status.emojiName = nil
                }
            }
        }
        .frame(minHeight: InterfaceScale.metric(34))
    }

    private var expirationMenu: some View {
        Menu {
            ForEach(ProfileStatusExpiration.allCases, id: \.self) { expiration in
                Button(expiration.label) {
                    draft.expiresAfter = expiration.seconds
                    draft.status.expiresAt = nil
                }
            }
        } label: {
            Text(expirationLabel)
        }
        .menuStyle(.borderlessButton)
        .tint(.primary)
        .fixedSize()
        .accessibilityLabel("Status expiry")
    }

    private var expirationLabel: String {
        if let seconds = draft.expiresAfter, let expiration = ProfileStatusExpiration.allCases.first(where: { $0.seconds == seconds }) {
            return String(localized: "Clear after \(expiration.label)", bundle: #bundle)
        }
        if let date = draft.status.expiresAt {
            return String(localized: "Clear at \(date.formatted(date: .omitted, time: .shortened))", bundle: #bundle)
        }
        return ProfileStatusExpiration.never.label
    }

    private func selectEmoji(_ activation: EmojiPickerActivation) {
        switch activation.selection {
        case let .native(value): draft.status.emojiID = nil; draft.status.emojiName = value
        case let .custom(emoji):
            guard profile.user.premiumType > 0 else {
                errorMessage = String(localized: "Custom status emojis require Nitro.", bundle: #bundle)
                return
            }
            draft.status.emojiID = emoji.id; draft.status.emojiName = emoji.name
        }
        errorMessage = nil
        showsEmojiPicker = false
    }
}

private struct ProfileStatusEmojiButton: View {
    let status: ProfileCustomStatus
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Group {
                if let id = status.emojiID, let url = DiscordCDN.emoji(id, fileExtension: "webp", query: "size=48&animated=false") {
                    AnimatedRemoteImage(url: url, animates: false, maximumPixelDimension: 48)
                } else if let emoji = status.emojiName {
                    Image(nsImage: ComponentUnicodeEmojiRenderer.image(for: emoji))
                        .resizable().scaledToFit().frame(width: InterfaceScale.metric(22), height: InterfaceScale.metric(22))
                } else {
                    Image(systemName: "face.smiling").font(.interfaceSystem(size: 21)).foregroundStyle(.secondary)
                }
            }
            .frame(width: InterfaceScale.metric(24), height: InterfaceScale.metric(24))
            .allowsHitTesting(false)
            .frame(width: InterfaceScale.metric(34), height: InterfaceScale.metric(34))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.primary.opacity(isHovered && isEnabled ? 0.14 : 0), in: Circle())
        .onModalHover { isHovered = $0 }
        .help("Choose status emoji")
        .accessibilityLabel("Status emoji: \(status.emojiName ?? String(localized: "not set", bundle: #bundle))")
    }
}

private enum ProfileStatusExpiration: CaseIterable {
    case day, fourHours, hour, halfHour, never

    var seconds: TimeInterval? {
        switch self {
        case .day: 86400
        case .fourHours: 14400
        case .hour: 3600
        case .halfHour: 1800
        case .never: nil
        }
    }

    var label: String {
        switch self {
        case .day: String(localized: "24 hours", bundle: #bundle)
        case .fourHours: String(localized: "4 hours", bundle: #bundle)
        case .hour: String(localized: "1 hour", bundle: #bundle)
        case .halfHour: String(localized: "30 minutes", bundle: #bundle)
        case .never: String(localized: "Don’t clear", bundle: #bundle)
        }
    }
}
