import AppKit
import MessageRendering
import SwiftUI

/// A text or code file in the media viewer: its first half megabyte, read
/// when shown, highlighted as a message code block, and selectable. The
/// viewer's download saves the whole file.
struct MediaViewerText: View {
    let url: URL
    let language: String
    @State private var text: NSAttributedString?
    @State private var failed = false

    /// Enough for any source file someone reads in a viewer.
    private nonisolated static let byteLimit = 512 * 1_024
    /// Highlighting is skipped past this, where it would hold up the viewer.
    private static let highlightLimit = 128 * 1_024
    private nonisolated static let session = URLSession(configuration: .ephemeral)

    var body: some View {
        Group {
            if let text {
                MediaViewerTextContent(text: text)
            } else if failed {
                Label("This file couldn't be read.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: InterfaceScale.metric(960), maxHeight: .infinity)
        .background(Color(nsColor: NativeTimelineRowPainter.discordCodeBackgroundColor))
        .clipShape(.rect(cornerRadius: MediaViewerStage.contentCornerRadius, style: .continuous))
        .task(id: url) {
            text = nil
            failed = false
            let source = await MediaViewerActionService.resolveRemoteURL?(url) ?? url
            let loaded = try? await Self.load(source)
            // A file left for another must not overwrite it.
            guard !Task.isCancelled else { return }
            guard let loaded else {
                failed = true
                return
            }
            text = Self.attributed(loaded.text, language: language, bytesLeft: loaded.bytesLeft)
        }
    }

    /// Reads up to the limit.
    private nonisolated static func load(_ url: URL) async throws -> (text: String, bytesLeft: Int) {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(byteLimit - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(status) {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= byteLimit { break }
        }
        let total = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last).flatMap { Int($0) } ?? Int(response.expectedContentLength)
        return (decodeReplacingInvalid(data), max(0, total - data.count))
    }

    /// UTF-8 with what isn't valid, such as a character the limit cut in
    /// two, replaced by U+FFFD.
    private nonisolated static func decodeReplacingInvalid(_ data: Data) -> String {
        var decoder = UTF8()
        var bytes = data.makeIterator()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&bytes) {
            case let .scalarValue(scalar): scalars.append(scalar)
            case .error: scalars.append("\u{FFFD}")
            case .emptyInput: return String(scalars)
            }
        }
    }

    private static func attributed(_ text: String, language: String, bytesLeft: Int) -> NSAttributedString {
        let notice = bytesLeft > 0
            ? "\n\n… \(NativeTimelineFileCard.sizeText(bytesLeft)) more. Download the file to see all of it."
            : ""
        let baseFontSize = InterfaceScale.fontSize(13)
        guard text.utf8.count <= highlightLimit else {
            return NSAttributedString(string: text + notice, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular),
                .foregroundColor: NSColor.white,
            ])
        }
        return NativeTimelineCoreText.scaledMarkdown(
            DiscordMarkdown.appKitCodePlan(text + notice, language: language), baseFontSize: baseFontSize
        )
    }
}

private struct MediaViewerTextContent: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: InterfaceScale.metric(16), height: InterfaceScale.metric(16))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.attributedString() != text else { return }
        textView.textStorage?.setAttributedString(text)
    }
}
