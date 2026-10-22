import AppKit
import Observation
import QuartzCore
import SakuraCordModels
import SwiftUI

/// What the board shows. The SwiftUI shell builds it from the model; the
/// board resolves per-card presentation itself, for visible cards only.
struct ForumBoardSnapshot: Equatable {
    /// Changing it scrolls back to the first post: a new query must not keep a
    /// deep offset into a different, possibly shorter, result.
    struct Query: Equatable {
        let channelID: ChannelID
        let searchText: String
        let tagIDs: Set<ForumTagID>
        let tagMatch: ForumTagMatch
        let sortOrder: ForumSortOrder
    }

    let query: Query
    let mode: ForumLayout
    let posts: [ForumPost]
    let recentCount: Int
    let showsPlaceholders: Bool
    let isLoadingMore: Bool
    let paginationError: String?
    let hasMore: Bool

    var items: [ForumBoardItem] {
        if posts.isEmpty, showsPlaceholders {
            return (0 ..< 8).map(ForumBoardItem.placeholder)
        }
        var items: [ForumBoardItem] = []
        items.reserveCapacity(posts.count + 4)
        for (index, post) in posts.enumerated() {
            if index == recentCount, index > 0 || recentCount == 0, index < posts.count {
                items.append(.olderPostsHeader)
            }
            items.append(.post(ForumCardGeometryInput(post: post)))
        }
        if isLoadingMore {
            items += (0 ..< (mode == .gallery ? 3 : 2)).map { .placeholder(100 + $0) }
        } else if paginationError != nil {
            items.append(.paginationStatus)
        }
        return items
    }
}

struct NativeForumBoardView: NSViewRepresentable {
    let model: AppModel
    let channel: Channel
    let snapshot: ForumBoardSnapshot
    /// The SwiftUI header's height; the board scrolls beneath it.
    let headerHeight: CGFloat

    func makeNSView(context _: Context) -> ForumBoardScrollView {
        ForumBoardScrollView()
    }

    func updateNSView(_ scrollView: ForumBoardScrollView, context _: Context) {
        scrollView.headerHeight = headerHeight
        scrollView.board.update(model: model, channel: channel, snapshot: snapshot)
    }

    static func dismantleNSView(_ scrollView: ForumBoardScrollView, coordinator _: ()) {
        scrollView.board.tearDown()
    }
}

