import MessageRendering
import SwiftUI

struct ForumPostTextEditor: View {
    let model: AppModel
    @Binding var text: String
    @Binding var selection: NSRange?
    @Binding var isFocused: Bool
    let placeholder: String
    var receiveAttachments: ((ComposerIncomingAttachments) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ComposerTextView(
                text: text,
                placeholder: placeholder,
                sendWithReturn: false,
                mentionPresentations: mentionPresentations,
                onTextChange: { text = $0 },
                onSubmit: {},
                onReceiveAttachments: receiveAttachments.map { receive in
                    { attachments, _ in
                        receive(attachments)
                        return true
                    }
                },
                canReceiveAttachments: { model.canAttachFilesToForumPosts },
                maximumHeight: 360,
                selection: $selection,
                isFocused: $isFocused
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if text.isEmpty {
                Text(placeholder)
                    .font(.interfaceSystem(size: 15))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private var mentionPresentations: [String: MentionPresentation] {
        MessageMentionResolver(model: model).presentations(in: text)
    }
}
