import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

extension NSAttributedString.Key {
    nonisolated static let discordEmojiToken = NSAttributedString.Key(
        "dev.sakuracord.discord-emoji-token"
    )
}

enum ComposerAutocompleteCommand {
    case previous
    case next
    case accept
    case dismiss
    case previousField
    case nextField
    case advance
    case removeField
}

enum ComposerEmojiAttributedText {
    static let expression = try! NSRegularExpression(
        pattern: #"<a?:[A-Za-z0-9_]+:[0-9]+>|"# + RenderedMention.tokenPattern
    )

    static func make(
        _ source: String,
        font: NSFont = .systemFont(ofSize: 15),
        mentionPresentations: [String: MentionPresentation] = [:],
        imageProvider: (String) -> NSImage? = { ComposerEmojiImageStore.shared.cachedImage(for: $0) }
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let range = NSRange(source.startIndex ..< source.endIndex, in: source)
        var cursor = 0
        for match in expression.matches(in: source, range: range) {
            if match.range.location > cursor {
                result.append(
                    NSAttributedString(
                        string: (source as NSString).substring(
                            with: NSRange(location: cursor, length: match.range.location - cursor)
                        ),
                        attributes: textAttributes(font)
                    )
                )
            }
            let token = (source as NSString).substring(with: match.range)
            if let mention = RenderedMention(rawToken: token) {
                let presentation = mentionPresentations[token]
                    ?? MentionPresentation.fallback(for: mention)
                result.append(
                    MentionAttachmentRenderer.attributedString(
                        presentation: presentation,
                        font: font
                    )
                )
                cursor = NSMaxRange(match.range)
                continue
            }
            let attachment = NSTextAttachment()
            let name = token.split(separator: ":").dropFirst().first.map(String.init) ?? "emoji"
            attachment.image = imageProvider(token)
                ?? placeholderImage(name: name, size: font.pointSize * 1.15)
            attachment.bounds = CGRect(
                x: 0,
                y: attachmentOriginY(font: font, size: font.pointSize * 1.15),
                width: font.pointSize * 1.15,
                height: font.pointSize * 1.15
            )
            let attributedAttachment = NSMutableAttributedString(attachment: attachment)
            var attachmentAttributes = textAttributes(font)
            attachmentAttributes[.discordEmojiToken] = token
            attributedAttachment.addAttributes(
                attachmentAttributes,
                range: NSRange(location: 0, length: attributedAttachment.length)
            )
            result.append(attributedAttachment)
            cursor = NSMaxRange(match.range)
        }
        if cursor < (source as NSString).length {
            result.append(
                NSAttributedString(
                    string: (source as NSString).substring(from: cursor), attributes: textAttributes(font)
                )
            )
        }
        return result
    }

    static func serialize(_ value: NSAttributedString, range: NSRange? = nil) -> String {
        let target = range ?? NSRange(location: 0, length: value.length)
        var result = ""
        value.enumerateAttributes(in: target) { attributes, range, _ in
            guard let token = (attributes[.discordEmojiToken] ?? attributes[.discordMentionToken]) as? String,
                  attributes[.attachment] is NSTextAttachment
            else {
                result += value.attributedSubstring(from: range).string
                return
            }

            let source = value.string as NSString
            var cursor = range.location
            while cursor < NSMaxRange(range) {
                let composedRange = NSIntersectionRange(
                    source.rangeOfComposedCharacterSequence(at: cursor),
                    range
                )
                let substring = source.substring(with: composedRange)
                result += composedRange.length == 1 && substring == "\u{FFFC}"
                    ? token
                    : substring
                cursor = NSMaxRange(composedRange)
            }
        }
        return result
    }

