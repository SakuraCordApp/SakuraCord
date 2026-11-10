import AppKit
import SakuraCordModels
import SwiftUI

/// The structured slash-command input. It owns its text locally so typing
/// never waits on SwiftUI; the draft model decides what each edit means.
struct ApplicationCommandEditorView: NSViewRepresentable {
    let composer: ApplicationCommandComposerModel
    let draft: ApplicationCommandDraft
    let caretRequestRevision: Int
    let fieldIssue: ApplicationCommandFieldIssue?
    let roles: [GuildRole]
    var generalInputSettings: GeneralInputSettingsSnapshot = .defaults
    var capturesUnfocusedTyping = true
    let onKeyboardCommand: (ComposerAutocompleteCommand) -> Bool
    let onSubmit: () -> Void
    /// Leaves the command, continuing with the given ordinary message text.
    let onCancel: (String) -> Void
    let canReceiveAttachment: () -> Bool
    let receiveAttachment: (ComposerIncomingAttachments) -> Void
    @Binding var isFocused: Bool

    static var maximumHeight: CGFloat { InterfaceScale.metric(150) }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: InterfaceScale.metric(400), height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        layoutManager.delegate = context.coordinator

        let textView = ApplicationCommandTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.capturesUnfocusedTyping = capturesUnfocusedTyping
        textView.onFirstResponderChange = { [weak coordinator = context.coordinator] in
            coordinator?.firstResponderDidChange($0)
        }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        // Undo restores draft values and structure together, not derived text ranges.
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: ApplicationCommandEditorStyle.verticalInset)
        // Option values are sent verbatim; substitutions would change them.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        ComposerTextCheckingConfiguration.apply(generalInputSettings, to: textView)
        textView.writingToolsBehavior = .none
        textView.unregisterDraggedTypes()
        textView.registerForDraggedTypes([.fileURL])
        textView.applySakuraCordTextSelectionAppearance()
        textView.setAccessibilityLabel("Command \(draft.command.displayName)")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        context.coordinator.render(in: textView, caret: composer.caretRequest)
        context.coordinator.appliedCaretRevision = caretRequestRevision
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ApplicationCommandTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        textView.capturesUnfocusedTyping = capturesUnfocusedTyping
        ComposerTextCheckingConfiguration.apply(generalInputSettings, to: textView)
        textView.applySakuraCordTextSelectionAppearance()
        guard !textView.isComposing else {
            coordinator.applyFocus(to: textView)
            return
        }
        let caret = coordinator.appliedCaretRevision != caretRequestRevision
            ? composer.caretRequest : nil
        coordinator.appliedCaretRevision = caretRequestRevision
        coordinator.render(in: textView, caret: caret)
        coordinator.applyFocus(to: textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? NSTextView else { return nil }
        // Ideal-size passes propose an unbounded width; only a real width
        // wraps, or the editor would report a single line.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let used = context.coordinator.measure(
            textView.textStorage ?? NSTextStorage(), width: width ?? .greatestFiniteMagnitude
        )
        let height = ceil(
            max(ApplicationCommandEditorStyle.lineHeight, used.height) + textView.textContainerInset.height * 2
        )
        scrollView.hasVerticalScroller = height > Self.maximumHeight
        return CGSize(width: width ?? min(ceil(used.width), InterfaceScale.metric(600)), height: min(height, Self.maximumHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: ApplicationCommandEditorView
        var appliedCaretRevision = 0
        private(set) var document: ApplicationCommandEditorDocument?
        private var renderedSignature: Int?
        private var pendingNativeFocus: ApplicationCommandDraftFocus?
        private var pendingNativeLength = 0
        /// Where the caret belongs after a native edit. NSTextView only moves
        /// its selection after posting the change, so it cannot be read there.
        private var pendingNativeCaret = 0
        private var isApplying = false
        private var appliedFocus = false
        private var isContinuingAsPlainText = false
        private var renderedDraft: ApplicationCommandDraft?
        private var undoSelection: NSRange?
        let undoManager: UndoManager = {
            let manager = UndoManager()
            manager.levelsOfUndo = 100
            return manager
        }()

        init(parent: ApplicationCommandEditorView) {
            self.parent = parent
        }

        /// SwiftUI asks for several candidate widths, so measurement uses its
        /// own layout rather than resizing the text the user sees.
        func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
            let storage = NSTextStorage(attributedString: text)
            let layoutManager = NSLayoutManager()
            layoutManager.delegate = self
            let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)
            return layoutManager.usedRect(for: container).size
        }

        /// The model's draft is current even between SwiftUI updates.
        var draft: ApplicationCommandDraft { parent.composer.draft ?? parent.draft }

        /// Discord keeps each chip on one line; wrap before a chip, never inside.
        nonisolated func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldBreakLineByWordBeforeCharacterAt charIndex: Int
        ) -> Bool {
            MainActor.assumeIsolated {
                guard let document else { return true }
                return !document.fields.contains {
                    charIndex > $0.label.location && charIndex < NSMaxRange($0.value)
                }
            }
        }

        // MARK: Rendering

        /// Rebuilds styled text from the draft when it differs from what is shown.
        func render(in textView: ApplicationCommandTextView, caret: ApplicationCommandEditorCaret?) {
            guard !isContinuingAsPlainText else { return }
            let draft = parent.composer.draft ?? parent.draft
            let document = ApplicationCommandEditorDocument(draft: draft)
            var hasher = Hasher()
            hasher.combine(document.string)
            hasher.combine(draft.fields.map { $0.resolved.map(String.init(describing:)) })
            hasher.combine(draft.focus)
            hasher.combine(parent.fieldIssue?.fieldID)
            hasher.combine(parent.roles.map(\.colorHex))
            hasher.combine(InterfaceScale.factor)
            let signature = hasher.finalize()
            textView.textContainerInset = NSSize(width: 0, height: ApplicationCommandEditorStyle.verticalInset)
            let previousSelection = textView.selectedRange()
            if let previous = renderedDraft, previous.command.id == draft.command.id,
               previous.fields != draft.fields || previous.gapTexts != draft.gapTexts {
                registerUndo(previous, selection: undoSelection ?? previousSelection, in: textView)
            }
            renderedDraft = draft
            undoSelection = nil
            self.document = document
            textView.document = document
            textView.focus = draft.focus
            textView.issueFieldID = parent.fieldIssue?.fieldID
            textView.valueTints = ApplicationCommandEditorStyle.valueTints(for: draft, roles: parent.roles)
            textView.remainingOptionCount = draft.availableOptions.count
            if signature != renderedSignature {
                renderedSignature = signature
                isApplying = true
                textView.textStorage?.setAttributedString(
                    ApplicationCommandEditorStyle.attributedString(
                        document: document, draft: draft, roles: parent.roles
                    )
                )
                isApplying = false
                textView.invalidateIntrinsicContentSize()
                textView.needsDisplay = true
            }
            let target: NSRange
            if let caret {
                target = document.range(of: caret)
            } else if previousSelection.location == NSNotFound || NSMaxRange(previousSelection) > document.length {
                target = NSRange(location: document.location(of: document.caret(endOf: draft.focus)), length: 0)
            } else {
                target = previousSelection
            }
            if textView.selectedRange() != target {
                isApplying = true
                textView.setSelectedRange(target)
                isApplying = false
            }
            textView.updateTypingAttributes(for: draft)
            if caret != nil { textView.scrollRangeToVisible(target) }
        }

        private func registerUndo(
            _ previous: ApplicationCommandDraft, selection: NSRange, in textView: ApplicationCommandTextView
        ) {
            undoManager.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView, coordinator.parent.composer.draft?.command.id == previous.command.id else { return }
                coordinator.parent.composer.applyEditorDraft(previous, caret: nil)
                coordinator.render(in: textView, caret: nil)
                let length = textView.string.utf16.count
                let location = min(selection.location, length)
                textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            }
            undoManager.setActionName("Edit Command")
        }

        /// NSTextView moves its caret after textDidChange. Finish structural
        /// edits now so the next IME operation/keystroke reaches the new field.
        func finishNativeInsertion(in textView: ApplicationCommandTextView) {
            let composer = parent.composer
            guard appliedCaretRevision != composer.caretRequestRevision,
                  let caret = composer.caretRequest else { return }
            appliedCaretRevision = composer.caretRequestRevision
            switch caret {
            case .command: composer.setFocus(.command)
            case let .field(id, _, _): composer.setFocus(.field(id))
            case let .gap(index, _): composer.setFocus(.gap(index))
            }
            render(in: textView, caret: caret)
        }

        func applyFocus(to textView: NSTextView) {
            guard parent.isFocused != appliedFocus else { return }
            appliedFocus = parent.isFocused
            if parent.isFocused {
                Task { @MainActor [weak textView] in
                    guard let textView, self.parent.isFocused else { return }
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }

        func firstResponderDidChange(_ isFirstResponder: Bool) {
            // Publish after AppKit finishes the responder change, never during
            // a SwiftUI update that triggered it.
            Task { @MainActor [weak self] in
                guard let self else { return }
                appliedFocus = isFirstResponder
                if parent.isFocused != isFirstResponder { parent.isFocused = isFirstResponder }
            }
        }

        // MARK: Editing

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn range: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isApplying, let document, let textView = textView as? ApplicationCommandTextView,
                  !textView.isComposing else { return true }
            undoSelection = textView.selectedRange()
            switch document.edit(replacing: range, with: replacementString ?? "", draft: draft) {
            case let .native(focus):
                pendingNativeFocus = focus
                pendingNativeLength = document.length
                pendingNativeCaret = range.location + (replacementString ?? "").utf16.count
                return true
            case let .replace(updated, caret):
                apply(updated, caret: caret, in: textView)
                return false
            case let .cancel(text):
                // SwiftUI replaces this view on its next update. Keep accepting
                // native edits in the meantime instead of repeatedly replacing
                // the selected command and losing the start of fast input.
                isContinuingAsPlainText = true
                pendingNativeFocus = nil
                self.document = nil
                textView.document = nil
                textView.focus = nil
                textView.remainingOptionCount = 0
                isApplying = true
                textView.string = text
                textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
                isApplying = false
                parent.onCancel(text)
                return false
            case .ignore:
                NSSound.beep()
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            if isContinuingAsPlainText, !isApplying,
               let textView = notification.object as? ApplicationCommandTextView {
                if !textView.isComposing { parent.onCancel(textView.string) }
                return
            }
            guard !isApplying, let focus = pendingNativeFocus, let document,
                  let textView = notification.object as? ApplicationCommandTextView,
                  !textView.isComposing else { return }
            pendingNativeFocus = nil
            let delta = (textView.string as NSString).length - pendingNativeLength
            let original: NSRange? = switch focus {
            case .command: nil
            case let .field(id): document.span(id)?.value
            case let .gap(index): document.gaps.indices.contains(index) ? document.gaps[index] : nil
            }
            guard let original else { return }
            let range = NSRange(location: original.location, length: max(0, original.length + delta))
            guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
            let text = (textView.string as NSString).substring(with: range)
            let caretOffset = textView.hasMarkedText()
                ? textView.selectedRange().location - range.location
                : pendingNativeCaret - range.location
            parent.composer.setText(text, for: focus)
            // Keep the local document in step so the next keystroke maps correctly.
            guard let updated = parent.composer.draft else { return }
            let caret: ApplicationCommandEditorCaret = switch updated.focus {
            case let .field(id) where updated.focus == focus: .field(id, offset: caretOffset)
            case let .gap(index) where updated.focus == focus: .gap(index, offset: caretOffset)
            default: ApplicationCommandEditorDocument(draft: updated).caret(endOf: updated.focus)
            }
            if !textView.hasMarkedText() {
                render(in: textView, caret: caret)
            } else {
                self.document = ApplicationCommandEditorDocument(draft: updated)
                textView.document = self.document
            }
        }

        private func apply(
            _ updated: ApplicationCommandDraft,
            caret: ApplicationCommandEditorCaret,
            in textView: ApplicationCommandTextView
        ) {
            parent.composer.applyEditorDraft(updated, caret: caret)
            appliedCaretRevision = parent.composer.caretRequestRevision
            render(in: textView, caret: caret)
        }

        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRange old: NSRange,
            toCharacterRange new: NSRange
        ) -> NSRange {
            guard !isApplying, let document,
                  (textView as? ApplicationCommandTextView)?.isComposing != true else { return new }
            // AppKit's line boundary includes neighbouring chips. Discord's
            // Command-arrow stays within the current editable value/name.
            var new = new
            if let event = NSApp.currentEvent, event.type == .keyDown,
               event.modifierFlags.contains(.command), [123, 124].contains(event.keyCode),
               let focus = document.focus(at: old.location) {
                let bounds: NSRange? = switch focus {
                case .command: document.command
                case let .field(id): document.span(id)?.value
                case let .gap(index): document.gaps[index]
                }
                if let bounds, old.length == 0 || document.focus(at: NSMaxRange(old)) == focus {
                    let lower = min(max(bounds.location, new.location), NSMaxRange(bounds))
                    let upper = min(max(lower, NSMaxRange(new)), NSMaxRange(bounds))
                    new = NSRange(location: lower, length: upper - lower)
                }
            }
            let isPointer = NSApp.currentEvent.map {
                [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains($0.type)
            } ?? false
            if isPointer { resetVerticalMovement() }
            if new.length > 0 {
                guard !isPointer else { return new }
                // Shift-arrows cross a label in one step, while retaining the
                // anchor so deleting a partial value does not remove its chip.
                if NSMaxRange(new) == NSMaxRange(old), new.location != old.location {
                    let lower = document.snap(new.location, direction: new.location < old.location ? .backward : .forward)
                    return NSRange(location: lower, length: max(0, NSMaxRange(new) - lower))
                }
                if new.location == old.location, NSMaxRange(new) != NSMaxRange(old) {
                    let upper = document.snap(NSMaxRange(new), direction: NSMaxRange(new) < NSMaxRange(old) ? .backward : .forward)
                    return NSRange(location: new.location, length: max(0, upper - new.location))
                }
                return new
            }
            let direction: ApplicationCommandEditorDirection =
                new.location > old.location ? .forward : (new.location < old.location ? .backward : .nearest)
            return NSRange(
                location: document.snap(new.location, direction: isPointer ? .nearest : direction),
                length: 0
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplying, let document,
                  let textView = notification.object as? ApplicationCommandTextView,
                  !textView.isComposing else { return }
            let selection = textView.selectedRange()
            if let focus = document.focus(at: selection.location),
               selection.length == 0 || document.focus(at: NSMaxRange(selection)) == focus
            {
                parent.composer.setFocus(focus)
                textView.focus = focus
                textView.needsDisplay = true
            }
            if let draft = parent.composer.draft {
                textView.updateTypingAttributes(for: draft)
            }
        }

        // MARK: Keyboard

        /// Delete across editable values, skipping chip labels and structural spacing.
        func deleteBackward(in textView: ApplicationCommandTextView) -> Bool {
            guard let document, textView.selectedRange().length == 0 else { return false }
            let location = textView.selectedRange().location
            if let index = document.fields.firstIndex(where: { $0.value.location == location }) {
                let span = document.fields[index]
                if draft.field(span.id)?.isEmpty == true {
                    removeEmptyField(at: index, in: textView)
                } else {
                    deleteBeforeGap(index, in: textView)
                }
                return true
            }
            if let span = document.fields.first(where: {
                $0.isAtomic && NSMaxRange($0.value) == location && $0.value.length > 0
            }) {
                textView.insertText("", replacementRange: span.value)
                return true
            }
            guard let gap = document.gaps.firstIndex(where: { $0.location == location }) else { return false }
            deleteBeforeGap(gap, in: textView)
            return true
        }

        private func removeEmptyField(at index: Int, in textView: ApplicationCommandTextView) {
            var updated = draft
            updated.removeField(updated.fields[index].id)
            updated.focus = .gap(index)
            // The first chip shared the command's text node. Discord leaves a
            // real separator when that chip is removed, even when no chips remain.
            if index == 0, updated.gapText.isEmpty { updated.gapText = " " }
            apply(updated, caret: .gap(index, offset: updated.gapText.utf16.count), in: textView)
        }

        private func deleteBeforeGap(_ index: Int, in textView: ApplicationCommandTextView) {
            guard let document else { return }
            let gap = document.gaps[index]
            if gap.length > 0 {
                let range = (document.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(gap) - 1)
                textView.insertText("", replacementRange: range)
            } else if index > 0 {
                let previous = document.fields[index - 1]
                if previous.value.length == 0 {
                    removeEmptyField(at: index - 1, in: textView)
                } else {
                    var updated = draft
                    guard let focus = updated.deleteBackward(intoFieldBefore: index) else { return }
                    apply(updated, caret: ApplicationCommandEditorDocument(draft: updated).caret(endOf: focus), in: textView)
                }
            } else {
                let range = (document.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(document.command) - 1)
                textView.insertText("", replacementRange: range)
            }
        }

        func deleteForward(in textView: ApplicationCommandTextView) -> Bool {
            guard let document, textView.selectedRange().length == 0 else { return false }
            let location = textView.selectedRange().location
            if let index = document.fields.firstIndex(where: { $0.value.location == location && $0.value.length == 0 }) {
                removeEmptyField(at: index, in: textView)
                return true
            }
            if let index = document.fields.firstIndex(where: { NSMaxRange($0.value) == location }) {
                deleteAfterGap(index + 1, in: textView)
                return true
            }
            if location == NSMaxRange(document.command) {
                deleteAfterGap(0, in: textView)
                return true
            }
            if let gap = document.gaps.firstIndex(where: { NSMaxRange($0) == location }) {
                deleteAfterGap(gap, in: textView)
                return true
            }
            return false
        }

        private func deleteAfterGap(_ index: Int, in textView: ApplicationCommandTextView) {
            guard let document else { return }
            let gap = document.gaps[index]
            if gap.length > 0, textView.selectedRange().location < NSMaxRange(gap) {
                textView.insertText("", replacementRange: (document.string as NSString).rangeOfComposedCharacterSequence(at: gap.location))
            } else if document.fields.indices.contains(index) {
                let next = document.fields[index]
                if next.value.length == 0 {
                    removeEmptyField(at: index, in: textView)
                } else {
                    let range = next.isAtomic ? next.value
                        : (document.string as NSString).rangeOfComposedCharacterSequence(at: next.value.location)
                    textView.insertText("", replacementRange: range)
                }
            }
            // At the end of the final populated value there is nothing to delete.
        }

        private var verticalColumn: CGFloat?

        func resetVerticalMovement(unless command: ComposerAutocompleteCommand? = nil) {
            if command != .previous, command != .next { verticalColumn = nil }
        }

        /// When a single-line value has no suggestions, vertical arrows cross
        /// its boundary. Within wrapped/multiline values retain the column relative
        /// to the value, whose first line starts after the command and option label.
        func moveVertically(forward: Bool, in textView: ApplicationCommandTextView) -> Bool {
            guard let document, let focus = document.focus(at: textView.selectedRange().location) else { return false }
            let target: ApplicationCommandEditorCaret
            switch focus {
            case let .field(id):
                guard let index = draft.index(of: id), let span = document.span(id) else { return false }
                if let layout = textView.layoutManager, let container = textView.textContainer {
                    layout.ensureLayout(for: container)
                    let position = min(textView.selectedRange().location, max(0, document.length - 1))
                    let edge = min(forward ? NSMaxRange(span.value) : span.value.location, max(0, document.length - 1))
                    let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: position), effectiveRange: nil)
                    let edgeLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: edge), effectiveRange: nil)
                    if abs(line.minY - edgeLine.minY) > 0.5 {
                        moveWithinValue(span.value, forward: forward, in: textView, layout: layout)
                        return true
                    }
                }
                let gap = forward ? index + 1 : index
                target = gap == 0 && document.gaps[0].length == 0
                    ? .command(offset: document.command.length)
                    : .gap(gap, offset: document.gaps[gap].length)
            case let .gap(index):
                let fieldIndex = forward ? index : index - 1
                if document.fields.indices.contains(fieldIndex) {
                    let span = document.fields[fieldIndex]
                    target = .field(span.id, offset: span.value.length)
                } else if !forward {
                    target = .command(offset: document.command.length)
                } else {
                    return true
                }
            case .command:
                guard forward else { return false }
                if document.gaps[0].length > 0 {
                    target = .gap(0, offset: document.gaps[0].length)
                } else if let first = document.fields.first {
                    target = .field(first.id, offset: first.value.length)
                } else {
                    target = .gap(0, offset: 0)
                }
            }
            verticalColumn = nil
            moveCaret(to: target, in: textView)
            return true
        }

        private func moveWithinValue(
            _ value: NSRange, forward: Bool, in textView: ApplicationCommandTextView, layout: NSLayoutManager
        ) {
            let position = textView.selectedRange().location
            let glyph = layout.glyphIndexForCharacter(at: position)
            var lineGlyphs = NSRange()
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            let firstGlyph = layout.glyphIndexForCharacter(at: value.location)
            let firstLine = layout.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
            let firstColumn = layout.location(forGlyphAt: firstGlyph).x
            let column = verticalColumn ?? (layout.location(forGlyphAt: glyph).x
                - (abs(line.minY - firstLine.minY) < 0.5 ? firstColumn : 0))
            verticalColumn = column
            let targetGlyph = forward ? NSMaxRange(lineGlyphs) : lineGlyphs.location - 1
            var targetGlyphs = NSRange()
            let targetLine = layout.lineFragmentRect(forGlyphAt: targetGlyph, effectiveRange: &targetGlyphs)
            let targetColumn = max(0, column)
                + (abs(targetLine.minY - firstLine.minY) < 0.5 ? firstColumn : 0)
            guard let container = textView.textContainer else { return }
            let location = layout.characterIndex(
                for: NSPoint(x: targetLine.minX + targetColumn, y: targetLine.midY),
                in: container, fractionOfDistanceBetweenInsertionPoints: nil
            )
            let targetCharacters = layout.characterRange(forGlyphRange: targetGlyphs, actualGlyphRange: nil)
            var end = min(NSMaxRange(value), NSMaxRange(targetCharacters))
            let string = textView.string as NSString
            while end > max(value.location, targetCharacters.location),
                  let scalar = UnicodeScalar(string.character(at: end - 1)), CharacterSet.newlines.contains(scalar) {
                end -= 1
            }
            textView.setSelectedRange(NSRange(
                location: min(max(max(value.location, targetCharacters.location), location), end), length: 0
            ))
        }

        private func moveCaret(to caret: ApplicationCommandEditorCaret, in textView: ApplicationCommandTextView) {
            guard let document else { return }
            textView.setSelectedRange(NSRange(location: document.location(of: caret), length: 0))
        }

        func plainText(for range: NSRange) -> String {
            document?.plainText(in: range) ?? ""
        }

        /// Key commands can move focus in the model; adopt that caret now so
        /// the next keystroke lands in the right place.
        func keyboardCommand(_ command: ComposerAutocompleteCommand, in textView: ApplicationCommandTextView) -> Bool {
            let handled = parent.onKeyboardCommand(command)
            syncCaret(in: textView)
            return handled
        }

        func syncCaret(in textView: ApplicationCommandTextView) {
            guard parent.composer.draft != nil,
                  appliedCaretRevision != parent.composer.caretRequestRevision
            else { return }
            appliedCaretRevision = parent.composer.caretRequestRevision
            render(in: textView, caret: parent.composer.caretRequest)
        }

        func submit() {
            parent.onSubmit()
        }

        func canReceiveAttachment() -> Bool {
            parent.canReceiveAttachment()
        }

        func receiveAttachment(_ attachments: ComposerIncomingAttachments) {
            parent.receiveAttachment(attachments)
        }
    }
}

