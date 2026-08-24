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
    func setHoveredCompactTimestampRow(_ value: Int?) {
        guard hoveredCompactTimestampRow != value else { return }
        let old = hoveredCompactTimestampRow
        hoveredCompactTimestampRow = value
        if let old {
            setNeedsDisplay(rowFrame(at: old))
        }
        if let value {
            setNeedsDisplay(rowFrame(at: value))
        }
    }

    func setHoveredMention(
        _ value: NativeTimelineMentionHover?
    ) {
        guard hoveredMention != value else { return }
        let oldIdentifier = hoveredMention?.itemIdentifier
        hoveredMention = value
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func setHoveredTextLink(
        _ value: NativeTimelineTextLinkHover?
    ) {
        guard hoveredTextLink != value else { return }
        let oldIdentifier = hoveredTextLink?.itemIdentifier
        hoveredTextLink = value
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func setHoveredTextSpoiler(
        _ value: NativeTimelineTextSpoilerHover?
    ) {
        guard hoveredTextSpoiler != value else { return }
        let oldIdentifier = hoveredTextSpoiler?.itemIdentifier
        hoveredTextSpoiler = value
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func setHoveredCodeBlock(
        _ value: NativeTimelineCodeBlockPointerTarget?
    ) {
        guard hoveredCodeBlock != value else { return }
        let oldIdentifier = hoveredCodeBlock?.itemIdentifier
        hoveredCodeBlock = value
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func setHoveredComponentButton(
        _ value: NativeTimelineComponentButtonTarget?
    ) {
        guard hoveredComponentButton != value else { return }
        let old = hoveredComponentButton
        hoveredComponentButton = value
        for target in [old, value].compactMap({ $0 }) {
            invalidateComponentButton(target)
        }
    }

    func setHoveredForwardedSourceMessageID(_ value: MessageID?) {
        guard hoveredForwardedSourceMessageID != value else { return }
        let old = hoveredForwardedSourceMessageID
        hoveredForwardedSourceMessageID = value
        for messageID in [old, value].compactMap({ $0 }) {
            guard let index = items.firstIndex(where: {
                $0.messageID == messageID
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func animateComponentButtonPress(
        _ target: NativeTimelineComponentButtonTarget,
        to destination: CGFloat
    ) {
        let destination = min(max(destination, 0), 1)
        if visualPressedComponentButton != target {
            if let old = visualPressedComponentButton {
                invalidateComponentButton(old)
            }
            componentButtonPressAnimationTask?.cancel()
            componentButtonPressProgress = 0
            visualPressedComponentButton = target
        }
        if abs(componentButtonPressProgress - destination) < 0.001 {
            componentButtonPressAnimationDestination = nil
            if destination == 0 {
                visualPressedComponentButton = nil
            }
            invalidateComponentButton(target)
            return
        }
        guard componentButtonPressAnimationDestination != destination else {
            return
        }
        componentButtonPressAnimationTask?.cancel()
        componentButtonPressAnimationDestination = destination
        let start = componentButtonPressProgress
        let startTime = ProcessInfo.processInfo.systemUptime
        componentButtonPressAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let elapsed =
                    ProcessInfo.processInfo.systemUptime - startTime
                let linear = min(
                    1,
                    elapsed
                        / NativeTimelineComponentButtonVisualState
                            .pressAnimationDuration
                )
                let progress =
                    NativeTimelineComponentButtonVisualState
                        .easeOut(linear)
                self.componentButtonPressProgress =
                    start + (destination - start) * progress
                self.invalidateComponentButton(target)
                if linear >= 1 {
                    self.componentButtonPressProgress = destination
                    self.componentButtonPressAnimationDestination = nil
                    self.componentButtonPressAnimationTask = nil
                    if destination == 0,
                       self.visualPressedComponentButton == target
                    {
                        self.visualPressedComponentButton = nil
                    }
                    self.invalidateComponentButton(target)
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    func invalidateComponentButton(
        _ target: NativeTimelineComponentButtonTarget
    ) {
        guard let index = items.firstIndex(where: {
            $0.messageID == target.messageID
        }) else { return }
        setNeedsDisplay(rowFrame(at: index))
    }

    func reconcileActionCapsule() {
        if actionCapsuleState?.isPresentationActive == true {
            guard editingMessageID == nil,
                  let messageID = actionCapsuleMessageID,
                  let index = items.firstIndex(where: {
                      $0.messageID == messageID
                  })
            else {
                removeActionCapsule()
                return
            }
            positionActionCapsule(at: index)
            return
        }
        guard editingMessageID == nil,
              let index = hoveredRow
                ?? mediaViewerHighlightedMessageID.flatMap({ messageID in
                    items.firstIndex(where: {
                        $0.messageID == messageID
                    })
                })
                ?? persistentActionCapsuleRow(),
              items.indices.contains(index),
              case let .message(row, _, _) = items[index],
              let model,
              let actions
        else {
            if actionCapsuleState?.isPresentationActive != true {
                removeActionCapsule()
            }
            return
        }

        if actionCapsuleMessageID == row.id {
            positionActionCapsule(at: index)
            return
        }
        removeActionCapsule()

        installActionCapsule(
            for: row,
            at: index,
            model: model,
            actions: actions
        )
    }

    private func persistentActionCapsuleRow() -> Int? {
        guard model?.interfaceSettings.messageActionVisibility == .always,
              !items.isEmpty
        else { return nil }
        let viewport = enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard var index = rowIndex(at: max(0, viewport.maxY - 1)) else {
            return nil
        }
        while items.indices.contains(index) {
            if case .message = items[index] {
                return index
            }
            guard index > items.startIndex else { break }
            index -= 1
        }
        return nil
    }

    private func installActionCapsule(
        for row: MessageRowPresentation,
        at index: Int,
        model: AppModel,
        actions: NativeTimelineRowActions
    ) {
        let state = NativeTimelineActionCapsuleState()
        state.presentationDidChange = { [weak self, weak state] isPresented in
            Task { @MainActor [weak self, weak state] in
                await Task.yield()
                guard let self,
                      let state,
                      self.actionCapsuleState === state
                else { return }
                if isPresented {
                    self.refreshActionCapsuleSizeAndPosition()
                } else {
                    self.reconcileActionCapsule()
                }
            }
        }
        let canEdit = row.message.author.id == model.snapshot?.currentUser.id
        let jumpToMessage = actions.openMessage.map { openMessage in
            { openMessage(row.message) }
        }
        let retry = row.message.outboxState == .failed
            ? { actions.retry(row.message) }
            : nil
        let reply = actions.reply.map { reply in
            { reply(row.message) }
        }
        let forward = model.canForward(row.message)
            ? actions.forward.map { forward in
                { forward(row.message) }
            }
            : nil
        let openThread = row.message.thread.map { thread in
            { actions.openThread(thread) }
        }
        let root = NativeTimelineActionCapsuleOverlay(
            model: model,
            message: row.message,
            canEdit: canEdit,
            state: state,
            jumpToMessage: jumpToMessage,
            retry: retry,
            edit: { [weak self] in
                self?.beginEditing(row: row, at: index)
            },
            reply: reply,
            forward: forward,
            react: { emoji in actions.react(emoji, row.message) },
            copy: { Self.copyText(row.message.content) },
            copyLink: { [weak self] in
                guard let self else { return }
                Self.copyText(self.messageLink(for: row.message))
            },
            openThread: openThread,
            delete: { actions.delete(row.message) }
        )
        // The canvas owns the capsule's exact document-coordinate frame.
        // Nested thread timelines extend beneath their top toolbar, so this
        // host must not inherit that container's safe-area displacement.
        let host = NativeTimelineActionCapsuleHost(rootView: AnyView(root))
        host.setContentHuggingPriority(.required, for: .horizontal)
        host.setContentHuggingPriority(.required, for: .vertical)
        host.setContentCompressionResistancePriority(.required, for: .horizontal)
        host.setContentCompressionResistancePriority(.required, for: .vertical)
        host.setAccessibilityIdentifier("message-action-capsule-\(row.id)")
        addSubview(host, positioned: .above, relativeTo: nil)
        actionCapsuleState = state
        actionCapsuleHost = host
        actionCapsuleMessageID = row.id
        let controlCount = jumpToMessage == nil
            ? 3
                + (retry == nil ? 0 : 1)
                + (reply == nil ? 0 : 1)
                + (forward == nil ? 0 : 1)
                + (canEdit ? 2 : 0)
                + (openThread == nil ? 0 : 1)
            : 1
        actionCapsuleSize = HoverActionPillMetrics.size(
            controlCount: controlCount,
            enlarged: model.accessibilitySettings.enlargesMessageActionTargets
        )
        positionActionCapsule(at: index)
    }

    func refreshActionCapsuleSizeAndPosition(at knownIndex: Int? = nil) {
        guard let host = actionCapsuleHost else { return }
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        actionCapsuleSize = NSSize(
            width: max(36, fitting.width),
            height: max(36, fitting.height)
        )
        positionActionCapsule(at: knownIndex)
    }

    func positionActionCapsule(at knownIndex: Int? = nil) {
        guard let host = actionCapsuleHost,
              let size = actionCapsuleSize,
              let messageID = actionCapsuleMessageID,
              let index =
                knownIndex.flatMap({ candidate in
                    guard items.indices.contains(candidate),
                          items[candidate].messageID == messageID
                    else { return nil }
                    return candidate
                })
                ?? items.firstIndex(where: { $0.messageID == messageID })
        else { return }
        host.frame = CGRect(
            x: max(0, bounds.width - 14 - size.width),
            y: displayedRowOrigin(at: index)
                + (layouts[index].highlightFrame?.minY ?? 0)
                - 13,
            width: size.width,
            height: size.height
        )
    }

    func removeActionCapsule() {
        actionCapsuleState?.presentationDidChange = nil
        actionCapsuleHost?.removeFromSuperview()
        actionCapsuleHost = nil
        actionCapsuleState = nil
        actionCapsuleMessageID = nil
        actionCapsuleSize = nil
    }

    func timelineTextCaret(
        at point: CGPoint,
        itemIdentifier: NativeMessageTimelineItem.Identifier?,
        region requestedRegion: NativeTimelineTextRegion?,
        clampsToText: Bool,
        requiresPointInTextContainer: Bool
    ) -> TextCaretCandidate? {
        let index: Int?
        if let itemIdentifier {
            index = items.firstIndex {
                $0.identifier == itemIdentifier
            }
        } else {
            index = rowIndex(at: point.y)
        }
        guard let index,
              items.indices.contains(index),
              layouts.indices.contains(index),
              itemIdentifier == nil
                  || items[index].identifier == itemIdentifier
        else { return nil }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        for selectable in selectableTextRegions(
            for: items[index],
            layout: layouts[index]
        )
        where requestedRegion == nil || selectable.region == requestedRegion {
            if requiresPointInTextContainer {
                let interactionFrame = textSelectionInteractionFrame(
                    region: selectable.region,
                    frame: selectable.interactionFrame,
                    rowIndex: index
                )
                guard interactionFrame.contains(point) else { continue }
            }
            guard let caret = NativeTimelineTextHitTester.caretIndex(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame,
                point: local,
                clampsToText: clampsToText
            ) else { continue }
            return TextCaretCandidate(
                itemIdentifier: items[index].identifier,
                region: selectable.region,
                rowIndex: index,
                caret: caret,
                value: selectable.value
            )
        }
        return nil
    }

    func textSelectionInteractionFrame(
        region: NativeTimelineTextRegion,
        frame: CGRect,
        rowIndex: Int
    ) -> CGRect {
        guard region == .content else {
            return frame.offsetBy(
                dx: 0,
                dy: displayedRowOrigin(at: rowIndex)
            )
        }
        return NativeTimelineTextSelectionGeometry.interactionFrame(
            contentFrame: frame,
            rowOrigin: displayedRowOrigin(at: rowIndex),
            canvasWidth: bounds.width
        )
    }

    func selectableTextRegions(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout
    ) -> [SelectableTextRegion] {
        textRegions(
            for: item,
            layout: layout,
            includesNonSelectable: false
        )
    }

    func linkPointerTextRegions(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout
    ) -> [SelectableTextRegion] {
        textRegions(
            for: item,
            layout: layout,
            includesNonSelectable: true
        )
    }

    private func textRegions(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout,
        includesNonSelectable: Bool
    ) -> [SelectableTextRegion] {
        var result: [SelectableTextRegion] = []
        if case let .beginning(beginning) = item,
           let beginningLayout = layout.beginningLayout
        {
            let title = NativeTimelineBeginningText.title(beginning)
            result.append(SelectableTextRegion(
                region: .beginningTitle,
                frame: beginningLayout.titleFrame,
                interactionFrame: beginningLayout.titleFrame,
                value: title.value,
                framesetter: title.framesetter
            ))
            if beginning.isDescriptionSelectable {
                let description = NativeTimelineBeginningText.description(
                    beginning
                )
                result.append(SelectableTextRegion(
                    region: .beginningDescription,
                    frame: beginningLayout.descriptionFrame,
                    interactionFrame: beginningLayout.descriptionFrame,
                    value: description.value,
                    framesetter: description.framesetter
                ))
            }
            return result
        }
        if let frame = layout.contentFrame,
           let value = layout.attributedContent,
           let framesetter = layout.contentFramesetter
        {
            result.append(SelectableTextRegion(
                region: .content,
                frame: NativeTimelineTextGeometry
                    .messageContentDrawingFrame(frame),
                interactionFrame: frame,
                value: value,
                framesetter: framesetter
            ))
        }
        for embed in layout.embedRegions {
            for (textIndex, textRegion) in
                embed.textRegions.enumerated()
            where includesNonSelectable || textRegion.isSelectable {
                var frame = textRegion.frame
                frame.size.height +=
                    textRegion.text.layoutHeightAdjustment
                result.append(SelectableTextRegion(
                    region: .embed(
                        embedID: embed.embedID,
                        textIndex: textIndex
                    ),
                    frame: frame,
                    interactionFrame: textRegion.frame,
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter
                ))
            }
        }
        for (layoutIndex, component) in
            layout.componentLayouts.enumerated()
        {
            for (textIndex, textRegion) in
                component.textRegions.enumerated()
            where includesNonSelectable || textRegion.isSelectable {
                var frame = textRegion.frame
                frame.size.height +=
                    textRegion.text.layoutHeightAdjustment
                result.append(SelectableTextRegion(
                    region: .component(
                        layoutIndex: layoutIndex,
                        textIndex: textIndex
                    ),
                    frame: frame,
                    interactionFrame: textRegion.frame,
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter
                ))
            }
        }
        return result
    }

    func setTextSelection(
        _ selection: NativeTimelineTextSelection?
    ) {
        guard textSelection != selection else { return }
        let oldIdentifier = textSelection?.itemIdentifier
        textSelection = selection
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        for identifier
            in [oldIdentifier, selection?.itemIdentifier].compactMap({
            $0
        }) {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func reconcileBeginningSelectionOverlay() {
        guard let selection = textSelection,
              let index = items.firstIndex(where: {
                  $0.identifier == selection.itemIdentifier
              }),
              layouts.indices.contains(index),
              case let .beginning(beginning) = items[index],
              let layout = layouts[index].beginningLayout
        else {
            beginningSelectionOverlay.image = nil
            beginningSelectionOverlay.isHidden = true
            return
        }

        let box: NativeTimelineAttributedTextBox
        let localFrame: CGRect
        switch selection.region {
        case .beginningTitle:
            box = NativeTimelineBeginningText.title(beginning)
            localFrame = layout.titleFrame
        case .beginningDescription:
            box = NativeTimelineBeginningText.description(beginning)
            localFrame = layout.descriptionFrame
        default:
            beginningSelectionOverlay.image = nil
            beginningSelectionOverlay.isHidden = true
            return
        }

        var overlayFrame = localFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
        overlayFrame.size.height += box.layoutHeightAdjustment
        beginningSelectionOverlay.frame = overlayFrame
        beginningSelectionOverlay.image =
            NativeTimelineRowPainter.selectionOverlayImage(
                box,
                size: overlayFrame.size,
                selectionRange: selection.range
            )
        beginningSelectionOverlay.isHidden = false
    }

    func selectedTextValue() -> String? {
        guard let selection = textSelection,
              selection.range.length > 0,
              let index = items.firstIndex(where: {
                  $0.identifier == selection.itemIdentifier
              }),
              layouts.indices.contains(index),
              let value = selectableTextRegions(
                  for: items[index],
                  layout: layouts[index]
              )
                  .first(where: {
                      $0.region == selection.region
                  })?.value,
              selection.range.location >= 0,
              NSMaxRange(selection.range) <= value.length
        else { return nil }
        return RichMessageCopySerializer.string(
            from: value,
            range: selection.range
        )
    }

    static func wordRange(
        at caret: Int,
        in string: String
    ) -> NSRange {
        let value = string as NSString
        guard value.length > 0 else { return NSRange(location: 0, length: 0) }
        var index = min(max(0, caret), value.length - 1)
        if value.character(at: index) == 0xFFFC {
            return NSRange(location: index, length: 1)
        }
        let wordCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_")
        )
        func isWordCharacter(at location: Int) -> Bool {
            let range = value.rangeOfComposedCharacterSequence(
                at: location
            )
            return value.substring(with: range).rangeOfCharacter(
                from: wordCharacters
            ) != nil
        }
        guard isWordCharacter(at: index) else {
            return value.rangeOfComposedCharacterSequence(at: index)
        }
        var start = index
        while start > 0 {
            let previous = value.rangeOfComposedCharacterSequence(
                at: start - 1
            )
            guard isWordCharacter(at: previous.location) else { break }
            start = previous.location
        }
        var end = NSMaxRange(
            value.rangeOfComposedCharacterSequence(at: index)
        )
        while end < value.length, isWordCharacter(at: end) {
            end = NSMaxRange(
                value.rangeOfComposedCharacterSequence(at: end)
            )
        }
        index = start
        return NSRange(location: index, length: end - index)
    }

    static func copyText(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func messageLink(for message: Message) -> String {
        let guild = (message.guildID ?? model?.selectedGuildID)?.description ?? "@me"
        return "https://discord.com/channels/\(guild)/\(message.channelID)/\(message.id)"
    }

    func beginEditing(
        row: MessageRowPresentation,
        at index: Int
    ) {
        guard editingMessageID == nil,
              items.indices.contains(index),
              items[index].messageID == row.id,
              let model,
              let actions
        else { return }
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

        let layout = layouts[index]
        let contentOrigin = editingContentOrigin(in: layout)
        let width = max(80, bounds.width - contentOrigin.x - 14)
        let root = NativeTimelineEditingMessageContent(
            model: model,
            message: row.message,
            save: { [weak self] value in
                self?.endEditing(commit: value)
            },
            cancel: { [weak self] in
                self?.endEditing(commit: nil)
            },
            react: { emoji in
                actions.react(emoji, row.message)
            }
        )
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        let host = NativeTimelineEditingHost(rootView: AnyView(root))
        host.setAccessibilityIdentifier("message-editing-row-\(row.id)")
        host.fittingHeightDidChange = { [weak self, weak host] height in
            guard let host else { return }
            self?.updateEditingRowHeight(
                to: height,
                for: host
            )
        }
        host.frame = CGRect(
            x: contentOrigin.x,
            y: displayedRowOrigin(at: index) + contentOrigin.y,
            width: width,
            height: max(1, layout.contentFrame?.height ?? 24)
        )
        addSubview(host, positioned: .above, relativeTo: nil)
        host.layoutSubtreeIfNeeded()
        let fittedHeight = max(1, ceil(host.fittingSize.height))
        let fittedRowHeight = NativeTimelineEditingGeometry.rowHeight(
            avatarMaxY: layout.avatarFrame?.maxY,
            contentOriginY: contentOrigin.y,
            contentHeight: fittedHeight
        )
        editingMessageID = row.id
        editingRowIndexCache = index
        editingRowHost = host
        editingRowHeight = fittedRowHeight
        editingOverlayLocalFrame = CGRect(
            x: contentOrigin.x,
            y: contentOrigin.y,
            width: width,
            height: fittedHeight
        )
        editingRowScrollSnapshot = nil
        host.frame.size.height = fittedHeight
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        resizeForEditingChange(
            by: fittedRowHeight - layout.height
        )
        rebuildAccessibilityProxy(for: items[index].identifier)
        setNeedsDisplay(CGRect(
            x: 0,
            y: displayedRowOrigin(at: index),
            width: bounds.width,
            height: max(fittedRowHeight, layout.height)
        ))
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

    @discardableResult
    func beginEditingCurrentUserMessage(_ messageID: MessageID) -> Bool {
        guard editingMessageID == nil,
              let currentUserID = model?.snapshot?.currentUser.id,
              let index = items.firstIndex(where: {
                  $0.messageID == messageID
              }),
              case let .message(row, _, _) = items[index],
              row.message.author.id == currentUserID
        else { return false }
        beginEditing(row: row, at: index)
        return editingMessageID == messageID
    }

    func reconcileEditingRow() {
        guard let messageID = editingMessageID else { return }
        if let index = editingRowIndexCache,
           items.indices.contains(index),
           items[index].messageID == messageID
        {
            positionEditingRow()
            return
        }
        guard let index = items.firstIndex(where: {
            $0.messageID == messageID
        }) else {
            endEditing(commit: nil)
            return
        }
        editingRowIndexCache = index
        positionEditingRow()
    }

    func positionEditingRow() {
        guard let host = editingRowHost,
              editingMessageID != nil,
              let index = editingRowIndexCache,
              items.indices.contains(index),
              let localFrame = editingOverlayLocalFrame
        else { return }
        let frame = localFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
        if host.frame != frame {
            host.frame = frame
        }
    }

    func updateEditingRowHeight(
        to fittedHeight: CGFloat,
        for host: NativeTimelineEditingHost
    ) {
        guard editingRowHost === host,
              let index = editingRowIndexCache,
              items.indices.contains(index),
              let localFrame = editingOverlayLocalFrame,
              let previousRowHeight = editingRowHeight
        else { return }
        let fittedHeight = max(1, ceil(fittedHeight))
        let nextRowHeight = NativeTimelineEditingGeometry.rowHeight(
            avatarMaxY: layouts[index].avatarFrame?.maxY,
            contentOriginY: localFrame.minY,
            contentHeight: fittedHeight
        )
        let delta = nextRowHeight - previousRowHeight
        guard abs(delta) > 0.5
                || abs(fittedHeight - localFrame.height) > 0.5
        else { return }

        editingRowHeight = nextRowHeight
        editingOverlayLocalFrame?.size.height = fittedHeight
        host.frame.size.height = fittedHeight
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        resizeForEditingChange(by: delta)
        rebuildAccessibilityProxy(for: items[index].identifier)
        setNeedsDisplay(visibleRect)
    }

    func endEditing(commit value: String?) {
        guard let messageID = editingMessageID else { return }
        let index =
            editingRowIndexCache.flatMap { cachedIndex in
                guard items.indices.contains(cachedIndex),
                      items[cachedIndex].messageID == messageID
                else { return nil }
                return cachedIndex
            }
            ?? items.firstIndex(where: { $0.messageID == messageID })
        let message: Message?
        if let index,
           case let .message(row, _, _) = items[index]
        {
            message = row.message
        } else {
            message = nil
        }
        let delta: CGFloat
        if let index, let editingRowHeight {
            delta = editingRowHeight - layouts[index].height
        } else {
            delta = 0
        }
        editing.clear()
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        resizeForEditingChange(by: -delta)
        window?.invalidateCursorRects(for: self)
        if let index {
            rebuildAccessibilityProxy(for: items[index].identifier)
        } else {
            reconcileAccessibilityProxies()
        }
        setNeedsDisplay(visibleRect)
        if let value, let message {
            actions?.edit(message, value)
        }
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

#if DEBUG
    func reconcileVisibleReactionPreviewLoadsForTesting() {
        reconcileVisibleReactionPreviewLoads()
    }

    func hasVisibleReactionPreviewLoadForTesting(
        messageID: MessageID,
        reactionID: String
    ) -> Bool {
        visibleReactionPreviewLoadKeys.contains(
            ReactionPreviewLoadKey(
                messageID: messageID,
                reactionID: reactionID
            )
        )
    }

    var spoilerOverlayFramesForTesting:
        [NativeTimelineComponentRevealKey: CGRect]
    {
        spoilerOverlays.mapValues(\.frame)
    }

    var spoilerOverlayPillKeysForTesting:
        Set<NativeTimelineComponentRevealKey>
    {
        Set(
            spoilerOverlays.compactMap { key, overlay in
                overlay.hasPersistentPillForTesting ? key : nil
            }
        )
    }

    func reconcileSpoilerOverlaysForTesting() {
        reconcileSpoilerOverlays()
    }

    func animatedMediaKeysForTesting(
        row: MessageRowPresentation,
        layout: NativeTimelineRowLayout
    ) -> Set<NativeTimelineMediaKey> {
        animatedMediaKeys(for: row, layout: layout)
    }

    func installEditingGeometryForTesting(
        messageID: MessageID,
        rowIndex: Int,
        rowHeight: CGFloat
    ) {
        editingMessageID = messageID
        editingRowIndexCache = rowIndex
        editingRowHeight = rowHeight
    }

    var hasEditingGeometryForTesting: Bool {
        editingMessageID != nil
    }
#endif

    var editingHeightDelta: CGFloat {
        guard let index = editingRowIndex,
              let editingRowHeight
        else { return 0 }
        return editingRowHeight - layouts[index].height
    }

    var transientContentOriginY: CGFloat {
        NativeTimelineTransientRowGeometry.contentOriginY(
            base: baseContentOriginY,
            heightDelta: editingHeightDelta,
            minimum: ChatDetailLayoutPolicy.timelineTopPadding
        )
    }

    var displayedContentHeight: CGFloat {
        contentOriginY
            + NativeTimelineTransientRowGeometry.contentHeight(
                base: contentHeight,
                replacementHeight: editingRowHeight,
                baseRowHeight: editingRowIndex.map { layouts[$0].height }
            )
            + bottomSpacerHeight
    }

    func displayedRowOrigin(at index: Int) -> CGFloat {
        contentOriginY
            + NativeTimelineTransientRowGeometry.rowOrigin(
                base: rowOrigins[index],
                rowIndex: index,
                replacementIndex: editingRowIndex,
                replacementHeight: editingRowHeight,
                baseRowHeight: editingRowIndex.map { layouts[$0].height }
            )
    }

    func displayedRowHeight(at index: Int) -> CGFloat {
        NativeTimelineTransientRowGeometry.rowHeight(
            base: layouts[index].height,
            rowIndex: index,
            replacementIndex: editingRowIndex,
            replacementHeight: editingRowHeight
        )
    }

    func resizeForEditingChange(by delta: CGFloat) {
        guard abs(delta) > 0.5 else { return }
        let previousOriginY = contentOriginY
        contentOriginY = transientContentOriginY
        let size = NSSize(
            width: frame.width,
            height: max(displayedContentHeight, minimumHeight)
        )
        applyDocumentSize(size)
        enclosingScrollView?.tile()
        positionEditingRow()
        if abs(previousOriginY - contentOriginY) >= 0.5 {
            mentionPointerRegionCache.removeAll(keepingCapacity: true)
            codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            reconcileAccessibilityProxies()
            positionAnimatedMediaOverlays()
            reconcileBeginningSelectionOverlay()
            positionInlineVideoOverlays()
            positionLottieStickerOverlays()
            reconcileLoadingIndicators()
            positionSpoilerOverlays()
            needsDisplay = true
        }
    }

    func editingContentOrigin(
        in layout: NativeTimelineRowLayout
    ) -> CGPoint {
        var frames: [CGRect] = []
        if let frame = layout.contentFrame {
            frames.append(frame)
        }
        frames.append(contentsOf: layout.linkedImageRegions.map(\.frame))
        frames.append(contentsOf: layout.attachmentRegions.map(\.frame))
        frames.append(contentsOf: layout.embedFrames)
        frames.append(contentsOf: layout.componentFrames)
        frames.append(contentsOf: layout.stickerFrames)
        if let frame = layout.threadFrame {
            frames.append(frame)
        }
        frames.append(contentsOf: layout.reactionRegions.map(\.frame))
        if let frame = layout.addReactionFrame {
            frames.append(frame)
        }
        if let first = frames.min(by: {
            $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
        }) {
            return first.origin
        }
        return CGPoint(
            x: layout.authorFrame?.minX ?? 64,
            y: (layout.authorFrame?.maxY ?? layout.replyFrame?.maxY ?? 3) + 3
        )
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

    func freezeEditingRowForScroll() {
        guard editingRowScrollSnapshot == nil,
              let host = editingRowHost,
              host.alphaValue > 0.5,
              host.bounds.width > 0,
              host.bounds.height > 0,
              let representation = host.bitmapImageRepForCachingDisplay(
                  in: host.bounds
              )
        else { return }
        host.cacheDisplay(in: host.bounds, to: representation)
        representation.size = host.bounds.size
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(representation)
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
        guard let textView = firstDescendant(
            of: ComposerNSTextView.self,
            in: host
        ) else { return }
        editingTextView = textView
        guard let window = textView.window ?? self.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func firstDescendant<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        if let match = root as? View {
            return match
        }
        for child in root.subviews {
            if let match = firstDescendant(of: type, in: child) {
                return match
            }
        }
        return nil
    }

    func actionItem(
        _ title: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let target = NativeTimelineMenuAction(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(NativeTimelineMenuAction.performAction),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        item.isEnabled = true
        ContextMenuItemSupport.configure(
            item,
            title: title,
            systemImage: systemImage,
            isDestructive: isDestructive
        )
        return item
    }

    func requestDelete(_ message: Message) {
        guard let window, let actions else { return }
        removeActionCapsule()
        if MessageDeleteConfirmationPolicy.isBypassed(
            by: NSEvent.modifierFlags
        ) {
            actions.delete(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete this message?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Message")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // Do not order a sheet synchronously from a SwiftUI-hosted button
        // transaction. AppKit can throw while remote media views are being
        // reconciled during that same update group.
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, let window, self.window === window,
                  window.attachedSheet == nil
            else { return }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                actions.delete(message)
            }
        }
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
              let scrollView
        else { return }
        _ = scroll(
            to: .message(request.messageID, anchor: .center),
            in: scrollView
        )
    }
}
