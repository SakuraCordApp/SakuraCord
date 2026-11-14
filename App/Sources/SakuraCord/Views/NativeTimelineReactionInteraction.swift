import AppKit
import QuartzCore
import SakuraCordModels

extension NativeTimelineCanvasView {
    func reactionPointerHit(at point: CGPoint) -> ReactionPointerHit? {
        guard let index = hitRowIndex(at: point.y),
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
        let frames = displayedReactionFrames(at: index)
        switch target {
        case let .reaction(_, reactionID):
            guard let regionIndex = layouts[index].reactionRegions.firstIndex(where: {
                $0.reaction.id == reactionID
            }) else { return nil }
            return ReactionPointerHit(
                target: target,
                rowIndex: index,
                message: row.message,
                reaction: layouts[index].reactionRegions[regionIndex].reaction,
                frame: frames.reactions[regionIndex].offsetBy(dx: 0, dy: rowOrigin)
            )
        case .add:
            guard model?.canCreateReactions(on: row.message) == true,
                  let frame = frames.add else {
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

}
