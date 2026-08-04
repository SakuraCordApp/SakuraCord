import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

/// A viewless, virtualized message surface. One AppKit view owns the entire
/// timeline; only rows intersecting the dirty rectangle are painted.
@MainActor
final class NativeTimelineCanvasView: NSView {
    struct CachedRowBitmap {
        let item: NativeMessageTimelineItem
        let width: CGFloat
        let appearanceName: NSAppearance.Name
        let image: NSImage
        let cost: Int
        let mediaPinOwner: UUID
    }

    struct ReactionPointerHit {
        let target: NativeTimelineReactionPointerTarget
        let rowIndex: Int
        let message: Message
        let reaction: Reaction?
        let frame: CGRect
    }

    struct ReactionCountKey: Hashable {
        let messageID: MessageID
        let reactionID: String
    }

    struct ReactionPreviewLoadKey: Hashable {
        let messageID: MessageID
        let reactionID: String
    }

    struct ActiveReactionCountAnimation {
        let from: Int
        let to: Int
    }

    struct ReactionCountSnapshot {
        let counts: [ReactionCountKey: Int]
        let messageIDs: Set<MessageID>
    }

    struct InlineVideoOverlayKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let embedID: String
        let url: URL
    }

    struct LottieStickerOverlayKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let stickerID: String
        let url: URL
    }

    enum AnimatedMediaOverlayRole: Hashable {
        case authorAvatar
        case authorAvatarDecoration
        case replyAvatar
        case invocationAvatar
        case reactionAvatar(String, Int)
        case linkedImage(Int)
        case attachment(String)
        case messageEmoji(Int)
        case embedImage(String, Int)
        case embedMedia(String)
        case embedEmoji(String, Int, Int)
        case componentImage(Int, String)
        case componentMedia(Int, String)
        case componentEmoji(Int, Int, Int)
        case componentButton(Int, String)
        case sticker(String)
        case reaction(String)
    }

    struct AnimatedMediaOverlayKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let role: AnimatedMediaOverlayRole
        let media: NativeTimelineMediaKey
    }

    struct TextCaretCandidate {
        let itemIdentifier: NativeMessageTimelineItem.Identifier
        let region: NativeTimelineTextRegion
        let rowIndex: Int
        let caret: Int
        let value: NSAttributedString
    }

    struct SelectableTextRegion {
        let region: NativeTimelineTextRegion
        let frame: CGRect
        let interactionFrame: CGRect
        let value: NSAttributedString
        let framesetter: CTFramesetter
    }

    struct MentionPointerRegion {
        let region: NativeTimelineTextRegion
        let characterIndex: Int
        let rawToken: String
        let frame: CGRect
    }

    struct TextPointerHit {
        let hit: NativeTimelineTextHit
        let region: NativeTimelineTextRegion
    }

    struct ComponentButtonPointerHit {
        let target: NativeTimelineComponentButtonTarget
        let rowIndex: Int
        let message: Message
        let region: NativeTimelineComponentLayout.ButtonRegion
        let frame: CGRect
    }

    static let bitmapCostLimit =
        NativeTimelineMediaMemoryPolicy.rowBitmapBytes
    static let prewarmRowLimit = 8
    var storage = NativeTimelineCanvasStorage()
    var baseContentOriginY: CGFloat = 0
    var contentOriginY: CGFloat = 0
    var historySkeleton:
        TimelineHistorySkeletonPresentation?
    var historySkeletonShimmerTask: Task<Void, Never>?
    var minimumHeight: CGFloat = 1
    var bottomSpacerHeight: CGFloat = 0
    var maximumDrawDuration = 0.0
    var maximumRowRasterDuration = 0.0
    var maximumRowRasterHeight: CGFloat = 0
    var contentOriginInvalidationCount = 0
    var synchronousShortContentRedrawCount = 0
    var bitmapCache:
        [NativeMessageTimelineItem.Identifier: CachedRowBitmap] = [:]
    var bitmapInsertionOrder: [NativeMessageTimelineItem.Identifier] = []
    var bitmapEvictionIndex = 0
    var bitmapCost = 0
    let visibleMediaPinOwner = UUID()
    var presentationCacheInvalidationCount = 0
    var mentionPointerRegionCache:
        [NativeMessageTimelineItem.Identifier: [MentionPointerRegion]] = [:]
    var codeBlockPointerRegionCache:
        [NativeMessageTimelineItem.Identifier:
            [NativeTimelineCodeBlockPointerTarget]] = [:]

    var items: [NativeMessageTimelineItem] { storage.items }
    var layouts: [NativeTimelineRowLayout] { storage.layouts }
    var rowOrigins: [CGFloat] { storage.rowOrigins }
    var contentHeight: CGFloat { storage.contentHeight }

    var model: AppModel?
    var presentedConversationID: ChannelID?
    var actions: NativeTimelineRowActions?
    var onWidthChange: ((CGFloat) -> Void)?
    var usesViewportSizedBacking = false
    var onDocumentSizeChange: ((NSSize) -> Void)?

    let pointer = NativeTimelinePointerState()
    let beginningSelectionOverlay =
        NativeTimelineBeginningSelectionOverlay()
    var spoilerRevealStore = NativeTimelineSpoilerRevealStore()
    var spoilerRevealObserverID: UUID?
    var actionCapsuleHost: NSHostingView<AnyView>?
    var actionCapsuleState: NativeTimelineActionCapsuleState?
    var actionCapsuleMessageID: MessageID?
    var actionCapsuleSize: NSSize?
    let editing = NativeTimelineEditingSession()
    var messageProfilePopover: NSPopover?
    var componentChoicePopover: NSPopover?
    let mentionPopoverCoordinator =
        StableAnchoredPopoverPresenter<AnyView>.Coordinator()
    var activeMentionPopoverAnchor: StablePopoverAnchor?
    let accessibilityProxies =
        NativeTimelineAccessibilityProxyStore<
            NativeMessageTimelineItem.Identifier,
            NativeMessageTimelineItem
        >()
    let reactionPickerSource = StableReactionPickerSourceView()
    let reactionPickerCoordinator =
        StableReactionPickerPresenter<EmojiPickerView>.Coordinator()
    let reactionHoverCoordinator =
        StableAnchoredPopoverPresenter<MessageReactionTooltip>.Coordinator()
    var visibleReactionCounts: [ReactionCountKey: Int] = [:]
    var previouslyVisibleReactionMessageIDs: Set<MessageID> = []
    var activeReactionCountAnimations:
        [ReactionCountKey: ActiveReactionCountAnimation] = [:]
    var reactionCountAnimationHosts:
        [ReactionCountKey: NativeTimelineReactionCountAnimationHost] = [:]
    var reactionCountAnimationTasks:
        [ReactionCountKey: Task<Void, Never>] = [:]
    var reactionCountBaselineTask: Task<Void, Never>?
    var pendingReactionCountSnapshot: ReactionCountSnapshot?
    var hasCapturedVisibleReactionCounts = false
    var visibleReactionPreviewLoadKeys:
        Set<ReactionPreviewLoadKey> = []
    var reactionPreviewLoadTasks:
        [ReactionPreviewLoadKey: Task<Void, Never>] = [:]
    var animatedMediaRows:
        [NativeMessageTimelineItem.Identifier: Set<NativeTimelineMediaKey>] = [:]
    var inlineVideoRows:
        [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
    var lottieStickerRows:
        [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
    var inlineVideoOverlays:
        [InlineVideoOverlayKey: NativeTimelineInlineVideoOverlay] = [:]
    var lottieStickerOverlays:
        [LottieStickerOverlayKey: NativeTimelineLottieStickerOverlay] = [:]
    var animatedMediaOverlays:
        [AnimatedMediaOverlayKey: NativeTimelineAnimatedMediaOverlay] = [:]
    var loadingIndicators:
        [NativeMessageTimelineItem.Identifier:
            NativeTimelineLoadingIndicator] = [:]
    var spoilerOverlays:
        [NativeTimelineComponentRevealKey:
            NativeTimelineSpoilerOverlayHost] = [:]
    var spoilerOverlayPresentations:
        [NativeTimelineComponentRevealKey:
            NativeTimelineSpoilerOverlayPresentation] = [:]
    var animatedMediaReconcileTask: Task<Void, Never>?
    var mediaInvalidationTask: Task<Void, Never>?
    var pendingMediaInvalidations:
        Set<NativeMessageTimelineItem.Identifier> = []
    lazy var mediaViewerHost = NSHostingView(
        rootView: AnyView(Color.clear.frame(width: 0, height: 0))
    )

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func drawSuperclassContent(in dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
        wantsLayer = true
        // The document height changes whenever history is prepended or live
        // messages arrive. AppKit's normal drawRect-backed policy redraws a
        // layer-backed view merely because its frame resized, turning each
        // pagination page into a large Core Animation display transaction.
        // Timeline updates already invalidate the exact affected rows (or the
        // visible viewport when coordinates move), so size changes themselves
        // must preserve the existing backing contents.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        // Pointer-driven state must paint in the same display pass as the
        // mouse event. Async layer drawing visibly leaves the previous row's
        // hover behind even though hit testing has already moved on.
        layer?.drawsAsynchronously = false
        beginningSelectionOverlay.imageAlignment = .alignTopLeft
        beginningSelectionOverlay.imageScaling = .scaleNone
        beginningSelectionOverlay.isHidden = true
        addSubview(beginningSelectionOverlay)
        addSubview(reactionPickerSource)
        mediaViewerHost.frame = .zero
        addSubview(mediaViewerHost)
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(mediaPlaybackVisibilityDidChange(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(mediaPlaybackVisibilityDidChange(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(mediaPlaybackVisibilityDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reconcileBeginningSelectionOverlay()
    }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)
            mediaInvalidationTask?.cancel()
            historySkeletonShimmerTask?.cancel()
            cancelReactionPreviewLoads()
            NativeTimelineMediaStore.shared.removeStaticRequests(
                owner: visibleMediaPinOwner
            )
            NativeTimelineMediaStore.shared.releaseVisibleImages(
                owner: visibleMediaPinOwner
            )
            NativeTimelineMediaStore.shared.releasePinnedImages(
                owner: visibleMediaPinOwner
            )
            NativeTimelineMediaStore.shared.cancelAnimatedRequests(
                owner: visibleMediaPinOwner
            )
            if let spoilerRevealObserverID {
                spoilerRevealStore.removeObserver(spoilerRevealObserverID)
            }
        }
    }
}

@MainActor
enum NativeTimelineRowPainter {
    static func selectionOverlayImage(
        _ box: NativeTimelineAttributedTextBox,
        size: CGSize,
        selectionRange: NSRange
    ) -> NSImage {
        NSImage(size: size, flipped: true) { frame in
            attributedText(
                box,
                in: frame,
                model: nil,
                selectionRange: selectionRange
            )
            return true
        }
    }

    static func draw(
        item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout,
        in rowFrame: CGRect,
        model: AppModel?,
        isHovered: Bool,
        showsCompactTimestamp: Bool = false,
        hoveredMention: NativeTimelineMentionHover? = nil,
        hoveredTextLink: NativeTimelineTextLinkHover? = nil,
        hoveredTextSpoiler: NativeTimelineTextSpoilerHover? = nil,
        hoveredComponentButton:
            NativeTimelineComponentButtonTarget? = nil,
        pressedComponentButton:
            NativeTimelineComponentButtonTarget? = nil,
        componentButtonPressProgress: CGFloat = 0,
        hidesMessageContent: Bool = false,
        hoveredReactionID: String? = nil,
        isAddReactionHovered: Bool = false,
        textSelection: NativeTimelineTextSelection? = nil,
        revealedTextSpoilerState:
            NativeTimelineTextSpoilerRevealState = .init(),
        spoilerRevealStore: NativeTimelineSpoilerRevealStore? = nil,
        reactionCountTransitions:
            [String: NativeTimelineReactionCountTransition] = [:]
    ) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rowFrame.minX, yBy: rowFrame.minY)
        transform.concat()
        let bounds = CGRect(origin: .zero, size: rowFrame.size)

        if case let .message(row, _, _) = item,
           let highlightFrame = layout.highlightFrame
        {
            let currentUserID = model?.snapshot?.currentUser.id
            let currentUserRoleIDs =
                model?.currentUserRoleIDs(
                    for: row.message.guildID
                ) ?? []
            switch MessageRowPersistentHighlight.resolve(
                message: row.message,
                currentUserID: currentUserID,
                currentUserRoleIDs: currentUserRoleIDs
            ) {
            case .none:
                break
            case .ephemeral:
                NSColor(
                    srgbRed: 88 / 255,
                    green: 101 / 255,
                    blue: 242 / 255,
                    alpha: 0.10
                ).setFill()
                highlightFrame.fill()
            case .mention:
                NSColor(
                    srgbRed: 240 / 255,
                    green: 178 / 255,
                    blue: 50 / 255,
                    alpha: 0.12
                ).setFill()
                highlightFrame.fill()
            }
        }
        if isHovered, let highlightFrame = layout.highlightFrame {
            NSColor.labelColor.withAlphaComponent(0.055).setFill()
            highlightFrame.fill()
        }
        switch item {
        case let .beginning(beginning):
            drawBeginning(
                beginning,
                layout: layout,
                textSelection: textSelection
            )
        case let .loader(isLoading, kind):
            drawLoader(
                isLoading: isLoading,
                kind: kind,
                layout: layout
            )
        case let .message(row, _, isHighlighted):
            drawMessage(.init(
                row: row,
                layout: layout,
                bounds: bounds,
                model: model,
                highlighted: isHighlighted,
                isHovered: isHovered,
                showsCompactTimestamp: showsCompactTimestamp,
                hoveredMention: hoveredMention,
                hoveredTextLink: hoveredTextLink,
                hoveredTextSpoiler: hoveredTextSpoiler,
                hoveredComponentButton: hoveredComponentButton,
                pressedComponentButton: pressedComponentButton,
                componentButtonPressProgress:
                    componentButtonPressProgress,
                hidesMessageContent: hidesMessageContent,
                hoveredReactionID: hoveredReactionID,
                isAddReactionHovered: isAddReactionHovered,
                textSelection: textSelection,
                revealedTextSpoilerState:
                    revealedTextSpoilerState,
                spoilerRevealStore: spoilerRevealStore,
                reactionCountTransitions: reactionCountTransitions
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawBeginning(
        _ beginning: NativeTimelineBeginning,
        layout rowLayout: NativeTimelineRowLayout,
        textSelection: NativeTimelineTextSelection?
    ) {
        guard let layout = rowLayout.beginningLayout else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: layout.iconFrame).fill()
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 34,
            weight: .semibold
        ).applying(
            NSImage.SymbolConfiguration(
                // AppKit applies a configured palette color's alpha again
                // while rasterizing this hierarchical symbol. The square
                // root preserves SwiftUI's 55% secondary foreground result.
                paletteColors: [
                    NSColor.labelColor.withAlphaComponent(0.74)
                ]
            )
        )
        if let image = NSImage(
            systemSymbolName: beginning.symbolName,
            accessibilityDescription: beginning.title
        )?.withSymbolConfiguration(symbolConfiguration) {
            let imageSize = image.size
            let imageFrame = CGRect(
                x: layout.iconFrame.midX - imageSize.width / 2,
                y: layout.iconFrame.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            image.draw(in: imageFrame)
        }
        let selectedRegion =
            textSelection?.itemIdentifier == .beginning(beginning.id)
                ? textSelection?.region
                : nil
        if selectedRegion == .beginningTitle,
           let selectionRange = textSelection?.range
        {
            attributedText(
                NativeTimelineBeginningText.title(beginning),
                in: layout.titleFrame,
                model: nil,
                selectionRange: selectionRange
            )
        } else {
            text(
                beginning.title,
                in: layout.titleFrame,
                font: .systemFont(
                    ofSize: NSFont.preferredFont(
                        forTextStyle: .largeTitle
                    ).pointSize,
                    weight: .bold
                ),
                color: .labelColor,
                lineBreakMode: .byWordWrapping
            )
        }
        if selectedRegion == .beginningDescription,
           let selectionRange = textSelection?.range
        {
            attributedText(
                NativeTimelineBeginningText.description(beginning),
                in: layout.descriptionFrame,
                model: nil,
                selectionRange: selectionRange
            )
        } else {
            text(
                beginning.description,
                in: layout.descriptionFrame,
                font: .preferredFont(forTextStyle: .body),
                color: .secondaryLabelColor,
                lineBreakMode: .byWordWrapping
            )
        }
        if let date = beginning.startedAt,
           let frame = layout.dateSeparatorFrame
        {
            dateSeparator(date: date, frame: frame)
        }
    }

    static func drawLoader(
        isLoading: Bool,
        kind: NativeTimelineLoaderKind,
        layout: NativeTimelineRowLayout
    ) {
        guard isLoading,
              let loaderLayout = layout.loaderLayout
        else { return }
        text(
            kind.loadingLabel,
            in: loaderLayout.labelFrame,
            font: .preferredFont(forTextStyle: .caption1),
            color: .secondaryLabelColor,
            alignment: .center
        )
    }

}
