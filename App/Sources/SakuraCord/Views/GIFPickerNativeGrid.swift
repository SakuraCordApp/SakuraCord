import AppKit
import AVFoundation
import Foundation
import SakuraCordModels
import SwiftUI

nonisolated struct GIFMasonryGeometry: Equatable {
    let itemFrames: [CGRect]
    let contentSize: CGSize
}

nonisolated enum GIFPickerHoverPolicy {
    static func isHovered(
        pointer: CGPoint,
        bounds: CGRect,
        visibleRect: CGRect
    ) -> Bool {
        bounds.contains(pointer)
            && !visibleRect.isEmpty
            && visibleRect.contains(pointer)
    }
}

nonisolated struct GIFPickerVideoFallbackMemory {
    private let maximumCount: Int
    private var failedURLs: Set<URL> = []
    private var insertionOrder: [URL] = []

    init(maximumCount: Int = 128) {
        self.maximumCount = max(1, maximumCount)
    }

    func contains(_ url: URL) -> Bool {
        failedURLs.contains(url)
    }

    mutating func insert(_ url: URL) {
        guard failedURLs.insert(url).inserted else { return }
        insertionOrder.append(url)
        while insertionOrder.count > maximumCount {
            failedURLs.remove(insertionOrder.removeFirst())
        }
    }
}

nonisolated extension GIFMasonryLayout {
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 10

    static func geometry(
        for results: [GIFSearchResult],
        columnWidth: CGFloat
    ) -> GIFMasonryGeometry {
        let columns = columns(for: results, columnWidth: columnWidth)
        var frames = Array(repeating: CGRect.zero, count: results.count)
        let trailingX = horizontalInset + columnWidth + spacing
        let leadingHeight = place(
            columns.leading,
            originX: horizontalInset,
            columnWidth: columnWidth,
            frames: &frames
        )
        let trailingHeight = place(
            columns.trailing,
            originX: trailingX,
            columnWidth: columnWidth,
            frames: &frames
        )
        let width = horizontalInset * 2 + columnWidth * 2 + spacing
        let height = max(leadingHeight, trailingHeight) + verticalInset
        return GIFMasonryGeometry(
            itemFrames: frames,
            contentSize: CGSize(width: width, height: max(1, height))
        )
    }

    private static func place(
        _ items: [GIFMasonryItem],
        originX: CGFloat,
        columnWidth: CGFloat,
        frames: inout [CGRect]
    ) -> CGFloat {
        var originY = verticalInset
        for item in items {
            guard frames.indices.contains(item.ordinal) else { continue }
            frames[item.ordinal] = CGRect(
                x: originX,
                y: originY,
                width: columnWidth,
                height: item.height
            )
            originY += item.height + spacing
        }
        return max(verticalInset, originY - spacing)
    }
}

struct GIFPickerNativeGrid: NSViewRepresentable {
    let results: [GIFSearchResult]
    let columnWidth: CGFloat
    let favorites: Set<URL>
    let mutatingURL: URL?
    let choose: (GIFSearchResult) -> Void
    let toggleFavorite: (GIFSearchResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self, scrollView: scrollView)
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.stop()
        scrollView.documentView = nil
    }

    typealias Coordinator = GIFPickerNativeGridCoordinator
}

