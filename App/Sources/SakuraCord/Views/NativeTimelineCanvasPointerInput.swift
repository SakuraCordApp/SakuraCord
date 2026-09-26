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
    override func updateTrackingAreas() {
        guard !suppressesHoverPresentation,
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
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        guard !suppressesHoverPresentation,
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
                installTextCursorRects(at: index)
                for codeBlock in codeBlockPointerTargets(at: index) {
                    addCursorRect(
                        codeBlock.copyButtonFrame,
                        cursor: .pointingHand
                    )
                }
            }
            if layouts.indices.contains(index) {
                let rowOrigin = displayedRowOrigin(at: index)
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
                if let frame = layouts[index]
                    .commandInvocationRegion?.profileFrame
                {
                    addCursorRect(
                        frame.offsetBy(dx: 0, dy: rowOrigin),
                        cursor: .pointingHand
                    )
                }
                if let frame = layouts[index]
                    .ephemeralRegion?.dismissFrame
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
                installForwardedSourceCursor(at: index, rowOrigin: rowOrigin)
                installPollCursors(at: index, rowOrigin: rowOrigin)
                installInviteCursors(at: index, rowOrigin: rowOrigin)
                installTranslationCursor(at: index, rowOrigin: rowOrigin)
            }
            index += 1
        }
    }

    private func installTextCursorRects(at index: Int) {
        let item = items[index]
        let layout = layouts[index]
        let rowOrigin = displayedRowOrigin(at: index)
        for selectable in selectableTextRegions(for: item, layout: layout) {
            addCursorRect(
                textSelectionInteractionFrame(
                    region: selectable.region,
                    frame: selectable.interactionFrame,
                    rowIndex: index
                ),
                cursor: .iBeam
            )
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
        for mention in mentionPointerRegions(at: index) {
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

    private func installForwardedSourceCursor(at index: Int, rowOrigin: CGFloat) {
        guard let frame = layouts[index].forwardedSourceRegion?.frame else { return }
        addCursorRect(
            frame.offsetBy(dx: 0, dy: rowOrigin),
            cursor: .pointingHand
        )
    }

    override func mouseEntered(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        guard !suppressesHoverPresentation,
              !overlayBlocksInteractions,
              editingMessageID == nil,
              event.trackingArea?.userInfo?["nativeTimelineTrackingKind"]
                as? String == "row",
              let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
              ] as? Int
        else { return }
        let point = currentMouseLocationInCanvas()
        guard !actionCapsuleContains(point) else { return }
        setHoveredRow(index)
        setHoveredPollTarget(pollPointerHit(at: point)?.target)
        setHoveredCompactTimestampRow(
            compactTimestampRowIndex(at: point)
        )
        setHoveredAuthorMessageID(
            authorNamePointerHit(at: point)
        )
        setHoveredMention(
            mentionPointerHit(at: point)
        )
        setHoveredTextLink(
            textLinkPointerHit(at: point)
        )
        setHoveredTextSpoiler(
            textSpoilerPointerHit(at: point)
        )
        setHoveredCodeBlock(
            codeBlockPointerHit(at: point)
        )
        setHoveredComponentButton(
            componentButtonPointerHit(at: point)?.target
        )
        setHoveredForwardedSourceMessageID(
            forwardedSourcePointerHit(at: point)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        guard !suppressesHoverPresentation,
              !overlayBlocksInteractions,
              editingMessageID == nil
        else {
            return
        }
        let point = currentMouseLocationInCanvas()
        guard !actionCapsuleContains(point) else { return }
        setHoveredPollTarget(pollPointerHit(at: point)?.target)
        synchronizeHoveredRow(at: point)
        setHoveredCompactTimestampRow(
            compactTimestampRowIndex(at: point)
        )
        setHoveredAuthorMessageID(authorNamePointerHit(at: point))
        setHoveredMention(mentionPointerHit(at: point))
        setHoveredTextLink(textLinkPointerHit(at: point))
        setHoveredTextSpoiler(textSpoilerPointerHit(at: point))
        setHoveredCodeBlock(codeBlockPointerHit(at: point))
        setHoveredComponentButton(
            componentButtonPointerHit(at: point)?.target
        )
        setHoveredForwardedSourceMessageID(
            forwardedSourcePointerHit(at: point)
        )
        setHoveredReaction(
            reactionPointerHit(at: point),
            mouseLocationInScreen: NSEvent.mouseLocation
        )
    }

    override func mouseExited(with event: NSEvent) {
        let kind = event.trackingArea?.userInfo?[
            "nativeTimelineTrackingKind"
        ] as? String
        if kind == "row" {
            setHoveredPollTarget(nil)
            guard !actionCapsuleContains(currentMouseLocationInCanvas()) else {
                return
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               hoveredRow == index
            {
                setHoveredRow(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               hoveredCompactTimestampRow == index
            {
                setHoveredCompactTimestampRow(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               items[index].messageID == hoveredAuthorMessageID
            {
                setHoveredAuthorMessageID(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               hoveredMention?.itemIdentifier == items[index].identifier
            {
                setHoveredMention(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               hoveredTextLink?.itemIdentifier == items[index].identifier
            {
                setHoveredTextLink(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               hoveredTextSpoiler?.itemIdentifier
                    == items[index].identifier
            {
                setHoveredTextSpoiler(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               hoveredCodeBlock?.itemIdentifier
                    == items[index].identifier
            {
                setHoveredCodeBlock(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               items[index].messageID
                    == hoveredComponentButton?.messageID
            {
                setHoveredComponentButton(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               items[index].messageID == hoveredForwardedSourceMessageID
            {
                setHoveredForwardedSourceMessageID(nil)
            }
            return
        }
        if kind == "canvas" {
            setHoveredPollTarget(nil)
            setHoveredCompactTimestampRow(nil)
            setHoveredAuthorMessageID(nil)
            setHoveredMention(nil)
            setHoveredTextLink(nil)
            setHoveredTextSpoiler(nil)
            setHoveredCodeBlock(nil)
            setHoveredComponentButton(nil)
            setHoveredForwardedSourceMessageID(nil)
            setHoveredReaction(nil)
            setHoveredRow(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !overlayBlocksInteractions else { return }
        window?.makeFirstResponder(self)
        guard event.buttonNumber == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        pressedActivationTarget = nil
        if let hit = pollPointerHit(at: point) {
            setHoveredPollTarget(hit.target)
            pressedPollTarget = hit.target
            setNeedsDisplay(visibleRect)
            textSelectionGesture = nil
            setTextSelection(nil)
            return
        }
        if let target = codeBlockCopyButtonHit(at: point) {
            setHoveredCodeBlock(target)
            pressedCodeBlockCopyButton = target
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
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              let frame = layouts[index].forwardedSourceRegion?.frame
        else { return nil }
        let local = CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index))
        return frame.contains(local) ? items[index].messageID : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !overlayBlocksInteractions else { return }
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
        guard !overlayBlocksInteractions else { return }
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
                Self.copyText(pressedCodeBlockCopyButton.content)
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
                case let .component(region):
                    _ = activateComponentButton(
                        region,
                        message: hit.message
                    )
                case let .sakuraCordDeepLink(action):
                    _ = activateSakuraCordDeepLink(action, message: hit.message)
                case let .invite(card, expands):
                    activateInvite(card, message: hit.message, expands: expands)
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
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              let actions
        else { return }
        let item = items[index]
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        if case let .loader(isLoading, _) = item {
            if !isLoading,
               layouts[index].loaderLayout?.controlFrame.contains(local)
                    == true
            {
                actions.loadEarlier()
            }
            return
        }
        guard case let .message(row, _, _) = item else { return }
        let layout = layouts[index]
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
                anchor: authorFrame.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: rowIndex)
                )
            )
            return true
        }
        if let invocation = layout.commandInvocationRegion,
           invocation.profileFrame.contains(point),
           let user = row.message.interactionMetadata?.user
        {
            showMessageProfile(
                for: user,
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
            if let presentation = NativeTimelineMediaViewerPlan.linkedImages(
                in: row.message,
                selectedReferenceID: linkedImage.reference.id
            ) {
                model?.mediaViewerPresentation = mediaViewerPresentation(
                    presentation,
                    sourceFrame: linkedImage.frame,
                    rowIndex: rowIndex,
                    mediaKey: .media(
                        linkedImage.reference.displayURL,
                        maximumPixelDimension:
                            linkedImage.reference.isEmoji ? 96 : 720
                    ),
                    cornerRadius: linkedImage.reference.isEmoji ? 7 : 10,
                    fillsFrame: !linkedImage.reference.isEmoji
                        && !linkedImage.reference.isSticker
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
            } else if let presentation =
                NativeTimelineMediaViewerPlan.attachments(
                    in: row.message,
                    selectedAttachmentID: attachment.id,
                    isRevealed: { [spoilerRevealStore] componentID in
                        spoilerRevealStore.isMediaRevealed(
                            NativeTimelineComponentRevealKey(
                                messageID: row.id,
                                componentID: componentID
                            )
                        )
                    }
                )
            {
                model?.mediaViewerPresentation = mediaViewerPresentation(
                    presentation,
                    sourceFrame: attachmentRegion.frame,
                    rowIndex: rowIndex,
                    mediaKey: NativeTimelineMediaKey.attachment(attachment),
                    cornerRadius: 8,
                    fillsFrame: MediaGalleryImagePresentation.fillsFrame(
                        itemCount: layout.attachmentRegions.count
                    )
                )
            } else {
                NSWorkspace.shared.open(attachment.url)
            }
            return true
        }
        if let embedRegion = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(point) == true
        }) {
            if let presentation = NativeTimelineMediaViewerPlan.embed(
                in: row.message,
                id: embedRegion.embedID
            ) {
                model?.mediaViewerPresentation = mediaViewerPresentation(
                    presentation,
                    sourceFrame: embedRegion.mediaFrame ?? .zero,
                    rowIndex: rowIndex,
                    mediaKey: embedRegion.mediaURL.map {
                        NativeTimelineMediaKey.media($0)
                    },
                    cornerRadius: 8,
                    fillsFrame: false
                )
            } else if let mediaURL = embedRegion.mediaURL {
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
            Self.copyText(selectedText)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func activateReactionPointerHit(_ hit: ReactionPointerHit) {
        switch hit.target {
        case .reaction:
            if let reaction = hit.reaction {
                actions?.react(reaction.emoji, hit.message)
            }
        case .add:
            showReactionPicker(
                for: hit.message,
                anchor: hit.frame,
                preferredEdge: .maxX
            )
        }
    }

    func showMessageProfile(
        for user: User,
        anchor: CGRect
    ) {
        guard let model else { return }
        closeMentionPopover()
        let presentationIdentity = AnyHashable(user.id)
        if messageProfilePopoverCoordinator.isPresenting(
            identity: presentationIdentity
        ) {
            closeMessageProfilePopover()
            return
        }
        closeMessageProfilePopover()
        let requestID = model.showProfile(for: user)
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

    func showMentionProfile(
        for user: User,
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        closeMessageProfilePopover()
        let requestID = model.showProfile(for: user)
        showMentionPopover(
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
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        closeMessageProfilePopover()
        model.showMembers(withRole: roleID)
        showMentionPopover(
            AnyView(
                RoleMembersPopover(
                    model: model,
                    roleID: roleID
                )
            ),
            anchor: anchor
        )
    }

    func showMentionPopover(
        _ content: AnyView,
        anchor: StablePopoverAnchor,
        configuration: StablePopoverConfiguration = .interactive
    ) {
        activeMentionPopoverAnchor = anchor
        mentionPopoverCoordinator.update(
            anchor: anchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: configuration,
            onDismiss: { [weak self] in
                self?.activeMentionPopoverAnchor = nil
            },
            content: content
        )
    }

    func closeMentionPopover() {
        mentionPopoverCoordinator.close()
        activeMentionPopoverAnchor = nil
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
                  self.editingMessageID == nil
            else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard let hit = self.reactionPointerHit(at: point) else {
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
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index)
        else { return nil }
        guard case .message = items[index] else { return index }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        guard NativeTimelineHoverHitTesting.contains(
            local,
            in: layouts[index].highlightFrame
        ) else {
            return nil
        }
        return index
    }

    func compactTimestampRowIndex(
        at point: CGPoint
    ) -> Int? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              case .message = items[index],
              layouts[index].compactTimestampFrame != nil,
              NativeTimelineCompactTimestampHitTesting.contains(
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

    func synchronizeHoverWithCurrentPointer() {
        guard WindowModalCoordinator.allowsInput(for: self), !overlayBlocksInteractions, !suppressesHoverPresentation,
              editingMessageID == nil,
              window?.isKeyWindow == true
        else { return }
        let point = currentMouseLocationInCanvas()
        guard !actionCapsuleContains(point) else { return }
        synchronizeHoveredRow(at: point)
        setHoveredPollTarget(visibleRect.contains(point) ? pollPointerHit(at: point)?.target : nil)
        setHoveredCompactTimestampRow(
            visibleRect.contains(point)
                ? compactTimestampRowIndex(at: point)
                : nil
        )
        setHoveredAuthorMessageID(
            visibleRect.contains(point)
                ? authorNamePointerHit(at: point)
                : nil
        )
        setHoveredMention(
            visibleRect.contains(point)
                ? mentionPointerHit(at: point)
                : nil
        )
        setHoveredTextLink(
            visibleRect.contains(point)
                ? textLinkPointerHit(at: point)
                : nil
        )
        setHoveredTextSpoiler(
            visibleRect.contains(point)
                ? textSpoilerPointerHit(at: point)
                : nil
        )
        setHoveredCodeBlock(
            visibleRect.contains(point)
                ? codeBlockPointerHit(at: point)
                : nil
        )
        setHoveredComponentButton(
            visibleRect.contains(point)
                ? componentButtonPointerHit(at: point)?.target
                : nil
        )
        setHoveredReaction(
            reactionPointerHit(at: point),
            mouseLocationInScreen: NSEvent.mouseLocation
        )
    }

    func actionCapsuleContains(_ point: CGPoint) -> Bool {
        actionCapsuleHost?.frame.contains(point) == true
    }

    func synchronizeHoveredRow(at point: CGPoint) {
        setHoveredRow(
            visibleRect.contains(point)
                ? hoveredRowIndex(at: point)
                : nil
        )
    }

    func mentionPointerHit(
        at point: CGPoint
    ) -> NativeTimelineMentionHover? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              case .message = items[index]
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
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              case let .message(row, _, _) = items[index],
              row.startsGroup,
              !row.message.type.hasGeneratedContent,
              let authorFrame = layouts[index].authorFrame
        else { return nil }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        return authorFrame.contains(local) ? row.message.id : nil
    }

    func textLinkPointerHit(
        at point: CGPoint
    ) -> NativeTimelineTextLinkHover? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              items[index].messageID != nil
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
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              items[index].messageID != nil
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
            ).map { mention in
                MentionPointerRegion(
                    region: selectable.region,
                    characterIndex: mention.characterIndex,
                    rawToken: mention.presentation.rawToken,
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
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index)
        else { return nil }
        let item = items[index]
        let layout = layouts[index]
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        if case let .loader(isLoading, _) = item {
            guard !isLoading,
                  layout.loaderLayout?.controlFrame.contains(local) == true
            else { return nil }
            return .loader
        }
        guard case let .message(row, _, _) = item else { return nil }
        let message = row.message
        return componentActivationTarget(message: message, layout: layout, point: local)
            ?? textActivationTarget(
                message: message,
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
        message: Message,
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
                        message.id,
                        text.region,
                        rangeLocation: spoilerRange.location
                    )
                }
            }
            if let mention = text.hit.mention {
                return .textMention(
                    message.id,
                    text.region,
                    characterIndex: text.hit.characterIndex,
                    rawToken: mention.rawToken
                )
            }
            if let url = text.hit.url {
                return .textURL(
                    message.id,
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

    func componentButtonPointerHit(
        at point: CGPoint
    ) -> ComponentButtonPointerHit? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
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
