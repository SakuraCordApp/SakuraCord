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
                .activeInKeyWindow,
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
        guard !suppressesHoverPresentation,
              !overlayBlocksInteractions,
              editingMessageID == nil
        else {
            return
        }
        let point = currentMouseLocationInCanvas()
        guard !actionCapsuleContains(point) else { return }
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
            anchor: candidate.caret
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
        didDragTextSelection = true
        _ = autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
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

    var mouseUpOperation: @MainActor (NSEvent) -> Void {
        { [self] event in
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
            return
        }
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
                case .sakuraCordDeepLink(.checkForUpdates),
                     .sakuraCordDeepLink(.updateToApplyTheme):
                    actions?.checkForUpdates()
                case let .sakuraCordDeepLink(.applyTheme(theme)):
                    actions?.applyTheme(theme)
                }
            }
            return
        }
        if textSelectionGesture != nil {
            let consumesClick =
                didDragTextSelection
                || (textSelection?.range.length ?? 0) > 0
            textSelectionGesture = nil
            didDragTextSelection = false
            if consumesClick {
                pressedActivationTarget = nil
                return
            }
        }
        let point = convert(event.locationInWindow, from: nil)
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
        if let dismissFrame = layout.ephemeralRegion?.dismissFrame,
           dismissFrame.contains(local)
        {
            model?.dismissEphemeralMessage(row.message)
            return
        }
        if !row.message.type.hasGeneratedContent,
           let authorFrame =
               NativeTimelineAuthorProfileGeometry.hitFrame(
                   at: local,
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
                    dy: displayedRowOrigin(at: index)
                )
            )
            return
        }
        if let invocation = layout.commandInvocationRegion,
           invocation.profileFrame.contains(local),
           let user = row.message.interactionMetadata?.user
        {
            showMessageProfile(
                for: user,
                anchor: invocation.profileFrame.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
            )
            return
        }
        if let replyFrame = layout.replyFrame,
           replyFrame.contains(local),
           let replyID = row.replyMessageID
        {
            actions.openReply(replyID)
            return
        }
        if let source = layout.forwardedSourceRegion,
           source.frame.contains(local)
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
            return
        }
        if let linkedImage = layout.linkedImageRegions.first(
            where: { $0.frame.contains(local) }
        ) {
            if let presentation = NativeTimelineMediaViewerPlan.linkedImages(
                in: row.message,
                selectedReferenceID: linkedImage.reference.id
            ) {
                model?.mediaViewerPresentation = mediaViewerPresentation(
                    presentation,
                    sourceFrame: linkedImage.frame,
                    rowIndex: index,
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
            return
        }
        if let attachmentRegion = layout.attachmentRegions.first(
            where: { $0.frame.contains(local) }
        ) {
            let attachment = attachmentRegion.attachment
            let revealKey = NativeTimelineComponentRevealKey.attachment(
                messageID: row.id,
                attachmentID: attachment.id
            )
            if attachment.isSpoiler,
               !spoilerRevealStore.isMediaRevealed(revealKey)
            {
                reveal(revealKey, rowIndex: index)
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
                    rowIndex: index,
                    mediaKey: NativeTimelineMediaKey.attachment(attachment),
                    cornerRadius: 8,
                    fillsFrame: MediaGalleryImagePresentation.fillsFrame(
                        itemCount: layout.attachmentRegions.count
                    )
                )
            } else {
                NSWorkspace.shared.open(attachment.url)
            }
            return
        }
        if let embedRegion = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(local) == true
        }) {
            if let presentation = NativeTimelineMediaViewerPlan.embed(
                in: row.message,
                id: embedRegion.embedID
            ) {
                model?.mediaViewerPresentation = mediaViewerPresentation(
                    presentation,
                    sourceFrame: embedRegion.mediaFrame ?? .zero,
                    rowIndex: index,
                    mediaKey: embedRegion.mediaURL.map {
                        NativeTimelineMediaKey.media($0)
                    },
                    cornerRadius: 8,
                    fillsFrame: false
                )
            } else if let mediaURL = embedRegion.mediaURL {
                NSWorkspace.shared.open(mediaURL)
            }
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
    }

    override func mouseUp(with event: NSEvent) {
        guard !overlayBlocksInteractions else { return }
        mouseUpOperation(event)
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
            configuration: .contextualProfile,
            onDismiss: { [weak self] in
                self?.activeMessageProfilePopoverAnchor = nil
            },
            presentationIdentity: AnyHashable(user.id),
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
            configuration: .contextualProfile
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
                            .activeInKeyWindow,
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
        guard !suppressesHoverPresentation,
              editingMessageID == nil,
              window?.isKeyWindow == true
        else { return }
        let point = currentMouseLocationInCanvas()
        guard !actionCapsuleContains(point) else { return }
        synchronizeHoveredRow(at: point)
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

    var pointerActivationTargetOperation:
        @MainActor (CGPoint) -> NativeTimelinePointerActivationTarget?
    {
        { [self] point in
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

        for componentLayout in layout.componentLayouts {
            for container in componentLayout.containers
            where container.isSpoiler && container.frame.contains(local) {
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
                $0.frame.contains(local)
            }) {
                return .componentImage(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.media.first(where: {
                $0.frame.contains(local)
            }) {
                return .componentMedia(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.files.first(where: {
                $0.frame.contains(local)
            }) {
                return .componentFile(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.selects.first(where: {
                $0.frame.contains(local)
            }) {
                return .componentSelect(
                    message.id,
                    region.componentID
                )
            }
        }
        if let text = textPointerHit(in: layout, point: local) {
            if let spoilerRange = text.hit.spoilerRange {
                if let key = textSpoilerRevealKey(
                    itemIdentifier: item.identifier,
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
        if layout.ephemeralRegion?.dismissFrame.contains(local) == true {
            return .ephemeralDismiss(message.id)
        }
        if !message.type.hasGeneratedContent,
           NativeTimelineAuthorProfileGeometry.hitFrame(
               at: local,
               avatarFrame: layout.avatarFrame,
               authorFrame: layout.authorFrame
           ) != nil
        {
            return .authorProfile(message.id)
        }
        if layout.commandInvocationRegion?.profileFrame.contains(local)
            == true
        {
            return .invocationProfile(message.id)
        }
        if layout.replyFrame?.contains(local) == true,
           let replyID = row.replyMessageID
        {
            return .reply(message.id, replyID)
        }
        if let source = layout.forwardedSourceRegion,
           source.frame.contains(local)
        {
            return .forwardedSource(
                message.id,
                source.channelID,
                source.guildID,
                source.messageID
            )
        }
        if let region = layout.linkedImageRegions.first(where: {
            $0.frame.contains(local)
        }) {
            return .linkedImage(
                message.id,
                region.reference.url
            )
        }
        if let region = layout.attachmentRegions.first(where: {
            $0.frame.contains(local)
        }) {
            return .attachment(
                message.id,
                region.attachment.id
            )
        }
        if let region = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(local) == true
        }) {
            return .embedMedia(message.id, region.embedID)
        }
        if layout.threadFrame?.contains(local) == true,
           let thread = message.thread
        {
            return .thread(message.id, thread.id)
        }
        if actions?.openMessage != nil,
           NativeTimelineResultActivationPolicy.frame(
               for: messageInteractionContext,
               searchCardFrame: layout.searchCardFrame,
               highlightFrame: layout.highlightFrame
           )?.contains(local) == true
        {
            return .message(message.id)
        }
        return nil

        }
    }

    func pointerActivationTarget(
        at point: CGPoint
    ) -> NativeTimelinePointerActivationTarget? {
        pointerActivationTargetOperation(point)
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

    func reactionPointerHit(at point: CGPoint) -> ReactionPointerHit? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              case let .message(row, _, _) = items[index]
        else { return nil }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        let rowOrigin = displayedRowOrigin(at: index)
        let layout = layouts[index]
        let target = NativeTimelineReactionClickHitTesting.target(
            at: local,
            reactionFrames: layout.reactionRegions.map(\.frame),
            addReactionFrame: layout.addReactionFrame
        )
        switch target {
        case let .reaction(regionIndex):
            let region = layout.reactionRegions[regionIndex]
            return ReactionPointerHit(
                target: .reaction(
                    messageID: row.id,
                    reactionID: region.reaction.id
                ),
                rowIndex: index,
                message: row.message,
                reaction: region.reaction,
                frame: region.frame.offsetBy(dx: 0, dy: rowOrigin)
            )
        case .add:
            guard let frame = layout.addReactionFrame else { return nil }
            return ReactionPointerHit(
                target: .add(messageID: row.id),
                rowIndex: index,
                message: row.message,
                reaction: nil,
                frame: frame.offsetBy(dx: 0, dy: rowOrigin)
            )
        case nil:
            return nil
        }
    }

    func reactionPointerHit(
        for target: NativeTimelineReactionPointerTarget
    ) -> ReactionPointerHit? {
        guard let index = rowIndex(for: target),
              items.indices.contains(index),
              layouts.indices.contains(index),
              case let .message(row, _, _) = items[index]
        else { return nil }
        let rowOrigin = displayedRowOrigin(at: index)
        switch target {
        case let .reaction(_, reactionID):
            guard let region = layouts[index].reactionRegions.first(where: {
                $0.reaction.id == reactionID
            }) else { return nil }
            return ReactionPointerHit(
                target: target,
                rowIndex: index,
                message: row.message,
                reaction: region.reaction,
                frame: region.frame.offsetBy(dx: 0, dy: rowOrigin)
            )
        case .add:
            guard let frame = layouts[index].addReactionFrame else {
                return nil
            }
            return ReactionPointerHit(
                target: target,
                rowIndex: index,
                message: row.message,
                reaction: nil,
                frame: frame.offsetBy(dx: 0, dy: rowOrigin)
            )
        }
    }

    func rowIndex(for target: NativeTimelineReactionPointerTarget) -> Int? {
        if let hoveredRow,
           items.indices.contains(hoveredRow),
           items[hoveredRow].messageID == target.messageID
        {
            return hoveredRow
        }
        return items.firstIndex { $0.messageID == target.messageID }
    }

    func hoveredReactionID(inMessageAt index: Int) -> String? {
        guard items.indices.contains(index),
              let messageID = items[index].messageID,
              case let .reaction(targetMessageID, reactionID) = hoveredReaction,
              targetMessageID == messageID
        else { return nil }
        return reactionID
    }

    func isAddReactionHovered(inMessageAt index: Int) -> Bool {
        guard items.indices.contains(index),
              let messageID = items[index].messageID,
              case let .add(targetMessageID) = hoveredReaction
        else { return false }
        return targetMessageID == messageID
    }

    func reactionCountSnapshot() -> ReactionCountSnapshot? {
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else { return nil }
        var counts: [ReactionCountKey: Int] = [:]
        var messageIDs: Set<MessageID> = []
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            if case let .message(row, _, _) = items[index] {
                messageIDs.insert(row.id)
                for reaction in row.message.reactions where reaction.count > 0 {
                    counts[ReactionCountKey(
                        messageID: row.id,
                        reactionID: reaction.id
                    )] = reaction.count
                }
            }
            index += 1
        }
        return ReactionCountSnapshot(
            counts: counts,
            messageIDs: messageIDs
        )
    }

    func reconcileReactionCountAnimations(
        storedBeforeUpdate: ReactionCountSnapshot? = nil
    ) {
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else { return }
        var counts: [ReactionCountKey: Int] = [:]
        var visibleMessageIDs: Set<MessageID> = []
        let reducesMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            if case let .message(row, _, _) = items[index] {
                visibleMessageIDs.insert(row.id)
                for reaction in row.message.reactions where reaction.count > 0 {
                    let key = ReactionCountKey(
                        messageID: row.id,
                        reactionID: reaction.id
                    )
                    counts[key] = reaction.count
                    guard NativeTimelineReactionCountBaseline.canAnimate(
                        hasCapturedVisibleCounts:
                            hasCapturedVisibleReactionCounts,
                        hasStoredSnapshot: storedBeforeUpdate != nil
                    ) else { continue }
                    let oldCount =
                        NativeTimelineReactionCountBaseline.previousCount(
                            capturedCount: visibleReactionCounts[key],
                            storedCountBeforeUpdate:
                                storedBeforeUpdate?.counts[key],
                            messageExistedBeforeUpdate:
                                storedBeforeUpdate?.messageIDs.contains(row.id)
                                    == true,
                            messageWasPreviouslyVisible:
                                previouslyVisibleReactionMessageIDs.contains(
                                    row.id
                                ),
                            currentCount: reaction.count
                        )
                    if !reducesMotion, oldCount != reaction.count {
                        activeReactionCountAnimations[key] =
                            ActiveReactionCountAnimation(
                                from: oldCount,
                                to: reaction.count
                            )
                        startReactionCountAnimation(
                            for: key,
                            from: oldCount,
                            to: reaction.count,
                            rowIndex: index,
                            reaction: reaction
                        )
                    }
                }
            }
            index += 1
        }

        // A canvas can receive its first model update before its clip view has
        // a non-zero viewport. Do not treat that empty pass as the baseline:
        // doing so makes the first real reaction mutation after launch appear
        // without a numeric transition.
        guard !visibleMessageIDs.isEmpty else { return }
        visibleReactionCounts = counts
        previouslyVisibleReactionMessageIDs = visibleMessageIDs
        hasCapturedVisibleReactionCounts = true
    }

    func scheduleInitialReactionCountCapture() {
        guard !hasCapturedVisibleReactionCounts,
              reactionCountBaselineTask == nil
        else { return }
        reactionCountBaselineTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.reactionCountBaselineTask = nil
            self.reconcileReactionCountAnimations()
        }
    }

    func startReactionCountAnimation(
        for key: ReactionCountKey,
        from: Int,
        to: Int,
        rowIndex: Int,
        reaction: Reaction
    ) {
        guard layouts.indices.contains(rowIndex),
              let region = layouts[rowIndex].reactionRegions.first(where: {
                  $0.reaction.id == reaction.id
              }),
              let countFrame = region.countFrame
        else {
            activeReactionCountAnimations[key] = nil
            return
        }

        reactionCountAnimationTasks[key]?.cancel()
        reactionCountAnimationTasks[key] = nil
        reactionCountAnimationHosts[key]?.removeFromSuperview()

        let color: NSColor = reaction.didCurrentUserReact
            ? .sakuraCordAccentColor
            : .labelColor
        let animationState = TimelineReactionCountAnimation(
            from: from,
            to: to
        )
        let root = AnyView(NativeTimelineReactionCountAnimationView(
            state: animationState,
            color: color
        ))
        let host = NativeTimelineReactionCountAnimationHost(rootView: root)
        let countFont = NativeTimelineReactionFonts.count
        let stableCountWidth = max(
            countFrame.width,
            ceil((String(from) as NSString).size(withAttributes: [
                .font: countFont,
            ]).width),
            ceil((String(to) as NSString).size(withAttributes: [
                .font: countFont,
            ]).width)
        )
        var stableCountFrame = countFrame
        stableCountFrame.size.width = stableCountWidth
        let canvasCountFrame = stableCountFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: rowIndex)
        )
        // The updated row bitmap already contains the destination count.
        // Paint the pill without its static glyph before attaching SwiftUI's
        // transition so the two values never overlap for one display pass.
        display(canvasCountFrame.insetBy(dx: -1, dy: -1))
        host.frame = canvasCountFrame
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(host, positioned: .above, relativeTo: nil)
        reactionCountAnimationHosts[key] = host
        // A newly constructed NSHostingView can otherwise publish the target
        // before its initial state has ever reached the screen. Commit the
        // starting count synchronously, then mutate on the next run-loop turn.
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.needsDisplay = true
        host.displayIfNeeded()
        DispatchQueue.main.async { @MainActor [weak host, weak animationState] in
            guard host?.superview != nil else { return }
            animationState?.start()
        }
        setNeedsDisplay(rowFrame(at: rowIndex))

        reactionCountAnimationTasks[key] = Task { @MainActor [weak self, weak host] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled,
                  let self,
                  self.reactionCountAnimationHosts[key] === host
            else { return }
            self.activeReactionCountAnimations[key] = nil
            if let index = self.rowIndex(for: .reaction(
                messageID: key.messageID,
                reactionID: key.reactionID
            )),
               self.layouts.indices.contains(index),
               let region = self.layouts[index].reactionRegions.first(
                   where: { $0.reaction.id == key.reactionID }
               ),
               let frame = region.countFrame
            {
                // Paint the final static count underneath the still-visible
                // host, then remove the host. This prevents an empty display
                // pass at the end of the transition.
                self.display(frame.offsetBy(
                    dx: 0,
                    dy: self.displayedRowOrigin(at: index)
                ).insetBy(dx: -1, dy: -1))
            }
            host?.removeFromSuperview()
            self.reactionCountAnimationHosts[key] = nil
            self.reactionCountAnimationTasks[key] = nil
        }
    }

    func cancelReactionCountAnimations() {
        for task in reactionCountAnimationTasks.values {
            task.cancel()
        }
        for host in reactionCountAnimationHosts.values {
            host.removeFromSuperview()
        }
        reactionCountAnimationTasks.removeAll()
        reactionCountAnimationHosts.removeAll()
        activeReactionCountAnimations.removeAll()
    }

    func reconcileAnimatedMedia(
        allowsScrolling: Bool = false
    ) {
        // Scrolling changes which compositor overlays are visible, but it
        // must not tear down the active players or decoded frames on every
        // momentum tick. A delayed reconciliation commonly lands after
        // scrolling begins.
        guard allowsScrolling || !suppressesHoverPresentation else { return }
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            animatedMediaRows.removeAll()
            inlineVideoRows.removeAll()
            lottieStickerRows.removeAll()
            removeInlineVideoOverlays()
            removeLottieStickerOverlays()
            removeAnimatedMediaOverlays()
            return
        }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || (model?.accessibilitySettings.reducesAllOptionalMotion(
                systemReduceMotion: false
            ) ?? false)
            || (model?.chatSettings.reducesAnimatedMedia
                ?? UserDefaults.standard.bool(forKey: "reduceAnimatedMedia"))
            || !permitsAnimatedMediaPlayback

        var rows:
            [NativeMessageTimelineItem.Identifier: Set<NativeTimelineMediaKey>] = [:]
        var videoRows:
            [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
        var stickerRows:
            [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            guard case let .message(row, _, _) = items[index],
                  layouts.indices.contains(index)
            else {
                index += 1
                continue
            }
            let identifier = items[index].identifier
            let keys = animatedMediaKeys(
                for: row,
                layout: layouts[index]
            )
            if !reduceMotion, !keys.isEmpty {
                rows[identifier] = keys
                for key in keys {
                    NativeTimelineMediaStore.shared.requestAnimated(
                        key,
                        owner: visibleMediaPinOwner,
                        subscriber: identifier
                    ) { [weak self] in
                        guard let self,
                              let currentIndex = self.items.firstIndex(
                                  where: { $0.identifier == identifier }
                              )
                        else { return }
                        self.invalidateBitmap(identifier)
                        self.setNeedsDisplay(self.rowFrame(at: currentIndex))
                        self.reconcileAnimatedMediaOverlays(
                            reduceMotion: false
                        )
                    }
                }
            }
            let videoURLs: Set<URL> = Set(
                layouts[index].embedRegions.compactMap { region -> URL? in
                    guard region.mediaIsVideo,
                          region.mediaAutoplaysInline
                    else { return nil }
                    return region.mediaURL
                }
            )
            if !videoURLs.isEmpty {
                videoRows[identifier] = videoURLs
            }
            let stickerURLs = Set(row.message.stickers.compactMap { sticker -> URL? in
                guard sticker.format == .lottie else { return nil }
                return sticker.mediaURL
            })
            if !stickerURLs.isEmpty {
                stickerRows[identifier] = stickerURLs
            }
            index += 1
        }
        animatedMediaRows = rows
        inlineVideoRows = videoRows
        lottieStickerRows = stickerRows
        reconcileAnimatedMediaOverlays(reduceMotion: reduceMotion)
        if !allowsScrolling {
            reconcileInlineVideoOverlays(
                plays: !reduceMotion
                    && (model?.chatSettings.autoplaysInlineVideos ?? true)
            )
            reconcileLottieStickerOverlays(
                reduceMotion: reduceMotion
                    || (model?.accessibilitySettings.reducesAnimation(
                        .sticker,
                        systemReduceMotion: false
                    ) ?? false)
                    || !(model?.chatSettings.autoplaysAnimatedStickers ?? true)
            )
        }
    }

}