@MainActor
final class GIFPickerNativeGridCoordinator: NSObject,
    NSCollectionViewDataSource
{
    private static let itemIdentifier = NSUserInterfaceItemIdentifier(
        "GIFPickerNativeCell"
    )

    private var parent: GIFPickerNativeGrid
    private let layout = GIFMasonryCollectionLayout()
    private weak var collectionView: NSCollectionView?

    init(parent: GIFPickerNativeGrid) {
        self.parent = parent
    }

    func makeScrollView() -> NSScrollView {
        let collectionView = GIFPickerCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            GIFPickerCollectionViewItem.self,
            forItemWithIdentifier: Self.itemIdentifier
        )
        collectionView.chooseAtIndex = { [weak self] index in
            guard let self,
                  self.parent.results.indices.contains(index)
            else { return }
            self.parent.choose(self.parent.results[index])
        }
        collectionView.toggleFavoriteAtIndex = { [weak self] index in
            guard let self,
                  self.parent.results.indices.contains(index)
            else { return }
            self.parent.toggleFavorite(self.parent.results[index])
        }

        let scrollView = GIFPickerGridScrollView()
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        self.collectionView = collectionView
        update(parent: parent, scrollView: scrollView)
        return scrollView
    }

    func update(parent: GIFPickerNativeGrid, scrollView: NSScrollView) {
        guard let collectionView else { return }
        let resultsChanged = self.parent.results != parent.results
        let widthChanged = abs(self.parent.columnWidth - parent.columnWidth) > 0.5
        self.parent = parent
        layout.update(
            results: parent.results,
            columnWidth: parent.columnWidth
        )
        if resultsChanged {
            collectionView.reloadData()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if widthChanged {
            layout.invalidateLayout()
        }
        refreshVisibleItems()
    }

    func stop() {
        if let collectionView = collectionView as? GIFPickerCollectionView {
            collectionView.chooseAtIndex = nil
            collectionView.toggleFavoriteAtIndex = nil
        }
        collectionView?.dataSource = nil
        collectionView = nil
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        parent.results.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: Self.itemIdentifier,
            for: indexPath
        )
        configure(item, at: indexPath.item)
        return item
    }

    private func refreshVisibleItems() {
        guard let collectionView else { return }
        for item in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item) else {
                continue
            }
            configure(item, at: indexPath.item)
        }
    }

    private func configure(_ item: NSCollectionViewItem, at index: Int) {
        guard parent.results.indices.contains(index),
              let item = item as? GIFPickerCollectionViewItem
        else { return }
        let gif = parent.results[index]
        item.configure(
            gif: gif,
            isFavorite: parent.favorites.contains(gif.url),
            isMutatingFavorite: parent.mutatingURL == gif.url,
            choose: { [weak self] in self?.parent.choose(gif) },
            toggleFavorite: { [weak self] in
                self?.parent.toggleFavorite(gif)
            }
        )
    }
}

@MainActor
private final class GIFPickerCollectionView: NSCollectionView {
    private enum Action: Equatable {
        case choose
        case favorite
    }

    private struct PressTarget: Equatable {
        let index: Int
        let action: Action
    }

    var chooseAtIndex: ((Int) -> Void)?
    var toggleFavoriteAtIndex: ((Int) -> Void)?
    private var pressedTarget: PressTarget?

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        pressedTarget = pressTarget(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedTarget else { return }
        let point = convert(event.locationInWindow, from: nil)
        if pressTarget(at: point) != pressedTarget {
            self.pressedTarget = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = pressedTarget
        pressedTarget = nil
        guard target == pressTarget(at: point), let target else { return }
        switch target.action {
        case .choose:
            chooseAtIndex?(target.index)
        case .favorite:
            toggleFavoriteAtIndex?(target.index)
        }
    }

    private func pressTarget(at point: CGPoint) -> PressTarget? {
        let probe = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        guard let attribute = collectionViewLayout?
            .layoutAttributesForElements(in: probe)
            .first(where: { $0.frame.contains(point) }),
            let indexPath = attribute.indexPath
        else { return nil }
        let localPoint = CGPoint(
            x: point.x - attribute.frame.minX,
            y: point.y - attribute.frame.minY
        )
        let favoriteFrame = CGRect(
            x: max(0, attribute.frame.width - 35),
            y: 7,
            width: 28,
            height: 28
        )
        return PressTarget(
            index: indexPath.item,
            action: favoriteFrame.contains(localPoint) ? .favorite : .choose
        )
    }
}

@MainActor
private final class GIFMasonryCollectionLayout: NSCollectionViewLayout {
    private var geometry = GIFMasonryGeometry(
        itemFrames: [],
        contentSize: CGSize(width: 1, height: 1)
    )
    private var attributes: [NSCollectionViewLayoutAttributes] = []

    func update(results: [GIFSearchResult], columnWidth: CGFloat) {
        let nextGeometry = GIFMasonryLayout.geometry(
            for: results,
            columnWidth: columnWidth
        )
        guard nextGeometry != geometry else { return }
        geometry = nextGeometry
        attributes = nextGeometry.itemFrames.enumerated().map { index, frame in
            let value = NSCollectionViewLayoutAttributes(
                forItemWith: IndexPath(item: index, section: 0)
            )
            value.frame = frame
            return value
        }
        invalidateLayout()
    }

    override var collectionViewContentSize: NSSize {
        geometry.contentSize
    }

