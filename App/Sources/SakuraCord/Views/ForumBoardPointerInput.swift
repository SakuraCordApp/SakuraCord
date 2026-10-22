import AppKit
import SakuraCordModels

extension ForumBoardView {
    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    struct Hit {
        let entry: ForumBoardLayout.Entry
        let local: CGPoint
    }

    func hit(at point: CGPoint) -> Hit? {
        guard let layoutState else { return nil }
        let probe = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        guard let entry = layoutState.entries(intersecting: probe).first(where: { $0.frame.contains(point) }) else { return nil }
        // A card waiting for its bitmap is not on screen yet; the card it
        // replaces may still show there, so the pointer reaches neither.
        guard cards[entry.item.id]?.layer.isHidden != true else { return nil }
        return Hit(entry: entry, local: CGPoint(x: point.x - entry.frame.minX, y: point.y - entry.frame.minY))
    }

    private func isInteractive(_ item: ForumBoardItem) -> Bool {
        switch item {
        case .post, .paginationStatus: true
        case .placeholder, .olderPostsHeader: false
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with _: NSEvent) {
        setHovered(nil)
        clearInnerHover()
    }

    func updateHoverFromCurrentPointer() {
        guard let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else {
            setHovered(nil)
            clearInnerHover()
            return
        }
        updateHover(at: point)
    }

    private func updateHover(at point: CGPoint) {
        guard WindowModalCoordinator.allowsInput(for: self) else {
            setHovered(nil)
            clearInnerHover()
            return
        }
        guard let hit = hit(at: point), isInteractive(hit.entry.item) else {
            setHovered(nil)
            clearInnerHover()
            return
        }
        setHovered(hit.entry.item.id)
        let id = hit.entry.item.id
        var interaction = interactions[id] ?? ForumCardInteraction()
        let previous = interaction
        switch hit.entry.item {
        case let .post(input):
            let regions = cardRegions(for: id)
            let isOnReaction = regions?.reactionRegionFrame?.contains(hit.local) == true
            interaction.isReactionHovered = isOnReaction
            if isOnReaction, let summary = presentations[input.id]?.reaction {
                presentReactionTooltip(postID: input.id, summary: summary)
            } else if !isOnReaction {
                closeReactionTooltip()
            }
            if let renderer = excerptRenderers[input.id], let excerptOrigin = excerptOrigin(for: id) {
                let location = renderer.hiddenSpoilerLocation(at: CGPoint(x: hit.local.x - excerptOrigin.x, y: hit.local.y - excerptOrigin.y))
                if renderer.setHoveredSpoiler(location) { cards[id]?.render(scale: backingScale, fading: false) }
            }
        case .paginationStatus:
            interaction.isRetryHovered = ForumCardPainter.paginationRetryFrame(in: CGRect(origin: .zero, size: hit.entry.frame.size)).contains(hit.local)
        case .placeholder, .olderPostsHeader:
            break
        }
        for (otherID, other) in interactions where otherID != id && other != ForumCardInteraction() {
            interactions[otherID] = ForumCardInteraction()
            cards[otherID]?.render(scale: backingScale, fading: false)
        }
        if interaction != previous {
            interactions[id] = interaction
            cards[id]?.render(scale: backingScale, fading: false)
        }
    }

    /// Where the excerpt's text begins inside its card; spoiler hit tests
    /// are relative to it.
    private func excerptOrigin(for id: ForumBoardItem.Identifier) -> CGPoint? {
        guard let regions = cardRegions(for: id) else { return nil }
        if isGallery {
            return regions.heroFrame.map { CGPoint(x: $0.minX + InterfaceScale.metric(16), y: $0.minY + InterfaceScale.metric(14)) }
        }
        return regions.excerptFrame?.origin
    }

    private func clearInnerHover() {
        closeReactionTooltip()
        for (id, interaction) in interactions where interaction != ForumCardInteraction() {
            interactions[id] = ForumCardInteraction()
            cards[id]?.render(scale: backingScale, fading: false)
        }
        for (postID, renderer) in excerptRenderers where renderer.setHoveredSpoiler(nil) {
            cards[.post(postID)]?.render(scale: backingScale, fading: false)
        }
    }

    private func setHovered(_ id: ForumBoardItem.Identifier?) {
        guard hoveredID != id else { return }
        let previous = hoveredID
        hoveredID = id
        for changed in [previous, id].compactMap(\.self) {
            if let card = cards[changed] { applyChrome(card, id: changed, animated: true) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hit(at: point), isInteractive(hit.entry.item) else { return }
        pressedID = hit.entry.item.id
        if case .post = hit.entry.item, let card = cards[hit.entry.item.id] {
            applyChrome(card, id: hit.entry.item.id, animated: true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedID else { return }
        let point = convert(event.locationInWindow, from: nil)
        let isInside = layoutState?.entry(for: pressedID)?.frame.contains(point) == true
        if let card = cards[pressedID] {
            card.applyChrome(
                isHovered: isInside,
                isKeyboardFocused: false,
                isPressed: isInside,
                isSelected: false,
                appearance: effectiveAppearance,
                animated: true
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressedID else { return }
        self.pressedID = nil
        let point = convert(event.locationInWindow, from: nil)
        if let card = cards[pressedID] { applyChrome(card, id: pressedID, animated: true) }
        guard let hit = hit(at: point), hit.entry.item.id == pressedID else { return }
        activate(hit.entry.item, at: hit.local)
    }

    override func resetCursorRects() {
        guard let layoutState else { return }
        for entry in layoutState.entries(intersecting: visibleRect) where isInteractive(entry.item) {
            addCursorRect(entry.frame, cursor: .pointingHand)
        }
    }

    // MARK: Activation

    /// Opens a post or retries a failed page. A click passes the point inside
    /// the card so a hidden spoiler or the reaction pill can take it first;
    /// keyboard and accessibility activation pass none. Returns whether the
    /// item handled it.
    @discardableResult
    func activate(_ item: ForumBoardItem, at local: CGPoint?) -> Bool {
        guard let model else { return false }
        switch item {
        case let .post(input):
            guard let post = postsByID[input.id] else { return false }
            if let local, activateInnerRegion(of: input.id, at: local) { return true }
            model.open(post)
            return true
        case .paginationStatus:
            guard snapshot?.paginationError != nil else { return false }
            Task { await model.loadMoreForumPosts() }
            return true
        case .placeholder, .olderPostsHeader:
            return false
        }
    }

    private func activateInnerRegion(of postID: ChannelID, at local: CGPoint) -> Bool {
        let id = ForumBoardItem.Identifier.post(postID)
        if let renderer = excerptRenderers[postID], let origin = excerptOrigin(for: id),
           let location = renderer.hiddenSpoilerLocation(at: CGPoint(x: local.x - origin.x, y: local.y - origin.y))
        {
            renderer.revealSpoiler(at: location)
            return true
        }
        if let frame = cardRegions(for: id)?.reactionRegionFrame, frame.contains(local),
           presentations[postID]?.reaction != nil
        {
            toggleReaction(on: postID)
            return true
        }
        return false
    }

    @discardableResult
    func toggleReaction(on postID: ChannelID) -> Bool {
        guard let model, let summary = presentations[postID]?.reaction, !summary.isDisabled else { return false }
        Task { await model.toggleReaction(summary.reaction.emoji, on: summary.message) }
        return true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let layoutState else { return super.keyDown(with: event) }
        // Posts and a failed page's retry notice take keyboard focus.
        let posts = layoutState.entries.filter {
            if case .paginationStatus = $0.item { return true }
            return $0.item.postID != nil
        }
        guard !posts.isEmpty else { return super.keyDown(with: event) }
        let currentIndex = keyboardID.flatMap { id in posts.firstIndex { $0.item.id == id } }
        var next: Int?
        switch event.specialKey {
        case .downArrow:
            next = currentIndex.map { verticalStep(from: $0, down: true, in: posts) } ?? 0
        case .upArrow:
            next = currentIndex.map { verticalStep(from: $0, down: false, in: posts) } ?? 0
        case .rightArrow where isGallery: next = currentIndex.map { min(posts.count - 1, $0 + 1) } ?? 0
        case .leftArrow where isGallery: next = currentIndex.map { max(0, $0 - 1) } ?? 0
        case .carriageReturn, .enter:
            if let currentIndex { activate(posts[currentIndex].item, at: nil) }
            return
        default:
            if event.charactersIgnoringModifiers == " ", let currentIndex {
                activate(posts[currentIndex].item, at: nil)
                return
            }
            return super.keyDown(with: event)
        }
        guard let next else { return }
        let previous = keyboardID
        keyboardID = posts[next].item.id
        for id in [previous, keyboardID].compactMap(\.self) {
            if let card = cards[id] { applyChrome(card, id: id, animated: true) }
        }
        scrollToVisible(posts[next].frame.insetBy(dx: 0, dy: -metrics.cardSpacing))
    }

    /// The entry Up or Down moves to: one entry in a list, and in a gallery the
    /// entry of the adjacent row nearest the current one's horizontal position,
    /// so rows of different sections may have different column counts.
    private func verticalStep(from index: Int, down: Bool, in posts: [ForumBoardLayout.Entry]) -> Int {
        guard isGallery else { return down ? min(posts.count - 1, index + 1) : max(0, index - 1) }
        return ForumBoardLayout.adjacentRowIndex(from: index, down: down, in: posts.map(\.frame))
    }

    override func resignFirstResponder() -> Bool {
        if let keyboardID {
            self.keyboardID = nil
            if let card = cards[keyboardID] { applyChrome(card, id: keyboardID, animated: true) }
        }
        return super.resignFirstResponder()
    }
}
