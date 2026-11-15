import AppKit
import CoreText
import SakuraCordModels
import SwiftUI

/// A viewless, virtualized message surface. One AppKit view owns the entire
/// timeline; only rows intersecting the dirty rectangle are painted.
@MainActor
final class NativeTimelineCanvasView: NSView, WindowModalInputParticipant {
    struct CachedRowBitmap {
        let item: NativeMessageTimelineItem
        let width: CGFloat
        let appearanceName: NSAppearance.Name
        var images: [Int: NSImage]
        var cost: Int
        let mediaPinOwner: UUID
        let missingMediaKeys: Set<MediaImageKey>

        /// Whether the bitmap still pictures `item` at `width` in `appearanceName`.
        func matches(_ item: NativeMessageTimelineItem, width: CGFloat, appearanceName: NSAppearance.Name) -> Bool {
            self.item == item && abs(self.width - width) < 0.5 && self.appearanceName == appearanceName
        }
    }

    struct ReactionPointerHit {
        let target: NativeTimelineReactionPointerTarget
        let rowIndex: Int
        let message: Message
        let reaction: Reaction?
        let frame: CGRect
    }

    struct ReactionPreviewLoadKey: Hashable {
        let messageID: MessageID
        let reactionID: String
        let count: Int
    }

    struct InlineVideoOverlayKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let embedID: String
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
        case pollAnswer(Int)

        var playsOnHover: Bool {
            switch self {
            case .authorAvatar, .authorAvatarDecoration, .replyAvatar, .invocationAvatar, .reactionAvatar:
                true
            default:
                false
            }
        }

        /// Whether the row paints nothing beneath this overlay once it is live.
        var replacesPoster: Bool {
            switch self {
            case .sticker, .reaction, .componentButton, .pollAnswer: true
            default: false
            }
        }
    }

    struct AnimatedMediaOverlayKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let role: AnimatedMediaOverlayRole
        let media: MediaImageKey
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
        let isTimestamp: Bool
        let frame: CGRect
    }

    struct TextPointerHit {
        let hit: NativeTimelineTextHit
        let region: NativeTimelineTextRegion
    }

    struct ComponentButtonPointerHit {
        enum Kind {
            case autoModAlert(NativeTimelineAutoModAlertLayout.Action)
            case component(NativeTimelineComponentLayout.ButtonRegion)
            case sakuraCordDeepLink(SakuraCordDeepLinkAction)
            case invite(NativeTimelineInviteLayout, expands: Bool)
            case fileCard(NativeTimelineFileCard)

            var isDisabled: Bool {
                switch self {
                case let .component(region):
                    region.isDisabled
                case .sakuraCordDeepLink, .autoModAlert:
                    false
                case let .invite(card, expands):
                    !expands && card.isDisabled
                case .fileCard:
                    false
                }
            }
        }

        let target: NativeTimelineComponentButtonTarget
        let rowIndex: Int
        let message: Message
        let kind: Kind
        let frame: CGRect
    }

    struct MessageJumpHighlight: Equatable {
        let messageID: MessageID
        let startedAt: TimeInterval
    }

    struct MessageJumpHighlightPresentation: Equatable {
        let frame: CGRect
        let opacity: CGFloat
    }

    struct VisibleMediaProjection {
        let rowRange: Range<Int>
        let keysByIdentifier:
            [NativeMessageTimelineItem.Identifier:
                Set<MediaImageKey>]
    }

    static let bitmapCostLimit =
        MediaMemoryPolicy.rowBitmapBytes
    var pollStates: [MessageID: NativeTimelinePollPresentation] = [:]
    var pollRowIndexes: [MessageID: Int] = [:]
    var pollSnapshots: [MessageID: MessagePoll] = [:]
    var pollAnimations: [MessageID: (from: [Int: CGFloat], start: TimeInterval)] = [:]
    var pollAccountID: UserID?
    var pressedPollTarget: NativeTimelinePollTarget?
    var hoveredPollTarget: NativeTimelinePollTarget?
    var pollPopover: NSPopover?
    var reactionDetailsPopover: NSPopover?
    var reactionDetailsMessageID: MessageID?
    var reactionPickerMessageID: MessageID?
    weak var reactionDetailsPopoverAnchor: NSView?
    var reactionPopoverLayoutAnchors: [(view: NSView, frameInWindow: CGRect)] = []
    var pollClockTask: Task<Void, Never>?
    let pollAnimationTicker = DisplayLinkTicker()
    // Intermediate resize widths are short-lived; paint them without replacing
    // the stable row bitmap cache on every animation frame.
    var isPreviewingWidth = false
    var storage = NativeTimelineCanvasStorage()
    var baseContentOriginY: CGFloat = 0
    /// Moving the content, as a growing composer does to a short
    /// conversation, carries the inline editor with its row.
    var contentOriginY: CGFloat = 0 {
        didSet {
            if contentOriginY != oldValue { positionEditingRow() }
        }
    }
    var historySkeleton:
        TimelineHistorySkeletonPresentation?
    let historySkeletonShimmer = SkeletonShimmer()
    var historySkeletonShimmerFrame = CGRect.null
    var historySkeletonShimmerScale = InterfaceScale.factor
    var historySkeletonShimmerPresentation: TimelineHistorySkeletonPresentation?
    var messageJumpHighlight: MessageJumpHighlight?
    var messageJumpHighlightTask: Task<Void, Never>?
    var sendTransitions: [NativeTimelineSendTransition] = []
    var transcriptGlide: NativeTimelineTranscriptGlide?
    var transcriptGlideFinishTask: Task<Void, Never>?
    var unreadDividerFades: [NativeMessageTimelineItem.Identifier: NativeTimelineUnreadDividerFade] = [:]
    var unreadDividerGap: NativeTimelineUnreadDividerGap?
    let authorHoverTicker = DisplayLinkTicker()
    var minimumHeight: CGFloat = 1
    var bottomSpacerHeight: CGFloat = 0
    /// The height the floating composer covers at the viewport's bottom.
    var bottomObscuredHeight: CGFloat = 0
    /// The edges of the part of the viewport the window toolbar and the
    /// composer leave uncovered.
    var unobscuredMinY: CGFloat { visibleRect.minY + (enclosingScrollView?.scrollerInsets.top ?? 0) }
    var unobscuredMaxY: CGFloat { visibleRect.maxY - bottomObscuredHeight }
    var maximumDrawDuration = 0.0
    var totalDrawDuration = 0.0
