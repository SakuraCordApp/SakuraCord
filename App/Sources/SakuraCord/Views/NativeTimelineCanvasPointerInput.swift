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
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Subview controls share the canvas's presentation transform, but
        // AppKit hit testing uses their unanimated frames as well.
        return glideBlocksPointer && hit != nil ? self : hit
    }

    /// Whether the pointer's hover is followed: not while scrolling, nor
    /// while a workspace motion moves the rows under a still pointer, which
    /// hit-tested their text on every frame. Each resumes hover once done.
    var tracksHover: Bool {
        !suppressesHoverPresentation && !WorkspaceLayoutMotion.isMoving
    }

    override func updateTrackingAreas() {
        guard tracksHover,
              !glideBlocksPointer,
              !overlayBlocksInteractions
        else {
            pointer.removeTrackingAreas(from: self)
            return
        }
        pointer.removeTrackingAreas(from: self)
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self,
            userInfo: ["nativeTimelineTrackingKind": "canvas"]
        )
        addTrackingArea(tracking)
        self.tracking = tracking
        installVisibleRowTrackingAreas()
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        removeAllToolTips()
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        guard !suppressesHoverPresentation,
              !glideBlocksPointer,
              !overlayBlocksInteractions
        else { return }
        super.resetCursorRects()
        guard var index = rowIndex(at: max(0, visibleRect.minY)) else {
            return
        }
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            if layouts.indices.contains(index) {
                installContentCursors(at: index, rowOrigin: displayedRowOrigin(at: index))
                installTextCursorRects(at: index)
                for codeBlock in codeBlockPointerTargets(at: index) {
                    addCursorRect(
                        codeBlock.copyButtonFrame,
                        cursor: .pointingHand
                    )
                    addToolTip(codeBlock.copyButtonFrame, owner: self, userData: nil)
                }
            }
            if layouts.indices.contains(index) {
                let rowOrigin = displayedRowOrigin(at: index)
                if let toggle = layouts[index].suppressedHeader?.toggleFrame {
                    addCursorRect(toggle.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
                }
                if case let .loader(isLoading, _) = items[index],
                   !isLoading,
                   let frame = layouts[index].loaderLayout?.controlFrame
                {
                    addCursorRect(
                        frame.offsetBy(dx: 0, dy: rowOrigin),
                        cursor: .pointingHand
                    )
                }
                if case let .message(row, _, _) = items[index],
                   !row.message.type.hasGeneratedContent
                {
                    for frame in
                        NativeTimelineAuthorProfileGeometry.hitFrames(
                            avatarFrame: layouts[index].avatarFrame,
                            authorFrame: layouts[index].authorFrame
                        )
                    {
                        addCursorRect(
                            frame.offsetBy(dx: 0, dy: rowOrigin),
                            cursor: .pointingHand
                        )
                    }
                }
                if let region = layouts[index].commandInvocationRegion {
                    addCursorRect(region.profileFrame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
                    addCursorRect(region.pillFrame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
                }
                for frame in [layouts[index].ephemeralRegion?.dismissFrame].compactMap(\.self)
                    + layouts[index].deliveryActions.map(\.frame)
                {
                    addCursorRect(
                        frame.offsetBy(dx: 0, dy: rowOrigin),
                        cursor: .pointingHand
                    )
                }
                for region in layouts[index].sakuraCordDeepLinkRegions {
                    addCursorRect(
                        region.buttonFrame.offsetBy(dx: 0, dy: rowOrigin),
                        cursor: .pointingHand
                    )
                }
                if let tag = layouts[index].serverTagRegion, tag.presentation.identity.guildID != nil {
                    addCursorRect(tag.frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
                }
                installRoleIconToolTip(at: index, rowOrigin: rowOrigin)
                installForwardedSourceCursor(at: index, rowOrigin: rowOrigin)
                installThreadCardCursor(at: index, rowOrigin: rowOrigin)
                installReactionCursors(at: index, rowOrigin: rowOrigin)
                installPollCursors(at: index, rowOrigin: rowOrigin)
                installInviteCursors(at: index, rowOrigin: rowOrigin)
                installFileCardCursors(at: index, rowOrigin: rowOrigin)
                installAudioFileCursors(at: index, rowOrigin: rowOrigin)
                installComponentCursors(at: index, rowOrigin: rowOrigin)
                installAutoModAlertCursors(at: index, rowOrigin: rowOrigin)
                installTranslationCursor(at: index, rowOrigin: rowOrigin)
            }
            index += 1
        }
    }

    private func installReactionCursors(at index: Int, rowOrigin: CGFloat) {
        guard case let .message(row, _, _) = items[index] else { return }
        let cursor: NSCursor = model?.canUpdateReactions(on: row.message) == true ? .pointingHand : .operationNotAllowed
        for region in layouts[index].reactionRegions {
            addCursorRect(region.frame.offsetBy(dx: 0, dy: rowOrigin), cursor: cursor)
        }
        if let frame = layouts[index].addReactionFrame, model?.canCreateReactions(on: row.message) == true {
            addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
        }
    }

    private func installTextCursorRects(at index: Int) {
        let item = items[index]
        let layout = layouts[index]
        let rowOrigin = displayedRowOrigin(at: index)
        let hiddenContainers = hiddenSpoilerContainerFrames(at: index).map { $0.offsetBy(dx: 0, dy: rowOrigin) }
        for selectable in selectableTextRegions(for: item, layout: layout) {
            let frame = textSelectionInteractionFrame(
                region: selectable.region,
                frame: selectable.interactionFrame,
                rowIndex: index
            )
            guard !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                frame, hiddenContainerFrames: hiddenContainers
            ) else { continue }
            addCursorRect(frame, cursor: .iBeam)
            for spoiler in NativeTimelineTextHitTester.spoilerRegions(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame
            ) {
                guard let key = textSpoilerRevealKey(
                    itemIdentifier: item.identifier,
                    region: selectable.region,
                    rangeLocation: spoiler.range.location
                ), !spoilerRevealStore.isTextRevealed(key)
                else { continue }
                addCursorRect(
                    spoiler.frame.offsetBy(dx: 0, dy: rowOrigin),
                    cursor: .pointingHand
                )
            }
        }
        for mention in mentionPointerRegions(at: index) where !mention.isTimestamp {
            addCursorRect(mention.frame, cursor: .pointingHand)
        }
        for selectable in linkPointerTextRegions(for: item, layout: layout) {
            for frame in NativeTimelineTextHitTester.linkFrames(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame
            ) {
                addCursorRect(
                    frame.offsetBy(dx: 0, dy: rowOrigin),
                    cursor: .pointingHand
                )
            }
        }
    }

    private func installRoleIconToolTip(at index: Int, rowOrigin: CGFloat) {
        guard let roleRegion = layouts[index].roleIconRegion else { return }
        addToolTip(roleRegion.frame.offsetBy(dx: 0, dy: rowOrigin), owner: self, userData: nil)
    }

    private func installForwardedSourceCursor(at index: Int, rowOrigin: CGFloat) {
        guard let frame = layouts[index].forwardedSourceRegion?.frame else { return }
        addCursorRect(
            frame.offsetBy(dx: 0, dy: rowOrigin),
            cursor: .pointingHand
        )
    }

    override func mouseEntered(with event: NSEvent) {
        // Entering a row's tracking area hovers the row it was installed for.
        followPointer(event, row: event.trackingArea?.userInfo?["nativeTimelineRowIndex"] as? Int)
    }

    override func mouseMoved(with event: NSEvent) {
        followPointer(event)
    }

    private func followPointer(_ event: NSEvent, row: Int? = nil) {
        guard !glideBlocksPointer else { return }
        guard !isPointerCovered(at: event.locationInWindow) else {
            updateHoverTargets(at: nil)
            return
        }
        guard WindowModalCoordinator.allowsInput(for: self), tracksHover, !overlayBlocksInteractions else { return }
        updateHoverTargets(at: convert(event.locationInWindow, from: nil), row: row)
    }

    override func mouseExited(with event: NSEvent) {
        switch event.trackingArea?.userInfo?["nativeTimelineTrackingKind"] as? String {
        case "row": followPointer(event)
        case "canvas": updateHoverTargets(at: nil)
        default: break
        }
    }

    func restorePointerInteractions() {
        guard !glideBlocksPointer else { return }
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        synchronizeHoverWithCurrentPointer()
    }

    func suppressPointerInteractions() {
        // A press begun before the rows moved must not activate on release.
        clearPointerTargets()
        textSelectionGesture = nil
        if let press = voiceMessagePress {
            voiceMessagePress = nil
            // A scrub paused playback, which its release would resume.
            if case .waveform = press.control { model?.voiceMessagePlayback.endScrub(press.region.playbackID) }
        }
        updateCodeCopyControl()
        closeHoverTooltips()
        removeActionCapsule()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        setNeedsDisplay(visibleRect)
    }

    /// An edit's lines easing, as a send's glide, leave the pointer nothing
    /// to hit: the rows' regions sit where they land.
    var glideBlocksPointer: Bool {
        sendTransitionBlocksInteractions || !editedTextBands.isEmpty
    }

    override func mouseDown(with event: NSEvent) {
        pointer.didForceClickLookup = false
        guard !overlayBlocksInteractions, !glideBlocksPointer else { return }
        window?.makeFirstResponder(self)
        guard event.buttonNumber == 0 else { return }
        dismissHoverLabel()
        let point = convert(event.locationInWindow, from: nil)
        pressedActivationTarget = nil
        if beginVoiceMessagePress(at: point) {
            textSelectionGesture = nil
            setTextSelection(nil)
            return
        }
        if let hit = pollPointerHit(at: point) {
            setHoveredPollTarget(hit.target)
            pressedPollTarget = hit.target
            setNeedsDisplay(visibleRect)
            textSelectionGesture = nil
            setTextSelection(nil)
            return
        }
        if let target = codeBlockCopyButtonHit(at: point) {
            pressedCodeBlockCopyButton = target
            setHoveredCodeBlock(target)
            textSelectionGesture = nil
            didDragTextSelection = false
            setTextSelection(nil)
            return
        }
        if let hit = componentButtonPointerHit(at: point),
           !hit.kind.isDisabled
        {
            setHoveredComponentButton(hit.target)
            pressedComponentButton = hit.target
            animateComponentButtonPress(
                hit.target,
                to: 1
            )
            return
        }
        pressedActivationTarget = pointerActivationTarget(at: point)
        if pressedActivationTarget?.supportsTextSelection == false {
            textSelectionGesture = nil
            didDragTextSelection = false
            setTextSelection(nil)
            return
        }
        guard let candidate = timelineTextCaret(
            at: point,
            itemIdentifier: nil,
            region: nil,
            clampsToText: true,
            requiresPointInTextContainer: true
        ) else {
            textSelectionGesture = nil
            didDragTextSelection = false
            setTextSelection(nil)
            return
        }
        textSelectionGesture = NativeTimelineTextSelectionGesture(
            itemIdentifier: candidate.itemIdentifier,
            region: candidate.region,
            anchor: candidate.caret,
            initialPoint: point
        )
        didDragTextSelection = false
        if event.clickCount >= 3 {
            setTextSelection(NativeTimelineTextSelection(
                itemIdentifier: candidate.itemIdentifier,
                region: candidate.region,
                range: NSRange(
                    location: 0,
                    length: candidate.value.length
                )
            ))
        } else if event.clickCount == 2 {
            setTextSelection(NativeTimelineTextSelection(
                itemIdentifier: candidate.itemIdentifier,
                region: candidate.region,
                range: Self.wordRange(
                    at: candidate.caret,
                    in: candidate.value.string
                )
            ))
        } else {
            setTextSelection(nil)
        }
    }

    private func forwardedSourcePointerHit(at point: CGPoint) -> MessageID? {
        messageID(at: point) { layouts[$0].forwardedSourceRegion?.frame }
    }
    private func footerActionPointerHit(at point: CGPoint) -> NativeTimelineFooterActionTarget? {
        guard let index = hitRowIndex(at: point.y)
        else { return nil }
        let local = CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index))
        if case let .suppressedMessages(group) = items[index] {
            guard layouts[index].suppressedHeader?.toggleFrame.contains(local) == true else { return nil }
            return .init(messageID: group.id, kind: .suppressedToggle)
        }
        guard let messageID = items[index].messageID else { return nil }
        if layouts[index].ephemeralRegion?.dismissFrame.contains(local) == true {
            return .init(messageID: messageID, kind: .ephemeralDismiss)
        }
        if layouts[index].translationRegion?.actionFrame?.contains(local) == true {
            return .init(messageID: messageID, kind: .translation)
        }
        return layouts[index].deliveryAction(at: local).map { .init(messageID: messageID, kind: $0) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !pointer.didForceClickLookup else { return }
        guard !overlayBlocksInteractions, !glideBlocksPointer else { return }
        if dragVoiceMessagePress(to: convert(event.locationInWindow, from: nil)) { return }
        if pressedPollTarget != nil {
            setHoveredPollTarget(pollPointerHit(at: convert(event.locationInWindow, from: nil))?.target)
            return
        }
        if pressedCodeBlockCopyButton != nil {
            let point = convert(event.locationInWindow, from: nil)
            setHoveredCodeBlock(codeBlockPointerHit(at: point))
            return
        }
        if let pressedComponentButton {
            let point = convert(event.locationInWindow, from: nil)
            let hit = componentButtonPointerHit(at: point)
            setHoveredComponentButton(hit?.target)
            let isInside = hit?.target == pressedComponentButton
            animateComponentButtonPress(
                pressedComponentButton,
                to: isInside ? 1 : 0
            )
            return
        }
        if case .thread? = pressedActivationTarget {
            setHoveredThreadMessageID(threadCardPointerHit(at: convert(event.locationInWindow, from: nil)))
            return
        }
        guard let gesture = textSelectionGesture else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if !didDragTextSelection {
            guard gesture.hasExceededDragThreshold(at: point) else { return }
            didDragTextSelection = true
        }
        _ = autoscroll(with: event)
        guard let candidate = timelineTextCaret(
            at: point,
            itemIdentifier: gesture.itemIdentifier,
            region: gesture.region,
            clampsToText: true,
            requiresPointInTextContainer: false
        ) else { return }
        let location = min(gesture.anchor, candidate.caret)
        let length = abs(candidate.caret - gesture.anchor)
        setTextSelection(
            length > 0
                ? NativeTimelineTextSelection(
                    itemIdentifier: gesture.itemIdentifier,
                    region: gesture.region,
                    range: NSRange(location: location, length: length)
                )
                : nil
        )
    }

    override func mouseUp(with event: NSEvent) {
        if pointer.didForceClickLookup {
            pointer.didForceClickLookup = false
            return
        }
        guard !overlayBlocksInteractions, !glideBlocksPointer else { return }
        if endVoiceMessagePress(at: convert(event.locationInWindow, from: nil)) { return }
        if let pressed = pressedPollTarget {
            pressedPollTarget = nil
            setNeedsDisplay(visibleRect)
            if let hit = pollPointerHit(at: convert(event.locationInWindow, from: nil)), hit.target == pressed {
                activatePoll(hit)
            }
            return
        }
        if finishCodeBlockCopyClick(event) || finishComponentButtonClick(event) { return }
        if textSelectionGesture != nil {
            let consumesClick = didDragTextSelection || (textSelection?.range.length ?? 0) > 0
            textSelectionGesture = nil
            didDragTextSelection = false
            if consumesClick {
                pressedActivationTarget = nil
                return
            }
        }
        activateReleasedPointer(at: convert(event.locationInWindow, from: nil))
    }

    private func finishCodeBlockCopyClick(_ event: NSEvent) -> Bool {
        if let pressedCodeBlockCopyButton {
            let point = convert(event.locationInWindow, from: nil)
            let released = codeBlockCopyButtonHit(at: point)
            self.pressedCodeBlockCopyButton = nil
            setHoveredCodeBlock(codeBlockPointerHit(at: point))
            if released?.itemIdentifier
                    == pressedCodeBlockCopyButton.itemIdentifier,
               released?.region == pressedCodeBlockCopyButton.region,
               released?.rangeLocation
                    == pressedCodeBlockCopyButton.rangeLocation
            {
                Pasteboard.copy(pressedCodeBlockCopyButton.content)
                codeCopyControl?.confirmCopy()
            }
            return true
        }
        return false
    }

    private func finishComponentButtonClick(_ event: NSEvent) -> Bool {
        if let pressedComponentButton {
            let point = convert(event.locationInWindow, from: nil)
            let hit = componentButtonPointerHit(at: point)
            setHoveredComponentButton(hit?.target)
            self.pressedComponentButton = nil
            animateComponentButtonPress(
                pressedComponentButton,
                to: 0
            )
            if TimelineButtonActivationPolicy.activates(
                pressed: pressedComponentButton,
                released: hit?.target
            ), let hit
            {
                switch hit.kind {
                case let .autoModAlert(action):
                    activateAutoModAlertAction(action, message: hit.message, anchor: hit.frame)
                case let .component(region):
                    _ = activateComponentButton(
                        region,
                        message: hit.message
                    )
                case let .sakuraCordDeepLink(action):
                    _ = activateSakuraCordDeepLink(action, message: hit.message)
                case let .invite(card, expands):
                    activateInvite(card, message: hit.message, expands: expands)
                case let .fileCard(card):
                    if card.part(of: hit.target, messageID: hit.message.id) == .card {
                        previewFileCard(card, message: hit.message, rowIndex: hit.rowIndex)
                    } else {
                        activateFileCard(card.attachment)
                    }
                }
            }
            return true
        }
        return false
    }

    private func activateReleasedPointer(at point: CGPoint) {
        let pressedActivationTarget = pressedActivationTarget
        self.pressedActivationTarget = nil
        guard NativeTimelinePointerActivationPolicy.activates(
            pressed: pressedActivationTarget,
            released: pointerActivationTarget(at: point)
        ) else { return }
        guard let index = hitRowIndex(at: point.y),
              let actions
        else { return }
        let item = items[index]
        let layout = layouts[index]
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        if case let .suppressedMessages(group) = item {
            if layout.suppressedHeader?.toggleFrame.contains(local) == true {
                toggleSuppressedGroup(group)
            }
            return
        }
        if case let .loader(isLoading, _) = item {
            if !isLoading,
               layout.loaderLayout?.controlFrame.contains(local)
                    == true
            {
                actions.loadEarlier()
            }
            return
        }
        if case .beginning = item {
            _ = handleTextClick(in: layout, message: nil, point: local, rowIdentifier: item.identifier)
            return
        }
        guard case let .message(row, _, _) = item else { return }
        if handleComponentClick(
            in: layout,
            message: row.message,
            point: local,
            rowIndex: index
        ) {
            return
        }
        if handleTextClick(
            in: layout,
            message: row.message,
            point: local,
            rowIdentifier: item.identifier
        ) {
            return
        }
        if handleMessageChromeClick(row: row, layout: layout, point: local, rowIndex: index) {
            return
        }
        if handleMessageMediaClick(row: row, layout: layout, point: local, rowIndex: index) {
            return
        }
        if let threadFrame = layout.threadFrame,
           threadFrame.contains(local),
           let thread = row.message.thread
        {
            actions.openThread(thread)
            return
        }
        actions.openMessage?(row.message)
    }

    private func handleMessageChromeClick(
        row: MessageRowPresentation,
        layout: NativeTimelineRowLayout,
        point: CGPoint,
        rowIndex: Int
    ) -> Bool {
        if let dismissFrame = layout.ephemeralRegion?.dismissFrame,
           dismissFrame.contains(point)
        {
            model?.dismissEphemeralMessage(row.message)
            return true
        }
        if layout.translationRegion?.actionFrame?.contains(point) == true {
            model?.performMessageTranslationCaptionAction(row.message)
            return true
        }
        switch layout.deliveryAction(at: point) {
        case .retrySend:
            actions?.retry(row.message)
            return true
        default:
            break
        }
        if let tag = layout.serverTagRegion, tag.frame.contains(point),
           let guildID = tag.presentation.identity.guildID {
            showServerTagCard(guildID: guildID, anchor: tag.frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: rowIndex)))
            return true
        }
        if !row.message.type.hasGeneratedContent,
           let authorFrame =
               NativeTimelineAuthorProfileGeometry.hitFrame(
                   at: point,
                   avatarFrame: layout.avatarFrame,
                   authorFrame: layout.authorFrame
               )
        {
            let author =
                model?.authorPresentation(for: row.message).user
                ?? row.message.author
            showMessageProfile(
                for: author,
                sourceMessage: row.message,
                anchor: authorFrame.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: rowIndex)
                )
            )
            return true
        }
        if layout.commandInvocationRegion?.pillFrame.contains(point) == true {
            showCommandInvocation(for: row.message)
            return true
        }
        if let invocation = layout.commandInvocationRegion,
           invocation.profileFrame.contains(point),
           let user = row.message.interactionMetadata?.user
        {
            showMessageProfile(
                for: user,
                sourceMessage: row.message,
                anchor: invocation.profileFrame.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: rowIndex)
                )
            )
            return true
        }
        if let replyFrame = layout.replyFrame,
           replyFrame.contains(point),
           let replyID = row.replyMessageID
        {
            actions?.openReply(replyID)
            return true
        }
        if let source = layout.forwardedSourceRegion,
           source.frame.contains(point)
        {
            if let messageID = source.messageID {
                model?.navigate(
                    to: source.guildID,
                    channelID: source.channelID,
                    messageID: messageID
                )
            } else {
                model?.navigate(
                    to: source.guildID,
                    linkedChannelID: source.channelID
                )
            }
            return true
        }
        return false
    }

    private func handleMessageMediaClick(
        row: MessageRowPresentation,
        layout: NativeTimelineRowLayout,
        point: CGPoint,
        rowIndex: Int
    ) -> Bool {
        if let linkedImage = layout.linkedImageRegions.first(
            where: { $0.frame.contains(point) }
        ) {
            if let presentation = MediaViewerPlan.linkedImages(
                in: row.message,
                selectedReferenceID: linkedImage.reference.id
            ) {
                model?.mediaViewerPresentation = mediaViewerPresentation(
                    presentation,
                    sourceFrame: linkedImage.frame,
                    rowIndex: rowIndex,
                    mediaKey: linkedImage.mediaKey,
                    cornerRadius: linkedImage.cornerRadius,
                    fillsFrame: linkedImage.fillsFrame
                )
            } else {
                NSWorkspace.shared.open(linkedImage.reference.url)
            }
            return true
        }
        if let attachmentRegion = layout.attachmentRegions.first(
            where: { $0.frame.contains(point) }
        ) {
            let attachment = attachmentRegion.attachment
            let revealKey = NativeTimelineComponentRevealKey.attachment(
                messageID: row.id,
                attachmentID: attachment.id
            )
            if attachment.isSpoiler,
               !spoilerRevealStore.isMediaRevealed(revealKey)
            {
                reveal(revealKey, rowIndex: rowIndex)
            } else if attachment.mediaKind == .video {
                playInline(
                    attachment.proxyURL ?? attachment.url, mediaID: attachment.id,
                    frame: attachmentRegion.frame, rowIndex: rowIndex
                ) { [weak self, attachmentID = attachment.id] index, layout, message in
                    guard let region = layout.attachmentRegions.first(where: { $0.attachment.id == attachmentID }) else { return }
                    _ = self?.openAttachmentInViewer(
                        region.attachment, sourceFrame: region.frame, message: message, layout: layout, rowIndex: index
                    )
                }
            } else if !openAttachmentInViewer(
                attachment, sourceFrame: attachmentRegion.frame, message: row.message, layout: layout, rowIndex: rowIndex
            ) {
                NSWorkspace.shared.open(attachment.url)
            }
            return true
        }
        if let embedRegion = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(point) == true
        }) {
            if !openEmbedMediaInViewer(id: embedRegion.embedID, region: embedRegion, message: row.message, rowIndex: rowIndex),
               let mediaURL = embedRegion.mediaURL
            {
                NSWorkspace.shared.open(mediaURL)
            }
            return true
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           let selectedText = selectedTextValue()
        {
            guard !sendTransitionBlocksInteractions else { return true }
            Pasteboard.copy(selectedText)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func activateReactionPointerHit(_ hit: ReactionPointerHit) {
        guard model?.canUpdateReactions(on: hit.message) == true else { return }
        switch hit.target {
        case .reaction:
            if let reaction = hit.reaction {
                actions?.react(reaction.emoji, hit.message)
            }
        case .add:
            showReactionPicker(forMessageRow: hit.message)
        }
    }

    func showMessageProfile(
        for user: User,
        sourceMessage: Message,
        anchor: CGRect
    ) {
        guard let model else { return }
        // One webhook can post with different names and avatars in adjacent messages.
        let presentationIdentity = sourceMessage.webhookID != nil && user.isWebhookIdentity
            ? AnyHashable(sourceMessage.id)
            : AnyHashable(ProfileCacheKey(userID: user.id, guildID: model.messagePresentationGuildID(for: sourceMessage)))
        if messageProfilePopoverCoordinator.isPresenting(
            identity: presentationIdentity
        ) {
            closeMessageProfilePopover()
            return
        }
        closeCanvasPopovers()
        let requestID = model.showProfile(for: user, sourceMessage: sourceMessage)
        let popoverAnchor = StablePopoverAnchor(
            sourceView: self,
            sourceRect: { anchor }
        )
        activeMessageProfilePopoverAnchor = popoverAnchor
        messageProfilePopoverCoordinator.update(
            anchor: popoverAnchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .memberProfile,
            onDismiss: { [weak self] in
                self?.activeMessageProfilePopoverAnchor = nil
            },
            presentationIdentity: presentationIdentity,
            content: AnyView(
                MessageProfilePopoverContent(
                    model: model,
                    userID: user.id,
                    requestID: requestID
                )
            )
        )
    }

    func closeMessageProfilePopover() {
        messageProfilePopoverCoordinator.close()
        activeMessageProfilePopoverAnchor = nil
    }

    /// The canvas shows one anchored popover at a time, so opening one
    /// closes the others. `kept` is left to update in place.
    func closeCanvasPopovers(keeping kept: StableAnchoredPopoverPresenter<AnyView>.Coordinator? = nil) {
        if kept !== messageProfilePopoverCoordinator { closeMessageProfilePopover() }
        if kept !== inlinePopoverCoordinator { closeInlinePopover() }
        if kept !== serverTagPopoverCoordinator { closeServerTagPopover() }
    }

    func showMentionProfile(
        for user: User,
        sourceMessage: Message?,
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        let requestID = model.showProfile(for: user, sourceMessage: sourceMessage)
        showInlinePopover(
            AnyView(
                MessageProfilePopoverContent(
                    model: model,
                    userID: user.id,
                    requestID: requestID
                )
            ),
            anchor: anchor,
            configuration: .memberProfile
        )
    }

    func showMentionRole(
        _ roleID: RoleID,
        sourceMessage: Message?,
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        let guildID = sourceMessage.flatMap { model.messagePresentationGuildID(for: $0) } ?? model.selectedGuildID
        model.showMembers(withRole: roleID, in: guildID)
        showInlinePopover(
            AnyView(
                RoleMembersPopover(
                    model: model,
                    roleID: roleID,
                    guildID: guildID
                )
            ),
            anchor: anchor
        )
    }

    func showInlinePopover(
        _ content: AnyView,
        anchor: StablePopoverAnchor,
        configuration: StablePopoverConfiguration = .interactive,
        presentationIdentity: AnyHashable? = nil
    ) {
        closeCanvasPopovers(keeping: inlinePopoverCoordinator)
        activeInlinePopoverAnchor = anchor
        inlinePopoverCoordinator.update(
            anchor: anchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: configuration,
            onDismiss: { [weak self] in
                self?.activeInlinePopoverAnchor = nil
            },
            presentationIdentity: presentationIdentity,
            content: content
        )
    }

    func closeInlinePopover() {
        inlinePopoverCoordinator.close()
        activeInlinePopoverAnchor = nil
    }

    func currentMouseLocationInCanvas() -> CGPoint {
        guard let window else { return .zero }
        return convert(
            window.convertPoint(fromScreen: NSEvent.mouseLocation),
            from: nil
        )
    }

    func installReactionMouseMonitor() {
        guard pointer.reactionMouseMonitor == nil else { return }
        pointer.reactionMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  !self.overlayBlocksInteractions,
                  !self.glideBlocksPointer
            else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            // An inline editor's suggestions and its Cancel and Save can
            // lie over reactions.
            guard !self.editingOverlayContains(point),
                  let hit = self.reactionPointerHit(at: point)
            else {
                return event
            }
            self.window?.makeFirstResponder(self)
            self.activateReactionPointerHit(hit)
            return nil
        }
    }

    func removeReactionMouseMonitor() {
        pointer.removeReactionMouseMonitor()
    }

    func hoveredRowIndex(at point: CGPoint) -> Int? {
        guard let index = hitRowIndex(at: point.y)
        else { return nil }
        guard case .message = items[index] else { return index }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        let layout = layouts[index]
        guard NativeTimelineHoverHitTesting.contains(
            local,
            in: layout.highlightFrame
        ) || layout.authorFrame?.contains(local) == true
          || layout.avatarFrame?.contains(local) == true
          || layout.roleIconRegion?.frame.contains(local) == true
          || layout.serverTagRegion?.frame.contains(local) == true
        else {
            return nil
        }
        return index
    }

    func compactTimestampRowIndex(
        at point: CGPoint
    ) -> Int? {
        guard let index = hitRowIndex(at: point.y),
              case .message = items[index],
              layouts[index].compactTimestampFrame != nil,
              NativeTimelineHoverHitTesting.contains(
                  point,
                  rowOrigin: displayedRowOrigin(at: index),
                  highlightFrame: layouts[index].highlightFrame
              )
        else { return nil }
        return index
    }

    func installVisibleRowTrackingAreas() {
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else { return }
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            if case .message = items[index],
               let highlight = layouts[index].highlightFrame
            {
                let paintedFrame = highlight.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
                // CoreText's optical text bounds sit one point below the
                // logical line box used by row layout. Align pointer ownership
                // with those visible bounds so the boundary between adjacent
                // messages is not perceived one point above the text.
                let frame = NativeTimelineHoverHitTesting.pointerFrame(
                    for: paintedFrame
                ) ?? paintedFrame
                if frame.intersects(visibleRect) {
                    let area = NSTrackingArea(
                        rect: frame,
                        options: [
                            .activeAlways,
                            .mouseEnteredAndExited,
                        ],
                        owner: self,
                        userInfo: [
                            "nativeTimelineTrackingKind": "row",
                            "nativeTimelineRowIndex": index,
                        ]
                    )
                    addTrackingArea(area)
                    rowTrackingAreas.append(area)
                }
            }
            index += 1
        }
    }

    @objc func composerOverlayDidChange(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        synchronizeHoverWithCurrentPointer()
    }

    /// Whether something drawn over the timeline takes the pointer: the
    /// window toolbar, whose glass the timeline scrolls beneath, or the
    /// composer's suggestions.
    private func isPointerCovered(at location: NSPoint? = nil) -> Bool {
        guard let window else { return false }
        let point = location ?? window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return window.toolbarCovers(point)
            || ComposerOverlayPointerRegion.containsPointer(in: window, at: point)
    }

    /// Points every hover target at what lies under `point`, or clears them
    /// all when it is nil. `row` stands in for the row under `point`, and
    /// `measuresVoiceDuration` is false when the rows moved, not the pointer.
    func updateHoverTargets(at point: CGPoint?, row: Int? = nil, measuresVoiceDuration: Bool = true) {
        if let point {
            guard !actionCapsuleContains(point) else {
                // The capsule covers the row's text, so its mentions and badge stop being hovered.
                setHoveredMention(nil)
                setHoveredSilentBadgeMessageID(nil)
                return
            }
            guard !hoversEditingOverlay(at: point) else { return }
        }
        let point = point.flatMap { visibleRect.contains($0) ? $0 : nil }
        setHoveredPollTarget(point.flatMap { pollPointerHit(at: $0)?.target })
        updateVoiceMessageHover(at: point, measuresDuration: measuresVoiceDuration)
        setHoveredRow(row ?? point.flatMap { hoveredRowIndex(at: $0) })
        setHoveredCompactTimestampRow(point.flatMap { compactTimestampRowIndex(at: $0) })
        setHoveredAuthorMessageID(point.flatMap { authorNamePointerHit(at: $0) })
        setHoveredServerTagMessageID(point.flatMap { serverTagPointerHit(at: $0) })
        setHoveredSilentBadgeMessageID(point.flatMap { silentBadgePointerHit(at: $0) })
        setHoveredCommandPillMessageID(point.flatMap { commandPillPointerHit(at: $0) })
        setHoveredMention(point.flatMap { mentionPointerHit(at: $0) })
        setHoveredTextLink(point.flatMap { textLinkPointerHit(at: $0) })
        setHoveredTextSpoiler(point.flatMap { textSpoilerPointerHit(at: $0) })
        setHoveredCodeBlock(point.flatMap { codeBlockPointerHit(at: $0) })
        setHoveredComponentButton(point.flatMap { componentButtonPointerHit(at: $0)?.target })
        setHoveredForwardedSourceMessageID(point.flatMap { forwardedSourcePointerHit(at: $0) })
        setHoveredThreadMessageID(point.flatMap { threadCardPointerHit(at: $0) })
        setHoveredFooterAction(point.flatMap { footerActionPointerHit(at: $0) })
        setHoveredReaction(point.flatMap { reactionPointerHit(at: $0) })
    }

    func synchronizeHoverWithCurrentPointer() {
        guard !glideBlocksPointer else { return }
        guard !isPointerCovered() else {
            updateHoverTargets(at: nil)
            return
        }
        guard WindowModalCoordinator.allowsInput(for: self), !overlayBlocksInteractions, tracksHover,
              window?.isKeyWindow == true
        else { return }
        updateHoverTargets(at: currentMouseLocationInCanvas(), measuresVoiceDuration: false)
    }

    /// The editor and its suggestions cover the rows under them, so
    /// pointing at them points at the edited row. True when they do.
    private func hoversEditingOverlay(at point: CGPoint) -> Bool {
        guard editingOverlayContains(point) else { return false }
        updateHoverTargets(at: nil, row: editingRowIndex)
        return true
    }

    /// Whether the inline editor, its suggestions or its controls are under `point`.
    func editingOverlayContains(_ point: CGPoint) -> Bool {
        editingRowHost?.frame.contains(point) == true || editing.controlsHost?.frame.contains(point) == true
    }

    func actionCapsuleContains(_ point: CGPoint) -> Bool {
        guard let host = actionCapsuleHost else { return false }
        return (host.interactiveFrame ?? host.frame).contains(point)
    }

    func mentionPointerHit(
        at point: CGPoint
    ) -> NativeTimelineMentionHover? {
        guard let index = hitRowIndex(at: point.y),
              items[index].textOwnerID != nil
        else { return nil }
        for mention in mentionPointerRegions(at: index)
        where mention.frame.contains(point) {
            return NativeTimelineMentionHover(
                itemIdentifier: items[index].identifier,
                region: mention.region,
                characterIndex: mention.characterIndex,
                rawToken: mention.rawToken
            )
        }
        return nil
    }

    func authorNamePointerHit(at point: CGPoint) -> MessageID? {
        messageID(at: point) { index in
            guard case let .message(row, _, _) = items[index], row.startsGroup, !row.message.type.hasGeneratedContent
            else { return nil }
            return layouts[index].authorFrame
        }
    }

    func textLinkPointerHit(
        at point: CGPoint
    ) -> NativeTimelineTextLinkHover? {
        guard let index = hitRowIndex(at: point.y),
              items[index].textOwnerID != nil
        else { return nil }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        guard let hit = textPointerHit(
            in: layouts[index],
            point: local
        ), hit.hit.url != nil
        else { return nil }
        return NativeTimelineTextLinkHover(
            itemIdentifier: items[index].identifier,
            region: hit.region,
            characterIndex: hit.hit.characterIndex
        )
    }

    func textSpoilerPointerHit(
        at point: CGPoint
    ) -> NativeTimelineTextSpoilerHover? {
        guard let index = hitRowIndex(at: point.y),
              items[index].textOwnerID != nil
        else { return nil }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        guard let hit = textPointerHit(
            in: layouts[index],
            point: local
        ),
              let spoilerRange = hit.hit.spoilerRange,
              let key = textSpoilerRevealKey(
                  itemIdentifier: items[index].identifier,
                  region: hit.region,
                  rangeLocation: spoilerRange.location
              ),
              !spoilerRevealStore.isTextRevealed(key)
        else { return nil }
        return NativeTimelineTextSpoilerHover(
            itemIdentifier: items[index].identifier,
            region: hit.region,
            rangeLocation: spoilerRange.location
        )
    }

    func mentionPointerRegions(
        at index: Int
    ) -> [MentionPointerRegion] {
        guard items.indices.contains(index),
              layouts.indices.contains(index)
        else { return [] }
        let identifier = items[index].identifier
        if let cached = mentionPointerRegionCache[identifier] {
            return cached
        }
        let rowOrigin = displayedRowOrigin(at: index)
        let regions = selectableTextRegions(
            for: items[index],
            layout: layouts[index]
        ).flatMap { selectable in
            NativeTimelineTextHitTester.mentionRegions(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame
            ).filter { $0.presentation.isInteractive || $0.presentation.isTimestamp }.map { mention in
                MentionPointerRegion(
                    region: selectable.region,
                    characterIndex: mention.characterIndex,
                    rawToken: mention.presentation.rawToken,
                    isTimestamp: mention.presentation.isTimestamp,
                    frame: mention.frame.offsetBy(
                        dx: 0,
                        dy: rowOrigin
                    )
                )
            }
        }
        mentionPointerRegionCache[identifier] = regions
        return regions
    }

    func codeBlockPointerHit(
        at point: CGPoint
    ) -> NativeTimelineCodeBlockPointerTarget? {
        guard let index = rowIndex(at: point.y) else { return nil }
        return codeBlockPointerTargets(at: index).first {
            $0.blockFrame.contains(point)
        }
    }

    func codeBlockCopyButtonHit(
        at point: CGPoint
    ) -> NativeTimelineCodeBlockPointerTarget? {
        guard let index = rowIndex(at: point.y) else { return nil }
        return codeBlockPointerTargets(at: index).first {
            $0.copyButtonFrame.contains(point)
        }
    }

    func codeBlockPointerTargets(
        at index: Int
    ) -> [NativeTimelineCodeBlockPointerTarget] {
        guard items.indices.contains(index),
              layouts.indices.contains(index)
        else { return [] }
        let identifier = items[index].identifier
        if let cached = codeBlockPointerRegionCache[identifier] {
            return cached
        }
        let rowOrigin = displayedRowOrigin(at: index)
        let targets = selectableTextRegions(
            for: items[index],
            layout: layouts[index]
        ).flatMap { selectable in
            NativeTimelineCodeBlockGeometry.regions(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame
            ).map { codeBlock in
                NativeTimelineCodeBlockPointerTarget(
                    itemIdentifier: identifier,
                    region: selectable.region,
                    rangeLocation: codeBlock.range.location,
                    blockFrame: codeBlock.backgroundFrame.offsetBy(
                        dx: 0,
                        dy: rowOrigin
                    ),
                    copyButtonFrame:
                        codeBlock.copyButtonFrame.offsetBy(
                            dx: 0,
                            dy: rowOrigin
                        ),
                    content: codeBlock.content
                )
            }
        }
        codeBlockPointerRegionCache[identifier] = targets
        return targets
    }

    func pointerActivationTarget(
        at point: CGPoint
    ) -> NativeTimelinePointerActivationTarget? {
        guard let index = hitRowIndex(at: point.y)
        else { return nil }
        let item = items[index]
        let layout = layouts[index]
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        if case let .suppressedMessages(group) = item {
            guard layout.suppressedHeader?.toggleFrame.contains(local) == true else { return nil }
            return .suppressedMessages(group.id)
        }
        if case let .loader(isLoading, _) = item {
            guard !isLoading,
                  layout.loaderLayout?.controlFrame.contains(local) == true
            else { return nil }
            return .loader
        }
        if case .beginning = item, let messageID = item.textOwnerID {
            return textActivationTarget(
                messageID: messageID,
                itemIdentifier: item.identifier,
                layout: layout,
                point: local
            )
        }
        guard case let .message(row, _, _) = item else { return nil }
        let message = row.message
        return componentActivationTarget(message: message, layout: layout, point: local)
            ?? textActivationTarget(
                messageID: message.id,
                itemIdentifier: item.identifier,
                layout: layout,
                point: local
            )
            ?? messageActivationTarget(row: row, layout: layout, point: local)
    }

    private func componentActivationTarget(
        message: Message,
        layout: NativeTimelineRowLayout,
        point: CGPoint
    ) -> NativeTimelinePointerActivationTarget? {
        for componentLayout in layout.componentLayouts {
            for container in componentLayout.containers
            where container.isSpoiler && container.frame.contains(point) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: container.componentID
                )
                if !spoilerRevealStore.isMediaRevealed(key) {
                    return .componentReveal(
                        message.id,
                        container.componentID
                    )
                }
            }
            if let region = componentLayout.images.first(where: {
                $0.frame.contains(point)
            }) {
                return .componentImage(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.media.first(where: {
                $0.frame.contains(point)
            }) {
                return .componentMedia(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.files.first(where: {
                $0.frame.contains(point)
            }) {
                return .componentFile(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.selects.first(where: {
                $0.frame.contains(point)
            }) {
                return .componentSelect(
                    message.id,
                    region.componentID
                )
            }
        }
        return nil
    }

    private func textActivationTarget(
        messageID: MessageID,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        layout: NativeTimelineRowLayout,
        point: CGPoint
    ) -> NativeTimelinePointerActivationTarget? {
        if let text = textPointerHit(in: layout, point: point) {
            if let spoilerRange = text.hit.spoilerRange {
                if let key = textSpoilerRevealKey(
                    itemIdentifier: itemIdentifier,
                    region: text.region,
                    rangeLocation: spoilerRange.location
                ), !spoilerRevealStore.isTextRevealed(key) {
                    return .textSpoiler(
                        messageID,
                        text.region,
                        rangeLocation: spoilerRange.location
                    )
                }
            }
            if let mention = text.hit.mention, mention.isInteractive {
                return .textMention(
                    messageID,
                    text.region,
                    characterIndex: text.hit.characterIndex,
                    rawToken: mention.rawToken
                )
            }
            if let url = text.hit.url {
                return .textURL(
                    messageID,
                    text.region,
                    characterIndex: text.hit.characterIndex,
                    url: url
                )
            }
        }
        return nil
    }

    private func messageActivationTarget(
        row: MessageRowPresentation,
        layout: NativeTimelineRowLayout,
        point: CGPoint
    ) -> NativeTimelinePointerActivationTarget? {
        let message = row.message
        if layout.ephemeralRegion?.dismissFrame.contains(point) == true {
            return .ephemeralDismiss(message.id)
        }
        if layout.translationRegion?.actionFrame?.contains(point) == true {
            return .translationAction(message.id)
        }
        if let kind = layout.deliveryAction(at: point) {
            return .deliveryAction(message.id, kind)
        }
        if let tag = layout.serverTagRegion, tag.frame.contains(point),
           let guildID = tag.presentation.identity.guildID {
            return .serverTag(message.id, guildID)
        }
        if !message.type.hasGeneratedContent,
           NativeTimelineAuthorProfileGeometry.hitFrame(
               at: point,
               avatarFrame: layout.avatarFrame,
               authorFrame: layout.authorFrame
           ) != nil
        {
            return .authorProfile(message.id)
        }
        if layout.commandInvocationRegion?.profileFrame.contains(point)
            == true
        {
            return .invocationProfile(message.id)
        }
        if layout.commandInvocationRegion?.pillFrame.contains(point) == true {
            return .commandPill(message.id)
        }
        if layout.replyFrame?.contains(point) == true,
           let replyID = row.replyMessageID
        {
            return .reply(message.id, replyID)
        }
        if let source = layout.forwardedSourceRegion,
           source.frame.contains(point)
        {
            return .forwardedSource(
                message.id,
                source.channelID,
                source.guildID,
                source.messageID
            )
        }
        if let region = layout.linkedImageRegions.first(where: {
            $0.frame.contains(point)
        }) {
            return .linkedImage(
                message.id,
                region.reference.url
            )
        }
        if let region = layout.attachmentRegions.first(where: {
            $0.frame.contains(point)
        }) {
            return .attachment(
                message.id,
                region.attachment.id
            )
        }
        if let region = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(point) == true
        }) {
            return .embedMedia(message.id, region.embedID)
        }
        if layout.threadFrame?.contains(point) == true,
           let thread = message.thread
        {
            return .thread(message.id, thread.id)
        }
        if actions?.openMessage != nil,
           NativeTimelineResultActivationPolicy.frame(
               for: messageInteractionContext,
               searchCardFrame: layout.searchCardFrame,
               highlightFrame: layout.highlightFrame
           )?.contains(point) == true
        {
            return .message(message.id)
        }
        return nil
    }

    /// Enabled buttons, link buttons and selects take the pointing hand at
    /// their drawn frame. Disabled or loading ones, and those under an
    /// unrevealed spoiler, keep the arrow.
    func installComponentCursors(at index: Int, rowOrigin: CGFloat) {
        guard let messageID = items[index].messageID else { return }
        for layout in layouts[index].componentLayouts {
            let hiddenContainers = NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(
                in: layout, messageID: messageID, store: spoilerRevealStore
            )
            let frames = layout.buttons.filter { !$0.isDisabled && !$0.isLoading }.map(\.frame)
                + layout.selects.filter { !$0.isDisabled && !$0.isLoading }.map(\.frame)
            for frame in frames where !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                frame, hiddenContainerFrames: hiddenContainers
            ) {
                addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
            }
        }
    }

    func componentButtonPointerHit(
        at point: CGPoint
    ) -> ComponentButtonPointerHit? {
        guard let index = hitRowIndex(at: point.y),
              case let .message(row, _, _) = items[index]
        else { return nil }
        let rowOrigin = displayedRowOrigin(at: index)
        let local = CGPoint(
            x: point.x,
            y: point.y - rowOrigin
        )
        for card in layouts[index].inviteRegions {
            let isButton = card.buttonFrame.contains(local) && card.buttonFrame.height > 0
            let expands = !isButton && card.detailsFrame?.contains(local) == true
            if isButton || expands {
                return ComponentButtonPointerHit(
                    target: NativeTimelineComponentButtonTarget(messageID: row.id, componentID: card.componentID + (expands ? ":details" : "")),
                    rowIndex: index, message: row.message, kind: .invite(card, expands: expands),
                    frame: (expands ? card.detailsFrame! : card.buttonFrame).offsetBy(dx: 0, dy: rowOrigin))
            }
        }
        if let button = layouts[index].autoModAlert?.button(at: local) {
            return ComponentButtonPointerHit(
                target: NativeTimelineComponentButtonTarget(messageID: row.id, componentID: button.action.rawValue),
                rowIndex: index, message: row.message, kind: .autoModAlert(button.action),
                frame: button.frame.offsetBy(dx: 0, dy: rowOrigin)
            )
        }
        if let region = layouts[index].sakuraCordDeepLinkRegions.first(
            where: { $0.buttonFrame.contains(local) }
        ) {
            return ComponentButtonPointerHit(
                target: NativeTimelineComponentButtonTarget(
                    messageID: row.id,
                    componentID: region.componentID
                ),
                rowIndex: index,
                message: row.message,
                kind: .sakuraCordDeepLink(region.action),
                frame: region.buttonFrame.offsetBy(
                    dx: 0,
                    dy: rowOrigin
                )
            )
        }
        if let hit = fileCardPointerHit(at: local, rowIndex: index, rowOrigin: rowOrigin, message: row.message) {
            return hit
        }
        for layout in layouts[index].componentLayouts {
            if layout.containers.contains(where: { container in
                guard container.isSpoiler,
                      container.frame.contains(local)
                else { return false }
                return !spoilerRevealStore.isMediaRevealed(
                    NativeTimelineComponentRevealKey(
                        messageID: row.id,
                        componentID: container.componentID
                    )
                )
            }) {
                return nil
            }
            for region in layout.buttons
            where region.frame.contains(local) {
                return ComponentButtonPointerHit(
                    target: NativeTimelineComponentButtonTarget(
                        messageID: row.id,
                        componentID: region.componentID
                    ),
                    rowIndex: index,
                    message: row.message,
                    kind: .component(region),
                    frame: region.frame.offsetBy(
                        dx: 0,
                        dy: rowOrigin
                    )
                )
            }
        }
        return nil
    }

}

