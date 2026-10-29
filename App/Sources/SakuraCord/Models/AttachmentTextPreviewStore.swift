import Foundation
import SakuraCordModels

/// Fetches the start of text file attachments for the timeline's inline
/// previews, and remembers each preview's expansion, language, wrapping, and
/// scroll.
///
/// Like Discord, a preview reads only the first 50,001 bytes, and a file that
/// can't be read shows as a plain file card instead.
@MainActor
final class AttachmentTextPreviewStore {
    struct Preview: Equatable {
        let text: String
        /// Bytes past the fetched range; zero when `text` is the whole file.
        let bytesLeft: Int

        var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
    }

    enum State: Equatable {
        case loading
        case loaded(Preview)
        case failed
    }

    /// What a preview's layout depends on, so a laid-out row can tell
    /// whether it is still current.
    struct Presentation: Equatable {
        var state: State?
        var isExpanded: Bool
        /// The language the text is highlighted as, the extension at first.
        var language: String?
        var wrapsText: Bool
        var rendersMarkdown: Bool

        /// Discord renders Markdown files as Markdown unless asked not to.
        var showsMarkdown: Bool {
            rendersMarkdown && ["markdown", "md", "mkd", "mkdown"].contains(language)
        }
    }

    nonisolated static let byteLimit = 50_000

    private(set) var states: [String: State] = [:]
    /// Messages showing a file that is still loading. The same file can
    /// appear in more than one, as in a forward.
    private var waitingMessages: [String: Set<MessageID>] = [:]
    private var broughtUpToDate: Set<MessageAttachment> = []

    private struct MessageAttachment: Hashable {
        let messageID: MessageID
        let attachmentID: String
    }
    private var expansions: [String: Bool] = [:]
    private var languages: [String: String] = [:]
    private var unwrapped: Set<String> = []
    private var plainMarkdown: Set<String> = []
    /// How far each expanded preview's text is scrolled.
    private(set) var scrollOffsets: [String: CGPoint] = [:]
    /// Re-signs an expiring Discord attachment link before it is fetched.
    var resolveRemoteURL: (@MainActor (URL) async -> URL)?
    /// Lays out the message again after one of its previews changes.
    var onChange: (@MainActor (MessageID) -> Void)?

    private nonisolated static let session = URLSession(configuration: .ephemeral)

    func presentation(of attachment: Attachment, in message: Message) -> Presentation {
        Presentation(
            state: states[attachment.id],
            isExpanded: expansions[attachment.id] ?? Self.isExpandedByDefault(message),
            language: languages[attachment.id] ?? attachment.textPreviewLanguage,
            wrapsText: !unwrapped.contains(attachment.id),
            rendersMarkdown: !plainMarkdown.contains(attachment.id)
        )
    }

    /// Discord opens a file's preview when the file is all its message holds.
    private static func isExpandedByDefault(_ message: Message) -> Bool {
        message.content.isEmpty && message.attachments.count == 1 && message.embeds.isEmpty
    }

    /// Starts fetching a preview the first time a row shows it, and brings
    /// a row laid out before the file finished loading up to date.
    func load(_ attachment: Attachment, in messageID: MessageID, showing shown: State?) {
        switch states[attachment.id] {
        case nil:
            states[attachment.id] = .loading
            waitingMessages[attachment.id] = [messageID]
            let resolveRemoteURL = resolveRemoteURL
            Task { [weak self] in
                let source = await resolveRemoteURL?(attachment.url) ?? attachment.url
                let preview = try? await Self.fetch(source)
                guard let self else { return }
                states[attachment.id] = preview.map(State.loaded) ?? .failed
                for waiting in waitingMessages.removeValue(forKey: attachment.id) ?? [] { onChange?(waiting) }
            }
        case .loading:
            waitingMessages[attachment.id, default: []].insert(messageID)
        case let state?:
            // Once per message, so a row that can't relayout never loops.
            if state != shown, broughtUpToDate.insert(MessageAttachment(messageID: messageID, attachmentID: attachment.id)).inserted {
                onChange?(messageID)
            }
        }
    }

    func toggleExpanded(_ attachment: Attachment, in message: Message) {
        expansions[attachment.id] = !presentation(of: attachment, in: message).isExpanded
        scrollOffsets[attachment.id] = nil
        onChange?(message.id)
    }

    func setScrollOffset(_ offset: CGPoint, for attachmentID: String) {
        scrollOffsets[attachmentID] = offset
    }

    func setLanguage(_ language: String, for attachment: Attachment, in messageID: MessageID) {
        languages[attachment.id] = language
        onChange?(messageID)
    }

    func toggleWrapping(_ attachment: Attachment, in messageID: MessageID) {
        if unwrapped.remove(attachment.id) == nil { unwrapped.insert(attachment.id) }
        onChange?(messageID)
    }

    func toggleMarkdown(_ attachment: Attachment, in messageID: MessageID) {
        if plainMarkdown.remove(attachment.id) == nil { plainMarkdown.insert(attachment.id) }
        onChange?(messageID)
    }

    private nonisolated static func fetch(_ url: URL) async throws -> Preview {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(byteLimit)", forHTTPHeaderField: "Range")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, !(200 ..< 300).contains(status) { throw URLError(.badServerResponse) }
        // Discord counts what is left from the range's total, so a server
        // that ignores the range sends the whole file with nothing left.
        let total = (http?.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) }
        let bytesLeft = total.map { max(0, $0 - data.count) } ?? 0
        var text = decode(data, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
        // The range can end inside a character.
        if bytesLeft > 0, !text.isEmpty { text.removeLast() }
        return Preview(text: stripInvisibles(text), bytesLeft: bytesLeft)
    }

    /// Decodes in the response's charset, or as UTF-8 that replaces what
    /// isn't valid, as Discord's decoder does, rather than failing.
    private nonisolated static func decode(_ data: Data, contentType: String?) -> String {
        if let charset = contentType?.split(separator: "charset=").dropFirst().last {
            let encoding = CFStringConvertIANACharSetNameToEncoding(String(charset) as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
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

    /// Discord drops format and control characters other than newlines and
    /// tabs, separators other than the plain space, and invisible fillers.
    private nonisolated static func stripInvisibles(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .format, .lineSeparator, .paragraphSeparator: false
            case .control: scalar == "\n" || scalar == "\t"
            case .spaceSeparator: scalar == " "
            default: !invisibleFillers.contains(scalar)
            }
        })
        return String(scalars)
    }

    private nonisolated static let invisibleFillers: Set<Unicode.Scalar> = [
        "\u{034F}", "\u{17B4}", "\u{17B5}", "\u{1160}", "\u{3164}", "\u{FFA0}",
    ]
}
