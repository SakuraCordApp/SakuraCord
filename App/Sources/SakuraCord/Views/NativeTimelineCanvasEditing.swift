import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    func beginEditing(
        row: MessageRowPresentation,
        at index: Int
    ) {
        guard !sendTransitionBlocksInteractions,
              !row.message.hasPoll, !row.message.flags.contains(.voiceMessage), editingMessageID != row.id,
              items.indices.contains(index),
              items[index].messageID == row.id,
              let model,
              model.guildTimeoutUntil(in: row.message.channelID, guildID: row.message.guildID) == nil,
              let editingLayout = makeEditingLayout?(items[index], 0)
        else { return }
        // Editing another message discards that edit, as Cancel does; one
        // still saving keeps its editor.
        if editingMessageID != nil {
            endEditing(commit: nil)
            guard editingMessageID == nil else { return }
        }
        finishRowMotions()
        removeActionCapsule()
        setTextSelection(nil)
        textSelectionGesture = nil
        hoveredRow = nil
        hoveredCompactTimestampRow = nil
        setHoveredMention(nil)
        setHoveredTextLink(nil)
        setHoveredTextSpoiler(nil)
        setHoveredCodeBlock(nil)
        setHoveredComponentButton(nil)
        pressedCodeBlockCopyButton = nil
        pressedComponentButton = nil
        pressedActivationTarget = nil
        visualPressedComponentButton = nil
        componentButtonPressProgress = 0
        componentButtonPressAnimationDestination = nil
        componentButtonPressAnimationTask?.cancel()
        componentButtonPressAnimationTask = nil

        editingMessageID = row.id
        editingRowIndexCache = index
        editing.item = items[index]
        editingRowScrollSnapshot = nil
        let draft = NativeTimelineInlineEditDraft(text: row.message.content)
        editing.draft = draft
        let host = makeEditingHost(
            for: row, model: model, draft: draft,
            isOnOutgoingBubble: editingLayout.bubbleRegion?.isOutgoing == true
        )
        editingRowHost = host
        addSubview(host, positioned: .above, relativeTo: nil)
        let controls = NativeTimelineActionCapsuleHost(rootView: AnyView(
            NativeTimelineInlineEditControls(
                draft: draft,
                canEdit: { [weak model] in
                    model?.guildTimeoutUntil(in: row.message.channelID, guildID: row.message.guildID) == nil
                },
                save: { [weak self] in self?.endEditing(commit: MessageEditInputPolicy.submission(from: draft.text)) },
                cancel: { [weak self] in self?.endEditing(commit: nil) }
            )
        ))
        controls.setAccessibilityIdentifier("message-editing-controls-\(row.id)")
        addSubview(controls, positioned: .above, relativeTo: nil)
        editing.controlsHost = controls
        applyEditingLayout(editingLayout)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusEditingTextView(in: host)
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host,
                  self.editingRowHost === host
            else { return }
            self.focusEditingTextView(in: host)
        }
    }

    private func makeEditingHost(
        for row: MessageRowPresentation,
        model: AppModel,
        draft: NativeTimelineInlineEditDraft,
        isOnOutgoingBubble: Bool
    ) -> NativeTimelineEditingHost {
        let root = NativeTimelineEditingMessageContent(
            model: model,
            message: row.message,
            draft: draft,
            isOnOutgoingBubble: isOnOutgoingBubble,
            save: { [weak self] value in
                self?.endEditing(commit: value)
            },
            cancel: { [weak self] in
                self?.endEditing(commit: nil)
            },
            editorHeightDidChange: { [weak self] height in
                guard let self, self.editingMessageID == row.id else { return }
                self.editing.editorHeight = ceil(height)
                self.relayoutEditingRow()
            },
            draftDidChange: { [weak self] in
                guard let self, self.editingMessageID == row.id,
                      self.editing.keepsRenderedHeight != self.editing.draftMatches(row.message)
                else { return }
                self.relayoutEditingRow()
            }
        )
        let editingHost = NativeTimelineEditingHost(rootView: AnyView(root))
        editingHost.setAccessibilityIdentifier("message-editing-row-\(row.id)")
        editingHost.fittingHeightDidChange = { [weak self, weak editingHost] _ in
            guard let self, self.editingRowHost === editingHost else { return }
            self.positionEditingRow()
        }
        return editingHost
    }

    @discardableResult
    func beginEditingCurrentUserMessage(_ messageID: MessageID) -> Bool {
        guard let currentUserID = model?.currentUser?.id,
              let index = items.firstIndex(where: {
                  $0.messageID == messageID
              }),
              case let .message(row, _, _) = items[index],
              row.message.author.id == currentUserID
        else { return false }
        beginEditing(row: row, at: index)
        return editingMessageID == messageID
    }

    /// Follows the edited row through storage updates; an update to its
    /// message lays the row out again around the editor.
    func reconcileEditingRow() {
        guard let messageID = editingMessageID else { return }
        if editingRowIndex == nil {
            // A message deleted mid-edit, or mid-save, takes its editor with it.
            guard let index = items.firstIndex(where: { $0.messageID == messageID }) else {
                return finishEditing(at: nil)
            }
            editingRowIndexCache = index
        }
        guard let index = editingRowIndex else { return }
        // A saved edit has arrived; the row now draws what the editor showed.
        if let committed = editing.committedContent, let current = items[index].messageRow?.message,
           current.content == committed
            || editing.savedEditTimestamp.map({ (current.editedTimestamp ?? .distantPast) >= $0 }) == true {
            return finishEditing(at: index)
        }
        // The update may bring a new message or a new width; either changes
        // the row around the editor.
        editing.item = items[index]
        relayoutEditingRow()
    }

    func relayoutEditingRow() {
        guard let item = editing.item, case let .message(row, _, _) = item,
              let index = editingRowIndex
        else { return }
        // The editor reports its draft's height as CoreText suggests it.
        let draftHeight = editing.editorHeight > 0
            ? NativeTimelineRowLayout.messageTextHeight(suggested: editing.editorHeight) : 0
        guard var layout = makeEditingLayout?(item, draftHeight) else { return }
        // A message's own rendering, such as a heading or jumbo emoji, can
        // be taller than its raw text; until the draft changes, the row
        // keeps its height, with the room below the draft.
        editing.keepsRenderedHeight = editing.draftMatches(row.message)
        let shortfall = storage.layouts[index].height - layout.height
        if editing.keepsRenderedHeight, shortfall > 0.5,
           let tallerLayout = makeEditingLayout?(item, (layout.contentFrame?.height ?? draftHeight) + shortfall) {
            layout = tallerLayout
        }
        applyEditingLayout(layout)
    }

    private func applyEditingLayout(_ layout: NativeTimelineRowLayout) {
        guard let index = editingRowIndex else { return }
        let previousHeight = editingRowHeight ?? storage.layouts[index].height
        editing.layout = layout
        invalidateBitmap(items[index].identifier)
        clearPointerRegionCaches()
        resizeForEditingChange(by: layout.height - previousHeight)
        positionEditingRow()
        rebuildAccessibilityProxy(for: items[index].identifier)
        reconcileInlinePlayers()
        setNeedsDisplay(visibleRect)
    }

    /// The editor sits on the text it replaces; emoji suggestions open
    /// above it, over the rows before.
    func positionEditingRow() {
        guard let host = editingRowHost,
              let index = editingRowIndex,
              let content = editing.layout?.contentFrame
        else { return }
        // Only the host's height beyond the editor's own is suggestions.
        let height = host.lastReportedFittingHeight > 0 ? host.lastReportedFittingHeight : content.height
        let suggestionsHeight = editing.editorHeight > 0 ? max(0, height - editing.editorHeight) : 0
        // Near the top of the timeline there is no room above; they open below.
        let unobscuredMinY = visibleRect.minY + (enclosingScrollView?.scrollerInsets.top ?? 0)
        let opensBelow = suggestionsHeight > 0
            && displayedRowOrigin(at: index) + content.minY - suggestionsHeight < unobscuredMinY
        if let draft = editing.draft, suggestionsHeight > 0, draft.showsSuggestionsBelow != opensBelow {
            draft.showsSuggestionsBelow = opensBelow
        }
        let localFrame = CGRect(
            x: content.minX,
            y: editing.draft?.showsSuggestionsBelow == true ? content.minY : content.minY - suggestionsHeight,
            width: content.width,
            height: height
        )
        editingOverlayLocalFrame = localFrame
        let frame = localFrame.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
        if host.frame != frame {
            host.frame = frame
        }
        if let controls = editing.controlsHost {
            let frame = rowActionsFrame(size: controls.fittingSize, at: index)
            if controls.frame != frame { controls.frame = frame }
        }
    }

    func endEditing(commit value: String?) {
        guard let messageID = editingMessageID, editing.committedContent == nil else { return }
        let index = editingRowIndex ?? items.firstIndex(where: { $0.messageID == messageID })
        let message: Message?
        if let index,
           case let .message(row, _, _) = items[index]
        {
            message = row.message
        } else {
            message = nil
        }
        if value != nil, let message,
           model?.guildTimeoutUntil(in: message.channelID, guildID: message.guildID) != nil {
            return
        }
        if let value, let message, value != message.content {
            awaitEditedMessage(message, value: value)
        } else {
            finishEditing(at: index)
            if let value, let message, let edit = actions?.edit {
                Task { _ = await edit(message, value) }
            }
        }
    }

    /// Keeps the saved text in the editor until the timeline shows the
    /// saved message, so the row never falls back to the old text in
    /// between, however long the save takes. A failed save gives the row
    /// back.
    private func awaitEditedMessage(_ message: Message, value: String) {
        editing.committedContent = value
        editing.draft?.isSaving = true
        editing.controlsHost?.removeFromSuperview()
        editing.controlsHost = nil
        guard let edit = actions?.edit else { return finishEditing(at: editingRowIndex) }
        Task { [weak self, weak draft = editing.draft] in
            let saved = await edit(message, value)
            // Only this save's session; a later edit of the message has its own draft.
            guard let self, let draft, self.editing.draft === draft, self.editing.committedContent != nil else { return }
            guard let saved else { return self.finishEditing(at: self.editingRowIndex) }
            // The timeline may already show the save, or a later edit from
            // elsewhere, whose text can differ from what was typed.
            self.editing.savedEditTimestamp = saved.editedTimestamp ?? .distantPast
            // Outside a timeline update, the hand-off from the editor to the
            // row eases here, as the update's would.
            self.captureRowMotionBaseline()
            self.reconcileEditingRow()
            self.beginRowMotions()
        }
    }

    private func finishEditing(at index: Int?) {
        let delta = editingHeightDelta
        let identifier = editing.item?.identifier
        editing.clear()
        if let identifier { invalidateBitmap(identifier) }
        clearPointerRegionCaches()
        resizeForEditingChange(by: -delta)
        window?.invalidateCursorRects(for: self)
        if let index {
            rebuildAccessibilityProxy(for: items[index].identifier)
        } else {
            reconcileAccessibilityProxies()
        }
        reconcileInlinePlayers()
        setNeedsDisplay(visibleRect)
        refreshHoverPresentation()
    }

    var editingRowIndex: Int? {
        guard let index = editingRowIndexCache,
              items.indices.contains(index),
              layouts.indices.contains(index),
              rowOrigins.indices.contains(index),
              items[index].messageID == editingMessageID
        else { return nil }
        return index
    }

    /// Rows after the edited one move with it even when the content origin
    /// stays, so their overlays and pointer regions follow every change.
    func resizeForEditingChange(by delta: CGFloat) {
        guard abs(delta) > 0.5 else { return }
        contentOriginY = transientContentOriginY
        let size = NSSize(
            width: frame.width,
            height: max(displayedContentHeight, minimumHeight)
        )
        applyDocumentSize(size)
        enclosingScrollView?.tile()
        clearPointerRegionCaches()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        reconcileAccessibilityProxies()
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        positionRowOverlays()
        needsDisplay = true
    }

    func editingOverlayFrame(at index: Int) -> CGRect {
        guard let localFrame = editingOverlayLocalFrame else {
            return .zero
        }
        return localFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
    }

    /// A picture of the inline editor as it shows now.
    func editingHostSnapshot() -> NSImage? {
        guard let host = editingRowHost,
              host.alphaValue > 0.5,
              host.bounds.width > 0,
              host.bounds.height > 0,
              let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return nil }
        host.cacheDisplay(in: host.bounds, to: representation)
        representation.size = host.bounds.size
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    func freezeEditingRowForScroll() {
        guard editingRowScrollSnapshot == nil,
              let host = editingRowHost,
              let image = editingHostSnapshot()
        else { return }
        editingRowScrollSnapshot = image
        host.alphaValue = 0
        if let index = editingRowIndexCache, items.indices.contains(index) {
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func restoreEditingRowAfterScroll() {
        guard let host = editingRowHost, host.alphaValue < 0.5 else {
            return
        }
        host.alphaValue = 1
        editingRowScrollSnapshot = nil
        if window?.isKeyWindow == true,
           let editingTextView,
           window?.firstResponder !== editingTextView
        {
            window?.makeFirstResponder(editingTextView)
        }
        if let index = editingRowIndexCache, items.indices.contains(index) {
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func focusEditingTextView(
        in host: NSView
    ) {
        guard let textView = host.firstDescendant(of: ComposerNSTextView.self) else { return }
        editingTextView = textView
        guard let window = textView.window ?? self.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

}

extension NativeMessageTimelineCoordinator {
    func applyEditRequestIfNeeded() {
        guard let request = parent.editRequest,
              request.id != lastEditRequestID,
              let canvas
        else { return }
        lastEditRequestID = request.id
        guard canvas.beginEditingCurrentUserMessage(request.messageID),
              let scrollView,
              let index = canvas.editingRowIndex,
              let content = canvas.editing.layout?.contentFrame
        else { return }
        // An editor in sight, even in part, is edited where it is; one out
        // of sight is brought just into it, from the side it was on. The
        // editor, not its row, is tested and aligned: a row's attachments
        // can be in sight while its text is not.
        let editor = content.offsetBy(dx: 0, dy: canvas.displayedRowOrigin(at: index))
        let insets = scrollView.scrollerInsets
        let visible = canvas.visibleRect.divided(atDistance: insets.top, from: .minYEdge).remainder
            .divided(atDistance: insets.bottom, from: .maxYEdge).remainder
        guard !visible.intersects(editor) else { return }
        let offset = editor.maxY <= visible.minY ? editor.minY - visible.minY : editor.maxY - visible.maxY
        cancelGlide()
        scroll(toDocumentY: scrollView.contentView.bounds.minY + offset, scrollView: scrollView)
        reportScrollState(force: true)
    }
}
