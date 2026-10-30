import AppKit
import QuartzCore
import SakuraCordModels

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
        let frames = displayedReactionFrames(at: index)
        let target = NativeTimelineReactionClickHitTesting.target(
            at: local,
            reactionFrames: frames.reactions,
            addReactionFrame: frames.add
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
                frame: frames.reactions[regionIndex].offsetBy(dx: 0, dy: rowOrigin)
            )
        case .add:
            guard model?.canCreateReactions(on: row.message) == true,
                  let frame = frames.add else { return nil }
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
            guard model?.canCreateReactions(on: row.message) == true,
                  let frame = layouts[index].addReactionFrame else {
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
            removeInlineVideoOverlays()
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
            // A message still flying in from the composer gets its media
            // once it lands.
            if hidesRowForSendTransition(identifier) {
                index += 1
                continue
            }
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
            index += 1
        }
        animatedMediaRows = rows
        inlineVideoRows = videoRows
        reconcileAnimatedMediaOverlays(reduceMotion: reduceMotion)
        if !allowsScrolling {
            reconcileInlineVideoOverlays(
                plays: !reduceMotion
            )
        }
    }

}
