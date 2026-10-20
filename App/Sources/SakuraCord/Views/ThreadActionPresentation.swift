import SakuraCordModels
import SwiftUI

/// Presents the Edit Thread/Edit Post dialog and the Delete confirmation that
/// thread menus on every surface request through AppModel.
struct ThreadActionPresentationModifier: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .windowModal(
                item: Bindable(model.threadActions).renaming,
                cornerRadius: InterfaceScale.metric(32),
                cornerStyle: .circular
            ) {
                ThreadRenameView(model: model, presentation: $0)
            }
            .background {
                ThreadDeletionConfirmationHost(model: model, store: model.threadActions)
            }
    }
}

/// Edit Thread / Edit Post: the thread's name, saved once on Save.
private struct ThreadRenameView: View {
    let model: AppModel
    let presentation: ThreadActionStore.RenamePresentation
    @Environment(\.windowModalContext) private var modal
    @Environment(\.windowModalAvailableSize) private var availableSize

    var body: some View {
        let store = model.threadActions
        let noun = presentation.isForumPost ? "Post" : "Thread"
        VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
            Text("Edit \(noun)")
                .font(.interface(.title2).weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, InterfaceScale.metric(12))
            VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                ThreadNameField(
                    title: presentation.isForumPost ? "Post Title" : "Thread Name",
                    draft: Bindable(store).draftName,
                    submit: model.saveThreadRename
                )
                if let error = store.error {
                    Text(error).font(.interface(.caption)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, InterfaceScale.metric(12))
            HStack {
                ModalGlassButton(symbol: "xmark", label: "Cancel") { modal?.dismiss() }
                    .disabled(store.isSaving)
                Spacer(minLength: InterfaceScale.metric(16))
                ModalGlassButton(
                    symbol: "checkmark", label: "Save", primary: true, isLoading: store.isSaving,
                    action: model.saveThreadRename
                )
                .disabled(store.isSaving || store.nameToSave == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, InterfaceScale.metric(4))
        }
        .disabled(store.isSaving)
        .padding(.top, InterfaceScale.metric(12))
        .padding(InterfaceScale.metric(12))
        .frame(width: min(InterfaceScale.metric(400), availableSize.width))
        .windowModalDismissDisabled(store.isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit \(noun)")
    }
}

private struct ThreadNameField: View {
    let title: String
    @Binding var draft: String
    let submit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text(title).font(.interface(.headline))
            TextField(title, text: $draft)
                .textFieldStyle(.plain).font(.interface(.body))
                .focused($isFocused)
                .onSubmit(submit)
                .padding(InterfaceScale.metric(14)).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ModalInputSurface(isFocused: isFocused) { isFocused = true })
                .onChange(of: draft) { _, value in
                    guard value.count > ThreadNamePolicy.maximumLength else { return }
                    draft = String(value.prefix(ThreadNamePolicy.maximumLength))
                }
                .accessibilityLabel(title)
        }
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}

private struct ThreadDeletionConfirmationHost: View {
    let model: AppModel
    @Bindable var store: ThreadActionStore

    var body: some View {
        let noun = store.deletion?.isForumPost == true ? "Post" : "Thread"
        Color.clear
            .alert(
                "Delete ‘\(store.deletion?.thread.name ?? noun)’?",
                isPresented: Binding(
                    get: { store.deletion != nil },
                    set: { if !$0 { store.deletion = nil } }
                ),
                presenting: store.deletion
            ) { confirmation in
                Button("Delete \(noun)", role: .destructive) {
                    model.confirmThreadDeletion(confirmation)
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.isForumPost
                    ? "This permanently deletes the post and all of its replies."
                    : "This permanently deletes the thread and its messages.")
            }
    }
}