final class ForumBoardScrollView: NSScrollView {
    let board = ForumBoardView()
    var headerHeight: CGFloat = 0 {
        didSet { if headerHeight != oldValue { updateTopInset() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        documentView = board
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            board,
            selector: #selector(ForumBoardView.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
        setAccessibilityIdentifier("forum-board-scroll")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateTopInset()
        board.viewportDidResize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTopInset()
    }

    /// Insets the first post below the window toolbar and the SwiftUI header,
    /// both of which the board extends beneath.
    private func updateTopInset() {
        guard let window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let toolbarHeight = max(0, frameInWindow.maxY - window.contentLayoutRect.maxY)
        let top = toolbarHeight + headerHeight
        guard abs(contentInsets.top - top) > 0.25 else { return }
        let wasAtTop = contentView.bounds.minY <= -contentInsets.top + 1
        var insets = contentInsets
        insets.top = top
        contentInsets = insets
        if wasAtTop {
            contentView.scroll(to: NSPoint(x: 0, y: -top))
            reflectScrolledClipView(contentView)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        super.scrollWheel(with: event)
    }
}

/// The forum's post board: a flipped document view whose visible items are
/// recycled `ForumBoardCard` layers painted with Core Graphics and Core Text.
///
/// It replaced a SwiftUI `LazyVStack`/`LazyVGrid` of cards, whose rows changed
/// height as starter messages, thumbnails, reactions and fonts arrived. Here
/// geometry comes only from `ForumBoardLayout`, late data repaints in place,
/// and structural changes animate on the compositor. This file owns the state,
/// updates, layout and card realization; the extensions beside it handle
/// presentation and painting, pointer and keyboard input, accessibility,
/// media and menus, and animation.
final class ForumBoardView: NSView, NSViewToolTipOwner {
    weak var model: AppModel?
    var channel: Channel?
    /// The channel's tags by ID, rebuilt when the channel changes, so
    /// presentations resolve tags without building a map per post.
    var tagsByID: [ForumTagID: ForumTag] = [:]
    var snapshot: ForumBoardSnapshot?
    var items: [ForumBoardItem] = []
    var postsByID: [ChannelID: ForumPost] = [:]
    var layoutState: ForumBoardLayout?
    var metrics = ForumBoardMetrics.current()
    var titleCounter: ForumTitleLineCounter
    let cardsLayer = CALayer()
    var cards: [ForumBoardItem.Identifier: ForumBoardCard] = [:]
    var reusableCards: [ForumBoardCard] = []
    /// Cards fading out after a live removal, no longer in `cards`.
    var exitingCards: [ObjectIdentifier: ForumBoardCard] = [:]
    /// Hidden new cards, by card, waiting for their group's bitmaps.
    var revealGroups: [ObjectIdentifier: ForumBoardRevealGroup] = [:]
    /// Set while the board swaps under a cross-fade, so every card arriving
    /// on screen is drawn before the fade captures the new board.
    var drawsArrivalsNow = false
    /// Set while the board follows a width change in progress (a pane
    /// sliding, the window resizing): resized cards reflow off the main
    /// thread, excerpts included, and redraw once more through the usual
    /// path when the width settles.
    private var followsLiveResize = false
    /// Read by `scene` while a live resize redraws a card.
    var laysOutExcerptsOffMain = false
    private var liveResizedIDs = Set<ForumBoardItem.Identifier>()
    private var resizeSettleTask: Task<Void, Never>?
    let rasterCache = ForumCardRasterCache()
    var presentations: [ChannelID: ForumCardPresentation] = [:]
    var regions: [ForumBoardItem.Identifier: ForumCardRegions] = [:]
    var excerptRenderers: [ChannelID: ForumPostPreviewTextRenderer] = [:]
    var interactions: [ForumBoardItem.Identifier: ForumCardInteraction] = [:]
    /// The relative time each card last painted, so the minute tick repaints
    /// only cards whose text changed.
    var paintedRelativeTimes: [ForumBoardItem.Identifier: String] = [:]
    var hoveredID: ForumBoardItem.Identifier?
    var pressedID: ForumBoardItem.Identifier?
    var keyboardID: ForumBoardItem.Identifier?
    var trackingArea: NSTrackingArea?
    let mediaOwner = UUID()
    var presentationRefreshScheduled = false
    var observationGeneration = 0
    private var minuteTimer: Timer?
    private var lastLayoutWidth: CGFloat = 0
    let menuBuilder = ForumPostMenuBuilder()
    /// The post whose reactors popover is showing.
    var reactionTooltipPostID: ChannelID?
    let reactionTooltip = StableAnchoredPopoverPresenter<MessageReactionTooltip>.Coordinator()
    var accessibilityProxies: [ForumBoardItem.Identifier: ForumBoardAccessibilityProxyView] = [:]
    /// A page request is in flight from this board; the model also guards.
    var isRequestingPage = false
    /// Media whose last request failed, so painters can show a fallback.
    var failedMediaKeys = Set<NativeTimelineMediaKey>()
    /// The entry indices realized last time; nil forces the next refresh to
    /// reconcile every card and rebuild settled state.
    private var realizedRange: Range<Int>?
    private var settledWorkTask: Task<Void, Never>?
    private var needsObservationRefresh = false
    var authorPrefixes: [AuthorPrefixKey: ForumPostPreviewTextView.Prefix] = [:]

    override var isFlipped: Bool { true }

    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    var isGallery: Bool { snapshot?.mode == .gallery }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init() {
        titleCounter = ForumTitleLineCounter(font: metrics.titleFont, maximumLines: metrics.maximumTitleLines)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        cardsLayer.anchorPoint = .zero
        layer?.addSublayer(cardsLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Forum posts")
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(fontsDidLoad), name: ProfileNameFontLoader.didLoadFonts, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func tearDown() {
        settledWorkTask?.cancel()
        resizeSettleTask?.cancel()
        minuteTimer?.invalidate()
        minuteTimer = nil
        reactionTooltip.close()
        NativeTimelineMediaStore.shared.releaseVisibleImages(owner: mediaOwner)
        NativeTimelineMediaStore.shared.cancelStaticRequestsOutsideVisibleSet(owner: mediaOwner)
        for renderer in excerptRenderers.values { renderer.stopObservingReveals() }
        excerptRenderers.removeAll()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            minuteTimer?.invalidate()
            minuteTimer = nil
            return
        }
        orientCardsLayer()
        if minuteTimer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRelativeTimes() }
            }
            RunLoop.main.add(timer, forMode: .common)
            minuteTimer = timer
        }
        #if DEBUG
        if let scrollView = enclosingScrollView {
            ForumBoardBenchmark.register(scrollView: scrollView)
        }
        #endif
    }

    /// Card coordinates are top-down like the view's. AppKit may or may not
    /// flip a flipped view's backing layer, so the host layer adapts.
    private func orientCardsLayer() {
        guard let layer else { return }
        if cardsLayer.superlayer !== layer { layer.addSublayer(cardsLayer) }
        cardsLayer.isGeometryFlipped = false
        cardsLayer.isGeometryFlipped = !cardsLayer.contentsAreFlipped()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for (id, card) in cards { applyChrome(card, id: id, animated: false) }
        // The chrome changes at once, so the content does too.
        repaintVisibleCards(fading: false, synchronously: true)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for card in cards.values {
            card.render(scale: backingScale, fading: false, synchronously: true)
        }
    }

    @objc private func fontsDidLoad() {
        // Author prefixes captured fallback fonts; rebuild them.
        reconfigureRealizedExcerpts()
        repaintVisibleCards(fading: false)
    }

    @objc private func displayOptionsDidChange() {
        for (id, card) in cards { refreshShimmer(card, id: id) }
    }

    // MARK: Updates

    func update(model: AppModel, channel: Channel, snapshot: ForumBoardSnapshot) {
        let previousSnapshot = self.snapshot
        let previousChannel = self.channel
        let channelChanged = previousChannel?.id != channel.id
        let channelUpdated = previousChannel != channel
        if channelUpdated {
            tagsByID = Dictionary(channel.availableTags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        self.model = model
        self.channel = channel
        guard previousSnapshot != snapshot || channelChanged else {
            // Observation covers model reads; the channel's tags and default
            // reaction arrive as a value, so only a change to it re-resolves.
            if channelUpdated { schedulePresentationRefresh() }
            return
        }
        self.snapshot = snapshot
        postsByID = Dictionary(snapshot.posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let queryChanged = previousSnapshot?.query != snapshot.query
        let modeChanged = previousSnapshot?.mode != snapshot.mode
        let wasShowingPlaceholders = previousSnapshot.map { $0.posts.isEmpty && $0.showsPlaceholders } ?? true
        let newItems = snapshot.items
        let structureChanged = newItems != items || modeChanged
        items = newItems
        if channelChanged { presentations.removeAll() }
        // Excerpts depend on the layout: the starter in list, the latest
        // message in gallery. Reconfigure before cards repaint.
        if modeChanged { reconfigureRealizedExcerpts() }
        // Posts replace loading placeholders in one frame: fading one into
        // the other would briefly show two misaligned boards.
        let isFirstPopulation = previousSnapshot == nil || channelChanged || wasShowingPlaceholders
        // A new query or layout swaps the whole board in one cross-fade, with
        // every arriving card drawn for it; cards gliding between the two
        // boards would cross each other.
        let swapsBoard = !isFirstPopulation && (queryChanged || modeChanged)
        if swapsBoard {
            crossFadeBoard()
            // A move or entrance still running from a live update would carry
            // its card across the new board after the fade.
            for card in cards.values {
                card.layer.removeAnimation(forKey: "move")
                card.layer.removeAnimation(forKey: "entrance")
            }
        }
        drawsArrivalsNow = swapsBoard
        defer { drawsArrivalsNow = false }
        if structureChanged || layoutState == nil {
            let transition: ForumBoardTransition = isFirstPopulation || swapsBoard ? .none : .reflow
            relayout(transition: transition, scrollsToTop: queryChanged || channelChanged)
        } else {
            // A new query starts at its first post even when it selects the
            // same cards, as the previous view did.
            if queryChanged {
                cancelExits()
                scrollToTop()
            }
            refreshVisibleCards(transition: .none)
        }
        schedulePresentationRefresh()
    }

    func scrollToTop() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func viewportDidResize() {
        guard let scrollView = enclosingScrollView else { return }
        let width = scrollView.contentView.bounds.width
        guard width > 0, abs(width - lastLayoutWidth) > 0.5 || InterfaceScale.factor != metrics.scale else {
            refreshVisibleCards(transition: .none)
            return
        }
        // An interface size change redraws at once; its fonts differ.
        followsLiveResize = InterfaceScale.factor == metrics.scale
        relayout(transition: .none, scrollsToTop: false)
        followsLiveResize = false
        scheduleResizeSettle()
    }

    /// Once the width has held for a moment, cards reflowed during the change
    /// redraw once more through the usual path (the same layout, so nothing
    /// moves); each keeps its bitmap until the new one lands.
    private func scheduleResizeSettle() {
        resizeSettleTask?.cancel()
        resizeSettleTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(80))) != nil, let self else { return }
            let ids = liveResizedIDs
            liveResizedIDs.removeAll()
            for id in ids {
                cards[id]?.render(scale: backingScale, fading: false)
            }
        }
    }

    @objc func clipViewBoundsDidChange(_: Notification) {
        refreshVisibleCards(transition: .none)
        updateHoverFromCurrentPointer()
        requestNextPageIfNeeded()
    }

    private func relayout(transition: ForumBoardTransition, scrollsToTop: Bool) {
        guard let scrollView = enclosingScrollView else { return }
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        if metrics.scale != InterfaceScale.factor {
            metrics = ForumBoardMetrics.current()
            titleCounter = ForumTitleLineCounter(font: metrics.titleFont, maximumLines: metrics.maximumTitleLines)
            regions.removeAll()
            // Excerpt fonts and emoji sizes follow the interface size.
            reconfigureRealizedExcerpts()
        }
        let anchor = transition == .none && !scrollsToTop ? scrollAnchor() : nil
        let counter = titleCounter
        let signpost = AppPerformanceSignposts.signposter.beginInterval("ForumBoardLayout")
        let newLayout = ForumBoardLayout.make(
            items: items,
            mode: snapshot?.mode ?? .list,
            width: width,
            metrics: metrics,
            titleLines: { counter.lines($0, width: $1) }
        )
        AppPerformanceSignposts.signposter.endInterval("ForumBoardLayout", signpost)
        let widthChanged = abs(width - lastLayoutWidth) > 0.5
        lastLayoutWidth = width
        layoutState = newLayout
        if widthChanged { regions.removeAll() }
        let height = max(newLayout.contentHeight, scrollView.contentView.bounds.height - scrollView.contentInsets.top)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameSize(NSSize(width: width, height: height))
        cardsLayer.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        CATransaction.commit()
        if scrollsToTop {
            scrollToTop()
        } else if let anchor {
            restore(anchor)
        }
        if transition != .reflow { cancelExits() }
        // Geometry changed under the same cards: rebuild settled state too.
        realizedRange = nil
        refreshVisibleCards(transition: transition)
        window?.invalidateCursorRects(for: self)
        // A page that leaves the end of the board on screen asks for the next.
        requestNextPageIfNeeded()
    }

    private struct ScrollAnchor {
        let id: ForumBoardItem.Identifier
        let offset: CGFloat
    }

    private func scrollAnchor() -> ScrollAnchor? {
        guard let layoutState else { return nil }
        let visible = visibleRect
        guard visible.minY > 1,
              let entry = layoutState.entries(intersecting: visible).first(where: { $0.frame.maxY > visible.minY })
        else { return nil }
        return ScrollAnchor(id: entry.item.id, offset: entry.frame.minY - visible.minY)
    }

    private func restore(_ anchor: ScrollAnchor) {
        guard let scrollView = enclosingScrollView, let entry = layoutState?.entry(for: anchor.id) else { return }
        let maximum = max(-scrollView.contentInsets.top, frame.height - scrollView.contentView.bounds.height)
        let targetY = min(max(-scrollView.contentInsets.top, entry.frame.minY - anchor.offset), maximum)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Visible cards

    /// The visible rect plus overscan, so cards are painted before they scroll in.
    func realizationRect(for visible: CGRect) -> CGRect {
        let overscan = max(InterfaceScale.metric(360), visible.height * 0.6)
        return visible.insetBy(dx: 0, dy: -overscan)
    }

    private func refreshVisibleCards(transition: ForumBoardTransition) {
        guard let layoutState else { return }
        let visible = visibleRect
        let realized = layoutState.entries(intersecting: realizationRect(for: visible))
        // Scrolling within the same entries changes nothing.
        guard transition != .none || realized.indices != realizedRange else { return }
        realizedRange = realized.indices
        let liveIDs = Set(realized.map(\.item.id))
        // A post taking a placeholder's place appears there at once, so a
        // skeleton never shows beneath arriving content.
        let replacedPlaceholderFrames = cards.compactMap { id, card -> CGRect? in
            guard case .placeholder = id, !liveIDs.contains(id) else { return nil }
            return card.frame
        }
        var realizedNewPost = false
        let group = ForumBoardRevealGroup()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in realized {
            let entersAnimated = !replacedPlaceholderFrames.contains { $0.intersects(entry.frame) }
            let realization = Realization(
                animates: entersAnimated && transition == .reflow,
                visible: visible,
                group: group
            )
            if realize(entry, realization) {
                realizedNewPost = true
            }
        }
        retireCards(notIn: liveIDs, fades: transition == .reflow, visible: visible, group: group)
        CATransaction.commit()
        begin(group)
        drawArrivals(of: group)
        let livePostIDs = Set(liveIDs.compactMap { if case let .post(id) = $0 { id } else { nil } })
        for id in excerptRenderers.keys where !livePostIDs.contains(id) {
            excerptRenderers[id]?.stopObservingReveals()
            excerptRenderers[id] = nil
        }
        reportStability()
        refreshMedia()
        if realizedNewPost { needsObservationRefresh = true }
        scheduleSettledWork()
    }

    private struct Realization {
        /// Moves and entrances play for a live reflow.
        let animates: Bool
        let visible: CGRect
        /// Collects new cards, which stay hidden until their bitmaps land.
        let group: ForumBoardRevealGroup
    }

    /// Brings one entry's card in line with the layout, creating it if
    /// needed. Returns whether its post content was resolved.
    private func realize(
        _ entry: ForumBoardLayout.Entry,
        _ realization: Realization
    ) -> Bool {
        let animates = realization.animates
        let visible = realization.visible
        let isVisible = entry.frame.intersects(visible)
        let id = entry.item.id
        var resolved = false
        if case let .post(postID) = id {
            resolved = resolveContent(for: postID, isNewCard: cards[id] == nil)
        }
        if let card = cards[id] {
            if resolved { card.render(scale: backingScale, fading: false) }
            let oldFrame = card.frame
            // Scrolling leaves realized cards untouched.
            guard oldFrame != entry.frame || animates else { return resolved }
            configure(card, entry: entry, isVisible: isVisible)
            if animates, oldFrame != entry.frame, oldFrame.intersects(visible) || isVisible {
                animateMove(card, from: oldFrame)
            }
        } else {
            let card = dequeueCard()
            cards[id] = card
            card.layer.isHidden = true
            configure(card, entry: entry, isVisible: isVisible)
            cardsLayer.addSublayer(card.layer)
            // A card arriving off screen just appears once its bitmap lands.
            if isVisible {
                var entrance = ForumBoardRevealGroup.Entrance.none
                if animates {
                    entrance = .animated
                } else if case .placeholder = entry.item {
                    entrance = .placeholder
                }
                realization.group.add(card, entrance: entrance)
            }
        }
        return resolved
    }

    /// Removes cards that left the board. Only a live removal fades; a new
    /// query or arriving posts replace them in one frame, once the incoming
    /// cards' bitmaps are ready, so outgoing and incoming cards never
    /// overlap and no gap shows between them.
    private func retireCards(
        notIn liveIDs: Set<ForumBoardItem.Identifier>,
        fades: Bool,
        visible: CGRect,
        group: ForumBoardRevealGroup
    ) {
        for (id, card) in cards where !liveIDs.contains(id) {
            cards[id] = nil
            regions[id] = nil
            interactions[id] = nil
            paintedRelativeTimes[id] = nil
            let isPlaceholder = if case .placeholder = id { true } else { false }
            let isOnScreen = !card.layer.isHidden && card.frame.intersects(visible)
            if fades, !isPlaceholder, isOnScreen {
                animateExit(card)
            } else if isOnScreen, holds(card.frame, until: group) {
                group.keepUntilRevealed(card)
            } else {
                recycle(card, replacedBy: group)
            }
        }
    }

    /// Whether a card already on screen now occupies `frame`; a replaced
    /// card there would overlap it while waiting.
    func isCoveredByShownCard(_ frame: CGRect) -> Bool {
        cards.values.contains { !$0.layer.isHidden && $0.frame.intersects(frame) }
    }

    /// Tooltips, accessibility proxies and observation of newly realized
    /// cards wait until scrolling pauses; cards are already painted, so
    /// this keeps per-frame work to realizing and positioning layers.
    private func scheduleSettledWork() {
        settledWorkTask?.cancel()
        let assistiveTechnology = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        if assistiveTechnology { updateAccessibilityChildren() }
        settledWorkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            rebuildToolTips()
            if !assistiveTechnology { updateAccessibilityChildren() }
            window?.invalidateCursorRects(for: self)
            if needsObservationRefresh {
                needsObservationRefresh = false
                schedulePresentationRefresh()
            }
        }
    }

    private func dequeueCard() -> ForumBoardCard {
        if let card = reusableCards.popLast() {
            card.layer.removeAllAnimations()
            card.layer.opacity = 1
            card.layer.transform = CATransform3DIdentity
            return card
        }
        return ForumBoardCard()
    }

    func recycle(_ card: ForumBoardCard) {
        leaveRevealGroup(card)
        card.layer.removeFromSuperlayer()
        card.clearContent()
        card.updateShimmer(frames: [], color: .clear, animates: false)
        if reusableCards.count < 24 { reusableCards.append(card) }
    }

    private func configure(_ card: ForumBoardCard, entry: ForumBoardLayout.Entry, isVisible: Bool) {
        let id = entry.item.id
        let kind: ForumBoardCard.Kind =
            switch entry.item {
            case .post: .card
            case .placeholder: .placeholder
            case .olderPostsHeader: .sectionHeader
            case .paginationStatus: .paginationStatus
            }
        let sizeChanged = card.frame.size != entry.frame.size || card.kind != kind
        card.configure(kind: kind, cornerRadius: metrics.cardCornerRadius)
        card.frame = entry.frame
        card.sceneBuilder = { [weak self] size, scale in
            self?.scene(id: id, size: size, scale: scale) ?? .empty(size: size, scale: scale)
        }
        card.didCommit = { [weak self, weak card] in
            guard let self, let card else { return }
            cardDidCommit(card, id: id)
        }
        if sizeChanged || !card.hasContent && !card.isRendering {
            regions[id] = nil
            if sizeChanged, card.hasContent, followsLiveResize {
                // A width change in progress reflows off the main thread;
                // a worker-drawn excerpt redraws once more when it settles.
                if case let .post(postID) = id, excerptRenderers[postID]?.supportsWorkerText == true {
                    liveResizedIDs.insert(id)
                }
                laysOutExcerptsOffMain = true
                card.render(scale: backingScale, fading: false)
                laysOutExcerptsOffMain = false
            } else {
                // A resized card on screen redraws at once: its old bitmap
                // would not fit its new frame. Off screen, it redraws in the
                // background. A card arriving during a board swap is drawn for
                // the cross-fade.
                card.render(scale: backingScale, fading: false, synchronously: (card.hasContent || drawsArrivalsNow) && isVisible)
            }
        }
        applyChrome(card, id: id, animated: false)
        refreshShimmer(card, id: id)
    }

    func applyChrome(_ card: ForumBoardCard, id: ForumBoardItem.Identifier, animated: Bool) {
        let postID: ChannelID? = if case let .post(value) = id { value } else { nil }
        card.applyChrome(
            isHovered: hoveredID == id || keyboardID == id,
            isKeyboardFocused: keyboardID == id,
            isPressed: pressedID == id,
            isSelected: postID != nil && postID == model?.openThread?.id,
            appearance: effectiveAppearance,
            animated: animated
        )
    }

    func refreshShimmer(_ card: ForumBoardCard, id: ForumBoardItem.Identifier) {
        let frames = cardRegions(for: id)?.skeletonFrames ?? []
        var color = NSColor.white
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = ForumCardPainter.skeletonFill
        }
        card.updateShimmer(
            frames: frames,
            color: color,
            animates: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && window?.occlusionState.contains(.visible) != false
        )
    }

    func repaintVisibleCards(fading: Bool, synchronously: Bool = false) {
        for (id, card) in cards {
            regions[id] = nil
            card.render(scale: backingScale, fading: fading, synchronously: synchronously)
        }
        rebuildToolTips()
    }

    // MARK: Stability probe

    /// Reports realized cards' on-screen sizes to the DEBUG layout-stability
    /// probe, which counts any card that resizes after first appearing.
    private func reportStability() {
        #if DEBUG
        guard let width = layoutState?.width else { return }
        for (id, card) in cards {
            guard case let .post(postID) = id else { continue }
            ForumLayoutStabilityProbe.shared.record(postID: postID, size: card.frame.size, containerWidth: width)
        }
        #endif
    }
}

enum ForumBoardTransition: Equatable {
    /// Width, scale, first population, or a board swap under a cross-fade:
    /// no per-card motion.
    case none
    /// Live inserts, removals and reorders.
    case reflow
}