extension NativeTimelineCanvasView {
    /// Opens the media viewer at an attachment, zooming from its tile.
    /// Returns false when the attachment has no viewer presentation.
    func openAttachmentInViewer(
        _ attachment: Attachment,
        sourceFrame: CGRect,
        message: Message,
        layout: NativeTimelineRowLayout,
        rowIndex: Int
    ) -> Bool {
        guard let presentation = MediaViewerPlan.attachments(
            in: message,
            selectedAttachmentID: attachment.id,
            isRevealed: { [spoilerRevealStore] componentID in
                spoilerRevealStore.isMediaRevealed(
                    NativeTimelineComponentRevealKey(messageID: message.id, componentID: componentID)
                )
            }
        ) else { return false }
        model?.mediaViewerPresentation = mediaViewerPresentation(
            presentation,
            sourceFrame: sourceFrame,
            rowIndex: rowIndex,
            mediaKey: MediaImageKey.attachment(attachment),
            cornerRadius: InterfaceScale.metric(8),
            fillsFrame: MediaGalleryImagePresentation.fillsFrame(itemCount: layout.mediaGalleryItemCount)
        )
        return true
    }

    /// Opens an embed's media in the viewer, zooming from `region` when it
    /// is on screen; false when the embed has nothing the viewer shows.
    func openEmbedMediaInViewer(
        id: String,
        region: NativeTimelineRowLayout.EmbedRegion?,
        message: Message,
        rowIndex: Int
    ) -> Bool {
        guard let presentation = MediaViewerPlan.embed(in: message, id: id) else { return false }
        model?.mediaViewerPresentation = mediaViewerPresentation(
            presentation,
            sourceFrame: region?.mediaFrame ?? .zero,
            rowIndex: rowIndex,
            mediaKey: region?.mediaURL.map { MediaImageKey.media($0) },
            cornerRadius: InterfaceScale.metric(8),
            fillsFrame: region?.mediaFillsFrame ?? false
        )
        return true
    }
}
