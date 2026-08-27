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
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Message").font(.headline)
            TextEditor(text: $content)
                .tint(SakuraCordAccentColor.color)
                .frame(minHeight: 120)
                .font(.body)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save(content); dismiss() }.keyboardShortcut(.defaultAction).disabled(content.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }
}
