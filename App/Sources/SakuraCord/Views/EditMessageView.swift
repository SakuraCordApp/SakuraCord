import SakuraCordModels
import SwiftUI

struct EditMessageView: View {
    let message: Message
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content: String

    init(message: Message, save: @escaping (String) -> Void) {
        self.message = message
        self.save = save
        content = message.content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(14)) {
            Text("Edit Message").font(.interface(.headline))
            TextEditor(text: $content)
                .frame(minHeight: InterfaceScale.metric(120))
                .font(.interface(.body))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save(content); dismiss() }.keyboardShortcut(.defaultAction).disabled(content.isEmpty)
            }
        }
        .padding(InterfaceScale.metric(20)).frame(width: InterfaceScale.metric(480))
    }
}