    override func layoutAttributesForElements(
        in rect: NSRect
    ) -> [NSCollectionViewLayoutAttributes] {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }
}

@MainActor
private final class GIFPickerCollectionViewItem: NSCollectionViewItem {
    private var cellView: GIFPickerCollectionCellView? {
        view as? GIFPickerCollectionCellView
    }

    override func loadView() {
        view = GIFPickerCollectionCellView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cellView?.prepareForReuse()
    }

    func configure(
        gif: GIFSearchResult,
        isFavorite: Bool,
        isMutatingFavorite: Bool,
        choose: @escaping () -> Void,
        toggleFavorite: @escaping () -> Void
    ) {
        cellView?.configure(
            gif: gif,
            isFavorite: isFavorite,
            isMutatingFavorite: isMutatingFavorite,
            choose: choose,
            toggleFavorite: toggleFavorite
        )
    }
}

@MainActor
private final class GIFPickerCollectionCellView: NSView {
    private static let maximumPixelDimension = 420
    private let mediaCanvas = AnimatedImageCanvas()
    private let videoCanvas = GIFPickerVideoCanvas()
    private let hoverOverlay = GIFPickerPassthroughView()
    private let favoriteGlass = NSGlassEffectView()
    private let favoriteButton = NSButton()
    private var representedGIFURL: URL?
    private var staticLoadTask: Task<Void, Never>?
    private var animatedLoadTask: Task<Void, Never>?
    private var animatedLoadID: UUID?
    private var choose: (() -> Void)?
    private var toggleFavorite: (() -> Void)?
    private var isHovered = false
    private var isFavorite = false
    private weak var observedClipView: NSClipView?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        addSubview(mediaCanvas)
        videoCanvas.isHidden = true
        addSubview(videoCanvas)

        hoverOverlay.wantsLayer = true
        hoverOverlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hoverOverlay.isHidden = true
        addSubview(hoverOverlay)