    static func usesCurrentMentionPresentations(
        _ value: NSAttributedString,
        mentionPresentations: [String: MentionPresentation]
    ) -> Bool {
        var isCurrent = true
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) {
            attributes, _, stop in
            guard let token = attributes[.discordMentionToken] as? String,
                  let mention = RenderedMention(rawToken: token)
            else { return }
            let expected = mentionPresentations[token]
                ?? MentionPresentation.fallback(for: mention)
            guard let attachment = attributes[.attachment] as? MentionTextAttachment,
                  attachment.presentation == expected
            else {
                isCurrent = false
                stop.pointee = true
                return
            }
        }
        return isCurrent
    }

    static func displayRange(forRaw range: NSRange, source: String) -> NSRange {
        let start = displayOffset(forRawOffset: range.location, source: source)
        let end = displayOffset(forRawOffset: NSMaxRange(range), source: source)
        return NSRange(location: start, length: max(0, end - start))
    }

    static func rawRange(forDisplay range: NSRange, attributed: NSAttributedString) -> NSRange {
        let start = serialize(
            attributed, range: NSRange(location: 0, length: min(range.location, attributed.length))
        ).utf16.count
        let endLocation = min(NSMaxRange(range), attributed.length)
        let end = serialize(attributed, range: NSRange(location: 0, length: endLocation)).utf16.count
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func displayOffset(forRawOffset offset: Int, source: String) -> Int {
        var reduction = 0
        let sourceLength = (source as NSString).length
        for match in expression.matches(in: source, range: NSRange(location: 0, length: sourceLength)) {
            if offset >= NSMaxRange(match.range) {
                reduction += match.range.length - 1
            } else if offset > match.range.location {
                return match.range.location - reduction + 1
            }
        }
        return max(0, offset - reduction)
    }

    static func textAttributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func attachmentOriginY(font: NSFont, size: CGFloat) -> CGFloat {
        (font.ascender + font.descender - size) / 2
    }

    private static func placeholderImage(name: String, size: CGFloat) -> NSImage {
        let image = NSImage(
            systemSymbolName: "face.smiling",
            accessibilityDescription: name
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        ) ?? NSImage(size: NSSize(width: size, height: size))
        image.isTemplate = true
        return image
    }
}

struct ComposerTextView: NSViewRepresentable {
    let text: String
    let placeholder: String
    let sendWithReturn: Bool
    var mentionPresentations: [String: MentionPresentation] = [:]
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    var onAutocompleteCommand: (ComposerAutocompleteCommand) -> Bool = { _ in false }
    var capturesUnfocusedTyping = false
    var maximumHeight: CGFloat = 150
    @Binding var selection: NSRange?
    @Binding var isFocused: Bool