#if SAKURACORD_MOTION_BENCHMARK
    /// Like `totalDrawDuration`, but never reset (motion benchmark).
    var lifetimeDrawDuration = 0.0
#endif
    var drawCount = 0
    var maximumRowRasterDuration = 0.0
    var maximumRowRasterHeight: CGFloat = 0
    var totalRowRasterDuration = 0.0
    var rowRasterCount = 0
    var rowBitmapCacheHitCount = 0
    var liveScrollDirectPaintCount = 0
    var contentOriginInvalidationCount = 0
    var synchronousShortContentRedrawCount = 0
    var bitmapCache:
        [NativeMessageTimelineItem.Identifier: CachedRowBitmap] = [:]
    var bitmapInsertionOrder: [NativeMessageTimelineItem.Identifier] = []
    var bitmapCost = 0
    let visibleMediaPinOwner = UUID()
    var mediaKeysByIdentifier:
        [NativeMessageTimelineItem.Identifier:
            Set<MediaImageKey>] = [:]
    var visibleMediaProjection: VisibleMediaProjection?
    /// The visible rows `presentRowsEnteringViewport` last presented; its own
    /// record, so another refresh of the projection cannot hide an entry.
    var presentedMediaRowRange: Range<Int>?
    var presentationCacheInvalidationCount = 0
    var mentionPointerRegionCache:
        [NativeMessageTimelineItem.Identifier: [MentionPointerRegion]] = [:]
    var codeBlockPointerRegionCache:
        [NativeMessageTimelineItem.Identifier:
            [NativeTimelineCodeBlockPointerTarget]] = [:]

    var items: [NativeMessageTimelineItem] { storage.items }
    var layouts: NativeTimelineCanvasLayouts { .init(storage: storage, editing: editing) }
    var rowOrigins: [CGFloat] { storage.rowOrigins }
    var contentHeight: CGFloat { storage.contentHeight }

    var inboxEventHosts: [ScheduledEventID: NSHostingView<InboxScheduledEventView>] = [:]
    var inboxForumPostHosts: [ChannelID: NSHostingView<InboxForumPostView>] = [:]
    var inboxHeaderHosts: [ChannelID: NSHostingView<InboxGroupHeaderView>] = [:]
    var rowDisclosure: NativeTimelineRowDisclosure?
    var disclosureMaskedViews: [NSView] = []
    /// A header whose viewport position the next structural update keeps.
    var pendingDisclosureScrollAnchor: NativeTimelineRowDisclosure.Key?
    var model: AppModel?
    var accessibilitySettingsSnapshot = AccessibilitySettingsSnapshot.defaults
    var presentedConversationID: ChannelID?
    var mediaReadyConversationID: ChannelID?
    var mediaViewerHighlightedMessageID: MessageID?
    var mediaViewerTransition: NativeTimelineMediaViewerTransition?
    var messageInteractionContext: NativeTimelineMessageInteractionContext = .conversation
    var actions: NativeTimelineRowActions?
    var onWidthChange: ((CGFloat) -> Void)?
    /// Lays a row out around an inline editor of the given text height.
    var makeEditingLayout: ((NativeMessageTimelineItem, CGFloat) -> NativeTimelineRowLayout)?
    var usesViewportSizedBacking = false
    var onDocumentSizeChange: ((NSSize) -> Void)?

    let pointer = NativeTimelinePointerState()
    let beginningSelectionOverlay =
        NativeTimelineBeginningSelectionOverlay()
    var spoilerRevealStore = NativeTimelineSpoilerRevealStore()
    var spoilerRevealObserverID: UUID?
    var actionCapsuleHost: NativeTimelineActionCapsuleHost?
    var actionCapsuleState: NativeTimelineActionCapsuleState?
    var actionCapsuleMessageID: MessageID?
    var actionCapsuleModifierMonitor: Any?
    let editing = NativeTimelineEditingSession()
    let messageProfilePopoverCoordinator =
        StableAnchoredPopoverPresenter<AnyView>.Coordinator()
    var activeMessageProfilePopoverAnchor: StablePopoverAnchor?
    let serverTagPopoverCoordinator = StableAnchoredPopoverPresenter<AnyView>.Coordinator()
    var activeServerTagPopoverAnchor: StablePopoverAnchor?
    var serverTagCardPresentation: ServerTagCardPresentation?

    var componentChoiceOverlay: ComponentChoiceOverlayController?
    var activeComponentChoiceTarget: NativeTimelineComponentSelectTarget?
    /// Mention profiles, role members and command invocations, anchored to
    /// what was clicked inside a message.
    let inlinePopoverCoordinator =
        StableAnchoredPopoverPresenter<AnyView>.Coordinator()
    var activeInlinePopoverAnchor: StablePopoverAnchor?
    let accessibilityProxies =
        NativeTimelineAccessibilityProxyStore<
            NativeMessageTimelineItem.Identifier,
            NativeTimelineAccessibilityRowState
        >()
    let reactionPickerSource = StablePickerPopoverSourceView()
    let reactionPickerCoordinator =
        StablePickerPopoverPresenter<EmojiPickerView>.Coordinator()
    let reactionHoverCoordinator =
        StableAnchoredPopoverPresenter<MessageReactionTooltip>.Coordinator()
    let rowMotion = NativeTimelineRowMotionState()
    var reactionTransitions: [NativeMessageTimelineItem.Identifier: NativeTimelineReactionTransition] = [:]
    var editedTextBands: [NativeMessageTimelineItem.Identifier: NativeTimelineEditedTextBand] = [:] {
        didSet {
            guard oldValue.isEmpty != editedTextBands.isEmpty else { return }
            if editedTextBands.isEmpty { restorePointerInteractions() } else { suppressPointerInteractions() }
        }
    }
    var reactionPictures: [ReactionPictureKey: CGImage] = [:]
    var reactionBandViews: [NativeMessageTimelineItem.Identifier: NativeTimelineReactionBandView] = [:]
    let hoverLabelCoordinator =
        StableAnchoredPopoverPresenter<NativeHoverHelpLabel>.Coordinator()
    /// A press dismisses the hovered target's label until another is hovered.
    var dismissedHoverLabel: NativeTimelineHoverLabelTarget?
    var visibleReactionPreviewLoadKeys:
        Set<ReactionPreviewLoadKey> = []
    var reactionPreviewLoadTasks:
        [ReactionPreviewLoadKey: Task<Void, Never>] = [:]
    var animatedMediaRows:
        [NativeMessageTimelineItem.Identifier: Set<MediaImageKey>] = [:]
    var inlineVideoRows:
        [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
    var inlineVideoOverlays:
        [InlineVideoOverlayKey: NativeTimelineInlineVideoOverlay] = [:]
    /// Video attachments the user started, playing over their tiles.
    var inlinePlayers: [NativeTimelineInlinePlayer.Key: NativeTimelineInlinePlayer] = [:]
    var animatedMediaOverlays:
        [AnimatedMediaOverlayKey: NativeTimelineAnimatedMediaOverlay] = [:]
    var voiceMessageOverlay: NativeTimelineVoiceMessageOverlay?
    var codeCopyControl: NativeTimelineCodeCopyControl?
    /// A hovered audio file's seek bar while another player is active.
    var voiceMessageHoverOverlay: NativeTimelineVoiceMessageOverlay?
    var voiceMessageActiveID: VoiceMessagePlaybackID?
    var voiceMessageResting = VoiceMessageRestingPresentation()
    var voiceMessagePress: VoiceMessagePointerHit?
    var hoveredVoiceMessage: VoiceMessageHover?
    struct ActivityIndicatorKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let index: Int
    }

    var activityIndicators: [ActivityIndicatorKey: NSView] = [:]
    var uploadRings: [UploadRingKey: NativeTimelineUploadRingView] = [:]
    var spoilerOverlays:
        [NativeTimelineComponentRevealKey:
            NativeTimelineSpoilerOverlayHost] = [:]
    var animatedMediaReconcileTask: Task<Void, Never>?
    var mediaInvalidationTask: Task<Void, Never>?
    var pendingMediaInvalidations:
        Set<NativeMessageTimelineItem.Identifier> = []
    var visibleMediaRequestTask: Task<Void, Never>?
    var pendingVisibleMediaRequests:
        [NativeMessageTimelineItem.Identifier: Set<MediaImageKey>] = [:]
    lazy var mediaViewerHost = NSHostingView(
        rootView: AnyView(Color.clear.frame(width: 0, height: 0))
    )

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        scheduleSelectionEmphasisRefresh()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        scheduleSelectionEmphasisRefresh()
        return super.resignFirstResponder()
    }

    /// The window records its new first responder only after these calls return.
    private func scheduleSelectionEmphasisRefresh() {
        Task { @MainActor [weak self] in self?.selectionEmphasisDidChange() }
    }

    @objc func selectionEmphasisDidChange(_ notification: Notification? = nil) {
        guard notification == nil || notification?.object as? NSWindow === window else { return }
        needsDisplay = true
        reconcileBeginningSelectionOverlay()
        animatedMediaOverlays.values.forEach { $0.updateSelectionColor() }
    }

    func drawSuperclassContent(in dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
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
        layer?.addSublayer(historySkeletonShimmer.layer)
        beginningSelectionOverlay.imageAlignment = .alignTopLeft
        beginningSelectionOverlay.imageScaling = .scaleNone
        beginningSelectionOverlay.isHidden = true
        addSubview(beginningSelectionOverlay)
        addSubview(reactionPickerSource)
        mediaViewerHost.frame = .zero
        // Placed by frame: as autoresizing constraints, its updates reached
        // the enclosing SwiftUI layouts on every frame of a column's motion.
        mediaViewerHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mediaViewerHost)
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(composerOverlayDidChange(_:)),
                                       name: ComposerOverlayPointerRegion.changed, object: nil)
        notificationCenter.addObserver(self, selector: #selector(restoreInboxKeyboardFocus),
                                       name: NSApplication.didBecomeActiveNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(synchronizeActionCapsuleShiftState),
                                       name: NSApplication.didBecomeActiveNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(synchronizeActionCapsuleShiftState),
                                       name: NSMenu.didEndTrackingNotification, object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            notificationCenter.addObserver(self, selector: #selector(selectionEmphasisDidChange(_:)), name: name, object: nil)
        }
        notificationCenter.addObserver(self, selector: #selector(voiceMessagePlaybackDidChange(_:)),
                                       name: VoiceMessagePlaybackStore.didChange, object: nil)
        notificationCenter.addObserver(self, selector: #selector(attachmentDownloadsDidChange(_:)),
                                       name: AttachmentDownloadStore.didChange, object: nil)
        notificationCenter.addObserver(self, selector: #selector(attachmentUploadsDidChange(_:)),
                                       name: AttachmentUploadProgressStore.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(mediaPlaybackVisibilityDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
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
        // In-flight copies were rendered for the previous appearance.
        finishSendTransitions(reconcilesHeldMedia: true)
        finishRowMotions()
        invalidatePresentationCaches()
        reconcileBeginningSelectionOverlay()
        reconcileHistorySkeletonShimmer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // AppKit also calls this as the window is resized or moved with
        // neither changed, which would snap a motion mid-update.
        let backing = (scale: window?.backingScaleFactor ?? 0, colorSpace: window?.colorSpace)
        guard backing != rowMotion.backing else { return }
        rowMotion.backing = backing
        // Moving chips and row pictures were drawn for the previous display's
        // scale and colours.
        finishRowMotions()
        invalidatePresentationCaches()
    }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            pollClockTask?.cancel()
            pollAnimationTicker.stop()
            clearDisclosure(redraws: false)
            pollPopover?.close()
            reactionDetailsPopover?.close()
            mediaInvalidationTask?.cancel()
            visibleMediaRequestTask?.cancel()
            messageJumpHighlightTask?.cancel()
            transcriptGlideFinishTask?.cancel()
            authorHoverTicker.stop()
            rowMotion.ticker.stop()
            for fade in unreadDividerFades.values {
                fade.finishTask?.cancel()
                fade.overlay.removeFromSuperview()
            }
            for transition in sendTransitions {
                transition.finishTask?.cancel()
                transition.overlay.removeFromSuperview()
            }
            cancelReactionPreviewLoads()
            releaseMediaPins()
            if let spoilerRevealObserverID {
                spoilerRevealStore.removeObserver(spoilerRevealObserverID)
            }
            if let actionCapsuleModifierMonitor {
                NSEvent.removeMonitor(actionCapsuleModifierMonitor)
            }
        }
    }
}

