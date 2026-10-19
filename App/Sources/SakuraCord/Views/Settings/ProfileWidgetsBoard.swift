import SakuraCordModels
import SwiftUI

struct ProfileWidgetsBoard: View {
    let editor: ProfileEditorState
    @State private var showsAddPicker = false

    var body: some View {
        ProfileWidgetBoardViewport {
            VStack(spacing: InterfaceScale.metric(12)) {
                ForEach(editor.widgets) { widget in
                    // Keep a stable outer identity around the card's conditional
                    // content and menus for SwiftUI's reorder container.
                    VStack(spacing: 0) {
                        ProfileWidgetCard(widget: widget, resources: editor.widgetResources, editor: editor, displayName: editor.name)
                            .overlay { widgetMenu(widget) }
                            .overlay(alignment: .topTrailing) {
                                widgetMenu(widget, isButton: true)
                                    .frame(width: InterfaceScale.metric(24), height: InterfaceScale.metric(24))
                                    .disabled(!editor.canEditWidgets)
                                    .padding(InterfaceScale.metric(12))
                            }
                    }
                    .contentShape(.interaction, .rect(cornerRadius: InterfaceScale.metric(16)))
                    .contentShape(.dragPreview, .rect(cornerRadius: InterfaceScale.metric(16)))
                }
#if compiler(>=6.4)
                .reorderable()
#endif
            }
#if compiler(>=6.4)
            .reorderContainer(for: ProfileWidget.self, isEnabled: editor.canEditWidgets) { difference in
                let before: String?
                switch difference.destination.position {
                case let .before(id): before = id
                case .end: before = nil
                }
                editor.moveWidgets(difference.sources, before: before)
            }
#endif
        }
        .overlay(alignment: .topTrailing) {
            Button { showsAddPicker = true } label: { Label("Add Widget", systemImage: "plus") }
                .disabled(!editor.canEditWidgets)
                .escapeDismissiblePopover(isPresented: $showsAddPicker) {
                    ProfileAddWidgetPicker(editor: editor) { showsAddPicker = false }
                }
                .padding(InterfaceScale.metric(10))
        }
        .onChange(of: editor.draftGeneration) { _, _ in showsAddPicker = false }
        .onChange(of: editor.isResolvingScope) { _, resolving in if resolving { showsAddPicker = false } }
    }

    private func widgetMenu(_ widget: ProfileWidget, isButton: Bool = false) -> some View {
        ProfileWidgetMenu(editor: editor, widgetID: widget.id, title: title(widget), isButton: isButton) {
            editor.removeWidget(id: widget.id)
        }
    }

    private func title(_ widget: ProfileWidget) -> String {
        switch widget.content {
        case let .personal(personal): personal.header.isEmpty ? String(localized: "Personal", bundle: #bundle) : personal.header
        case let .games(kind, _): kind.title
        case let .application(id): editor.widgetResources?.applications.first { $0.applicationID == id }?.applicationName ?? "Widget"
        case .unrecognized: "Widget"
        }
    }
}