    private let font = NSFont.systemFont(ofSize: 15)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = ComposerNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        // Let the workspace-level file destination own file drags. NSTextView's
        // default destination otherwise inserts a dropped file path as text.
        textView.unregisterDraggedTypes()
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.font = font
        textView.textColor = .labelColor
        textView.plainTypingAttributes = textAttributes
        textView.restorePlainTypingAttributes()
        textView.setAccessibilityLabel(placeholder)
        textView.onReturn = { [weak coordinator = context.coordinator] event in
            coordinator?.handleReturn(event) ?? false
        }
        textView.onAutocompleteCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.parent.onAutocompleteCommand(command) ?? false
        }
        textView.capturesUnfocusedTyping = capturesUnfocusedTyping

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self

        textView.onReturn = { [weak coordinator = context.coordinator] event in
            coordinator?.handleReturn(event) ?? false
        }
        textView.onAutocompleteCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.parent.onAutocompleteCommand(command) ?? false
        }
        textView.capturesUnfocusedTyping = capturesUnfocusedTyping
        textView.setAccessibilityLabel(placeholder)

        if ComposerEmojiAttributedText.serialize(textView.attributedString()) != text
            || !ComposerEmojiAttributedText.usesCurrentMentionPresentations(
                textView.attributedString(),
                mentionPresentations: mentionPresentations
            )
        {
            textView.textStorage?.setAttributedString(
                ComposerEmojiAttributedText.make(
                    text,
                    font: font,
                    mentionPresentations: mentionPresentations
                )
            )
            textView.font = font
            textView.textColor = .labelColor

            if selection == nil {
                textView.setSelectedRange(
                    ComposerEmojiAttributedText.displayRange(
                        forRaw: NSRange(location: text.utf16.count, length: 0), source: text
                    )
                )
            }
        }
        context.coordinator.loadEmojiImages(in: textView)
        context.coordinator.loadMentionAvatars(in: textView)

        if let selection,
           selection.location != NSNotFound,
           NSMaxRange(selection) <= text.utf16.count
        {
            let displayed = ComposerEmojiAttributedText.displayRange(forRaw: selection, source: text)
            if textView.selectedRange() != displayed {
                textView.setSelectedRange(displayed)
            }
        }
        textView.plainTypingAttributes = textAttributes
        textView.restorePlainTypingAttributes()

        context.coordinator.applyFocus(to: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return nil
        }

        let proposedWidth = proposal.width ?? scrollView.bounds.width
        guard proposedWidth > 0 else { return nil }

        layoutManager.ensureLayout(for: textContainer)

        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let contentHeight = ceil(max(lineHeight, layoutManager.usedRect(for: textContainer).height))

        return CGSize(width: proposedWidth, height: min(contentHeight, maximumHeight))
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        ComposerEmojiAttributedText.textAttributes(font)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var appliedFocus = false
        private var isNormalizing = false
        private let attachmentImageLoader = InlineAttachmentImageLoader()

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            appliedFocus = true
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            appliedFocus = false
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isNormalizing else { return }
            var raw = ComposerEmojiAttributedText.serialize(textView.attributedString())
            if !textView.hasMarkedText(),
               ComposerEmojiAttributedText.expression.firstMatch(
                   in: raw, range: NSRange(location: 0, length: (raw as NSString).length)
               ) != nil
            {
                let rawSelection = ComposerEmojiAttributedText.rawRange(
                    forDisplay: textView.selectedRange(), attributed: textView.attributedString()
                )
                let normalized = ComposerEmojiAttributedText.make(
                    raw,
                    mentionPresentations: parent.mentionPresentations
                )
                if normalized.string != textView.attributedString().string
                    || attachmentCount(in: normalized) != attachmentCount(in: textView.attributedString())
                {
                    isNormalizing = true
                    textView.textStorage?.setAttributedString(normalized)
                    textView.setSelectedRange(
                        ComposerEmojiAttributedText.displayRange(forRaw: rawSelection, source: raw)
                    )
                    if let composerTextView = textView as? ComposerNSTextView {
                        composerTextView.restorePlainTypingAttributes()
                    }
                    isNormalizing = false
                    loadEmojiImages(in: textView)
                    loadMentionAvatars(in: textView)
                }
                raw = ComposerEmojiAttributedText.serialize(textView.attributedString())
            }
            updateSelection(from: textView)
            if parent.text != raw {
                parent.onTextChange(raw)
            }
            textView.invalidateIntrinsicContentSize()
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateSelection(from: textView)
            if let composerTextView = textView as? ComposerNSTextView {
                composerTextView.restorePlainTypingAttributes()
                composerTextView.needsDisplay = true
            }
        }

        func applyFocus(to textView: NSTextView) {
            guard parent.isFocused != appliedFocus else { return }
            appliedFocus = parent.isFocused

            if parent.isFocused {
                Task { @MainActor [weak textView] in
                    guard let textView, parent.isFocused else { return }
                    textView.window?.makeFirstResponder(textView)
                }
            } else if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
        }

        func handleReturn(_ event: NSEvent) -> Bool {
            let action = ComposerReturnAction.decide(
                sendWithReturn: parent.sendWithReturn,
                shift: event.modifierFlags.contains(.shift),
                command: event.modifierFlags.contains(.command),
                hasMarkedText: (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
            )

            switch action {
            case .send:
                parent.onSubmit()
                return true
            case .newline, .inputMethod:
                return false
            }
        }

        private func updateSelection(from textView: NSTextView) {
            let newSelection = ComposerEmojiAttributedText.rawRange(
                forDisplay: textView.selectedRange(), attributed: textView.attributedString()
            )
            if parent.selection != newSelection {
                parent.selection = newSelection
            }
        }

        private func attachmentCount(in value: NSAttributedString) -> Int {
            var count = 0
            value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) {
                attachment, _, _ in if attachment != nil {
                    count += 1
                }
            }
            return count
        }

        func loadEmojiImages(in textView: NSTextView) {
            attachmentImageLoader.loadEmojiImages(in: textView)
        }

        func loadMentionAvatars(in textView: NSTextView) {
            attachmentImageLoader.loadMentionAvatars(in: textView)
        }
    }
}

@MainActor
final class ComposerEmojiImageStore {
    static let shared = ComposerEmojiImageStore()
    private let images = NSCache<NSString, NSImage>()
    private var registeredImages: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        images.countLimit = 256
    }

    func cachedImage(for token: String) -> NSImage? {
        registeredImages[token] ?? images.object(forKey: token as NSString)
    }

    func register(_ emoji: DiscordEmoji) {
        guard let url = emoji.assetURL,
              url.isFileURL,
              let image = NSImage(contentsOf: url)
        else { return }
        let displayImage = Self.preparedForInlineDisplay(image)
        registeredImages[emoji.messageToken] = displayImage
        images.setObject(displayImage, forKey: emoji.messageToken as NSString)
    }

    func image(for token: String) async -> NSImage? {
        if let cached = cachedImage(for: token) {
            return cached
        }
        if let task = inFlight[token] {
            return await task.value
        }
        let task = Task<NSImage?, Never> {
            let reference = EmojiReference(rawToken: token)
            guard let url = reference.imageURL(size: 64),
                  let data = try? await SharedMediaDataLoader.shared.data(for: url),
                  let image = NSImage(data: data)
            else { return nil }
            return Self.preparedForInlineDisplay(image)
        }
        inFlight[token] = task
        let image = await task.value
        inFlight[token] = nil
        if let image {
            images.setObject(image, forKey: token as NSString)
        }
        return image
    }

    nonisolated static func aspectFitRect(
        imageSize: NSSize,
        in bounds: NSRect
    ) -> NSRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              bounds.width > 0,
              bounds.height > 0
        else { return bounds }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func preparedForInlineDisplay(_ source: NSImage) -> NSImage {
        let sourceSize = source.size
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              abs(sourceSize.width - sourceSize.height) > 0.5
        else { return source }

        let side = max(sourceSize.width, sourceSize.height)
        let canvasSize = NSSize(width: side, height: side)
        let image = NSImage(size: canvasSize, flipped: false) { bounds in
            source.draw(
                in: aspectFitRect(imageSize: sourceSize, in: bounds),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return true
        }
        image.accessibilityDescription = source.accessibilityDescription
        return image
    }
}

