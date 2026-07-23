import MessageRendering
import SwiftUI

struct ForumPostTextEditor: View {
    let model: AppModel
    @Binding var text: String
    @Binding var selection: NSRange?
    @Binding var isFocused: Bool
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            ComposerTextView(
                text: text,
                placeholder: placeholder,
                sendWithReturn: false,
                mentionPresentations: mentionPresentations,
                onTextChange: { text = $0 },
                onSubmit: {},
                maximumHeight: 360,
                selection: $selection,
                isFocused: $isFocused
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private var mentionPresentations: [String: MentionPresentation] {
        let resolver = MessageMentionResolver(model: model)
        return MessageDocumentCache.shared.document(for: text).segments.reduce(into: [:]) {
            values, segment in
            if case let .mention(mention) = segment {
                values[mention.rawToken] = resolver.presentation(mention)
            }
        }
    }
}
