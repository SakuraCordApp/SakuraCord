import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    func reactionPointerHit(at point: CGPoint) -> ReactionPointerHit? {
        guard case let (index, local)? = rowHit(at: point),
              case let .message(row, _, _) = items[index]
        else { return nil }
        let frames = displayedReactionFrames(at: index)
        switch NativeTimelineReactionClickHitTesting.target(
            at: local,
            reactionFrames: frames.reactions,
            addReactionFrame: frames.add
        ) {
        case let .reaction(regionIndex):
            let reaction = layouts[index].reactionRegions[regionIndex].reaction
            return reactionPointerHit(
                .reaction(messageID: row.id, reactionID: reaction.id),
                at: index, message: row.message, reaction: reaction, frame: frames.reactions[regionIndex]
            )
        case .add:
            return reactionPointerHit(
                .add(messageID: row.id), at: index, message: row.message, reaction: nil, frame: frames.add
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
        let frames = displayedReactionFrames(at: index)
        switch target {
        case let .reaction(_, reactionID):
            guard let regionIndex = layouts[index].reactionRegions.firstIndex(where: {
                $0.reaction.id == reactionID
            }) else { return nil }
            return reactionPointerHit(
                target, at: index, message: row.message,
                reaction: layouts[index].reactionRegions[regionIndex].reaction, frame: frames.reactions[regionIndex]
            )
        case .add:
            return reactionPointerHit(target, at: index, message: row.message, reaction: nil, frame: frames.add)
        }
    }

    /// The hit for a chip or the add button of the row at `index`, drawn at
    /// `frame` in the row; none for an add button the user may not use.
    private func reactionPointerHit(
        _ target: NativeTimelineReactionPointerTarget,
        at index: Int,
        message: Message,
        reaction: Reaction?,
        frame: CGRect?
    ) -> ReactionPointerHit? {
        if case .add = target, model?.canCreateReactions(on: message) != true { return nil }
        guard let frame else { return nil }
        return ReactionPointerHit(
            target: target,
            rowIndex: index,
            message: message,
            reaction: reaction,
            frame: frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
        )
    }

    func rowIndex(for target: NativeTimelineReactionPointerTarget) -> Int? {
        if let hoveredRow = pointer.hoveredRow,
           items.indices.contains(hoveredRow),
           items[hoveredRow].messageID == target.messageID
        {
            return hoveredRow
        }
        return rowIndex(forMessageID: target.messageID)
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

    func setHoveredReaction(
        _ hit: ReactionPointerHit?,
        mouseLocationInScreen: CGPoint = NSEvent.mouseLocation
    ) {
        let oldTarget = hoveredReaction
        let newTarget = hit?.target
        hoveredReaction = newTarget
        if oldTarget != newTarget {
            if let oldTarget, let index = rowIndex(for: oldTarget) {
                setNeedsDisplay(rowFrame(at: index))
            }
            if let hit {
                setNeedsDisplay(rowFrame(at: hit.rowIndex))
            }
        }

        guard let hit,
              let reaction = hit.reaction,
              case .reaction = hit.target
        else {
            reactionHoverCoordinator.close()
            return
        }
        presentReactionHover(
            hit,
            reaction: reaction,
            mouseLocationInScreen: mouseLocationInScreen
        )
        if oldTarget != newTarget {
            Task { [weak model] in
                await model?.loadReactionReactors(reaction, on: hit.message)
            }
        }
    }

    func reconcileReactionHover() {
        guard let target = hoveredReaction,
              let hit = reactionPointerHit(for: target)
        else {
            hoveredReaction = nil
            reactionHoverCoordinator.close()
            return
        }
        setHoveredReaction(hit)
    }

    func presentReactionHover(
        _ hit: ReactionPointerHit,
        reaction: Reaction,
        mouseLocationInScreen: CGPoint
    ) {
        let target = hit.target
        let anchor = StablePopoverAnchor(sourceView: self) { [weak self] in
            self?.reactionPointerHit(for: target)?.frame
        }
        let mouseInWindow = window?.convertPoint(
            fromScreen: mouseLocationInScreen
        ) ?? .zero
        let mouseInCanvas = convert(mouseInWindow, from: nil)
        let snapshot = StablePopoverAnchorSnapshot(
            mouseLocationInScreen: mouseLocationInScreen,
            mouseLocationInSource: CGPoint(
                x: mouseInCanvas.x - hit.frame.minX,
                y: mouseInCanvas.y - hit.frame.minY
            )
        )
        let emojiURL = reaction.emojiReference.imageURL(in: model?.customEmojiURLsByID)
        reactionHoverCoordinator.update(
            anchor: anchor,
            anchorSnapshot: snapshot,
            isPresented: true,
            configuration: .hover,
            onDismiss: {},
            content: MessageReactionTooltip(
                reaction: reaction,
                emojiURL: emojiURL
            )
        )
    }

    /// Both native reaction popovers use the visible message row as their anchor.
    /// The presenters freeze this rectangle while the popover remains open.
    func messageReactionPopoverAnchor(for message: Message) -> CGRect? {
        guard let index = rowIndex(forMessageID: message.id),
              layouts.indices.contains(index) else { return nil }
        let viewport = enclosingScrollView?.documentVisibleRect ?? visibleRect
        let anchor = visiblePart(ofRowAt: index, in: viewport) ?? viewport
        return anchor.isNull || anchor.isEmpty ? nil : anchor
    }

    /// The part of the row inside `viewport`, or nil when none of it is.
    private func visiblePart(ofRowAt index: Int, in viewport: CGRect) -> CGRect? {
        let part = rowFrame(at: index).intersection(viewport)
        return part.isNull || part.isEmpty ? nil : part
    }

    func beginReactionPopoverLayout() {
        // Layout may restore the viewport or rebase history coordinates. Keep
        // open popovers steady through that correction, independently of scroll.
        reactionPopoverLayoutAnchors = [reactionPickerSource.installedSnapshotAnchor, reactionDetailsPopoverAnchor]
            .compactMap { anchor in
                guard let anchor, anchor.window != nil, anchor.superview != nil else { return nil }
                return (anchor, anchor.convert(anchor.bounds, to: nil))
            }
    }

    func endReactionPopoverLayout() {
        for (anchor, frameInWindow) in reactionPopoverLayoutAnchors {
            guard let parent = anchor.superview, anchor.window === window else { continue }
            anchor.frame = parent.convert(frameInWindow, from: nil)
        }
        reactionPopoverLayoutAnchors.removeAll(keepingCapacity: true)
        dismissOffscreenReactionPopovers()
    }

    func dismissOffscreenReactionPopovers() {
        guard reactionPickerCoordinator.isShown || reactionDetailsPopover?.isShown == true else { return }
        let viewport = enclosingScrollView?.documentVisibleRect ?? visibleRect
        func isVisible(_ messageID: MessageID?) -> Bool {
            guard let messageID, let index = rowIndex(forMessageID: messageID) else { return false }
            return visiblePart(ofRowAt: index, in: viewport) != nil
        }
        if reactionPickerCoordinator.isShown, !isVisible(reactionPickerMessageID) {
            reactionPickerMessageID = nil
            reactionPickerCoordinator.close(notifyBinding: true)
        }
        if reactionDetailsPopover?.isShown == true, !isVisible(reactionDetailsMessageID) {
            reactionDetailsMessageID = nil
            reactionDetailsPopover?.close()
        }
    }

    func showReactionPicker(forMessageRow message: Message) {
        guard let model, model.canCreateReactions(on: message),
              let anchor = messageReactionPopoverAnchor(for: message) else { return }
        reactionPickerMessageID = message.id
        reactionPickerSource.frame = anchor
        reactionPickerSource.followsScrolling = true
        let content = EmojiPickerView(
            model: model,
            useCase: .reaction(
                guildID: message.guildID ?? model.selectedGuildID
            ),
            allowsPersistentSelection: true,
            dismiss: { [weak self] in
                guard let self else { return }
                self.reactionPickerCoordinator.close(notifyBinding: false)
                self.reactionPickerSource.frame = .zero
            },
            select: { [weak self] activation in
                guard let self else { return }
                let value = switch activation.selection {
                case let .native(value): value
                case let .custom(emoji): emoji.messageToken
                }
                self.actions?.react(value, message)
                if !activation.keepsPickerPresented {
                    self.reactionPickerCoordinator.close(
                        notifyBinding: false
                    )
                    self.reactionPickerSource.frame = .zero
                }
            }
        )
        reactionPickerCoordinator.update(
            sourceView: reactionPickerSource,
            isPresented: true,
            preferredEdge: .maxX,
            accessibilityIdentifier: ReactionActionMenuPresentation.inline.pickerAccessibilityIdentifier,
            content: content,
            setPresented: { [weak self] isPresented in
                if !isPresented {
                    self?.reactionPickerSource.frame = .zero
                }
            }
        )
    }
}
