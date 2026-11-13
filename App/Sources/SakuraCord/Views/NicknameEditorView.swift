import SakuraCordModels
import SwiftUI

/// Discord's Change Nickname and friend-nickname dialogs. Edits stay local
/// until Save; a failed save keeps the dialog open with Discord's reason.
struct NicknameEditorView: View {
    let model: AppModel
    let presentation: NicknameEditorStore.Presentation

    var body: some View {
        let store = model.nicknameEditor
        let isFriend = presentation.target == .friend
        NameEditorPanel(
            title: NicknameEditorCopy.title(for: presentation),
            fieldTitle: isFriend ? "Friend Nickname" : "Nickname",
            placeholder: presentation.fallbackName,
            draft: Bindable(store).draft,
            maximumLength: NicknameEditorStore.maximumLength,
            error: store.error,
            isSaving: store.isSaving,
            save: save
        ) {
            if isFriend {
                Text("Find a friend faster with a personal nickname. It will only be visible to you in your direct messages.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(
                    "Nicknames are visible to everyone on this server. Do not change them unless you are enforcing a naming system or clearing a bad nickname.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            // Discord offers a server reset only while a nickname is set.
            if isFriend || presentation.currentNickname != nil {
                Button(isFriend ? "Reset Friend Nickname" : "Reset Nickname") { store.draft = "" }
                    .buttonStyle(.link)
            }
        }
    }

    private func save() {
        guard !model.nicknameEditor.isSaving else { return }
        model.saveNickname(presentation)
    }
}

/// The app's single-name dialog: a title and notice, one field with an
/// optional accessory below it, and Cancel beside the primary action.
struct NameEditorPanel<Notice: View, Accessory: View>: View {
    let title: String
    let fieldTitle: String
    let placeholder: String
    @Binding var draft: String
    /// Discord's limit in UTF-16 units, as its text input counts them.
    var maximumLength: Int?
    var error: String?
    var isSaving = false
    var actionTitle = "Save"
    let save: () -> Void
    @ViewBuilder let notice: Notice
    @ViewBuilder let accessory: Accessory
    @Environment(\.windowModalContext) private var modal
    @Environment(\.windowModalAvailableSize) private var availableSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                notice
            }
            .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 8) {
                NameEditorField(title: fieldTitle, placeholder: placeholder, draft: $draft, maximumLength: maximumLength, submit: save)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory
            }
            .disabled(isSaving)
            .padding(.horizontal, 12)
            // Keep the 12-point footer inset that makes the capsules concentric with the panel.
            HStack {
                ModalGlassButton(symbol: "xmark", label: "Cancel") { modal?.dismiss() }
                    .disabled(isSaving)
                Spacer(minLength: 16)
                ModalGlassButton(symbol: "checkmark", label: actionTitle, primary: true, isLoading: isSaving, action: save)
                    .disabled(isSaving)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(.top, 12)
        .padding(12)
        .frame(width: min(400, availableSize.width))
        .windowModalDismissDisabled(isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

nonisolated enum NicknameEditorCopy {
    static func title(for presentation: NicknameEditorStore.Presentation) -> String {
        switch presentation.target {
        case .server: "Change Nickname"
        case .friend: presentation.currentNickname == nil ? "Add Friend Nickname" : "Change Friend Nickname"
        }
    }
}

private struct NameEditorField: View {
    let title: String
    let placeholder: String
    @Binding var draft: String
    let maximumLength: Int?
    let submit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain).font(.body)
                .focused($isFocused)
                .onSubmit(submit)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ModalInputSurface(isFocused: isFocused) { isFocused = true })
                .onChange(of: draft) { _, value in
                    guard let maximumLength, value.utf16.count > maximumLength else { return }
                    var trimmed = value
                    while trimmed.utf16.count > maximumLength { trimmed.removeLast() }
                    draft = trimmed
                }
                .accessibilityLabel(title)
        }
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}

struct NicknameEditorPresentationModifier: ViewModifier {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .windowModal(item: Bindable(model.nicknameEditor).presentation, cornerRadius: 32, cornerStyle: .circular) {
                NicknameEditorView(model: model, presentation: $0)
            }
            .onChange(of: model.nicknameEditor.settingsRequest) { _, _ in openSettings() }
    }
}
