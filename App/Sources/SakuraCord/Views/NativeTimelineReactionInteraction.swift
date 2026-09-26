import AppKit
import QuartzCore
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
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
        // Keep the paused compositor layers and their clocks while occluded.
        // Discarding them here would restart decorations when the window returns.
        guard permitsAnimatedMediaPlayback else { return }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

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
                        if self.layouts[currentIndex].linkedImageRegions.contains(where: {
                            .media(
                                $0.reference.displayURL,
                                maximumPixelDimension: $0.reference.isEmoji ? 96 : 720
                            ) == key
                        }) {
                            self.scheduleMediaInvalidation(identifier)
                        }
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
            )
            reconcileLottieStickerOverlays(
                reduceMotion: reduceMotion
            )
        }
    }

}
