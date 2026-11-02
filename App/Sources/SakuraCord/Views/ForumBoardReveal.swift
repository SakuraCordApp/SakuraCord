import AppKit
import QuartzCore

/// Cards one board pass adds. Card bitmaps rasterize off the main thread, so
/// new cards stay hidden until every one of them has its first bitmap; the
/// visible cards they replace stay until then, and everything swaps in one
/// frame. A board never shows a card without its content, nor a gap where
/// replaced cards were.
final class ForumBoardRevealGroup {
    enum Entrance {
        case none
        case animated
        /// The delayed fade-in that keeps fast loads from flashing skeletons.
        case placeholder
    }

    struct Member {
        let card: ForumBoardCard
        let entrance: Entrance
    }

    fileprivate(set) var members: [Member] = []
    fileprivate var waiting = Set<ObjectIdentifier>()
    /// Replaced cards, recycled when the group reveals.
    fileprivate(set) var retiring: [ForumBoardCard] = []
    fileprivate var isFinished = false
    fileprivate var timeout: Task<Void, Never>?

    func add(_ card: ForumBoardCard, entrance: Entrance) {
        members.append(Member(card: card, entrance: entrance))
        if card.isRendering { waiting.insert(ObjectIdentifier(card)) }
    }

    /// Whether a card this group has yet to show will cover `frame`,
    /// including one whose bitmap is ready but waits for the rest.
    func covers(_ frame: CGRect) -> Bool {
        !isFinished && members.contains { $0.card.layer.isHidden && $0.card.frame.intersects(frame) }
    }

    func keepUntilRevealed(_ card: ForumBoardCard) {
        retiring.append(card)
    }
}

extension ForumBoardView {
    /// The longest a group waits for its bitmaps before showing the cards
    /// that are ready; the rest appear as their own bitmaps land.
    private static let revealTimeout: Duration = .milliseconds(400)

    func begin(_ group: ForumBoardRevealGroup) {
        guard !group.waiting.isEmpty else {
            reveal(group)
            return
        }
        for member in group.members {
            revealGroups[ObjectIdentifier(member.card)] = group
        }
        group.timeout = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.revealTimeout)) != nil else { return }
            self?.reveal(group)
        }
    }

    /// Cards arriving on screen wait for their bitmaps only where replaced
    /// cards hold their place. When any would leave a blank spot instead
    /// (after a jump, or a card inserted into a gap), or the board swaps
    /// under a cross-fade, the whole group draws now and appears in one frame.
    func drawArrivals(of group: ForumBoardRevealGroup) {
        let pending = group.members.map(\.card).filter { !$0.hasContent && $0.isRendering }
        guard drawsArrivalsNow
            || pending.contains(where: { card in !group.retiring.contains { $0.frame.intersects(card.frame) } })
        else { return }
        for card in pending {
            card.render(scale: backingScale, fading: false, synchronously: true)
        }
    }

    /// Recycles a card the current pass replaces. A hidden card that never
    /// appeared hands the cards it was replacing to `group`, so they stay on
    /// screen until something does: its own group's remaining cards, or the
    /// new group's. Where a shown card now covers them, they go.
    func recycle(_ card: ForumBoardCard, replacedBy group: ForumBoardRevealGroup) {
        guard let previous = revealGroups[ObjectIdentifier(card)], previous !== group, !group.waiting.isEmpty else {
            recycle(card)
            return
        }
        let retirees = previous.retiring
        previous.retiring.removeAll()
        recycle(card)
        for retiree in retirees {
            // Cards the earlier group still owes keep covering their spots.
            if holds(retiree.frame, until: previous) {
                previous.keepUntilRevealed(retiree)
            } else if holds(retiree.frame, until: group) {
                group.keepUntilRevealed(retiree)
            } else {
                recycle(retiree)
            }
        }
    }

    /// Whether a replaced card at `frame` stays until `group` reveals: a
    /// card the group adds will cover it, and no shown card already does.
    func holds(_ frame: CGRect, until group: ForumBoardRevealGroup) -> Bool {
        group.covers(frame) && !isCoveredByShownCard(frame)
    }

    /// Shows a card once its first bitmap is on screen, or its whole group
    /// once the last of the group's bitmaps is.
    func cardDidCommit(_ card: ForumBoardCard, id: ForumBoardItem.Identifier) {
        refreshShimmer(card, id: id)
        let key = ObjectIdentifier(card)
        if let group = revealGroups[key] {
            group.waiting.remove(key)
            if group.waiting.isEmpty { reveal(group) }
        } else if card.layer.isHidden, cards[id] === card {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.layer.isHidden = false
            CATransaction.commit()
            refreshHover(over: [card])
        }
    }

    /// Drops a recycled card from its group, revealing the group if it was
    /// the last card the group waited for.
    func leaveRevealGroup(_ card: ForumBoardCard) {
        let key = ObjectIdentifier(card)
        guard let group = revealGroups.removeValue(forKey: key) else { return }
        group.members.removeAll { $0.card === card }
        if group.waiting.remove(key) != nil, group.waiting.isEmpty { reveal(group) }
    }

    private func reveal(_ group: ForumBoardRevealGroup) {
        guard !group.isFinished else { return }
        group.isFinished = true
        group.timeout?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var shown: [ForumBoardCard] = []
        for member in group.members {
            let card = member.card
            let key = ObjectIdentifier(card)
            if revealGroups[key] === group { revealGroups[key] = nil }
            // A card still without a bitmap stays hidden until its own lands.
            guard card.hasContent else { continue }
            card.layer.isHidden = false
            shown.append(card)
            switch member.entrance {
            case .none:
                break
            case .animated:
                animateEntrance(card)
            case .placeholder:
                animatePlaceholderEntrance(card)
            }
        }
        let retiring = group.retiring
        group.retiring.removeAll()
        for card in retiring { recycle(card) }
        CATransaction.commit()
        refreshHover(over: shown)
    }

    /// Hover ignores hidden cards, so a card that appears under a resting
    /// pointer picks up its hover now rather than on the next mouse move.
    private func refreshHover(over shownCards: [ForumBoardCard]) {
        guard let window, !shownCards.isEmpty else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard shownCards.contains(where: { $0.frame.contains(point) }) else { return }
        updateHoverFromCurrentPointer()
    }
}
