import AppKit
import SakuraCordModels
import SwiftUI

/// A text file shown whole, as Discord's View Whole File does: everything
/// the preview fetched, selectable, above the file's name, size, and download.
struct TextFilePresentation: Identifiable {
    let attachment: Attachment
    let preview: AttachmentTextPreviewStore.Preview
    let language: String?
    let isMarkdown: Bool

    var id: String { attachment.id }
}

struct TextFilePreviewSheet: View {
    let presentation: TextFilePresentation
    let download: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TextFileContentView(
                text: NativeTimelineTextPreview.attributedText(
                    presentation.preview,
                    shownLines: nil,
                    wrapsText: true,
                    language: presentation.language,
                    isMarkdown: presentation.isMarkdown
                ),
                background: presentation.isMarkdown ? .textBackgroundColor : NativeTimelineRowPainter.discordCodeBackgroundColor
            )
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                    Text(presentation.attachment.filename)
                        .font(.interface(.body))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(NativeTimelineTextPreview.sizeText(presentation.attachment.size))
                        .font(.interface(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download", action: download)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(InterfaceScale.metric(16))
        }
        // Discord opens the whole file in its largest modal.
        .frame(minWidth: InterfaceScale.metric(800), minHeight: InterfaceScale.metric(560))
    }
}

private struct TextFileContentView: NSViewRepresentable {
    let text: NSAttributedString
    let background: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: InterfaceScale.metric(12), height: InterfaceScale.metric(12))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.backgroundColor = background
        if textView.attributedString() != text { textView.textStorage?.setAttributedString(text) }
    }
}