/// Typography and colours shared by the editor's text and chip drawing.
enum ApplicationCommandEditorStyle {
    static var font: NSFont { .interfaceSystemFont(ofSize: 15) }
    static var lineHeight: CGFloat { InterfaceScale.metric(24) }
    static var verticalInset: CGFloat { InterfaceScale.metric(6) }
    static var chipPadding: CGFloat { InterfaceScale.metric(6) }
    static var labelGap: CGFloat { InterfaceScale.metric(10) }
    static var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: font]).width }

    static func trailingChipInset(_ span: ApplicationCommandEditorDocument.Span) -> CGFloat {
        chipPadding + (span.value.length == 0 ? InterfaceScale.metric(3) : 0)
    }

    static let partKey = NSAttributedString.Key("dev.sakuracord.command-part")

    private static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func baseAttributes(color: NSColor = .labelColor, font: NSFont = font) -> [NSAttributedString.Key: Any] {
        // A fixed line taller than the font leaves the extra space above the
        // glyphs; lift them so text sits centred in its chip.
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .baselineOffset: 3]
    }

    static func attributedString(
        document: ApplicationCommandEditorDocument,
        draft: ApplicationCommandDraft,
        roles: [GuildRole]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: document.string,
            attributes: baseAttributes()
        )
        result.addAttributes(
            [.font: NSFont.interfaceSystemFont(ofSize: 15, weight: .semibold)],
            range: document.command
        )
        // Structural spaces carry only the neighbouring pill's inset. The
        // separator itself stays one ordinary text space, including the empty
        // draft and its trailing optional-options hint. Typed gap text keeps
        // its natural width and all document/caret offsets stay unchanged.
        for (index, gap) in document.gaps.enumerated() {
            result.addAttribute(.kern, value: index == 0 ? 0 : trailingChipInset(document.fields[index - 1]),
                                range: NSRange(location: gap.location - 1, length: 1))
        }
        for span in document.fields {
            result.addAttribute(.kern, value: chipPadding - spaceWidth,
                                range: NSRange(location: span.label.location - 1, length: 1))
        }
        for span in document.fields {
            result.addAttributes([
                .font: NSFont.interfaceSystemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85),
                .baselineOffset: 3.5,
                partKey: "label",
            ], range: span.label)
            if span.label.length > 0 {
                result.addAttribute(
                    .kern, value: labelGap,
                    range: NSRange(location: NSMaxRange(span.label) - 1, length: 1)
                )
            }
            guard let field = draft.field(span.id), span.value.length > 0 else { continue }
            result.addAttributes(valueAttributes(for: field, roles: roles), range: span.value)
        }
        return result
    }

    static func valueTints(for draft: ApplicationCommandDraft, roles: [GuildRole]) -> [String: NSColor] {
        var tints: [String: NSColor] = [:]
        for field in draft.fields {
            switch field.resolved {
            case .user?, .channel?:
                tints[field.id] = .sakuraCordAccentColor
            case let .role(id)?:
                tints[field.id] = SakuraCordAccentColor.nsColor(forRoleColorHex: roles.first { $0.id == id }?.colorHex)
            case let .mentionable(id)?:
                tints[field.id] = roles.first { $0.id.description == id }
                    .map { SakuraCordAccentColor.nsColor(forRoleColorHex: $0.colorHex) } ?? .sakuraCordAccentColor
            default:
                break
            }
        }
        return tints
    }

    static func valueAttributes(for field: ApplicationCommandDraftField, roles: [GuildRole]) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes()
        attributes[partKey] = "value"
        guard let resolved = field.resolved else { return attributes }
        switch resolved {
        case .user, .channel, .mentionable:
            attributes[.font] = NSFont.interfaceSystemFont(ofSize: 15, weight: .semibold)
            attributes[.foregroundColor] = NSColor.sakuraCordAccentColor
            if case let .mentionable(id) = resolved, let role = roles.first(where: { $0.id.description == id }) {
                attributes[.foregroundColor] = SakuraCordAccentColor.nsColor(forRoleColorHex: role.colorHex)
            }
        case let .role(id):
            attributes[.font] = NSFont.interfaceSystemFont(ofSize: 15, weight: .semibold)
            attributes[.foregroundColor] = SakuraCordAccentColor.nsColor(
                forRoleColorHex: roles.first { $0.id == id }?.colorHex
            )
        case .attachment:
            attributes[.font] = NSFont.interfaceSystemFont(ofSize: 14, weight: .medium)
        default:
            attributes[.font] = NSFont.interfaceSystemFont(ofSize: 15, weight: .medium)
        }
        return attributes
    }
}