@MainActor
enum NativeTimelineRowPainter {
    /// Like an NSTextView, the canvas draws its text selection in the active
    /// colour only while it is the key window's first responder.
    static var drawsEmphasizedSelection = true

    static func selectionOverlayImage(
        _ box: NativeTimelineAttributedTextBox,
        size: CGSize,
        selectionRange: NSRange,
        revealedSpoilerLocations: Set<Int> = []
    ) -> NSImage {
        NSImage(size: size, flipped: true) { frame in
            attributedText(
                box,
                in: frame,
                model: nil,
                selectionRange: selectionRange,
                revealedSpoilerLocations: revealedSpoilerLocations
            )
            return true
        }
    }

    static func draw(
        item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout,
        in rowFrame: CGRect,
        model: AppModel?,
        interaction: NativeTimelineRowInteraction = .idle,
        drawsBubbleBackground: Bool = true,
        textSelection: NativeTimelineTextSelection? = nil,
        revealedTextSpoilerState:
            NativeTimelineTextSpoilerRevealState = .init(),
        spoilerRevealStore: NativeTimelineSpoilerRevealStore? = nil,
        pollPresentation: NativeTimelinePollPresentation = .init(),
        animatedOverlayRoles: Set<NativeTimelineCanvasView.AnimatedMediaOverlayRole> = []
    ) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rowFrame.minX, yBy: rowFrame.minY)
        transform.concat()

        if drawsBubbleBackground, let bubble = layout.bubbleRegion {
            NativeTimelineBubbleDrawing.fill(bubble)
        }

        drawHighlight(
            for: item,
            in: layout.highlightFrame,
            bubbleRegion: layout.bubbleRegion,
            model: model,
            isHovered: interaction.isHovered
        )
        switch item {
        case let .suppressedMessages(group):
            if let day = group.day, let frame = layout.daySeparatorFrame {
                dateSeparator(date: day, frame: frame, isUnread: layout.foldedUnreadDay != nil)
            }
            if let frame = layout.unreadSeparatorFrame { newMessagesSeparator(frame: frame) }
            if let header = layout.suppressedHeader {
                drawSuppressedHeader(group, layout: header, isToggleHovered: interaction.isSuppressedToggleHovered)
            }
        case .inboxGroup, .inboxForumPost, .inboxEvent:
            break
        case let .beginning(beginning):
            drawBeginning(
                beginning,
                layout: layout,
                textSelection: textSelection,
                revealedTextSpoilerState: revealedTextSpoilerState,
                model: model
            )
        case let .loader(isLoading, kind):
            drawLoader(
                isLoading: isLoading,
                kind: kind,
                layout: layout
            )
        case let .message(row, _, _):
            drawMessage(.init(
                row: row,
                layout: layout,
                model: model,
                interaction: interaction,
                textSelection: textSelection,
                revealedTextSpoilerState:
                    revealedTextSpoilerState,
                spoilerRevealStore: spoilerRevealStore,
                pollPresentation: pollPresentation,
                animatedOverlayRoles: animatedOverlayRoles
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawStripedHighlight(
        in frame: CGRect,
        color: NSColor,
        backgroundAlpha: CGFloat
    ) {
        color.withAlphaComponent(backgroundAlpha).setFill()
        frame.fill()
        color.setFill()
        CGRect(
            x: frame.minX,
            y: frame.minY,
            width: min(InterfaceScale.metric(2), frame.width),
            height: frame.height
        ).fill()
    }

    static func drawHighlight(
        for item: NativeMessageTimelineItem,
        in frame: CGRect?,
        bubbleRegion: NativeTimelineBubbleRegion?,
        model: AppModel?,
        isHovered: Bool
    ) {
        guard case let .message(row, _, isHighlighted) = item,
              let frame
        else { return }
        NSGraphicsContext.saveGraphicsState()
        if let bubbleRegion {
            NativeTimelineBubbleDrawing.path(for: bubbleRegion).addClip()
        }
        defer { NSGraphicsContext.restoreGraphicsState() }
        let drawFrame = bubbleRegion.map {
            NativeTimelineBubbleDrawing.path(for: $0).bounds
        } ?? frame
        if isHighlighted {
            drawStripedHighlight(
                in: drawFrame,
                color: .sakuraCordAccentColor,
                backgroundAlpha: 0.14
            )
        } else {
            let currentUserID = model?.currentUser?.id
            let currentUserRoleIDs =
                model?.currentUserRoleIDs(for: row.message.guildID) ?? []
            switch MessageRowPersistentHighlight.resolve(
                message: row.message,
                currentUserID: currentUserID,
                currentUserRoleIDs: currentUserRoleIDs
            ) {
            case .none:
                break
            case .failed:
                drawStripedHighlight(
                    in: drawFrame,
                    color: .systemRed,
                    backgroundAlpha: 0.12
                )
            case .ephemeral:
                NSColor(
                    srgbRed: 88 / 255,
                    green: 101 / 255,
                    blue: 242 / 255,
                    alpha: 0.10
                ).setFill()
                drawFrame.fill()
            case .mention:
                drawStripedHighlight(
                    in: drawFrame,
                    color: NSColor(
                        srgbRed: 240 / 255,
                        green: 178 / 255,
                        blue: 50 / 255,
                        alpha: 1
                    ),
                    backgroundAlpha: 0.12
                )
            }
        }
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.055).setFill()
            drawFrame.fill()
        }
    }

    static func drawBeginning(
        _ beginning: NativeTimelineBeginning,
        layout rowLayout: NativeTimelineRowLayout,
        textSelection: NativeTimelineTextSelection?,
        revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState = .init(),
        model: AppModel? = nil
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
        if let image = SakuraCordSystemSymbol.image(
            named: beginning.symbolName,
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
                font: .interfaceSystemFont(
                    ofSize: NSFont.preferredFont(
                        forTextStyle: .largeTitle
                    ).pointSize,
                    weight: .bold
                ),
                color: .labelColor,
                lineBreakMode: .byWordWrapping
            )
        }
        attributedText(
            layout.descriptionBox,
            in: layout.descriptionFrame,
            model: model,
            selectionRange: selectedRegion == .beginningDescription ? textSelection?.range : nil,
            revealedSpoilerLocations: revealedTextSpoilerState.locations(in: .beginningDescription)
        )
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
            font: .interfacePreferredFont(forTextStyle: .caption1),
            color: .secondaryLabelColor,
            alignment: .center
        )
    }

}

extension NativeTimelineCanvasView: NSViewToolTipOwner {
    /// The tooltip of the timeline's buttons that have no label.
    func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?) -> String {
        if codeBlockCopyButtonHit(at: point) != nil { return "Copy Code" }
        guard case let (index, local)? = rowHit(at: point) else { return "" }
        if let roleRegion = layouts[index].roleIconRegion,
           roleRegion.frame.contains(local) {
            return roleRegion.role.name
        }
        guard let messageID = items[index].messageID else { return "" }
        guard let card = fileCards(at: index, messageID: messageID).first(where: { $0.buttonFrame.contains(local) }) else { return "" }
        return fileCardAction(card.attachment, name: card.attachment.filename).title
    }
}
