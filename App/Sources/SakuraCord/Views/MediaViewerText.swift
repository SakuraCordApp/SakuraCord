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
    /// Files read this session by their link, newest last, so reopening one
    /// doesn't fetch it again.
    private static var loaded: [(url: URL, file: (text: String, bytesLeft: Int))] = []
    private static let maximumLoaded = 8

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
        // Discord's dark code fill flattened onto black, so the file reads
        // as a dark code block over the viewer's dimmed backdrop.
        .background(Color(red: 13 / 255, green: 14 / 255, blue: 27 / 255))
        .environment(\.colorScheme, .dark)
        .clipShape(.rect(cornerRadius: MediaViewerStage.contentCornerRadius, style: .continuous))
        .task(id: url) {
            text = nil
            failed = false
            let loaded = try? await Self.text(of: url)
            // A file left for another must not overwrite it.
            guard !Task.isCancelled else { return }
            guard let loaded else {
                failed = true
                return
            }
            text = Self.attributed(loaded.text, language: language, bytesLeft: loaded.bytesLeft)
        }
    }

    private static func text(of url: URL) async throws -> (text: String, bytesLeft: Int) {
        if let index = loaded.firstIndex(where: { $0.url == url }) {
            let entry = loaded.remove(at: index)
            loaded.append(entry)
            return entry.file
        }
        let source = await MediaViewerActionService.resolveRemoteURL?(url) ?? url
        let file = try await load(source)
        loaded.removeAll { $0.url == url }
        loaded.append((url, file))
        if loaded.count > maximumLoaded { loaded.removeFirst() }
        return file
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
        guard text.utf8.count <= highlightLimit else {
            return NSAttributedString(string: text + notice, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: InterfaceScale.fontSize(13), weight: .regular),
                .foregroundColor: NSColor.white,
            ])
        }
        // The message text size, so the file's code matches a message's code block.
        return NativeTimelineCoreText.scaledMarkdown(
            DiscordMarkdown.appKitCodePlan(text + notice, language: language),
            baseFontSize: InterfaceScale.fontSize(InterfaceTypographyMetrics.messageTextSize)
        )
    }
}

private struct MediaViewerTextContent: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.appearance = NSAppearance(named: .darkAqua)
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
