import AppKit
import MessageRendering
import Observation
import SakuraCordModels
import SwiftUI
import WebKit

enum ComposerAutocompleteCommand {
    case previous
    case next
    case accept
    case dismiss
    case previousField
    case nextField
    case advance
    case removeField

    /// Moves through `count` rows, wrapping at either end, accepts the
    /// highlighted row or dismisses the list. Field commands are not the
    /// list's, so they return false.
    func route(_ index: inout Int, count: Int, accept: (Int) -> Void, dismiss: () -> Void) -> Bool {
        switch self {
        case .previous: index = (index - 1 + count) % count
        case .next: index = (index + 1) % count
        case .accept, .advance: accept(min(index, count - 1))
        case .dismiss: dismiss()
        case .previousField, .nextField, .removeField: return false
        }
        return true
    }
}

/// The composer's scroll view, which an editor that never scrolls leaves
/// the wheel to its enclosing scroll view.
final class ComposerScrollView: NSScrollView {
    var scrolls = true

    override func scrollWheel(with event: NSEvent) {
        if scrolls {
            super.scrollWheel(with: event)
        } else {
            (superview?.enclosingScrollView ?? nextResponder)?.scrollWheel(with: event)
        }
    }
}

struct ComposerTextView: NSViewRepresentable {
    let text: String
    var conversationID: ChannelID?
    var translationEditID: UUID?
    let placeholder: String
    let sendWithReturn: Bool
    var generalInputSettings: GeneralInputSettingsSnapshot = .defaults
    var mentionPresentations: [String: MentionPresentation] = [:]
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    var onEscape: () -> Void = {}
    var onEditLatestMessage: () -> Bool = { false }
    var onNavigateReplySelection: (MessageReplyNavigationDirection) -> Bool = { _ in false }
    var onAutocompleteCommand: (ComposerAutocompleteCommand) -> Bool = { _ in false }
    var onDropTargetChanged: ((_ isTargeted: Bool, _ isInstant: Bool) -> Void)?
    var onReceiveAttachments: ((_ attachments: ComposerIncomingAttachments, _ isInstant: Bool) -> Bool)?
    /// Whether the destination currently accepts files; pastes fall back to text otherwise.
    var canReceiveAttachments: () -> Bool = { true }
    var onCompositionStateChange: ((Bool) -> Void)?
    var capturesUnfocusedTyping = false
    var verticalContentInset: CGFloat = 0
    var maximumHeight: CGFloat = InterfaceScale.metric(150)
    /// Overrides the accent caret, for text set on an accent fill.
    var insertionPointColor: NSColor?
    var sendTransitionAnchor: ComposerSendTransitionAnchor?
    var textStyle: ComposerTextStyle = .composer
    /// False for an editor exactly as tall as its text, as inline edits
    /// are: it never scrolls, and the wheel scrolls whatever holds it.
    var scrolls = true
    var accessibilityHint: String?
    @Binding var selection: NSRange?
    @Binding var isFocused: Bool