        favoriteButton.isBordered = false
        favoriteButton.imagePosition = .imageOnly
        favoriteButton.imageScaling = .scaleProportionallyDown
        favoriteButton.focusRingType = .none
        favoriteButton.autoresizingMask = [.width, .height]
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavoritePressed)
        favoriteGlass.style = .regular
        favoriteGlass.cornerRadius = 14
        favoriteGlass.effectIsInteractive = true
        favoriteGlass.contentView = favoriteButton
        favoriteGlass.isHidden = true
        addSubview(favoriteGlass)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateColorsForEffectiveAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorsForEffectiveAppearance()
        needsDisplay = true
    }

    private func updateColorsForEffectiveAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(0.07).cgColor
        }
    }

    isolated deinit {
        stopObservingViewport()
    }

    override func layout() {
        super.layout()
        mediaCanvas.frame = bounds
        videoCanvas.frame = bounds
        hoverOverlay.frame = bounds
        favoriteGlass.frame = CGRect(
            x: max(0, bounds.width - 35),
            y: 7,
            width: 28,
            height: 28
        )
        favoriteButton.frame = favoriteGlass.bounds
        updateViewportVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColorsForEffectiveAppearance()
        if window == nil {
            stopObservingViewport()
        } else {
            startObservingViewport()
        }
        updateViewportVisibility()
    }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow, .inVisibleRect,
                .mouseEnteredAndExited,
            ],
            owner: self
        ))
        super.updateTrackingAreas()
        synchronizeHoverWithCurrentPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func accessibilityPerformPress() -> Bool {
        choose?()
        return true
    }

    func configure(
        gif: GIFSearchResult,
        isFavorite: Bool,
        isMutatingFavorite: Bool,
        choose: @escaping () -> Void,
        toggleFavorite: @escaping () -> Void
    ) {
        self.choose = choose
        self.toggleFavorite = toggleFavorite
        self.isFavorite = isFavorite
        setAccessibilityLabel(gif.title)
        updateFavoriteButton(isMutating: isMutatingFavorite)

        guard representedGIFURL != gif.url else { return }
        representedGIFURL = gif.url
        cancelLoads()
        mediaCanvas.clear()
        videoCanvas.clear()
        let videoURL = GIFPickerMediaPolicy.nativeVideoURL(for: gif)
        if let videoURL,
           !GIFPickerVideoFallbackRegistry.shared.contains(videoURL)
        {
            startVideoLoad(url: videoURL, gif: gif)
            startStaticLoad(url: GIFPickerMediaPolicy.staticFallbackURL(for: gif))
        } else {
            startStaticLoad(url: GIFPickerMediaPolicy.staticFallbackURL(for: gif))
            startAnimatedLoad(
                urls: GIFPickerMediaPolicy.nativeAnimationURLs(for: gif),
                gifURL: gif.url
            )
        }
        updateViewportVisibility()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedGIFURL = nil
        choose = nil
        toggleFavorite = nil
        cancelLoads()
        mediaCanvas.clear()
        videoCanvas.clear()
        mediaCanvas.setPlaybackSuppressed(true)
        setAccessibilityCustomActions(nil)
        setHovered(false)
    }

    private func startStaticLoad(url: URL?) {
        guard let url else { return }
        staticLoadTask?.cancel()
        let representedGIFURL = representedGIFURL
        staticLoadTask = Task { [weak self] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url,
                maximumPixelDimension: Self.maximumPixelDimension,
                priority: .visible
            )
            guard !Task.isCancelled,
                  let self,
                  self.representedGIFURL == representedGIFURL,
                  self.mediaCanvas.displayedImage == nil
            else { return }
            self.mediaCanvas.displayStatic(image)
        }
    }

    private func startAnimatedLoad(urls: [URL], gifURL: URL) {
        guard !urls.isEmpty else {
            displayUnavailablePlaceholder()
            return
        }
        cancelAnimatedLoad()
        let loadID = UUID()
        animatedLoadID = loadID
        animatedLoadTask = Task { [weak self] in
            defer { self?.finishAnimatedLoad(loadID) }
            for url in urls {
                if let cached = AnimatedRemoteImageDisplayCache.shared.image(
                    for: url,
                    maximumPixelDimension: Self.maximumPixelDimension
                ) {
                    guard !Task.isCancelled,
                          let self,
                          self.representedGIFURL == gifURL
                    else { return }
                    self.display(cached)
                    return
                }
                do {
                    let image = try await SharedAnimatedImageLoader.shared.image(
                        for: url,
                        maximumPixelDimension: Self.maximumPixelDimension
                    )
                    guard !Task.isCancelled,
                          let self,
                          self.representedGIFURL == gifURL
                    else { return }
                    AnimatedRemoteImageDisplayCache.shared.insert(
                        image,
                        for: url,
                        maximumPixelDimension: Self.maximumPixelDimension
                    )
                    self.display(image)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
            guard !Task.isCancelled,
                  let self,
                  self.representedGIFURL == gifURL
            else { return }
            self.displayUnavailablePlaceholder()
        }
    }

    private func startVideoLoad(url: URL, gif: GIFSearchResult) {
        videoCanvas.isHidden = false
        videoCanvas.display(url) { [weak self] in
            guard let self, self.representedGIFURL == gif.url else { return }
            GIFPickerVideoFallbackRegistry.shared.insert(url)
            self.videoCanvas.clear()
            self.startAnimatedLoad(
                urls: GIFPickerMediaPolicy.nativeAnimationURLs(for: gif),
                gifURL: gif.url
            )
        }
    }

    private func display(_ image: DecodedAnimatedImage) {
        videoCanvas.clear()
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceAnimatedMedia")
        mediaCanvas.display(
            image,
            animates: !reducesMotion,
            isLooping: true,
            contentMode: .fit
        )
    }

    private func displayUnavailablePlaceholder() {
        guard mediaCanvas.displayedImage == nil else { return }
        videoCanvas.clear()
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 24,
            weight: .regular
        )
        let symbol = NSImage(
            systemSymbolName: "photo.badge.exclamationmark",
            accessibilityDescription: "GIF unavailable"
        )?.withSymbolConfiguration(configuration)
        mediaCanvas.layer?.contents = symbol
        mediaCanvas.layer?.contentsGravity = .center
    }

    private func cancelLoads() {
        staticLoadTask?.cancel()
        staticLoadTask = nil
        cancelAnimatedLoad()
    }

    private func cancelAnimatedLoad() {
        animatedLoadID = nil
        animatedLoadTask?.cancel()
        animatedLoadTask = nil
    }

    private func finishAnimatedLoad(_ loadID: UUID) {
        guard animatedLoadID == loadID else { return }
        animatedLoadID = nil
        animatedLoadTask = nil
    }

    private func startObservingViewport() {
        let clipView = enclosingScrollView?.contentView
        guard observedClipView !== clipView else { return }
        stopObservingViewport()
        guard let clipView else { return }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    private func stopObservingViewport() {
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = nil
    }

    @objc
    private func viewportBoundsDidChange(_ notification: Notification) {
        updateViewportVisibility()
        synchronizeHoverWithCurrentPointer()
    }

    private func updateViewportVisibility() {
        guard let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView,
              window != nil
        else {
            mediaCanvas.setPlaybackSuppressed(true)
            videoCanvas.setViewportVisible(false)
            return
        }
        let frameInDocument = convert(bounds, to: documentView)
        let isVisible = frameInDocument.intersects(
            scrollView.contentView.documentVisibleRect
        )
        mediaCanvas.setPlaybackSuppressed(!isVisible)
        videoCanvas.setViewportVisible(isVisible)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        hoverOverlay.isHidden = !hovered
        favoriteGlass.isHidden = !hovered
        layer?.borderColor = NSColor.white
            .withAlphaComponent(hovered ? 0.48 : 0.07).cgColor
        layer?.borderWidth = hovered ? 1.5 : 1
    }

    private func synchronizeHoverWithCurrentPointer() {
        guard let window else {
            setHovered(false)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let isInsideVisibleCell = GIFPickerHoverPolicy.isHovered(
            pointer: point,
            bounds: bounds,
            visibleRect: visibleRect
        )
        setHovered(isInsideVisibleCell)
    }

    private func updateFavoriteButton(isMutating: Bool) {
        let symbol = isFavorite ? "star.fill" : "star"
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        favoriteButton.image = image
        favoriteButton.contentTintColor = isFavorite ? .systemYellow : .white
        favoriteButton.isEnabled = !isMutating
        favoriteButton.alphaValue = isMutating ? 0.55 : 1
        favoriteButton.toolTip = isFavorite
            ? "Remove from favourites" : "Add to favourites"
        favoriteButton.setAccessibilityLabel(favoriteButton.toolTip)
        if isMutating {
            setAccessibilityCustomActions(nil)
        } else {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(
                    name: favoriteButton.toolTip ?? "Toggle favourite"
                ) { [weak self] in
                    guard let self else { return false }
                    self.toggleFavorite?()
                    return true
                },
            ])
        }
    }

    @objc
    private func toggleFavoritePressed() {
        toggleFavorite?()
    }
}