final class ComposerNSTextView: NSTextView {
    var onReturn: ((NSEvent) -> Bool)?
    var onAutocompleteCommand: ((ComposerAutocompleteCommand) -> Bool)?
    var plainTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var capturesUnfocusedTyping = false {
        didSet {
            unfocusedTypingMonitor.synchronize(
                with: self,
                enabled: capturesUnfocusedTyping
            )
        }
    }
    private lazy var unfocusedTypingMonitor = ComposerUnfocusedTypingMonitor()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unfocusedTypingMonitor.synchronize(
            with: self,
            enabled: capturesUnfocusedTyping
        )
    }

    func restorePlainTypingAttributes() {
        typingAttributes = plainTypingAttributes
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawSelectionOverAttachments(in: dirtyRect)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        restorePlainTypingAttributes()
        super.insertText(insertString, replacementRange: replacementRange)
        restorePlainTypingAttributes()
    }

    override func keyDown(with event: NSEvent) {
        let textNavigationModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        let usesTextNavigationModifier = !event.modifierFlags
            .intersection(textNavigationModifiers).isEmpty
        let autocompleteCommand: ComposerAutocompleteCommand? =
            switch event.keyCode {
            case 126 where !usesTextNavigationModifier: .previous
            case 125 where !usesTextNavigationModifier: .next
            case 48 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:
                event.modifierFlags.contains(.shift) ? .previousField : .advance
            case 36, 76: .accept
            case 53: .dismiss
            case 51 where string.isEmpty: .removeField
            case 117 where string.isEmpty: .removeField
            case 123 where shouldLeaveField(backward: true, event: event): .previousField
            case 124 where shouldLeaveField(backward: false, event: event): .nextField
            default: nil
            }
        if let autocompleteCommand, onAutocompleteCommand?(autocompleteCommand) == true {
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, onReturn?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    private func shouldLeaveField(backward: Bool, event: NSEvent) -> Bool {
        let disallowed: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        guard event.modifierFlags.intersection(disallowed).isEmpty,
              selectedRange().length == 0
        else { return false }
        return backward
            ? selectedRange().location == 0
            : NSMaxRange(selectedRange()) == (string as NSString).length
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let raw = ComposerEmojiAttributedText.serialize(attributedString(), range: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }

    override func paste(_ sender: Any?) {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        insertText(value, replacementRange: selectedRange())
    }

}

@MainActor
final class ComposerUnfocusedTypingMonitor {
    private weak var textView: NSTextView?
    private var eventMonitor: Any?

    isolated deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func synchronize(with textView: NSTextView, enabled: Bool) {
        self.textView = textView
        guard enabled, textView.window != nil
        else {
            removeMonitor()
            return
        }
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let textView = self.textView,
                  let window = textView.window,
                  event.window === window,
                  window.isKeyWindow,
                  window.firstResponder !== textView,
                  !Self.isEditingText(window.firstResponder),
                  Self.shouldRedirect(event)
            else { return event }

            window.makeFirstResponder(textView)
            return event
        }
    }

    private func removeMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private static func isEditingText(_ responder: NSResponder?) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        return textView.isEditable || textView.isFieldEditor
    }

    nonisolated static func shouldRedirect(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .function]
        guard modifierFlags.intersection(disallowed).isEmpty,
              let characters,
              !characters.isEmpty
        else { return false }
        return characters.unicodeScalars.contains {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func shouldRedirect(_ event: NSEvent) -> Bool {
        shouldRedirect(characters: event.characters, modifierFlags: event.modifierFlags)
    }
}

struct ComposerFocusSurface: NSViewRepresentable {
    let focus: () -> Void

    func makeNSView(context: Context) -> ComposerFocusSurfaceView {
        ComposerFocusSurfaceView(focus: focus)
    }

    func updateNSView(_ view: ComposerFocusSurfaceView, context: Context) {
        view.focus = focus
    }
}

final class ComposerFocusSurfaceView: NSView {
    var focus: () -> Void

    init(focus: @escaping () -> Void) {
        self.focus = focus
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with _: NSEvent) {
        focus()
    }
}