final class ApplicationCommandTextView: ComposerFocusReportingTextView {
    weak var coordinator: ApplicationCommandEditorView.Coordinator?
    var document: ApplicationCommandEditorDocument?
    var focus: ApplicationCommandDraftFocus?
    var issueFieldID: String?
    var commandPasteboard = NSPasteboard.general
    private lazy var unfocusedTypingMonitor = ComposerUnfocusedTypingMonitor()
    var capturesUnfocusedTyping = true {
        didSet { synchronizeTypingMonitor() }
    }

    private func synchronizeTypingMonitor() {
        unfocusedTypingMonitor.synchronize(
            with: self, enabled: capturesUnfocusedTyping,
            onUnfocusedReturn: { [weak self] event in self?.handleReturn(event) ?? false }
        )
    }

    private struct Composition {
        let original: NSAttributedString
        var range: NSRange
    }
    private var composition: Composition?
    private var isUpdatingComposition = false
    private var insertionDepth = 0
    var isComposing: Bool { composition != nil || isUpdatingComposition || hasMarkedText() }

    // AppKit owns provisional text. It can replace marked text without sending
    // textDidChange, so draft ranges must not be used to snap or edit it. Apply
    // the committed replacement once, through the normal structured editor.
    override func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if composition == nil {
            composition = Composition(original: NSAttributedString(attributedString: attributedString()), range:
                replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange)
        } else if replacementRange.location != NSNotFound, hasMarkedText(), var current = composition {
            // Reconversion can extend beyond the previously marked range.
            let marked = markedRange()
            let before = min(current.range.location, max(0, marked.location - replacementRange.location))
            let after = max(0, NSMaxRange(replacementRange) - NSMaxRange(marked))
            current.range.location -= before
            current.range.length = min(current.original.length - current.range.location,
                current.range.length + before + after)
            composition = current
        }
        isUpdatingComposition = true
        super.setMarkedText(value, selectedRange: selectedRange, replacementRange: replacementRange)
        isUpdatingComposition = false
        if !hasMarkedText() { unmarkText() }
    }

    override func insertText(_ value: Any, replacementRange: NSRange) {
        guard !isUpdatingComposition else {
            super.insertText(value, replacementRange: replacementRange)
            return
        }
        insertionDepth += 1
        defer {
            insertionDepth -= 1
            // AppKit can re-enter insertion before its outer call moves the
            // selection. Apply the model's caret after all native insertion.
            if insertionDepth == 0 { coordinator?.finishNativeInsertion(in: self) }
        }
        let range = restoreComposition() ?? replacementRange
        super.insertText(value, replacementRange: range)
    }

    override func unmarkText() {
        guard !isUpdatingComposition, composition != nil else {
            super.unmarkText()
            return
        }
        let marked = markedRange()
        let value = marked.location == NSNotFound ? "" : (string as NSString).substring(with: marked)
        if let range = restoreComposition() {
            insertText(value, replacementRange: range)
        }
    }

    private func restoreComposition() -> NSRange? {
        guard let current = composition else { return nil }
        isUpdatingComposition = true
        // Clear AppKit's provisional replacement before rebuilding the draft.
        // Unmarking alone can replay that old text on the next insertText call.
        let marked = markedRange()
        if marked.location != NSNotFound {
            super.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: marked)
        }
        super.unmarkText()
        inputContext?.discardMarkedText()
        textStorage?.setAttributedString(current.original)
        setSelectedRange(current.range)
        composition = nil
        isUpdatingComposition = false
        return current.range
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Take focus as soon as the editor replaces the plain composer, so a
        // key typed right after choosing a command is not lost in between.
        if let window, coordinator?.parent.isFocused == true {
            window.makeFirstResponder(self)
        }
        synchronizeTypingMonitor()
    }

    func updateTypingAttributes(for draft: ApplicationCommandDraft) {
        typingAttributes = ApplicationCommandEditorStyle.baseAttributes()
            .merging([ApplicationCommandEditorStyle.partKey: "value"]) { $1 }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText(), let coordinator else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        let plain = flags.isEmpty
        let command: ComposerAutocompleteCommand? = switch event.keyCode {
        case 126 where plain: .previous
        case 125 where plain: .next
        case 48 where flags.isSubset(of: [.shift]): flags.contains(.shift) ? .previousField : .advance
        case 36 where plain, 76 where plain: .accept
        case 53 where plain: .dismiss
        default: nil
        }
        coordinator.resetVerticalMovement(unless: command)
        if let command {
            if coordinator.keyboardCommand(command, in: self) { return }
            switch command {
            case .previous, .next:
                if coordinator.moveVertically(forward: command == .next, in: self) { return }
            case .accept:
                break
            case .advance, .previousField, .dismiss:
                return
            default:
                break
            }
        }
        if ComposerUnfocusedTypingMonitor.shouldOfferReturn(event.keyCode), handleReturn(event) { return }
        super.keyDown(with: event)
    }

    private func handleReturn(_ event: NSEvent) -> Bool {
        let action = ComposerReturnAction.decide(
            sendWithReturn: coordinator?.parent.generalInputSettings.sendsWithReturn ?? true,
            shift: event.modifierFlags.contains(.shift), command: event.modifierFlags.contains(.command),
            hasMarkedText: hasMarkedText()
        )
        guard action == .send else { return false }
        coordinator?.submit()
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        if coordinator?.deleteBackward(in: self) == true { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if coordinator?.deleteForward(in: self) == true { return }
        super.deleteForward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if selectedRange().length == 0, let document,
           case .gap? = document.focus(at: selectedRange().location) { return }
        super.insertNewline(sender)
    }

    override func insertTab(_: Any?) {
        _ = coordinator?.keyboardCommand(.advance, in: self)
    }

    override func insertBacktab(_: Any?) {
        _ = coordinator?.keyboardCommand(.previousField, in: self)
    }

    override var undoManager: UndoManager? { coordinator?.undoManager }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): undoManager?.canUndo == true
        case #selector(redo(_:)): undoManager?.canRedo == true
        default: super.validateMenuItem(menuItem)
        }
    }

    // MARK: Pasteboard

    override func copy(_: Any?) {
        let range = selectedRange()
        guard range.length > 0, let coordinator else { return }
        commandPasteboard.clearContents()
        commandPasteboard.setString(coordinator.plainText(for: range), forType: .string)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        coordinator?.canReceiveAttachment() == true
            ? ComposerPasteboardAttachments.readableTypes + [.string]
            : [.string]
    }

    override func paste(_ sender: Any?) {
        if coordinator?.canReceiveAttachment() == true,
           let type = commandPasteboard.availableType(from: ComposerPasteboardAttachments.readableTypes),
           let attachments = ComposerPasteboardAttachments.attachments(from: commandPasteboard, type: type)
        {
            coordinator?.receiveAttachment(attachments)
            return
        }
        guard var value = commandPasteboard.string(forType: .string) else { return }
        // Discord pastes into a command gap as one line, but preserves line
        // breaks when pasting directly into an option value.
        if let document, case .gap? = document.focus(at: selectedRange().location),
           document.gaps.contains(where: { selectedRange().location >= $0.location && NSMaxRange(selectedRange()) <= NSMaxRange($0) }) {
            value = value.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        insertText(value, replacementRange: selectedRange())
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard coordinator?.canReceiveAttachment() == true,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [URL], !urls.isEmpty
        else { return false }
        coordinator?.receiveAttachment(.external(urls))
        return true
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let document, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        func lineRects(_ range: NSRange) -> [NSRect] {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rects: [NSRect] = []
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in rects.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
            return rects
        }
        let padding = ApplicationCommandEditorStyle.chipPadding
        for span in document.fields {
            let isFocused = focus == .field(span.id)
            let isInvalid = issueFieldID == span.id
            let chips = lineRects(span.chip)
            for (index, line) in chips.enumerated() {
                var chip = line
                let leading = index == 0 ? padding : 0
                let trailing = index == chips.count - 1 ? ApplicationCommandEditorStyle.trailingChipInset(span) : 0
                chip.origin.x -= leading
                chip.size.width += leading + trailing
                chip = chip.insetBy(dx: 0, dy: 1)
                guard chip.intersects(rect) else { continue }
                let path = NSBezierPath(roundedRect: chip, xRadius: InterfaceScale.metric(7), yRadius: InterfaceScale.metric(7))
                // Discord marks only the focused or empty chip; a filled chip
                // shows its value pill alone.
                if isFocused || span.value.length == 0 {
                    NSColor.labelColor.withAlphaComponent(isFocused ? 0.07 : 0.05).setFill()
                    path.fill()
                }
                if isInvalid || isFocused {
                    (isInvalid ? NSColor.systemRed : NSColor.sakuraCordAccentColor)
                        .withAlphaComponent(0.8).setStroke()
                    path.lineWidth = 1.25
                    path.stroke()
                }
            }
            guard span.value.length > 0 else { continue }
            let tint = valueTints[span.id]
            for line in lineRects(span.value) {
                let pill = NSRect(
                    x: line.minX - InterfaceScale.metric(4), y: line.minY + InterfaceScale.metric(3), width: line.width + InterfaceScale.metric(8), height: line.height - InterfaceScale.metric(6)
                )
                guard pill.intersects(rect) else { continue }
                (tint?.withAlphaComponent(0.2) ?? NSColor.labelColor.withAlphaComponent(0.11)).setFill()
                NSBezierPath(roundedRect: pill, xRadius: InterfaceScale.metric(5), yRadius: InterfaceScale.metric(5)).fill()
            }
        }
    }

    /// Mention-style tints for chosen entities, keyed by field.
    var valueTints: [String: NSColor] = [:]
    /// Optional options not yet added, shown as Discord's trailing "+N more".
    var remainingOptionCount = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard remainingOptionCount > 0, let layoutManager, textContainer != nil, textStorage?.length ?? 0 > 0
        else { return }
        let lastGlyph = layoutManager.glyphIndexForCharacter(at: max(0, (textStorage?.length ?? 1) - 1))
        var line = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        line = line.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let label = NSAttributedString(string: "+\(remainingOptionCount) more", attributes: [
            .font: NSFont.interfaceSystemFont(ofSize: 14),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let size = label.size()
        let origin = NSPoint(x: line.maxX, y: line.midY - size.height / 2 + 0.5)
        // Hidden when the line has no room rather than overlapping text.
        guard origin.x + size.width <= bounds.maxX - 4 else { return }
        label.draw(at: origin)
    }
}