nonisolated struct GIFPickerStagedVideo: Sendable {
    let fileURL: URL
    let directory: URL

    nonisolated func discard(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }
}

nonisolated enum GIFPickerVideoTransport {
    static func stage(
        _ url: URL,
        dataLoader: SharedMediaDataLoader = .shared,
        fileManager: FileManager = .default
    ) async throws -> GIFPickerStagedVideo {
        guard let approvedURL = GIFMediaURLPolicy.approved(url) else {
            throw URLError(.unsupportedURL)
        }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SakuraCord", isDirectory: true)
            .appendingPathComponent("GIF Video", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent("video.mp4")
            try await dataLoader.copyRemoteMedia(from: approvedURL, to: fileURL)
            return GIFPickerStagedVideo(fileURL: fileURL, directory: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }
}

@MainActor
private final class GIFPickerVideoFallbackRegistry {
    static let shared = GIFPickerVideoFallbackRegistry()

    private var memory = GIFPickerVideoFallbackMemory()

    func contains(_ url: URL) -> Bool {
        memory.contains(url)
    }

    func insert(_ url: URL) {
        memory.insert(url)
    }
}

@MainActor
private final class GIFPickerVideoCanvas: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var loadTask: Task<Void, Never>?
    private var representedURL: URL?
    private var stagedPlaybackDirectory: URL?
    private var failure: (() -> Void)?
    private var isViewportVisible = false
    private var playbackWatchdogTask: Task<Void, Never>?
    private var stallRecoveryTask: Task<Void, Never>?
    private var didAttemptStallRecovery = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        layer?.addSublayer(playerLayer)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackVisibilityDidChange(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackVisibilityDidChange(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackVisibilityDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        player.pause()
        player.removeAllItems()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPlaybackState()
    }

    func display(_ url: URL, onFailure: @escaping () -> Void) {
        guard representedURL != url else { return }
        clear()
        representedURL = url
        failure = onFailure
        startLoadingIfNeeded()
    }

    func setViewportVisible(_ visible: Bool) {
        guard isViewportVisible != visible else { return }
        isViewportVisible = visible
        if visible {
            startLoadingIfNeeded()
        } else {
            unloadPlayback()
        }
        applyPlaybackState()
    }

    private func startLoadingIfNeeded() {
        guard isViewportVisible,
              loadTask == nil,
              looper == nil,
              let url = representedURL
        else { return }
        loadTask = Task { [weak self] in
            do {
                let staged = try await GIFPickerVideoTransport.stage(url)
                var retainsStagedFile = false
                defer {
                    if !retainsStagedFile {
                        staged.discard()
                    }
                }
                try Task.checkCancellation()
                guard let self, self.representedURL == url else { return }
                self.stagedPlaybackDirectory = staged.directory
                retainsStagedFile = true
                let asset = AVURLAsset(url: staged.fileURL)
                async let playable = asset.load(.isPlayable)
                async let duration = asset.load(.duration)
                guard try await playable,
                      (try await duration).isValid
                else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                guard self.representedURL == url else { return }
                let item = AVPlayerItem(asset: asset)
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(GIFPickerVideoCanvas.playerItemFailed(_:)),
                    name: AVPlayerItem.failedToPlayToEndTimeNotification,
                    object: item
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(GIFPickerVideoCanvas.playerItemStalled(_:)),
                    name: AVPlayerItem.playbackStalledNotification,
                    object: item
                )
                self.looper = AVPlayerLooper(
                    player: self.player,
                    templateItem: item
                )
                self.loadTask = nil
                self.applyPlaybackState()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.representedURL == url else { return }
                self.fail()
            }
        }
    }

    func clear() {
        unloadPlayback()
        representedURL = nil
        failure = nil
        isViewportVisible = false
        isHidden = true
    }

    private func unloadPlayback() {
        loadTask?.cancel()
        loadTask = nil
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        didAttemptStallRecovery = false
        NotificationCenter.default.removeObserver(
            self,
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: AVPlayerItem.playbackStalledNotification,
            object: nil
        )
        player.pause()
        player.removeAllItems()
        looper = nil
        if let stagedPlaybackDirectory {
            try? FileManager.default.removeItem(at: stagedPlaybackDirectory)
            self.stagedPlaybackDirectory = nil
        }
    }

    @objc
    private func playerItemFailed(_ notification: Notification) {
        fail()
    }

    @objc
    private func playerItemStalled(_ notification: Notification) {
        guard !didAttemptStallRecovery else {
            fail()
            return
        }
        didAttemptStallRecovery = true
        player.seek(to: .zero)
        player.play()
        stallRecoveryTask?.cancel()
        stallRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  let self,
                  self.isViewportVisible,
                  self.player.timeControlStatus != .playing
            else { return }
            self.fail()
        }
    }

    @objc
    private func playbackVisibilityDidChange(_ notification: Notification) {
        if let changedWindow = notification.object as? NSWindow,
           changedWindow !== window
        {
            return
        }
        applyPlaybackState()
    }

    private func applyPlaybackState() {
        let shouldPlay = window != nil
            && isViewportVisible
            && NSApp.isActive
            && window?.occlusionState.contains(.visible) == true
        if shouldPlay, looper != nil {
            isHidden = false
            player.play()
            startPlaybackWatchdogIfNeeded()
        } else {
            player.pause()
        }
    }

    private func startPlaybackWatchdogIfNeeded() {
        guard !playerLayer.isReadyForDisplay,
              playbackWatchdogTask == nil
        else { return }
        playbackWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.playbackWatchdogTask = nil
            guard self.isViewportVisible,
                  NSApp.isActive,
                  !self.playerLayer.isReadyForDisplay
            else { return }
            self.fail()
        }
    }

    private func fail() {
        let callback = failure
        clear()
        callback?()
    }
}

@MainActor
private final class GIFPickerPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class GIFPickerGridScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let collectionView = documentView as? NSCollectionView,
              let layout = collectionView.collectionViewLayout
        else { return }
        let layoutSize = layout.collectionViewContentSize
        let size = CGSize(
            width: max(contentSize.width, layoutSize.width),
            height: max(contentSize.height, layoutSize.height)
        )
        guard collectionView.frame.size != size else { return }
        collectionView.frame = CGRect(origin: .zero, size: size)
    }
}