    private var font: NSFont { textStyle.font }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = ComposerLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = ComposerNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.onFirstResponderChange = { [weak coordinator = context.coordinator] in
            coordinator?.firstResponderDidChange($0)
        }
        textView.isEditable = context.environment.acceptsComposerInput
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = true
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.allowsDocumentBackgroundColorChange = false
        textView.writingToolsBehavior = .none
        textView.allowedWritingToolsResultOptions = .plainText
        // NSTextView is the AppKit drag destination inside the SwiftUI
        // workspace. Own file URLs here so AppKit cannot fall back to inserting
        // their paths into the message text.
        textView.unregisterDraggedTypes()
        textView.registerForDraggedTypes([.fileURL])
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: verticalContentInset)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.font = font
        textView.textColor = textStyle.attributes[.foregroundColor] as? NSColor ?? .labelColor
        if let insertionPointColor { textView.insertionPointColor = insertionPointColor }
        textView.plainTextStyle = textStyle
        textView.restorePlainTypingAttributes()
        textView.setAccessibilityLabel(placeholder)
        textView.onReturn = { [weak coordinator = context.coordinator] event in
            coordinator?.handleReturn(event) ?? false
        }
        textView.onAutocompleteCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.parent.onAutocompleteCommand(command) ?? false
        }
        textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEscape()
        }
        textView.onEditLatestMessage = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEditLatestMessage() ?? false
        }
        textView.onNavigateReplySelection = { [weak coordinator = context.coordinator] direction in
            coordinator?.parent.onNavigateReplySelection(direction) ?? false
        }
        textView.onDropTargetChanged = onDropTargetChanged
        textView.onReceiveAttachments = onReceiveAttachments
        textView.canReceiveAttachments = { [weak coordinator = context.coordinator] in
            coordinator?.parent.canReceiveAttachments() ?? false
        }
        textView.capturesUnfocusedTyping = capturesUnfocusedTyping && context.environment.acceptsComposerInput
        ComposerTextCheckingConfiguration.apply(generalInputSettings, to: textView)

        let scrollView = ComposerScrollView()
        scrollView.scrolls = scrolls
        // The text view alone is the control; a fixed container is no scroll area.
        scrollView.setAccessibilityElement(scrolls)
        if !scrolls { scrollView.verticalScrollElasticity = .none }
        textView.setAccessibilityHelp(accessibilityHint)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        sendTransitionAnchor?.textView = textView

        return scrollView
    }

    /// The interface size changed: restyle the draft without moving the caret.
    private func restyleDraft(in textView: ComposerNSTextView) {
        let selectedRange = textView.selectedRange()
        textView.font = font
        textView.plainTextStyle = textStyle
        textView.typingAttributes = textAttributes
        textView.textStorage?.setAttributedString(
            ComposerEmojiAttributedText.make(
                text,
                style: textStyle,
                mentionPresentations: mentionPresentations
            )
        )
        let length = textView.string.utf16.count
        let location = min(selectedRange.location, length)
        textView.setSelectedRange(NSRange(
            location: location,
            length: min(selectedRange.length, length - location)
        ))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        if context.coordinator.parent.conversationID != conversationID {
            // Discard the old input session before rebinding its callbacks to
            // another conversation. unmarkText can otherwise publish the old draft.
            textView.delegate = nil
            textView.inputContext?.discardMarkedText()
            textView.unmarkText()
            textView.delegate = context.coordinator
        }
        let isTranslationEdit = translationEditID != nil
            && translationEditID != context.coordinator.parent.translationEditID
            && conversationID == context.coordinator.parent.conversationID
        context.coordinator.parent = self
        sendTransitionAnchor?.textView = textView
        textView.isEditable = context.environment.acceptsComposerInput
        textView.capturesUnfocusedTyping = capturesUnfocusedTyping && context.environment.acceptsComposerInput
        context.coordinator.updateCompositionState(from: textView, deferringNotification: true)

        textView.onReturn = { [weak coordinator = context.coordinator] event in
            coordinator?.handleReturn(event) ?? false
        }
        textView.onAutocompleteCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.parent.onAutocompleteCommand(command) ?? false
        }
        textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEscape()
        }
        textView.onEditLatestMessage = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEditLatestMessage() ?? false
        }
        textView.onNavigateReplySelection = { [weak coordinator = context.coordinator] direction in
            coordinator?.parent.onNavigateReplySelection(direction) ?? false
        }
        textView.onDropTargetChanged = onDropTargetChanged
        textView.onReceiveAttachments = onReceiveAttachments
        textView.canReceiveAttachments = { [weak coordinator = context.coordinator] in
            coordinator?.parent.canReceiveAttachments() ?? false
        }

        // During IME composition, NSTextView owns the marked range. Applying
        // the SwiftUI snapshot, selection, or typing attributes here can
        // replace the uncommitted Japanese text and make it disappear.
        guard !textView.hasMarkedText() else {
            context.coordinator.applyFocus(to: textView, resigning: textView)
            return
        }

        if let insertionPointColor { textView.insertionPointColor = insertionPointColor }
        textView.textContainerInset = NSSize(width: 0, height: verticalContentInset)
        ComposerTextCheckingConfiguration.apply(generalInputSettings, to: textView)
        textView.setAccessibilityLabel(placeholder)

        if textView.font != font {
            restyleDraft(in: textView)
        }

        if ComposerEmojiAttributedText.serialize(textView.attributedString()) != text
            || !ComposerEmojiAttributedText.usesCurrentMentionPresentations(
                textView.attributedString(),
                mentionPresentations: mentionPresentations
            )
        {
            let replacement = ComposerEmojiAttributedText.make(
                text, style: textStyle, mentionPresentations: mentionPresentations
            )
            if isTranslationEdit {
                textView.breakUndoCoalescing()
                textView.insertText(replacement, replacementRange: NSRange(location: 0, length: textView.attributedString().length))
                textView.undoManager?.setActionName(String(localized: "Translate Draft"))
                textView.breakUndoCoalescing()
            } else {
                textView.textStorage?.setAttributedString(replacement)
            }

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
        textView.plainTextStyle = textStyle
        textView.restorePlainTypingAttributes()

        context.coordinator.applyFocus(to: textView, resigning: textView)
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

        // A draft's lines, such as a smaller subtext line, set its height;
        // an empty draft keeps a line of the plain text.
        let textHeight = textView.string.isEmpty
            ? textStyle.emptyLineHeight
            : layoutManager.usedRect(for: textContainer).maxY
        let contentHeight = ceil(textHeight + textView.textContainerInset.height * 2)

        scrollView.hasVerticalScroller = scrolls && contentHeight > maximumHeight
        return CGSize(width: proposedWidth, height: min(contentHeight, maximumHeight))
    }

    private var textAttributes: [NSAttributedString.Key: Any] { textStyle.attributes }

    final class Coordinator: NSObject, NSTextViewDelegate, ComposerFocusSyncing {
        var parent: ComposerTextView
        var appliedFocus = false
        var focusBinding: Binding<Bool> { parent.$isFocused }
        private var isNormalizing = false
        private var isMarkedTextActive = false
        private let attachmentImageLoader = InlineAttachmentImageLoader()

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidEndEditing(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                updateCompositionState(from: textView)
            } else {
                updateCompositionState(isComposing: false)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isNormalizing else { return }
            updateCompositionState(from: textView)
            var raw = ComposerEmojiAttributedText.serialize(textView.attributedString())
            // An existing pill is checked too: typing on after `@here` leaves
            // literal text that no longer matches, and the pill must unfold.
            if !textView.hasMarkedText(),
               attachmentCount(in: textView.attributedString()) > 0
                   || ComposerEmojiAttributedText.expression.firstMatch(
                       in: raw, range: NSRange(location: 0, length: (raw as NSString).length)
                   ) != nil
            {
                let rawSelection = ComposerEmojiAttributedText.rawRange(
                    forDisplay: textView.selectedRange(), attributed: textView.attributedString()
                )
                let normalized = ComposerEmojiAttributedText.make(
                    raw,
                    style: parent.textStyle,
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
            // The representable's text is a render snapshot. Rapid edits may
            // return to that value before SwiftUI refreshes it; every native
            // text change must still reach the current draft model.
            parent.onTextChange(raw)
            textView.invalidateIntrinsicContentSize()
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateCompositionState(from: textView)
            updateSelection(from: textView)
            if let composerTextView = textView as? ComposerNSTextView,
               !composerTextView.hasMarkedText()
            {
                composerTextView.restorePlainTypingAttributes()
                composerTextView.needsDisplay = true
            }
        }

        func updateCompositionState(from textView: NSTextView, deferringNotification: Bool = false) {
            updateCompositionState(isComposing: textView.hasMarkedText(), deferringNotification: deferringNotification)
        }

        private func updateCompositionState(isComposing: Bool, deferringNotification: Bool = false) {
            guard isMarkedTextActive != isComposing else { return }
            isMarkedTextActive = isComposing
            if deferringNotification {
                // A representable update must not synchronously mutate SwiftUI
                // state. Read the latest state in case composition starts again.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    parent.onCompositionStateChange?(isMarkedTextActive)
                }
            } else {
                parent.onCompositionStateChange?(isComposing)
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
            value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, _, _ in
                if attachment != nil {
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

final class ComposerNSTextView: ComposerFocusReportingTextView, WindowModalEscapeConsumer {
    var onReturn: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    var onEditLatestMessage: (() -> Bool)?
    var onNavigateReplySelection: ((MessageReplyNavigationDirection) -> Bool)?
    var onAutocompleteCommand: ((ComposerAutocompleteCommand) -> Bool)?
    var onDropTargetChanged: ((_ isTargeted: Bool, _ isInstant: Bool) -> Void)?
    var onReceiveAttachments: ((_ attachments: ComposerIncomingAttachments, _ isInstant: Bool) -> Bool)?
    var canReceiveAttachments: (() -> Bool)?
    var plainTextStyle: ComposerTextStyle = .composer
    var plainTypingAttributes: [NSAttributedString.Key: Any] { plainTextStyle.attributes }
    var capturesUnfocusedTyping = false {
        didSet {
            unfocusedTypingMonitor.synchronize(
                with: self,
                enabled: capturesUnfocusedTyping,
                onUnfocusedReturn: unfocusedReturnHandler,
                onEditLatestMessage: unfocusedEditLatestMessageHandler,
                onNavigateReplySelection: unfocusedReplyNavigationHandler,
                onEscape: escapeHandler,
                onPasteAttachments: pasteAttachmentsHandler
            )
        }
    }
    private lazy var unfocusedTypingMonitor = ComposerUnfocusedTypingMonitor()

    private var unfocusedReturnHandler: (NSEvent) -> Bool {
        { [weak self] event in
            self?.onReturn?(event) ?? false
        }
    }

    private var unfocusedEditLatestMessageHandler: () -> Bool {
        { [weak self] in
            self?.onEditLatestMessage?() ?? false
        }
    }

    private var unfocusedReplyNavigationHandler:
        (MessageReplyNavigationDirection) -> Bool
    {
        { [weak self] direction in
            self?.onNavigateReplySelection?(direction) ?? false
        }
    }

    private var escapeHandler: () -> Void {
        { [weak self] in
            self?.onEscape?()
        }
    }

    private var pasteAttachmentsHandler: () -> Bool {
        { [weak self] in
            self?.readAttachments(from: .general) ?? false
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // As first responder the text view hears every mouse move and shows its
    // I-beam; a view drawn over it, such as the inline editor's controls,
    // keeps its own cursor.
    override func mouseMoved(with event: NSEvent) {
        guard let hit = window?.contentView?.hitTest(event.locationInWindow), hit !== self, !hit.isDescendant(of: self) else {
            return super.mouseMoved(with: event)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateAttachmentDropTarget(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateAttachmentDropTarget(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        true
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDropTargetChanged?(false, false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        let urls = ComposerPasteboardAttachments.fileURLs(
            from: sender.draggingPasteboard
        )
        let isInstant = NSEvent.modifierFlags.contains(.shift)
        let handled = !urls.isEmpty
            && onReceiveAttachments?(.external(urls), isInstant) == true
        onDropTargetChanged?(false, false)
        return handled
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onDropTargetChanged?(false, false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDropTargetChanged?(false, false)
    }

    private func updateAttachmentDropTarget(
        _ sender: any NSDraggingInfo
    ) -> NSDragOperation {
        let acceptsDrop = isEditable && onReceiveAttachments != nil
            && !ComposerPasteboardAttachments.fileURLs(
                from: sender.draggingPasteboard
            ).isEmpty
        let isInstant = acceptsDrop && NSEvent.modifierFlags.contains(.shift)
        onDropTargetChanged?(acceptsDrop, isInstant)
        return acceptsDrop ? .copy : []
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unfocusedTypingMonitor.synchronize(
            with: self,
            enabled: capturesUnfocusedTyping,
            onUnfocusedReturn: unfocusedReturnHandler,
            onEditLatestMessage: unfocusedEditLatestMessageHandler,
            onNavigateReplySelection: unfocusedReplyNavigationHandler,
            onEscape: escapeHandler,
            onPasteAttachments: pasteAttachmentsHandler
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
        guard isEditable else { return }
        restorePlainTypingAttributes()
        if let attributed = insertString as? NSAttributedString {
            let normalized = NSMutableAttributedString(attributedString: attributed)
            ComposerMarkdownPresentation.apply(to: normalized, style: plainTextStyle)
            super.insertText(normalized, replacementRange: replacementRange)
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
        }
        restorePlainTypingAttributes()
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable else {
            super.keyDown(with: event)
            return
        }
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let autocompleteCommand = autocompleteCommand(for: event)
        if let autocompleteCommand, onAutocompleteCommand?(autocompleteCommand) == true {
            return
        }
        if handleReplyNavigation(event) {
            return
        }
        if ComposerLatestMessageEditingPolicy.shouldRequest(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            composerIsEmpty: string.isEmpty
        ),
           onEditLatestMessage?() == true
        {
            // The timeline takes focus when it actually opens an editor.
            // Requests blocked by a send animation keep the composer focused.
            return
        }
        if KeyboardShortcutPolicy.isPlainEscape(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            onEscape?()
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, onReturn?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Escape closes an open suggestion menu before the modal around it.
    func consumeModalEscape() -> Bool {
        isEditable && !hasMarkedText() && onAutocompleteCommand?(.dismiss) == true
    }

    private func autocompleteCommand(for event: NSEvent) -> ComposerAutocompleteCommand? {
        let textNavigationModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        let usesTextNavigationModifier = !event.modifierFlags
            .isDisjoint(with: textNavigationModifiers)
        return switch event.keyCode {
            case 126 where !usesTextNavigationModifier: .previous
            case 125 where !usesTextNavigationModifier: .next
            case 48 where event.modifierFlags.isDisjoint(with: [.command, .option, .control]):
                event.modifierFlags.contains(.shift) ? .previousField : .advance
            case 36, 76: usesTextNavigationModifier ? nil : .accept
            case 53 where KeyboardShortcutPolicy.isPlainEscape(keyCode: event.keyCode, modifierFlags: event.modifierFlags): .dismiss
            case 51 where string.isEmpty: .removeField
            case 117 where string.isEmpty: .removeField
            case 123 where shouldLeaveField(backward: true, event: event): .previousField
            case 124 where shouldLeaveField(backward: false, event: event): .nextField
            default: nil
            }
    }

    nonisolated static func replyNavigationDirection(
        for event: NSEvent
    ) -> MessageReplyNavigationDirection? {
        let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevant == .command else { return nil }
        return switch event.keyCode {
        case 126: .older
        case 125: .newer
        default: nil
        }
    }

    private func handleReplyNavigation(_ event: NSEvent) -> Bool {
        guard let direction = Self.replyNavigationDirection(for: event) else {
            return false
        }
        return onNavigateReplySelection?(direction) == true
    }

    private func shouldLeaveField(backward: Bool, event: NSEvent) -> Bool {
        let disallowed: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        guard event.modifierFlags.isDisjoint(with: disallowed),
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
        Pasteboard.copy(raw)
    }

    // AppKit validates Paste and Services against these types, then reads
    // the first available one through `readSelection(from:type:)`.
    // Destinations that cannot take files omit the attachment types, so the
    // clipboard's text representation is pasted instead.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        receivesAttachments
            ? ComposerPasteboardAttachments.readableTypes + Self.textPasteboardTypes
            : Self.textPasteboardTypes
    }

    private var receivesAttachments: Bool {
        isEditable && onReceiveAttachments != nil && canReceiveAttachments?() != false
    }

    private static let textPasteboardTypes: [NSPasteboard.PasteboardType] = [.string, .rtfd, .rtf, .html]

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable else { return false }
        if ComposerPasteboardAttachments.readableTypes.contains(type) {
            // Declining lets AppKit read the next available type.
            guard receivesAttachments, let onReceiveAttachments,
                  let attachments = ComposerPasteboardAttachments.attachments(from: pasteboard, type: type)
            else { return false }
            return onReceiveAttachments(attachments, false)
        }
        guard let text = Self.plainText(from: pasteboard, type: type) else { return false }
        if type == .string, receivesAttachments, let onReceiveAttachments,
           let batch = ComposerPasteboardAttachments.longTextAttachment(text)
        {
            if onReceiveAttachments(.owned(batch), false) { return true }
            batch.discard()
        }
        insertText(text, replacementRange: selectedRange())
        return true
    }

    private static func plainText(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> String? {
        let documentType: NSAttributedString.DocumentType
        switch type {
        case .string: return pasteboard.string(forType: .string)
        case .rtfd: documentType = .rtfd
        case .rtf: documentType = .rtf
        case .html: documentType = .html
        default: return nil
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        if type == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        guard let data = pasteboard.data(forType: type) else { return nil }
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil).string
    }

    /// Reads only attachments, leaving text paste to the focused responder.
    private func readAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard receivesAttachments,
              let type = pasteboard.availableType(from: ComposerPasteboardAttachments.readableTypes)
        else { return false }
        return readSelection(from: pasteboard, type: type)
    }
}

private extension EnvironmentValues {
    /// A composer in a pane leaving the workspace takes no text: its thread
    /// has closed, and a picker closing with it can hand the editor focus
    /// back.
    var acceptsComposerInput: Bool { isEnabled && !isLeavingWorkspace }
}
