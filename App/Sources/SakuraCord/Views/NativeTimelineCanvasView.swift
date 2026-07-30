import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

enum NativeTimelineSemanticColor {
    static func opacity(
        _ color: NSColor,
        _ multiplier: CGFloat
    ) -> NSColor {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        return resolved.withAlphaComponent(
            resolved.alphaComponent * min(max(multiplier, 0), 1)
        )
    }
}

nonisolated enum NativeTimelineInlineVideoPresentationPolicy {
    static func canvasOwnsLoadingSurface(
        mediaIsVideo: Bool,
        autoplaysInline: Bool
    ) -> Bool {
        !mediaIsVideo || !autoplaysInline
    }
}

enum NativeTimelineDateSeparatorMetrics {
    static let rowHeight: CGFloat = 37
    static let verticalPadding: CGFloat = 12
    static let lineSpacing: CGFloat = 10
    static let labelHeight: CGFloat = 13

    static var font: NSFont {
        .systemFont(ofSize: 10, weight: .semibold)
    }

    static func labelWidth(_ label: String) -> CGFloat {
        let attributed = NSAttributedString(
            string: label,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(
            CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        )
    }

    static func labelFrame(
        for label: String,
        in frame: CGRect
    ) -> CGRect {
        let width = labelWidth(label)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.minY + verticalPadding,
            width: width,
            height: labelHeight
        )
    }
}

enum NativeTimelineUnreadSeparatorMetrics {
    static let rowHeight: CGFloat = 29
    static let capsuleHeight: CGFloat = 19
    static let verticalPadding: CGFloat = 5
}

enum NativeTimelineReplyMetrics {
    static var authorFont: NSFont {
        .systemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption2
            ).pointSize,
            weight: .semibold
        )
    }

    static var summaryFont: NSFont {
        .preferredFont(forTextStyle: .caption1)
    }

    static func textWidth(
        _ value: String,
        font: NSFont
    ) -> CGFloat {
        let attributed = NSAttributedString(
            string: value,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(
            CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        )
    }
}

nonisolated enum NativeTimelineHoverHitTesting {
    static let coreTextOpticalOffset: CGFloat = 1

    static func pointerFrame(
        for highlightFrame: CGRect?
    ) -> CGRect? {
        highlightFrame?.offsetBy(
            dx: 0,
            dy: coreTextOpticalOffset
        )
    }

    static func contains(
        _ point: CGPoint,
        in highlightFrame: CGRect?
    ) -> Bool {
        pointerFrame(for: highlightFrame)?.contains(point) == true
    }
}

nonisolated enum NativeTimelineCompactTimestampHitTesting {
    static func contains(
        _ point: CGPoint,
        rowOrigin: CGFloat,
        frame: CGRect?
    ) -> Bool {
        frame?
            .offsetBy(dx: 0, dy: rowOrigin)
            .contains(point) == true
    }
}

enum NativeTimelineCompactTimestampMetrics {
    static var font: NSFont {
        .preferredFont(forTextStyle: .caption2)
    }
}

nonisolated enum NativeTimelineMessageMenuAction: Equatable {
    case retrySending
    case addReaction
    case reply
    case markUnread
    case editMessage
    case copyText
    case deleteMessage
}

nonisolated enum NativeTimelineMessageMenuEntry: Equatable {
    case action(
        NativeTimelineMessageMenuAction,
        title: String,
        systemImage: String,
        isDestructive: Bool = false
    )
    case separator
}

nonisolated enum NativeTimelineMessageMenuPolicy {
    static func entries(
        canEdit: Bool,
        canRetry: Bool,
        canReply: Bool
    ) -> [NativeTimelineMessageMenuEntry] {
        var result: [NativeTimelineMessageMenuEntry] = []
        if canRetry {
            result.append(.action(
                .retrySending,
                title: "Retry Sending",
                systemImage: "arrow.clockwise"
            ))
            result.append(.separator)
        }
        result.append(.action(
            .addReaction,
            title: "Add Reaction",
            systemImage: "face.smiling.inverse"
        ))
        if canReply {
            result.append(.action(
                .reply,
                title: "Reply",
                systemImage: "arrowshape.turn.up.left"
            ))
        }
        result.append(.action(
            .markUnread,
            title: "Mark Unread",
            systemImage: "envelope.badge"
        ))
        if canEdit {
            result.append(.action(
                .editMessage,
                title: "Edit Message",
                systemImage: "pencil"
            ))
        }
        result.append(.action(
            .copyText,
            title: "Copy Text",
            systemImage: "doc.on.doc"
        ))
        if canEdit {
            result.append(.separator)
            result.append(.action(
                .deleteMessage,
                title: "Delete Message",
                systemImage: "trash",
                isDestructive: true
            ))
        }
        return result
    }
}

nonisolated struct NativeTimelineReactionCountTransition {
    let from: Int
    let to: Int
    let progress: CGFloat
}

nonisolated enum NativeTimelineReactionCountBaseline {
    static func canAnimate(
        hasCapturedVisibleCounts: Bool,
        hasStoredSnapshot: Bool
    ) -> Bool {
        hasCapturedVisibleCounts || hasStoredSnapshot
    }

    static func previousCount(
        capturedCount: Int?,
        storedCountBeforeUpdate: Int?,
        messageExistedBeforeUpdate: Bool,
        messageWasPreviouslyVisible: Bool,
        currentCount: Int
    ) -> Int {
        if let capturedCount {
            return capturedCount
        }
        if let storedCountBeforeUpdate {
            return storedCountBeforeUpdate
        }
        if messageExistedBeforeUpdate {
            return 0
        }
        return messageWasPreviouslyVisible ? 0 : currentCount
    }
}

nonisolated enum NativeTimelineReactionAddControlGeometry {
    static func iconFrame(in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.midX - 8,
            y: frame.midY - 8,
            width: 16,
            height: 16
        )
    }
}

nonisolated enum NativeTimelineSymbolGeometry {
    static func opticallyFitted(
        sourceSize: CGSize,
        alignmentRect: CGRect,
        in target: CGRect
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              target.width > 0,
              target.height > 0
        else { return target }
        let scale = min(
            target.width / sourceSize.width,
            target.height / sourceSize.height
        )
        let size = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let fitted = CGRect(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        guard alignmentRect.width > 0,
              alignmentRect.height > 0
        else { return fitted }
        // SF Symbols carry an alignment rect describing the center AppKit
        // uses when laying the symbol out beside native controls. NSImage's
        // low-level draw API ignores it, leaving several symbols visibly a
        // fraction of a point high or left. Apply that optical center here.
        return fitted.offsetBy(
            dx: (sourceSize.width / 2 - alignmentRect.midX) * scale,
            dy: (sourceSize.height / 2 - alignmentRect.midY) * scale
        )
    }
}

nonisolated enum NativeTimelineTextRegion: Hashable {
    case beginningTitle
    case beginningDescription
    case content
    case embed(embedID: String, textIndex: Int)
    case component(layoutIndex: Int, textIndex: Int)
}

nonisolated struct NativeTimelineTextSpoilerRevealState: Equatable {
    private var locationsByRegion:
        [NativeTimelineTextRegion: Set<Int>] = [:]

    var isEmpty: Bool {
        locationsByRegion.isEmpty
    }

    mutating func reveal(
        region: NativeTimelineTextRegion,
        rangeLocation: Int
    ) {
        locationsByRegion[region, default: []].insert(rangeLocation)
    }

    func locations(
        in region: NativeTimelineTextRegion
    ) -> Set<Int> {
        locationsByRegion[region] ?? []
    }
}

nonisolated struct NativeTimelineTextSpoilerRevealKey: Hashable {
    let messageID: MessageID
    let contentID: String
    let contentHash: Int
    let rangeLocation: Int
}

@MainActor
final class NativeTimelineSpoilerRevealStore {
    private var revealedMedia: Set<NativeTimelineComponentRevealKey> = []
    private var revealedText: Set<NativeTimelineTextSpoilerRevealKey> = []
    private var observers: [UUID: (MessageID) -> Void] = [:]

    func isMediaRevealed(
        _ key: NativeTimelineComponentRevealKey
    ) -> Bool {
        revealedMedia.contains(key)
    }

    @discardableResult
    func revealMedia(
        _ key: NativeTimelineComponentRevealKey
    ) -> Bool {
        let inserted = revealedMedia.insert(key).inserted
        if inserted {
            notifyObservers(messageID: key.messageID)
        }
        return inserted
    }

    func isTextRevealed(
        _ key: NativeTimelineTextSpoilerRevealKey
    ) -> Bool {
        revealedText.contains(key)
    }

    @discardableResult
    func revealText(
        _ key: NativeTimelineTextSpoilerRevealKey
    ) -> Bool {
        let inserted = revealedText.insert(key).inserted
        if inserted {
            notifyObservers(messageID: key.messageID)
        }
        return inserted
    }

    func revealedTextLocations(
        messageID: MessageID,
        contentID: String,
        contentHash: Int
    ) -> Set<Int> {
        Set(
            revealedText.lazy
                .filter {
                    $0.messageID == messageID
                        && $0.contentID == contentID
                        && $0.contentHash == contentHash
                }
                .map(\.rangeLocation)
        )
    }

    func observe(
        _ observer: @escaping (MessageID) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notifyObservers(messageID: MessageID) {
        for observer in observers.values {
            observer(messageID)
        }
    }
}

@MainActor
enum NativeTimelineSpoilerConcealmentPolicy {
    static func isConcealed(
        messageID: MessageID,
        contentID: String,
        isSpoiler: Bool,
        store: NativeTimelineSpoilerRevealStore
    ) -> Bool {
        isSpoiler
            && !store.isMediaRevealed(
                NativeTimelineComponentRevealKey(
                    messageID: messageID,
                    componentID: contentID
                )
            )
    }

    static func hiddenContainerFrames(
        in layout: NativeTimelineComponentLayout,
        messageID: MessageID,
        store: NativeTimelineSpoilerRevealStore
    ) -> [CGRect] {
        let frames = layout.containers.compactMap { container in
            isConcealed(
                messageID: messageID,
                contentID: container.componentID,
                isSpoiler: container.isSpoiler,
                store: store
            ) ? container.frame : nil
        }
        return frames.filter { candidate in
            !frames.contains { other in
                other != candidate
                    && other.width * other.height
                        > candidate.width * candidate.height
                    && other.contains(
                        CGPoint(
                            x: candidate.midX,
                            y: candidate.midY
                        )
                    )
            }
        }
    }

    static func isInsideHiddenContainer(
        _ frame: CGRect,
        hiddenContainerFrames: [CGRect]
    ) -> Bool {
        hiddenContainerFrames.contains {
            $0.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    static func shouldLoadOrAnimate(
        messageID: MessageID,
        contentID: String,
        isSpoiler: Bool,
        store: NativeTimelineSpoilerRevealStore
    ) -> Bool {
        !isConcealed(
            messageID: messageID,
            contentID: contentID,
            isSpoiler: isSpoiler,
            store: store
        )
    }
}

nonisolated enum NativeTimelineTextAccessibilityPresentation {
    static func hiddenSpoilerRanges(
        in value: NSAttributedString,
        revealedLocations: Set<Int>
    ) -> [NSRange] {
        guard value.length > 0 else { return [] }
        var result: [NSRange] = []
        value.enumerateAttribute(
            .discordMarkdownSpoiler,
            in: NSRange(location: 0, length: value.length)
        ) { rawValue, range, _ in
            guard (rawValue as? NSNumber)?.boolValue == true,
                  !revealedLocations.contains(range.location)
            else { return }
            result.append(range)
        }
        return result
    }

    static func text(
        _ value: NSAttributedString,
        revealedLocations: Set<Int>
    ) -> String {
        guard value.length > 0 else { return "" }
        let hiddenRanges = hiddenSpoilerRanges(
            in: value,
            revealedLocations: revealedLocations
        )
        let source = value.string as NSString
        var result = ""
        var cursor = 0
        var hiddenIndex = 0
        while cursor < value.length {
            if hiddenIndex < hiddenRanges.count,
               hiddenRanges[hiddenIndex].location == cursor
            {
                result += "Spoiler"
                cursor = NSMaxRange(hiddenRanges[hiddenIndex])
                hiddenIndex += 1
                continue
            }

            var effectiveRange = NSRange(location: 0, length: 0)
            let attributes = value.attributes(
                at: cursor,
                effectiveRange: &effectiveRange
            )
            let nextHiddenLocation = hiddenIndex < hiddenRanges.count
                ? hiddenRanges[hiddenIndex].location
                : value.length
            let runEnd = min(
                NSMaxRange(effectiveRange),
                nextHiddenLocation
            )
            let runRange = NSRange(
                location: cursor,
                length: max(1, runEnd - cursor)
            )
            if let mention = (
                attributes[.nativeTimelineMention]
                    as? NativeTimelineMentionBox
            )?.presentation {
                result += mention.label
            } else if let rawToken =
                attributes[.discordEmojiToken] as? String
            {
                result += ":\(EmojiReference(rawToken: rawToken).name):"
            } else {
                result += source.substring(with: runRange)
                    .replacingOccurrences(of: "\u{fffc}", with: "")
            }
            cursor = NSMaxRange(runRange)
        }
        return result
    }
}

nonisolated struct NativeTimelineMentionHover: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let characterIndex: Int
    let rawToken: String
}

nonisolated struct NativeTimelineTextSpoilerHover: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let rangeLocation: Int
}

struct NativeTimelineMentionHitRegion {
    let characterIndex: Int
    let presentation: MentionPresentation
    let frame: CGRect
}

enum NativeTimelineMentionAppearance {
    static func backgroundAlpha(isHovered: Bool) -> CGFloat {
        isHovered ? 0.34 : 0.18
    }
}

nonisolated struct NativeTimelineComponentButtonTarget: Hashable {
    let messageID: MessageID
    let componentID: String
}

nonisolated enum NativeTimelineComponentButtonVisualState {
    static let pressAnimationDuration: TimeInterval = 0.09

    static func scale(pressProgress: CGFloat) -> CGFloat {
        1 - 0.015 * min(max(pressProgress, 0), 1)
    }

    static func brightness(
        isHovered: Bool,
        pressProgress: CGFloat
    ) -> CGFloat {
        let pressProgress = min(max(pressProgress, 0), 1)
        let hoverBrightness: CGFloat = isHovered ? 0.035 : 0
        return hoverBrightness * (1 - pressProgress)
            - 0.07 * pressProgress
    }

    static func borderAlpha(
        isHovered: Bool,
        isEnabled: Bool
    ) -> CGFloat {
        isHovered && isEnabled ? 0.14 : 0.07
    }

    static func easeOut(_ progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return 1 - pow(1 - progress, 3)
    }
}

nonisolated enum NativeTimelineComponentButtonActivationPolicy {
    static func activates(
        pressed: NativeTimelineComponentButtonTarget?,
        released: NativeTimelineComponentButtonTarget?
    ) -> Bool {
        NativeTimelinePointerActivationPolicy.activates(
            pressed: pressed,
            released: released
        )
    }
}

nonisolated enum NativeTimelinePointerActivationTarget: Hashable {
    case loader
    case componentReveal(MessageID, String)
    case componentImage(MessageID, String)
    case componentMedia(MessageID, String)
    case componentFile(MessageID, String)
    case componentSelect(MessageID, String)
    case textMention(
        MessageID,
        NativeTimelineTextRegion,
        characterIndex: Int,
        rawToken: String
    )
    case textURL(
        MessageID,
        NativeTimelineTextRegion,
        characterIndex: Int,
        url: URL
    )
    case textSpoiler(
        MessageID,
        NativeTimelineTextRegion,
        rangeLocation: Int
    )
    case ephemeralDismiss(MessageID)
    case authorProfile(MessageID)
    case invocationProfile(MessageID)
    case reply(MessageID, MessageID)
    case linkedImage(MessageID, URL)
    case attachment(MessageID, String)
    case embedMedia(MessageID, String)
    case thread(MessageID, ChannelID)

    var supportsTextSelection: Bool {
        switch self {
        case .textMention, .textURL:
            true
        default:
            false
        }
    }
}

nonisolated enum NativeTimelinePointerActivationPolicy {
    static func activates<T: Equatable>(
        pressed: T?,
        released: T?
    ) -> Bool {
        pressed != nil && pressed == released
    }
}

nonisolated enum NativeTimelineAuthorProfileGeometry {
    static func hitFrames(
        avatarFrame: CGRect?,
        authorFrame: CGRect?
    ) -> [CGRect] {
        [avatarFrame, authorFrame].compactMap { $0 }
    }

    static func hitFrame(
        at point: CGPoint,
        avatarFrame: CGRect?,
        authorFrame: CGRect?
    ) -> CGRect? {
        hitFrames(
            avatarFrame: avatarFrame,
            authorFrame: authorFrame
        ).first(where: { $0.contains(point) })
    }
}

nonisolated enum NativeTimelineAvatarPresentation {
    static let decorationScale: CGFloat = 1.16

    static func decorationFrame(around avatarFrame: CGRect) -> CGRect {
        let width = avatarFrame.width * decorationScale
        let height = avatarFrame.height * decorationScale
        return CGRect(
            x: avatarFrame.midX - width / 2,
            y: avatarFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func replyAvatarFrame(in replyFrame: CGRect) -> CGRect {
        CGRect(
            x: replyFrame.minX + 35,
            y: replyFrame.minY + 3,
            width: 14,
            height: 14
        )
    }

    static func shouldDecodeAnimation(for url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "gif", "apng":
            return true
        default:
            return URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.contains {
                $0.name == "animated"
                    && $0.value?.lowercased() == "true"
            } == true
        }
    }
}

nonisolated enum NativeTimelineScrollingRenderPolicy {
    static func usesDirectPainter(
        isScrolling: Bool,
        hasCachedBitmap: Bool
    ) -> Bool {
        isScrolling && !hasCachedBitmap
    }
}

nonisolated struct NativeTimelineTextSelection: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let range: NSRange
}

@MainActor
private final class NativeTimelineReactionCountAnimationState:
    ObservableObject
{
    @Published var count: Int
    let targetCount: Int
    let countsDown: Bool

    init(from: Int, to: Int) {
        count = from
        targetCount = to
        countsDown = to < from
    }

    func start() {
        count = targetCount
    }
}

private struct NativeTimelineReactionCountAnimationView: View {
    @ObservedObject var state: NativeTimelineReactionCountAnimationState
    let countsDown: Bool
    let color: Color

    init(
        state: NativeTimelineReactionCountAnimationState,
        color: NSColor
    ) {
        self.state = state
        countsDown = state.countsDown
        self.color = Color(nsColor: color)
    }

    var body: some View {
        Text(state.count, format: .number)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText(countsDown: countsDown))
            .animation(.smooth(duration: 0.24), value: state.count)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
            .accessibilityHidden(true)
    }
}

private final class NativeTimelineReactionCountAnimationHost:
    NSHostingView<AnyView>
{
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class NativeTimelineEditingHost: NSHostingView<AnyView> {
    var fittingHeightDidChange: ((CGFloat) -> Void)?

    private var lastReportedFittingHeight: CGFloat = 0
    private var isMeasuringFittingHeight = false

    override func layout() {
        super.layout()
        guard !isMeasuringFittingHeight else { return }
        isMeasuringFittingHeight = true
        let height = max(1, ceil(fittingSize.height))
        isMeasuringFittingHeight = false
        guard abs(height - lastReportedFittingHeight) > 0.5 else {
            return
        }
        lastReportedFittingHeight = height
        DispatchQueue.main.async { [weak self] in
            self?.fittingHeightDidChange?(height)
        }
    }
}

private final class NativeTimelineLoadingIndicator: NSView {
    private let replicator = CAReplicatorLayer()
    private let spoke = CALayer()
    var controlSize: NSControl.ControlSize = .mini {
        didSet {
            needsLayout = true
            replicator.removeAnimation(forKey: "rotation")
            startAnimating()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        replicator.instanceCount = 8
        replicator.instanceAlphaOffset = -0.095
        replicator.instanceTransform = CATransform3DMakeRotation(
            .pi / 4,
            0,
            0,
            1
        )
        layer?.addSublayer(replicator)
        spoke.backgroundColor = NSColor.secondaryLabelColor
            .withAlphaComponent(0.82).cgColor
        replicator.addSublayer(spoke)
        startAnimating()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        replicator.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
        let thickness = max(1.25, side * 0.12)
        let length = max(3, side * 0.28)
        spoke.bounds = CGRect(
            x: 0,
            y: 0,
            width: thickness,
            height: length
        )
        spoke.position = CGPoint(x: side / 2, y: side / 2)
        spoke.anchorPoint = CGPoint(x: 0.5, y: 1.55)
        spoke.cornerRadius = thickness / 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            replicator.removeAnimation(forKey: "rotation")
        } else {
            startAnimating()
        }
    }

    private func startAnimating() {
        guard replicator.animation(forKey: "rotation") == nil else {
            return
        }
        let rotation = CABasicAnimation(
            keyPath: "transform.rotation.z"
        )
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = controlSize == .small ? 0.9 : 0.8
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(
            name: .linear
        )
        replicator.add(rotation, forKey: "rotation")
    }
}

@MainActor
private final class NativeTimelineInlineVideoOverlay: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var url: URL?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NativeTimelineSemanticColor.opacity(
            .secondaryLabelColor,
            0.10
        ).cgColor
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.player = player
        playerLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        playerLayer.autoresizingMask = [
            .layerWidthSizable,
            .layerHeightSizable,
        ]
        layer?.addSublayer(playerLayer)
        synchronizePlayerLayerFrame()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizePlayerLayerFrame()
    }

    override func layout() {
        super.layout()
        synchronizePlayerLayerFrame()
    }

    private func synchronizePlayerLayerFrame() {
        // AVPlayerLayer otherwise implicitly animates bounds/position changes.
        // During the transition, the canvas' rounded loading placeholder shows
        // through below the shorter presentation layer as a gray footer.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func display(_ url: URL, plays: Bool) {
        if self.url != url {
            stop()
            self.url = url
            looper = AVPlayerLooper(
                player: player,
                templateItem: AVPlayerItem(url: url)
            )
        }
        if plays {
            player.playImmediately(atRate: 1)
        } else {
            player.pause()
        }
    }

    func stop() {
        player.pause()
        player.removeAllItems()
        looper = nil
        url = nil
    }

    func pauseForScroll() {
        player.pause()
    }

    deinit {
        player.pause()
        player.removeAllItems()
    }
}

@MainActor
private final class NativeTimelineLottieStickerOverlay: NSView {
    private let animationView = LottieAnimationView()
    private let progressIndicator = NSProgressIndicator()
    private var loadingTask: Task<Void, Never>?
    private var url: URL?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .loop
        animationView.isHidden = true
        addSubview(animationView)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.startAnimation(nil)
        addSubview(progressIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        animationView.frame = bounds
        animationView.needsLayout = true
        animationView.layoutSubtreeIfNeeded()
        let spinnerSize = progressIndicator.fittingSize
        progressIndicator.frame = CGRect(
            x: (bounds.width - spinnerSize.width) / 2,
            y: (bounds.height - spinnerSize.height) / 2,
            width: spinnerSize.width,
            height: spinnerSize.height
        )
    }

    func display(_ url: URL, reduceMotion: Bool) {
        if self.url != url {
            stop()
            self.url = url
            animationView.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            loadingTask = Task { @MainActor [weak self] in
                let animation = await LottieAnimation.loadedFrom(url: url)
                guard !Task.isCancelled,
                      let self,
                      self.url == url
                else { return }
                self.loadingTask = nil
                self.animationView.animation = animation
                self.animationView.isHidden = animation == nil
                self.progressIndicator.isHidden = animation != nil
                self.updatePlayback(reduceMotion: reduceMotion)
            }
        } else {
            updatePlayback(reduceMotion: reduceMotion)
        }
    }

    private func updatePlayback(reduceMotion: Bool) {
        animationView.loopMode = .loop
        guard animationView.animation != nil else { return }
        if reduceMotion {
            animationView.pause()
            animationView.currentProgress = 0
        } else if !animationView.isAnimationPlaying {
            animationView.play()
        }
    }

    func pauseForScroll() {
        animationView.pause()
    }

    func stop() {
        loadingTask?.cancel()
        loadingTask = nil
        animationView.stop()
        animationView.animation = nil
        url = nil
    }

    deinit {
        loadingTask?.cancel()
    }
}

private struct NativeTimelineSpoilerOverlayPresentation: Hashable {
    let cornerRadius: CGFloat
}

nonisolated enum NativeTimelineSpoilerAppearance {
    static let pillHeight: CGFloat = 24
    static let pillHorizontalPadding: CGFloat = 10
    static let textCornerRadius: CGFloat = 4

    static func textBackgroundAlpha(isHovered: Bool) -> CGFloat {
        isHovered ? 0.62 : 0.46
    }

    static func pillFrame(
        in bounds: CGRect,
        measuredLabelWidth: CGFloat
    ) -> CGRect {
        let width = min(
            max(1, bounds.width),
            ceil(measuredLabelWidth) + pillHorizontalPadding * 2
        )
        let height = min(max(1, bounds.height), pillHeight)
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func isActivationKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 36, 49, 76:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class NativeTimelineSpoilerOverlayHost: NSView {
    private let cornerRadius: CGFloat
    private let revealAction: () -> Void
    private let pillView = NSView()
    private let pillLabel = NSTextField(labelWithString: "SPOILER")
    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false
    private var isPressed = false
    private var didActivate = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        frame: CGRect,
        cornerRadius: CGFloat,
        reveal: @escaping () -> Void
    ) {
        self.cornerRadius = cornerRadius
        revealAction = reveal
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            srgbRed: 0.12,
            green: 0.125,
            blue: 0.14,
            alpha: 1
        ).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius =
            NativeTimelineSpoilerAppearance.pillHeight / 2
        pillView.layer?.masksToBounds = true
        pillView.setAccessibilityElement(false)
        addSubview(pillView)

        pillLabel.attributedStringValue = NSAttributedString(
            string: "SPOILER",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white,
                .kern: 0.4,
            ]
        )
        pillLabel.alignment = .center
        pillLabel.lineBreakMode = .byClipping
        pillLabel.setAccessibilityElement(false)
        pillView.addSubview(pillLabel)
        updateAppearance()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reveal spoiler")
        setAccessibilityHelp(
            "Reveals this media without opening it"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let labelSize = pillLabel.attributedStringValue.size()
        pillView.frame = NativeTimelineSpoilerAppearance.pillFrame(
            in: bounds,
            measuredLabelWidth: labelSize.width
        )
        pillLabel.frame = pillView.bounds
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        window?.makeFirstResponder(self)
        isPressed = true
        updateAppearance()
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
        updateAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        let activates =
            isPressed
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updateAppearance()
        if activates {
            activate()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func otherMouseDown(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        if NativeTimelineSpoilerAppearance.isActivationKey(event) {
            activate()
        } else {
            super.keyDown(with: event)
        }
    }

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            activate()
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(
                concentricRoundedRect: bounds.insetBy(dx: 2, dy: 2),
                cornerRadius: max(1, cornerRadius - 2)
            )
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    private func updateAppearance() {
        layer?.backgroundColor = (
            isHovered
                ? NSColor(
                    srgbRed: 0.18,
                    green: 0.19,
                    blue: 0.21,
                    alpha: 1
                )
                : NSColor(
                    srgbRed: 0.12,
                    green: 0.125,
                    blue: 0.14,
                    alpha: 1
                )
        ).cgColor
        pillView.layer?.backgroundColor = NSColor.black.withAlphaComponent(
            isPressed ? 0.72 : (isHovered ? 0.62 : 0.52)
        ).cgColor
    }

#if DEBUG
    var hasPersistentPillForTesting: Bool {
        pillView.superview === self
            && pillLabel.superview === pillView
            && !pillView.isHidden
    }
#endif

    private func activate() {
        guard !didActivate else { return }
        didActivate = true
        revealAction()
    }
}

/// Presents decoded raster animation frames on Core Animation's compositor.
/// The outer view is deliberately transparent so the selection tint can
/// extend beyond the clipped media box exactly as the Core Text painter does.
private final class NativeTimelineAnimatedMediaOverlay: NSView {
    private let imageClipView = NSView()
    private let imageView = AnimatedImageCanvas()
    private let selectionView = NSView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        imageClipView.wantsLayer = true
        imageClipView.layer?.masksToBounds = true
        addSubview(imageClipView)

        imageView.frame = imageClipView.bounds
        imageView.autoresizingMask = [.width, .height]
        imageClipView.addSubview(imageView)

        selectionView.wantsLayer = true
        selectionView.layer?.backgroundColor =
            NSColor.selectedTextBackgroundColor
                .withAlphaComponent(0.5)
                .cgColor
        selectionView.isHidden = true
        addSubview(selectionView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(
        _ image: DecodedAnimatedImage,
        mediaFrame: CGRect,
        selectionFrame: CGRect?,
        cornerRadius: CGFloat,
        isLooping: Bool,
        opacity: CGFloat,
        fillsFrame: Bool
    ) {
        imageClipView.frame = mediaFrame
        imageClipView.alphaValue = opacity
        imageClipView.layer?.cornerRadius = cornerRadius
        if #available(macOS 13.0, *) {
            imageClipView.layer?.cornerCurve = .continuous
        }
        imageView.display(
            image,
            animates: true,
            isLooping: isLooping,
            contentMode: fillsFrame ? .fill : .fit
        )
        if let selectionFrame {
            selectionView.frame = selectionFrame
            selectionView.isHidden = false
        } else {
            selectionView.isHidden = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct NativeTimelineMediaKey: Hashable {
    let url: URL
    let maximumPixelDimension: Int

    static func avatar(_ url: URL) -> Self {
        Self(url: url, maximumPixelDimension: 96)
    }

    static func avatarDecoration(_ url: URL) -> Self {
        Self(url: url, maximumPixelDimension: 128)
    }

    static func media(_ url: URL, maximumPixelDimension: Int = 1_024) -> Self {
        Self(url: url, maximumPixelDimension: maximumPixelDimension)
    }

    fileprivate var cacheKey: NSString {
        "\(url.absoluteString)#native-timeline-pixel-max=\(maximumPixelDimension)" as NSString
    }
}

enum NativeTimelineReplyMediaPolicy {
    static func avatarKey(
        for preview: MessageReplyPreview?
    ) -> NativeTimelineMediaKey? {
        preview?.author.avatarURL.map(NativeTimelineMediaKey.avatar)
    }
}

@MainActor
private final class NativeTimelineAnimatedMedia {
    let decoded: DecodedAnimatedImage
    let firstFrame: NSImage?

    init(_ decoded: DecodedAnimatedImage) {
        self.decoded = decoded
        firstFrame = decoded.frames.first.map {
            NSImage(
                cgImage: $0,
                size: NSSize(width: $0.width, height: $0.height)
            )
        }
    }

    var isAnimated: Bool {
        decoded.frames.count > 1
            && decoded.frameDurations.reduce(0, +) > 0
    }
}

@MainActor
final class NativeTimelineMediaStore {
    static let shared = NativeTimelineMediaStore()

    private struct PinnedImageReference {
        let image: NSImage
        var ownerCount: Int
    }

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 384
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()
    private var loading: Set<NativeTimelineMediaKey> = []
    private var subscribers:
        [NativeTimelineMediaKey: [NativeMessageTimelineItem.Identifier: () -> Void]] = [:]
    private let animatedCache: NSCache<NSString, NativeTimelineAnimatedMedia> = {
        let cache = NSCache<NSString, NativeTimelineAnimatedMedia>()
        cache.countLimit = 64
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()
    private var animatedLoading: Set<NativeTimelineMediaKey> = []
    private var animatedSubscribers:
        [NativeTimelineMediaKey: [NativeMessageTimelineItem.Identifier: () -> Void]] = [:]
    // Row bitmaps can outlive NSCache's volatile decoded-media entry. Keep
    // the exact source images used by each retained bitmap strongly reachable
    // so a hover/direct-paint pass cannot replace an already-visible
    // attachment with its loading placeholder. Owners are released together
    // with the bounded bitmap cache, keeping this retention bounded too.
    private var pinnedKeysByOwner:
        [UUID: Set<NativeTimelineMediaKey>] = [:]
    private var pinnedImages:
        [NativeTimelineMediaKey: PinnedImageReference] = [:]

    func image(for key: NativeTimelineMediaKey) -> NSImage? {
        if let pinned = pinnedImages[key] {
            return pinned.image
        }
        return cache.object(forKey: key.cacheKey)
    }

    func firstAnimatedFrame(
        for key: NativeTimelineMediaKey
    ) -> NSImage? {
        animatedCache.object(forKey: key.cacheKey)?.firstFrame
    }

    func decodedAnimatedImage(
        for key: NativeTimelineMediaKey
    ) -> DecodedAnimatedImage? {
        guard let media = animatedCache.object(forKey: key.cacheKey),
              media.isAnimated
        else { return nil }
        return media.decoded
    }

    func decodedImage(
        for key: NativeTimelineMediaKey
    ) -> DecodedAnimatedImage? {
        animatedCache.object(forKey: key.cacheKey)?.decoded
    }

    func requestAnimated(
        _ key: NativeTimelineMediaKey,
        subscriber: NativeMessageTimelineItem.Identifier,
        completion: @escaping () -> Void
    ) {
        guard animatedCache.object(forKey: key.cacheKey) == nil else {
            return
        }
        animatedSubscribers[key, default: [:]][subscriber] = completion
        guard animatedLoading.insert(key).inserted else { return }

        Task { [weak self] in
            let decoded: DecodedAnimatedImage?
            do {
                decoded = try await SharedAnimatedImageLoader.shared.image(
                    for: key.url,
                    maximumPixelDimension: key.maximumPixelDimension
                )
            } catch {
                decoded = nil
            }
            guard let self else { return }
            animatedLoading.remove(key)
            let completions =
                animatedSubscribers.removeValue(forKey: key)?.values
                ?? [:].values
            if let decoded {
                let media = NativeTimelineAnimatedMedia(decoded)
                animatedCache.setObject(
                    media,
                    forKey: key.cacheKey,
                    cost: decoded.estimatedByteCount
                )
            }
            for completion in completions {
                completion()
            }
        }
    }

    func request(
        _ key: NativeTimelineMediaKey,
        subscriber: NativeMessageTimelineItem.Identifier,
        completion: @escaping () -> Void
    ) {
        guard image(for: key) == nil else { return }
        subscribers[key, default: [:]][subscriber] = completion
        guard loading.insert(key).inserted else { return }

        Task { [weak self] in
            let image: NSImage?
            do {
                let data = try await SharedMediaDataLoader.shared.data(for: key.url)
                let decoded = await Task.detached(priority: .utility) {
                    NativeTimelineMediaDecoder.decode(
                        data,
                        maximumPixelDimension: key.maximumPixelDimension
                    )
                }.value
                image = decoded.map {
                    NSImage(
                        cgImage: $0,
                        size: NSSize(width: $0.width, height: $0.height)
                    )
                }
            } catch {
                image = nil
            }
            guard let self else { return }
            loading.remove(key)
            let completions = subscribers.removeValue(forKey: key)?.values ?? [:].values
            if let image {
                let representation = image.representations.first
                let width = representation?.pixelsWide ?? Int(image.size.width)
                let height = representation?.pixelsHigh ?? Int(image.size.height)
                cache.setObject(
                    image,
                    forKey: key.cacheKey,
                    cost: max(1, width * height * 4)
                )
            }
            for completion in completions {
                completion()
            }
        }
    }

    func pinLoadedImages(
        for keys: Set<NativeTimelineMediaKey>,
        owner: UUID
    ) {
        releasePinnedImages(owner: owner)
        var loadedKeys: Set<NativeTimelineMediaKey> = []
        for key in keys {
            if var pinned = pinnedImages[key] {
                pinned.ownerCount += 1
                pinnedImages[key] = pinned
                loadedKeys.insert(key)
            } else if let image = cache.object(forKey: key.cacheKey) {
                pinnedImages[key] = PinnedImageReference(
                    image: image,
                    ownerCount: 1
                )
                loadedKeys.insert(key)
            }
        }
        if !loadedKeys.isEmpty {
            pinnedKeysByOwner[owner] = loadedKeys
        }
    }

    func releasePinnedImages(owner: UUID) {
        guard let keys = pinnedKeysByOwner.removeValue(forKey: owner)
        else { return }
        for key in keys {
            guard var pinned = pinnedImages[key] else { continue }
            pinned.ownerCount -= 1
            if pinned.ownerCount <= 0 {
                pinnedImages[key] = nil
            } else {
                pinnedImages[key] = pinned
            }
        }
    }

#if DEBUG
    func cacheImageForTesting(
        _ image: NSImage,
        for key: NativeTimelineMediaKey
    ) {
        cache.setObject(image, forKey: key.cacheKey)
    }

    func evictVolatileImageForTesting(
        for key: NativeTimelineMediaKey
    ) {
        cache.removeObject(forKey: key.cacheKey)
    }
#endif
}

private enum NativeTimelineMediaDecoder {
    nonisolated static func decode(
        _ data: Data,
        maximumPixelDimension: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelDimension),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

private struct NativeTimelineInlineEmojiRegion {
    let rawToken: String
    let characterRange: NSRange
    let mediaFrame: CGRect
    let selectionFrame: CGRect?
}

private enum NativeTimelineInlineEmojiGeometry {
    static func regions(
        in value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        selectionRange: NSRange?
    ) -> [NativeTimelineInlineEmojiRegion] {
        guard value.length > 0, frame.width > 0, frame.height > 0
        else { return [] }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var result: [NativeTimelineInlineEmojiRegion] = []
        for lineIndex in 0 ..< lines.count {
            let line = lines[lineIndex] as! CTLine
            let lineOrigin = origins[lineIndex]
            let runs = CTLineGetGlyphRuns(line) as NSArray
            for case let run as CTRun in runs {
                let range = CTRunGetStringRange(run)
                guard range.location >= 0,
                      range.location < value.length,
                      let rawToken = value.attribute(
                          .discordEmojiToken,
                          at: range.location,
                          effectiveRange: nil
                      ) as? String
                else { continue }

                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(
                    run,
                    CFRange(location: 0, length: 0),
                    &ascent,
                    &descent,
                    &leading
                ))
                let x = lineOrigin.x + CTLineGetOffsetForStringIndex(
                    line,
                    range.location,
                    nil
                )
                let size = CGSize(
                    width: max(1, width),
                    height: max(1, ascent + descent)
                )
                let localBottom = lineOrigin.y - descent
                let mediaFrame = CGRect(
                    x: frame.minX + x,
                    y: frame.maxY - localBottom - size.height,
                    width: size.width,
                    height: size.height
                )
                let isSelected =
                    NativeTimelineTextSelectionGeometry.intersects(
                        characterRange: range,
                        selectionRange: selectionRange
                    )
                let selectionFrame = isSelected
                    ? NativeTimelineTextSelectionGeometry.rects(
                        in: textFrame,
                        outerFrame: frame,
                        range: NSRange(
                            location: range.location,
                            length: max(1, range.length)
                        )
                    ).first
                    : nil
                result.append(NativeTimelineInlineEmojiRegion(
                    rawToken: rawToken,
                    characterRange: NSRange(
                        location: range.location,
                        length: max(1, range.length)
                    ),
                    mediaFrame: mediaFrame,
                    selectionFrame: selectionFrame
                ))
            }
        }
        return result
    }
}

@MainActor
final class NativeTimelineCanvasStorage {
    var items: [NativeMessageTimelineItem] = []
    var layouts: [NativeTimelineRowLayout] = []
    var rowHeights: [CGFloat] = []
    var rowOrigins: [CGFloat] = []
    var contentHeight: CGFloat = 0
}

nonisolated final class NativeTimelineAccessibilityElement:
    NSAccessibilityElement
{
    private let press: (@MainActor @Sendable () -> Bool)?

    nonisolated init(
        press: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        self.press = press
        super.init()
    }

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        press == nil ? [] : [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated {
            action?() ?? false
        }
    }

    @MainActor
    func performPressIfAvailable() -> Bool {
        press?() ?? false
    }
}

@MainActor
final class NativeTimelineAccessibilityProxyView: NSView {
    nonisolated private let press: (@MainActor @Sendable () -> Bool)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func isAccessibilityElement() -> Bool {
        true
    }

    init(source: NSAccessibilityElement) {
        if let source = source as? NativeTimelineAccessibilityElement {
            press = {
                source.performPressIfAvailable()
            }
        } else {
            press = nil
        }
        super.init(frame: .zero)
        setAccessibilityRole(source.accessibilityRole())
        setAccessibilitySubrole(source.accessibilitySubrole())
        setAccessibilityLabel(source.accessibilityLabel())
        setAccessibilityValue(source.accessibilityValue())
        setAccessibilityHelp(source.accessibilityHelp())
        setAccessibilityIdentifier(source.accessibilityIdentifier())
        setAccessibilityEnabled(source.isAccessibilityEnabled())
        setAccessibilityCustomActions(
            source.accessibilityCustomActions()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {}

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        press == nil ? [] : [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated {
            action?() ?? false
        }
    }
}

nonisolated enum NativeTimelineAccessibilityPresentation {
    static func attachmentLabel(_ attachment: Attachment) -> String {
        let label =
            nonblank(attachment.description)
            ?? nonblank(attachment.title)
            ?? attachment.filename
        if attachment.isSpoiler {
            return "Spoiler attachment, \(label)"
        }
        return label
    }

    static func stickerLabel(_ sticker: MessageSticker) -> String {
        nonblank(sticker.description) ?? sticker.name
    }

    static func threadLabel(_ thread: MessageThreadSummary) -> String {
        let replyCount = thread.messageCount
        return "\(thread.name), \(replyCount) "
            + (replyCount == 1 ? "reply" : "replies")
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum NativeTimelineAccessibilityPolicy {
    static func bufferedViewport(
        around viewport: CGRect,
        contentHeight: CGFloat
    ) -> CGRect {
        let minY = max(0, viewport.minY - viewport.height)
        let maxY = min(
            max(minY, contentHeight),
            viewport.maxY + viewport.height
        )
        return CGRect(
            x: 0,
            y: minY,
            width: viewport.width,
            height: max(0, maxY - minY)
        )
    }

    static func showsMessageBody(
        messageID: MessageID,
        editingMessageID: MessageID?
    ) -> Bool {
        messageID != editingMessageID
    }

    static func editingOverlayInsertionIndex(
        in rowIdentifiers: [NativeMessageTimelineItem.Identifier],
        editingMessageID: MessageID?
    ) -> Int? {
        guard let editingMessageID,
              let rowIndex = rowIdentifiers.firstIndex(
                  of: .message(editingMessageID)
              )
        else { return nil }
        return rowIndex + 1
    }
}

nonisolated enum NativeTimelineEditingGeometry {
    static func rowHeight(
        avatarMaxY: CGFloat?,
        contentOriginY: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        max(
            avatarMaxY ?? 0,
            contentOriginY + contentHeight + 3
        )
    }
}

struct NativeTimelineComponentRevealKey: Hashable {
    let messageID: MessageID
    let componentID: String

    static func attachmentComponentID(_ attachmentID: String) -> String {
        "attachment:\(attachmentID)"
    }

    static func attachment(
        messageID: MessageID,
        attachmentID: String
    ) -> Self {
        Self(
            messageID: messageID,
            componentID: attachmentComponentID(attachmentID)
        )
    }
}

nonisolated enum NativeTimelineTransientRowGeometry {
    static func contentOriginY(
        base: CGFloat,
        heightDelta: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        guard base > minimum + 0.5 else { return base }
        return max(minimum, base - heightDelta)
    }

    static func contentHeight(
        base: CGFloat,
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        base + heightDelta(
            replacementHeight: replacementHeight,
            baseRowHeight: baseRowHeight
        )
    }

    static func rowOrigin(
        base: CGFloat,
        rowIndex: Int,
        replacementIndex: Int?,
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementIndex, rowIndex > replacementIndex else {
            return base
        }
        return base + heightDelta(
            replacementHeight: replacementHeight,
            baseRowHeight: baseRowHeight
        )
    }

    static func rowHeight(
        base: CGFloat,
        rowIndex: Int,
        replacementIndex: Int?,
        replacementHeight: CGFloat?
    ) -> CGFloat {
        guard rowIndex == replacementIndex, let replacementHeight else {
            return base
        }
        return replacementHeight
    }

    private static func heightDelta(
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementHeight, let baseRowHeight else { return 0 }
        return replacementHeight - baseRowHeight
    }
}

@MainActor
private final class NativeTimelineActionCapsuleState: ObservableObject {
    @Published var isReactionPickerPresented = false {
        didSet {
            guard oldValue != isReactionPickerPresented else { return }
            presentationDidChange?(isReactionPickerPresented)
        }
    }

    var presentationDidChange: ((Bool) -> Void)?
}

private struct NativeTimelineActionCapsuleOverlay: View {
    let model: AppModel
    let message: Message
    let canEdit: Bool
    @ObservedObject var state: NativeTimelineActionCapsuleState
    let retry: (() -> Void)?
    let edit: () -> Void
    let reply: (() -> Void)?
    let react: (String) -> Void
    let copy: () -> Void
    let copyLink: () -> Void
    let openThread: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        MessageActionCapsule(
            model: model,
            message: message,
            canEdit: canEdit,
            isReactionPickerPresented: $state.isReactionPickerPresented,
            retry: retry,
            edit: edit,
            reply: reply,
            react: react,
            copy: copy,
            copyLink: copyLink,
            openThread: openThread,
            delete: delete
        )
        .fixedSize()
    }
}

struct NativeTimelineMediaViewerPresentation: Identifiable {
    let id = UUID()
    let items: [RichMediaItem]
    let selection: Int
}

enum NativeTimelineMediaViewerPlan {
    static func attachments(
        in message: Message,
        selectedAttachmentID: String
    ) -> NativeTimelineMediaViewerPresentation? {
        guard let selection = message.attachments.firstIndex(where: {
            $0.id == selectedAttachmentID
        }) else { return nil }
        return NativeTimelineMediaViewerPresentation(
            items: message.attachments.map(RichMediaItem.init),
            selection: selection
        )
    }

    static func embed(
        in message: Message,
        id: String
    ) -> NativeTimelineMediaViewerPresentation? {
        guard let embed = message.embeds.first(where: { $0.id == id }),
              let item = RichMediaItem(
                  embed: embed,
                  attachments: message.attachments
              )
        else { return nil }
        return NativeTimelineMediaViewerPresentation(
            items: [item],
            selection: 0
        )
    }
}

@MainActor
private final class NativeTimelineMediaViewerState: ObservableObject {
    @Published var presentation: NativeTimelineMediaViewerPresentation?

    func present(_ value: NativeTimelineMediaViewerPresentation) {
        presentation = value
    }

    func dismiss() {
        presentation = nil
    }
}

private struct NativeTimelineMediaViewerLayer: View {
    @ObservedObject var state: NativeTimelineMediaViewerState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: $state.presentation) { presentation in
                MediaViewer(
                    items: presentation.items,
                    selection: presentation.selection,
                    close: state.dismiss
                )
            }
    }
}

private final class NativeTimelineBeginningSelectionOverlay: NSImageView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

/// A viewless, virtualized message surface. One AppKit view owns the entire
/// timeline; only rows intersecting the dirty rectangle are painted.
@MainActor
final class NativeTimelineCanvasView: NSView {
    private struct CachedRowBitmap {
        let item: NativeMessageTimelineItem
        let width: CGFloat
        let appearanceName: NSAppearance.Name
        let image: NSImage
        let cost: Int
        let mediaPinOwner: UUID
    }

    private enum ReactionPointerTarget: Equatable {
        case reaction(messageID: MessageID, reactionID: String)
        case add(messageID: MessageID)

        var messageID: MessageID {
            switch self {
            case let .reaction(messageID, _), let .add(messageID):
                messageID
            }
        }
    }

    private struct ReactionPointerHit {
        let target: ReactionPointerTarget
        let rowIndex: Int
        let message: Message
        let reaction: Reaction?
        let frame: CGRect
    }

    private struct ReactionCountKey: Hashable {
        let messageID: MessageID
        let reactionID: String
    }

    private struct ActiveReactionCountAnimation {
        let from: Int
        let to: Int
    }

    private struct ReactionCountSnapshot {
        let counts: [ReactionCountKey: Int]
        let messageIDs: Set<MessageID>
    }

    private struct InlineVideoOverlayKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let embedID: String
        let url: URL
    }

    private struct LottieStickerOverlayKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let stickerID: String
        let url: URL
    }

    private enum AnimatedMediaOverlayRole: Hashable {
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

    private struct AnimatedMediaOverlayKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let role: AnimatedMediaOverlayRole
        let media: NativeTimelineMediaKey
    }

    private struct TextSelectionGesture {
        let itemIdentifier: NativeMessageTimelineItem.Identifier
        let region: NativeTimelineTextRegion
        let anchor: Int
    }

    private struct TextCaretCandidate {
        let itemIdentifier: NativeMessageTimelineItem.Identifier
        let region: NativeTimelineTextRegion
        let rowIndex: Int
        let caret: Int
        let value: NSAttributedString
    }

    private struct SelectableTextRegion {
        let region: NativeTimelineTextRegion
        let frame: CGRect
        let interactionFrame: CGRect
        let value: NSAttributedString
        let framesetter: CTFramesetter
    }

    private struct MentionPointerRegion {
        let region: NativeTimelineTextRegion
        let characterIndex: Int
        let rawToken: String
        let frame: CGRect
    }

    private struct CodeBlockPointerTarget: Equatable {
        let itemIdentifier: NativeMessageTimelineItem.Identifier
        let region: NativeTimelineTextRegion
        let rangeLocation: Int
        let blockFrame: CGRect
        let copyButtonFrame: CGRect
        let content: String
    }

    private struct TextPointerHit {
        let hit: NativeTimelineTextHit
        let region: NativeTimelineTextRegion
    }

    private struct ComponentButtonPointerHit {
        let target: NativeTimelineComponentButtonTarget
        let rowIndex: Int
        let message: Message
        let region: NativeTimelineComponentLayout.ButtonRegion
        let frame: CGRect
    }

    private static let bitmapCostLimit = 32 * 1024 * 1024
    private var storage = NativeTimelineCanvasStorage()
    private var baseContentOriginY: CGFloat = 0
    private var contentOriginY: CGFloat = 0
    private var historySkeleton:
        NativeTimelineHistorySkeletonPresentation?
    private var minimumHeight: CGFloat = 1
    private var bottomSpacerHeight: CGFloat = 0
    private(set) var maximumDrawDuration = 0.0
    private(set) var maximumRowRasterDuration = 0.0
    private(set) var maximumRowRasterHeight: CGFloat = 0
    private(set) var contentOriginInvalidationCount = 0
    private(set) var synchronousShortContentRedrawCount = 0
    private var bitmapCache:
        [NativeMessageTimelineItem.Identifier: CachedRowBitmap] = [:]
    private var bitmapInsertionOrder: [NativeMessageTimelineItem.Identifier] = []
    private var bitmapEvictionIndex = 0
    private var bitmapCost = 0
    private(set) var presentationCacheInvalidationCount = 0
    private var mentionPointerRegionCache:
        [NativeMessageTimelineItem.Identifier: [MentionPointerRegion]] = [:]
    private var codeBlockPointerRegionCache:
        [NativeMessageTimelineItem.Identifier: [CodeBlockPointerTarget]] = [:]

    private var items: [NativeMessageTimelineItem] { storage.items }
    private var layouts: [NativeTimelineRowLayout] { storage.layouts }
    private var rowOrigins: [CGFloat] { storage.rowOrigins }
    private var contentHeight: CGFloat { storage.contentHeight }

    var model: AppModel?
    var actions: NativeTimelineRowActions?
    var onWidthChange: ((CGFloat) -> Void)?
    var usesViewportSizedBacking = false
    var onDocumentSizeChange: ((NSSize) -> Void)?

    private var hoveredRow: Int?
    private var hoveredCompactTimestampRow: Int?
    private var hoveredMention: NativeTimelineMentionHover?
    private var hoveredTextSpoiler: NativeTimelineTextSpoilerHover?
    private var hoveredCodeBlock: CodeBlockPointerTarget?
    private var pressedCodeBlockCopyButton: CodeBlockPointerTarget?
    private var hoveredComponentButton:
        NativeTimelineComponentButtonTarget?
    private var pressedComponentButton:
        NativeTimelineComponentButtonTarget?
    private var visualPressedComponentButton:
        NativeTimelineComponentButtonTarget?
    private var componentButtonPressProgress: CGFloat = 0
    private var componentButtonPressAnimationTask: Task<Void, Never>?
    private var componentButtonPressAnimationDestination: CGFloat?
    private var pressedActivationTarget:
        NativeTimelinePointerActivationTarget?
    private var hoveredReaction: ReactionPointerTarget?
    private var suppressesHoverPresentation = false
    private var textSelection: NativeTimelineTextSelection?
    private var textSelectionGesture: TextSelectionGesture?
    private var didDragTextSelection = false
    private let beginningSelectionOverlay =
        NativeTimelineBeginningSelectionOverlay()
    private var spoilerRevealStore = NativeTimelineSpoilerRevealStore()
    private var spoilerRevealObserverID: UUID?
    private var tracking: NSTrackingArea?
    private var rowTrackingAreas: [NSTrackingArea] = []
    private var prewarmTask: Task<Void, Never>?
    private var actionCapsuleHost: NSHostingView<AnyView>?
    private var actionCapsuleState: NativeTimelineActionCapsuleState?
    private var actionCapsuleMessageID: MessageID?
    private var actionCapsuleSize: NSSize?
    private var editingRowHost: NativeTimelineEditingHost?
    private weak var editingTextView: ComposerNSTextView?
    private var editingMessageID: MessageID?
    private var editingRowIndexCache: Int?
    private var editingRowHeight: CGFloat?
    private var editingOverlayLocalFrame: CGRect?
    private var editingRowScrollSnapshot: NSImage?
    private var messageProfilePopover: NSPopover?
    private let mentionPopoverCoordinator =
        StableAnchoredPopoverPresenter<AnyView>.Coordinator()
    private var activeMentionPopoverAnchor: StablePopoverAnchor?
    private var accessibilityProxyRows:
        [NativeMessageTimelineItem.Identifier:
            NativeTimelineAccessibilityProxyView] = [:]
    private var accessibilityProxyItems:
        [NativeMessageTimelineItem.Identifier:
            NativeMessageTimelineItem] = [:]
    private var accessibilityProxyOrder:
        [NativeMessageTimelineItem.Identifier] = []
    private let reactionPickerSource = StableReactionPickerSourceView()
    private let reactionPickerCoordinator =
        StableReactionPickerPresenter<EmojiPickerView>.Coordinator()
    private let reactionHoverCoordinator =
        StableAnchoredPopoverPresenter<MessageReactionTooltip>.Coordinator()
    private var reactionMouseMonitor: Any?
    private var visibleReactionCounts: [ReactionCountKey: Int] = [:]
    private var previouslyVisibleReactionMessageIDs: Set<MessageID> = []
    private var activeReactionCountAnimations:
        [ReactionCountKey: ActiveReactionCountAnimation] = [:]
    private var reactionCountAnimationHosts:
        [ReactionCountKey: NativeTimelineReactionCountAnimationHost] = [:]
    private var reactionCountAnimationTasks:
        [ReactionCountKey: Task<Void, Never>] = [:]
    private var reactionCountBaselineTask: Task<Void, Never>?
    private var pendingReactionCountSnapshot: ReactionCountSnapshot?
    private var hasCapturedVisibleReactionCounts = false
    private var animatedMediaRows:
        [NativeMessageTimelineItem.Identifier: Set<NativeTimelineMediaKey>] = [:]
    private var inlineVideoRows:
        [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
    private var lottieStickerRows:
        [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
    private var inlineVideoOverlays:
        [InlineVideoOverlayKey: NativeTimelineInlineVideoOverlay] = [:]
    private var lottieStickerOverlays:
        [LottieStickerOverlayKey: NativeTimelineLottieStickerOverlay] = [:]
    private var animatedMediaOverlays:
        [AnimatedMediaOverlayKey: NativeTimelineAnimatedMediaOverlay] = [:]
    private var loadingIndicators:
        [NativeMessageTimelineItem.Identifier:
            NativeTimelineLoadingIndicator] = [:]
    private var spoilerOverlays:
        [NativeTimelineComponentRevealKey:
            NativeTimelineSpoilerOverlayHost] = [:]
    private var spoilerOverlayPresentations:
        [NativeTimelineComponentRevealKey:
            NativeTimelineSpoilerOverlayPresentation] = [:]
    private var animatedMediaReconcileTask: Task<Void, Never>?
    private var animatedMediaScrollReconcileTask: Task<Void, Never>?
    private let mediaViewerState = NativeTimelineMediaViewerState()
    private lazy var mediaViewerHost = NSHostingView(
        rootView: AnyView(
            NativeTimelineMediaViewerLayer(state: mediaViewerState)
        )
    )

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reconcileBeginningSelectionOverlay()
    }

    func apply(
        storage: NativeTimelineCanvasStorage,
        model: AppModel,
        actions: NativeTimelineRowActions,
        viewportWidth: CGFloat,
        minimumHeight: CGFloat,
        bottomSpacerHeight: CGFloat,
        contentOriginY: CGFloat,
        historySkeleton: NativeTimelineHistorySkeletonPresentation? = nil
    ) {
        precondition(storage.items.count == storage.layouts.count)
        precondition(storage.items.count == storage.rowOrigins.count)
        let previousContentOriginY = self.contentOriginY
        let contentOriginMoved: Bool
        // The coordinator and canvas intentionally share storage to avoid
        // copying thousands of rows. The coordinator mutates that storage
        // before calling apply, so a snapshot taken here is already the new
        // value. Consume the snapshot captured before the shared mutation.
        let reactionCountsBeforeUpdate =
            pendingReactionCountSnapshot ?? reactionCountSnapshot()
        pendingReactionCountSnapshot = nil
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        self.storage = storage
        self.model = model
        installSpoilerRevealStore(model.timelineSpoilerRevealStore)
        self.actions = actions
        baseContentOriginY = contentOriginY
        self.minimumHeight = max(1, minimumHeight)
        self.bottomSpacerHeight = max(0, bottomSpacerHeight)
        let previousHistorySkeleton = self.historySkeleton
        self.historySkeleton = historySkeleton
        // A conversation can disappear while its edit overlay is still
        // installed (for example, closing a supplementary thread). Reconcile
        // the cached edit index against the replacement storage before any
        // transient geometry reads it.
        reconcileEditingRow()
        self.contentOriginY = transientContentOriginY
        contentOriginMoved =
            abs(previousContentOriginY - self.contentOriginY) >= 0.5
        if activeMentionPopoverAnchor?.sourceRect() == nil {
            closeMentionPopover()
        }
        if let selection = textSelection {
            let selectionValue = storage.items.firstIndex(where: {
                $0.identifier == selection.itemIdentifier
            }).flatMap { index -> NSAttributedString? in
                guard storage.layouts.indices.contains(index) else {
                    return nil
                }
                return selectableTextRegions(
                    for: storage.items[index],
                    layout: storage.layouts[index]
                ).first(where: {
                    $0.region == selection.region
                })?.value
            }
            if selectionValue == nil
                || NSMaxRange(selection.range)
                    > (selectionValue?.length ?? 0)
            {
                textSelection = nil
                textSelectionGesture = nil
            }
        }
        let size = NSSize(
            width: max(1, viewportWidth),
            height: max(displayedContentHeight, self.minimumHeight)
        )
        applyDocumentSize(size)
        // A short timeline moves every row when its bottom-anchored origin
        // changes. Invalidating only an appended row leaves the old pixels
        // behind until a later footer/layout pass, which looks like rows
        // slowly sliding through and over one another.
        if contentOriginMoved {
            contentOriginInvalidationCount += 1
            needsDisplay = true
        }
        if previousHistorySkeleton != historySkeleton {
            // The canvas uses a bounded viewport-sized backing layer. A
            // skeleton can disappear while its former document coordinates
            // are simultaneously becoming real rows, so a targeted union can
            // miss stale pixels after the viewport window moves. Redrawing
            // the bounded canvas clears that transition without touching the
            // rest of the virtual document.
            needsDisplay = true
        }
        reconcileReactionCountAnimations(
            storedBeforeUpdate: reactionCountsBeforeUpdate
        )
        scheduleInitialReactionCountCapture()
        startVisibleInlineVideosImmediately()
        scheduleAnimatedMediaReconciliation()
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        reconcileLoadingIndicators()
        reconcileSpoilerOverlays()
        if !suppressesHoverPresentation {
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if !suppressesHoverPresentation {
            reconcileAccessibilityProxies()
        }
        reconcileReactionHover()
        reconcileActionCapsule()
        if !suppressesHoverPresentation {
            synchronizeHoverWithCurrentPointer()
        }
        redrawMovedShortContentSynchronously(
            from: previousContentOriginY,
            contentOriginMoved: contentOriginMoved
        )
    }

    func updateHistorySkeleton(
        _ presentation: NativeTimelineHistorySkeletonPresentation?
    ) {
        guard historySkeleton != presentation else { return }
        historySkeleton = presentation
        // The backing layer is only the viewport plus bounded overscan. Clear
        // that bounded surface whenever provisional history appears,
        // disappears, or belongs to a different conversation so no stale
        // placeholder pixels can survive into materialized rows.
        needsDisplay = true
    }

    func updateContentOriginY(
        _ value: CGFloat,
        minimumHeight: CGFloat,
        bottomSpacerHeight: CGFloat
    ) {
        let oldOriginY = contentOriginY
        let oldMinimumHeight = self.minimumHeight
        let oldBottomSpacerHeight = self.bottomSpacerHeight
        baseContentOriginY = value
        self.minimumHeight = max(1, minimumHeight)
        self.bottomSpacerHeight = max(0, bottomSpacerHeight)
        contentOriginY = transientContentOriginY
        guard abs(oldOriginY - contentOriginY) >= 0.5
                || abs(oldMinimumHeight - self.minimumHeight) >= 0.5
                || abs(oldBottomSpacerHeight - self.bottomSpacerHeight) >= 0.5
        else { return }
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        let size = NSSize(
            width: max(1, frame.width),
            height: max(displayedContentHeight, self.minimumHeight)
        )
        applyDocumentSize(size)
        if !suppressesHoverPresentation {
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if !suppressesHoverPresentation {
            reconcileAccessibilityProxies()
        }
        reconcileReactionHover()
        reconcileActionCapsule()
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        positionInlineVideoOverlays()
        positionLottieStickerOverlays()
        reconcileLoadingIndicators()
        positionSpoilerOverlays()
        needsDisplay = true
        if !suppressesHoverPresentation {
            synchronizeHoverWithCurrentPointer()
        }
        redrawMovedShortContentSynchronously(
            from: oldOriginY,
            contentOriginMoved:
                abs(oldOriginY - contentOriginY) >= 0.5
        )
    }

    private func redrawMovedShortContentSynchronously(
        from previousContentOriginY: CGFloat,
        contentOriginMoved: Bool
    ) {
        guard contentOriginMoved,
              window != nil,
              max(previousContentOriginY, contentOriginY)
                > ChatDetailLayoutPolicy.timelineTopPadding + 0.5
        else { return }
        // Bottom-aligned timelines move every existing row when a live
        // message consumes some of their leading space. With
        // `.onSetNeedsDisplay`, AppKit is allowed to preserve the old backing
        // pixels until the next display transaction. A pointer event can
        // invalidate only the newly positioned row first, leaving a duplicate
        // of that row at its former location. Short timelines cover at most
        // one viewport, so finish this bounded redraw before hover tracking is
        // allowed to paint a partial row.
        synchronousShortContentRedrawCount += 1
        displayIfNeeded()
    }

    func captureReactionCountsBeforeStorageMutation() {
        pendingReactionCountSnapshot = reactionCountSnapshot()
    }

    func invalidateRows(_ indexes: IndexSet) {
        for index in indexes where items.indices.contains(index) {
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func invalidateVisibleContent() {
        setNeedsDisplay(visibleRect)
    }

    func invalidatePresentationCaches() {
        prewarmTask?.cancel()
        prewarmTask = nil
        clearBitmapCache(keepingCapacity: true)
        bitmapInsertionOrder.removeAll(keepingCapacity: true)
        bitmapEvictionIndex = 0
        bitmapCost = 0
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        presentationCacheInvalidationCount += 1
        needsDisplay = true
    }

    func dismissHoverPresentationForScroll() {
        // Prewarming is idle work. A scroll can begin after a programmatic
        // position request has queued it but before that main-actor task gets
        // its first turn. Cancel it at the activity boundary so a cold bitmap
        // raster cannot block the first scrolling frames.
        prewarmTask?.cancel()
        prewarmTask = nil
        // Bounds changes arrive for every momentum-scroll tick. Repeating the
        // teardown work here used to restart the media timer on every tick,
        // which meant it could never fire until scrolling stopped.
        guard !suppressesHoverPresentation else {
            scheduleAnimatedMediaScrollReconciliation()
            return
        }
        suppressesHoverPresentation = true
        // Pause native playback once without destroying its presentation.
        // Recreating AVPlayer and Lottie overlays on each reconciliation
        // produced the benchmark's regular FAST/pause cadence, while removing
        // them made otherwise loaded videos and stickers blink out as soon as
        // scrolling began. Retaining the bounded overlays preserves their
        // current frames and avoids both costs.
        for overlay in inlineVideoOverlays.values {
            overlay.pauseForScroll()
        }
        for overlay in lottieStickerOverlays.values {
            overlay.pauseForScroll()
        }
        // Setting the flag only prevents future installation. Existing
        // in-visible-rect areas otherwise remain registered, so AppKit walks
        // and hit-tests the moving timeline under a stationary pointer on
        // every scroll transaction even though no hover can be presented.
        // Tear them and their cursor regions down immediately.
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        cancelReactionCountAnimations()
        animatedMediaReconcileTask?.cancel()
        animatedMediaReconcileTask = nil
        scheduleAnimatedMediaScrollReconciliation()
        let old = hoveredRow
        hoveredRow = nil
        let oldCompactTimestamp = hoveredCompactTimestampRow
        hoveredCompactTimestampRow = nil
        let oldMention = hoveredMention
        hoveredMention = nil
        let oldTextSpoiler = hoveredTextSpoiler
        hoveredTextSpoiler = nil
        let oldCodeBlock = hoveredCodeBlock
        hoveredCodeBlock = nil
        pressedCodeBlockCopyButton = nil
        let oldComponentButton =
            visualPressedComponentButton ?? hoveredComponentButton
        hoveredComponentButton = nil
        pressedComponentButton = nil
        pressedActivationTarget = nil
        visualPressedComponentButton = nil
        componentButtonPressProgress = 0
        componentButtonPressAnimationDestination = nil
        componentButtonPressAnimationTask?.cancel()
        componentButtonPressAnimationTask = nil
        hoveredReaction = nil
        reactionHoverCoordinator.close()
        closeMessageProfilePopover()
        removeActionCapsule()
        freezeEditingRowForScroll()
        reconcileAccessibilityProxies()
        if let old {
            setNeedsDisplay(rowFrame(at: old))
        }
        if let oldCompactTimestamp, oldCompactTimestamp != old {
            setNeedsDisplay(rowFrame(at: oldCompactTimestamp))
        }
        if let oldMention,
           let oldMentionIndex = items.firstIndex(where: {
               $0.identifier == oldMention.itemIdentifier
           }),
           oldMentionIndex != old,
           oldMentionIndex != oldCompactTimestamp
        {
            setNeedsDisplay(rowFrame(at: oldMentionIndex))
        }
        if let oldTextSpoiler,
           let oldTextSpoilerIndex = items.firstIndex(where: {
               $0.identifier == oldTextSpoiler.itemIdentifier
           }),
           oldTextSpoilerIndex != old,
           oldTextSpoilerIndex != oldCompactTimestamp
        {
            setNeedsDisplay(rowFrame(at: oldTextSpoilerIndex))
        }
        if let oldCodeBlock,
           let oldCodeBlockIndex = items.firstIndex(where: {
               $0.identifier == oldCodeBlock.itemIdentifier
           }),
           oldCodeBlockIndex != old,
           oldCodeBlockIndex != oldCompactTimestamp
        {
            setNeedsDisplay(rowFrame(at: oldCodeBlockIndex))
        }
        if let oldComponentButton {
            invalidateComponentButton(oldComponentButton)
        }
    }

    func allowHoverPresentationAfterScroll() {
        suppressesHoverPresentation = false
        animatedMediaScrollReconcileTask?.cancel()
        animatedMediaScrollReconcileTask = nil
        restoreEditingRowAfterScroll()
        reconcileAnimatedMedia()
        reconcileLoadingIndicators()
        reconcileSpoilerOverlays()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        reconcileAccessibilityProxies()
        synchronizeHoverWithCurrentPointer()
    }

    func installViewportGeometry(frame: CGRect, bounds: CGRect) {
        if self.bounds != bounds {
            self.bounds = bounds
            // A fast gesture can replace the entire overscanned window in one
            // event. Explicitly request the new bounded backing contents so
            // Core Animation never presents an empty document slice while
            // waiting for an unrelated invalidation.
            needsDisplay = true
        }
        if self.frame != frame {
            // `setFrameSize` invokes `onWidthChange` synchronously. That
            // callback can relayout the timeline and recursively install a
            // newer document-sized viewport. Installing this pass's bounds
            // first ensures it cannot overwrite those corrected bounds after
            // the callback returns. Before this ordering, the first scroll
            // event repaired the stale launch geometry, making the content
            // visibly jump into place.
            self.frame = frame
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(oldWidth - newSize.width) >= 1 {
            onWidthChange?(newSize.width)
        }
        positionEditingRow()
        positionActionCapsule()
        positionAnimatedMediaOverlays()
        positionInlineVideoOverlays()
        positionLottieStickerOverlays()
        reconcileLoadingIndicators()
        positionSpoilerOverlays()
    }

    private func applyDocumentSize(_ size: NSSize) {
        if usesViewportSizedBacking {
            onDocumentSizeChange?(size)
        } else if frame.size != size {
            super.setFrameSize(size)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            clearBitmapCache(keepingCapacity: false)
            bitmapInsertionOrder.removeAll(keepingCapacity: false)
            bitmapEvictionIndex = 0
            bitmapCost = 0
            removeReactionMouseMonitor()
            cancelReactionCountAnimations()
            reactionCountBaselineTask?.cancel()
            reactionCountBaselineTask = nil
            animatedMediaReconcileTask?.cancel()
            animatedMediaReconcileTask = nil
            animatedMediaScrollReconcileTask?.cancel()
            animatedMediaScrollReconcileTask = nil
            animatedMediaRows.removeAll()
            inlineVideoRows.removeAll()
            lottieStickerRows.removeAll()
            removeInlineVideoOverlays()
            removeLottieStickerOverlays()
            removeAnimatedMediaOverlays()
            removeLoadingIndicators()
            removeSpoilerOverlays()
            reactionPickerCoordinator.close(notifyBinding: false)
            reactionHoverCoordinator.close()
            closeMessageProfilePopover()
            closeMentionPopover()
            reactionPickerSource.frame = .zero
            hoveredMention = nil
            hoveredTextSpoiler = nil
            hoveredCodeBlock = nil
            pressedCodeBlockCopyButton = nil
            hoveredComponentButton = nil
            pressedComponentButton = nil
            pressedActivationTarget = nil
            visualPressedComponentButton = nil
            componentButtonPressProgress = 0
            componentButtonPressAnimationDestination = nil
            componentButtonPressAnimationTask?.cancel()
            componentButtonPressAnimationTask = nil
            hoveredReaction = nil
            removeAccessibilityProxies()
            removeActionCapsule()
            endEditing(commit: nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        if let spoilerRevealObserverID {
            MainActor.assumeIsolated {
                spoilerRevealStore.removeObserver(
                    spoilerRevealObserverID
                )
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installReactionMouseMonitor()
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.reconcileAccessibilityProxies()
            }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.reconcileAccessibilityProxies()
            }
        }
    }

    func rowFrame(at index: Int) -> CGRect {
        guard items.indices.contains(index) else { return .zero }
        return CGRect(
            x: 0,
            y: displayedRowOrigin(at: index),
            width: bounds.width,
            height: displayedRowHeight(at: index)
        )
    }

    func rowIndex(at documentY: CGFloat) -> Int? {
        guard !rowOrigins.isEmpty else { return nil }
        var lower = 0
        var upper = rowOrigins.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if displayedRowOrigin(at: middle) + displayedRowHeight(at: middle)
                <= documentY
            {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return items.indices.contains(lower) ? lower : nil
    }

    func firstVisibleMessage(
        in rect: CGRect,
        preferringVisibleOrigin: Bool = false
    ) -> (MessageID, CGFloat)? {
        guard var index = rowIndex(at: rect.minY) else { return nil }
        var intersectingMessage: (MessageID, CGFloat)?
        while items.indices.contains(index) {
            if let id = items[index].messageID {
                let offset = displayedRowOrigin(at: index) - rect.minY
                if intersectingMessage == nil {
                    intersectingMessage = (id, offset)
                }
                if !preferringVisibleOrigin
                    || (offset >= 0 && offset < rect.height)
                {
                    return (id, offset)
                }
            }
            index += 1
        }
        return intersectingMessage
    }

    override func draw(_ dirtyRect: NSRect) {
        let startUptime = ProcessInfo.processInfo.systemUptime
        defer {
            maximumDrawDuration = max(
                maximumDrawDuration,
                ProcessInfo.processInfo.systemUptime - startUptime
            )
        }
        super.draw(dirtyRect)
        // This view is transparent and layer-backed. Core Graphics does not
        // guarantee that invalidating a region clears its previous backing
        // pixels before draw(_:). Clear first so bottom-origin changes cannot
        // composite newly positioned rows over their former positions.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        drawHistorySkeleton(in: dirtyRect)
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, dirtyRect.minY))
        else { return }

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < dirtyRect.maxY
        {
            let rowFrame = rowFrame(at: index)
            if rowFrame.intersects(dirtyRect) {
                let revealedTextSpoilerState =
                    textSpoilerRevealState(
                        for: items[index].identifier
                    )
                if items[index].messageID == editingMessageID {
                    NSGraphicsContext.current?.cgContext.clear(
                        rowFrame.intersection(dirtyRect)
                    )
                    requestMedia(for: items[index], at: index)
                    NativeTimelineRowPainter.draw(
                        item: items[index],
                        layout: layouts[index],
                        in: rowFrame,
                        model: model,
                        isHovered: false,
                        hidesMessageContent: true,
                        spoilerRevealStore: spoilerRevealStore
                    )
                    if let snapshot = editingRowScrollSnapshot {
                        snapshot.draw(
                            in: editingOverlayFrame(at: index),
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: nil
                        )
                    }
                    index += 1
                    continue
                }
                requestMedia(for: items[index], at: index)
                let countTransitions = reactionCountTransitions(
                    inMessageAt: index
                )
                if hoveredRow == index
                    || hoveredCompactTimestampRow == index
                    || hoveredMention?.itemIdentifier
                        == items[index].identifier
                    || hoveredTextSpoiler?.itemIdentifier
                        == items[index].identifier
                    || hoveredComponentButton?.messageID
                        == items[index].messageID
                    || visualPressedComponentButton?.messageID
                        == items[index].messageID
                    || !countTransitions.isEmpty
                    || textSelection?.itemIdentifier
                        == items[index].identifier
                    || !revealedTextSpoilerState.isEmpty
                {
                    NativeTimelineRowPainter.draw(
                        item: items[index],
                        layout: layouts[index],
                        in: rowFrame,
                        model: model,
                        isHovered: hoveredRow == index,
                        showsCompactTimestamp:
                            hoveredCompactTimestampRow == index,
                        hoveredMention:
                            hoveredMention?.itemIdentifier
                                == items[index].identifier
                            ? hoveredMention
                            : nil,
                        hoveredTextSpoiler:
                            hoveredTextSpoiler?.itemIdentifier
                                == items[index].identifier
                            ? hoveredTextSpoiler
                            : nil,
                        hoveredComponentButton:
                            hoveredComponentButton?.messageID
                                == items[index].messageID
                            ? hoveredComponentButton
                            : nil,
                        pressedComponentButton:
                            visualPressedComponentButton?.messageID
                                == items[index].messageID
                            ? visualPressedComponentButton
                            : nil,
                        componentButtonPressProgress:
                            visualPressedComponentButton?.messageID
                                == items[index].messageID
                            ? componentButtonPressProgress
                            : 0,
                        hoveredReactionID: hoveredReactionID(
                            inMessageAt: index
                        ),
                        isAddReactionHovered: isAddReactionHovered(
                            inMessageAt: index
                        ),
                        textSelection: textSelection,
                        revealedTextSpoilerState:
                            revealedTextSpoilerState,
                        spoilerRevealStore: spoilerRevealStore,
                        reactionCountTransitions: countTransitions
                    )
                } else {
                    let cachedBitmap = cachedBitmap(
                        for: items[index],
                        width: rowFrame.width
                    )
                    if NativeTimelineScrollingRenderPolicy
                        .usesDirectPainter(
                            isScrolling: suppressesHoverPresentation,
                            hasCachedBitmap: cachedBitmap != nil
                        )
                    {
                        NativeTimelineRowPainter.draw(
                            item: items[index],
                            layout: layouts[index],
                            in: rowFrame,
                            model: model,
                            isHovered: false,
                            revealedTextSpoilerState:
                                revealedTextSpoilerState,
                            spoilerRevealStore: spoilerRevealStore
                        )
                    } else {
                        (cachedBitmap ?? bitmap(
                            for: items[index],
                            layout: layouts[index],
                            width: rowFrame.width
                        )).draw(
                            in: rowFrame,
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: nil
                        )
                    }
                }
                if let hoveredCodeBlock,
                   hoveredCodeBlock.itemIdentifier
                    == items[index].identifier
                {
                    drawCodeBlockCopyControl(hoveredCodeBlock)
                }
            }
            index += 1
        }
    }

    private func drawCodeBlockCopyControl(
        _ target: CodeBlockPointerTarget
    ) {
        let buttonFrame = target.copyButtonFrame
        let point = currentMouseLocationInCanvas()
        let isButtonHovered = buttonFrame.contains(point)
        if isButtonHovered
            || pressedCodeBlockCopyButton?.itemIdentifier
                == target.itemIdentifier
                && pressedCodeBlockCopyButton?.region == target.region
                && pressedCodeBlockCopyButton?.rangeLocation
                    == target.rangeLocation
        {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(
                concentricRoundedRect: buttonFrame,
                cornerRadius: 4
            ).fill()
        }
        guard let symbol = NSImage(
            systemSymbolName: "doc.on.doc.fill",
            accessibilityDescription: "Copy code"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: 16,
                weight: .regular
            )
            .applying(
                NSImage.SymbolConfiguration(
                    paletteColors: [
                        NSColor.labelColor.withAlphaComponent(
                            isButtonHovered ? 1 : 0.88
                        ),
                    ]
                )
            )
        ) else { return }
        let iconFrame = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: symbol.size,
            alignmentRect: symbol.alignmentRect,
            in: buttonFrame.insetBy(dx: 6, dy: 6)
        )
        symbol.draw(
            in: iconFrame,
            from: .zero,
            operation: .sourceOver,
            fraction: isButtonHovered ? 1 : 0.88,
            respectFlipped: true,
            hints: nil
        )
    }

    private func textSpoilerRevealState(
        for identifier: NativeMessageTimelineItem.Identifier
    ) -> NativeTimelineTextSpoilerRevealState {
        var result = NativeTimelineTextSpoilerRevealState()
        guard let rowIndex = items.firstIndex(where: {
            $0.identifier == identifier
        }),
           layouts.indices.contains(rowIndex),
           let messageID = items[rowIndex].messageID
        else { return result }
        for selectable in selectableTextRegions(
            for: items[rowIndex],
            layout: layouts[rowIndex]
        ) {
            guard let contentID = textSpoilerContentID(
                for: selectable.region,
                layout: layouts[rowIndex]
            ) else { continue }
            for location in spoilerRevealStore.revealedTextLocations(
                messageID: messageID,
                contentID: contentID,
                contentHash: selectable.value.string.hashValue
            ) {
                result.reveal(
                    region: selectable.region,
                    rangeLocation: location
                )
            }
        }
        return result
    }

    private func textSpoilerRevealKey(
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        rangeLocation: Int
    ) -> NativeTimelineTextSpoilerRevealKey? {
        guard let rowIndex = items.firstIndex(where: {
            $0.identifier == itemIdentifier
        }),
           layouts.indices.contains(rowIndex),
           let messageID = items[rowIndex].messageID,
           let selectable = selectableTextRegions(
               for: items[rowIndex],
               layout: layouts[rowIndex]
           ).first(where: { $0.region == region }),
           let contentID = textSpoilerContentID(
               for: region,
               layout: layouts[rowIndex]
           )
        else { return nil }
        return NativeTimelineTextSpoilerRevealKey(
            messageID: messageID,
            contentID: contentID,
            contentHash: selectable.value.string.hashValue,
            rangeLocation: rangeLocation
        )
    }

    private func textSpoilerContentID(
        for region: NativeTimelineTextRegion,
        layout: NativeTimelineRowLayout
    ) -> String? {
        switch region {
        case .beginningTitle, .beginningDescription:
            return nil
        case .content:
            return "message-content"
        case let .embed(embedID, textIndex):
            return "embed:\(embedID):\(textIndex)"
        case let .component(layoutIndex, textIndex):
            guard layout.componentLayouts.indices.contains(layoutIndex),
                  layout.componentLayouts[layoutIndex]
                      .textRegions.indices.contains(textIndex)
            else { return nil }
            return "component:"
                + (
                    layout.componentLayouts[layoutIndex]
                        .textRegions[textIndex].contentID
                        ?? "\(layoutIndex):\(textIndex)"
                )
        }
    }

    private func drawHistorySkeleton(in dirtyRect: CGRect) {
        guard let presentation = historySkeleton,
              presentation.frame.intersects(dirtyRect)
        else { return }

        let frame = presentation.frame
        let clipped = frame.intersection(dirtyRect)
        guard !clipped.isNull, clipped.height > 0 else { return }

        let rowStride: CGFloat = 76
        let rowCount = max(1, Int(ceil(frame.height / rowStride)))
        let firstOrdinal = max(
            0,
            Int(floor((frame.maxY - clipped.maxY) / rowStride))
        )
        let lastOrdinal = min(
            rowCount - 1,
            max(
                firstOrdinal,
                Int(ceil((frame.maxY - clipped.minY) / rowStride))
            )
        )
        let avatarColor =
            NSColor.placeholderTextColor.withAlphaComponent(0.18)
        let primaryBarColor =
            NSColor.placeholderTextColor.withAlphaComponent(0.16)
        let secondaryBarColor =
            NSColor.placeholderTextColor.withAlphaComponent(0.11)
        let contentX: CGFloat = 64
        let maximumContentWidth = max(
            80,
            frame.width - contentX - 14
        )
        let authorWidths: [CGFloat] = [92, 126, 108, 148]
        let lineFractions: [[CGFloat]] = [
            [0.72],
            [0.91, 0.58],
            [0.84, 0.76, 0.42],
            [0.64, 0.88],
        ]

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clipped).addClip()

        for ordinal in firstOrdinal ... lastOrdinal {
            let rowTop =
                frame.maxY - CGFloat(ordinal + 1) * rowStride
            let avatarFrame = CGRect(
                x: 14,
                y: rowTop + 11,
                width: 38,
                height: 38
            )
            avatarColor.setFill()
            NSBezierPath(ovalIn: avatarFrame).fill()

            let authorWidth = min(
                maximumContentWidth * 0.45,
                authorWidths[ordinal % authorWidths.count]
            )
            primaryBarColor.setFill()
            NSBezierPath(
                roundedRect: CGRect(
                    x: contentX,
                    y: rowTop + 10,
                    width: authorWidth,
                    height: 10
                ),
                xRadius: 5,
                yRadius: 5
            ).fill()
            secondaryBarColor.setFill()
            NSBezierPath(
                roundedRect: CGRect(
                    x: contentX + authorWidth + 8,
                    y: rowTop + 12,
                    width: 38,
                    height: 7
                ),
                xRadius: 3.5,
                yRadius: 3.5
            ).fill()

            let fractions =
                lineFractions[ordinal % lineFractions.count]
            for (line, fraction) in fractions.enumerated() {
                NSBezierPath(
                    roundedRect: CGRect(
                        x: contentX,
                        y: rowTop + 28 + CGFloat(line) * 13,
                        width: max(
                            34,
                            maximumContentWidth * fraction
                        ),
                        height: 8
                    ),
                    xRadius: 4,
                    yRadius: 4
                ).fill()
            }
        }
    }

    func resetDrawTelemetry() {
        maximumDrawDuration = 0
        maximumRowRasterDuration = 0
        maximumRowRasterHeight = 0
    }

    func prewarmRows(above rect: CGRect, count: Int) {
        prewarmTask?.cancel()
        guard count > 0,
              let firstVisible = rowIndex(at: rect.minY),
              firstVisible > 0
        else {
            return
        }
        let lowerBound = max(0, firstVisible - count)
        let indexes = Array(stride(
            from: firstVisible - 1,
            through: lowerBound,
            by: -1
        ))
        prewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for index in indexes {
                guard !Task.isCancelled,
                      self.items.indices.contains(index),
                      self.layouts.indices.contains(index)
                else { return }
                // Prewarmed row bitmaps must participate in the same media
                // lifecycle as on-screen draws. Otherwise they can cache
                // placeholders before a row becomes visible and, when the
                // shared media store already has the image, no asynchronous
                // completion remains to invalidate that stale bitmap.
                self.requestMedia(
                    for: self.items[index],
                    at: index
                )
                _ = self.bitmap(
                    for: self.items[index],
                    layout: self.layouts[index],
                    width: self.bounds.width
                )
                // `Task.yield()` may immediately resume the same main-actor
                // task, allowing dozens of full-width CoreText/Core Graphics
                // rasters to bunch up before the next presentation pass.
                // A short real delay keeps prewarming inside the benchmark's
                // existing warm-up window without producing a visible
                // launch-to-scroll hitch.
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return
                }
            }
        }
    }

    private func bitmap(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout,
        width: CGFloat
    ) -> NSImage {
        if let cached = cachedBitmap(for: item, width: width) {
            return cached
        }
        let appearanceName = effectiveAppearance.name

        let rasterStart = ProcessInfo.processInfo.systemUptime
        let size = NSSize(width: width, height: layout.height)
        let scale = max(
            1,
            window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
        )
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(layout.height * scale)))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: representation)
        else {
            return NSImage(size: size)
        }
        NSGraphicsContext.saveGraphicsState()
        graphics.cgContext.scaleBy(x: scale, y: scale)
        graphics.cgContext.translateBy(x: 0, y: layout.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        let flippedGraphics = NSGraphicsContext(
            cgContext: graphics.cgContext,
            flipped: true
        )
        NSGraphicsContext.current = flippedGraphics
        NativeTimelineRowPainter.draw(
            item: item,
            layout: layout,
            in: CGRect(origin: .zero, size: size),
            model: model,
            isHovered: false,
            spoilerRevealStore: spoilerRevealStore
        )
        flippedGraphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let rasterDuration =
            ProcessInfo.processInfo.systemUptime - rasterStart
        if rasterDuration > maximumRowRasterDuration {
            maximumRowRasterDuration = rasterDuration
            maximumRowRasterHeight = layout.height
        }

        let mediaPinOwner = UUID()
        NativeTimelineMediaStore.shared.pinLoadedImages(
            for: mediaKeys(
                for: item,
                at: items.firstIndex(where: {
                    $0.identifier == item.identifier
                })
            ),
            owner: mediaPinOwner
        )
        let cost = max(1, Int(ceil(width * layout.height * 4 * scale * scale)))
        if let previous = bitmapCache[item.identifier] {
            bitmapCost -= previous.cost
            NativeTimelineMediaStore.shared.releasePinnedImages(
                owner: previous.mediaPinOwner
            )
        } else {
            bitmapInsertionOrder.append(item.identifier)
        }
        bitmapCache[item.identifier] = CachedRowBitmap(
            item: item,
            width: width,
            appearanceName: appearanceName,
            image: image,
            cost: cost,
            mediaPinOwner: mediaPinOwner
        )
        bitmapCost += cost
        evictBitmapsIfNeeded()
        return image
    }

    private func cachedBitmap(
        for item: NativeMessageTimelineItem,
        width: CGFloat
    ) -> NSImage? {
        guard let cached = bitmapCache[item.identifier],
              cached.item == item,
              abs(cached.width - width) < 0.5,
              cached.appearanceName == effectiveAppearance.name
        else { return nil }
        return cached.image
    }

    private func evictBitmapsIfNeeded() {
        while bitmapCost > Self.bitmapCostLimit,
              bitmapEvictionIndex < bitmapInsertionOrder.count
        {
            let identifier = bitmapInsertionOrder[bitmapEvictionIndex]
            bitmapEvictionIndex += 1
            if let removed = bitmapCache.removeValue(forKey: identifier) {
                bitmapCost -= removed.cost
                NativeTimelineMediaStore.shared.releasePinnedImages(
                    owner: removed.mediaPinOwner
                )
            }
        }
        if bitmapEvictionIndex > 1_024,
           bitmapEvictionIndex * 2 > bitmapInsertionOrder.count
        {
            bitmapInsertionOrder.removeFirst(bitmapEvictionIndex)
            bitmapEvictionIndex = 0
        }
    }

    private func clearBitmapCache(keepingCapacity: Bool) {
        for cached in bitmapCache.values {
            NativeTimelineMediaStore.shared.releasePinnedImages(
                owner: cached.mediaPinOwner
            )
        }
        bitmapCache.removeAll(keepingCapacity: keepingCapacity)
    }

    private func requestMedia(
        for item: NativeMessageTimelineItem,
        at index: Int
    ) {
        let identifier = item.identifier
        for key in mediaKeys(for: item, at: index) {
            NativeTimelineMediaStore.shared.request(
                key,
                subscriber: identifier
            ) { [weak self] in
                guard let self,
                      let currentIndex = self.items.firstIndex(where: {
                          $0.identifier == identifier
                      })
                else { return }
                self.invalidateBitmap(identifier)
                self.setNeedsDisplay(self.rowFrame(at: currentIndex))
            }
        }
    }

    private func mediaKeys(
        for item: NativeMessageTimelineItem,
        at index: Int?
    ) -> Set<NativeTimelineMediaKey> {
        guard let index,
              layouts.indices.contains(index),
              case let .message(row, _, _) = item
        else { return [] }
        let message = row.message
        let visibleEmbedCount =
            MessageEmbedPresentation.visibleEmbeds(for: message).count
        var keys: [NativeTimelineMediaKey] = []
        keys.reserveCapacity(
            1 + message.attachments.count + visibleEmbedCount
                + message.stickers.count
        )
        let author = model?.authorPresentation(for: message)
        if let url = author?.user.avatarURL ?? message.author.avatarURL {
            keys.append(.avatar(url))
        }
        if let url =
            author?.user.avatarDecorationURL
                ?? message.author.avatarDecorationURL
        {
            keys.append(.avatarDecoration(url))
        }
        if let url = message.interactionMetadata?.user?.avatarURL {
            keys.append(.avatar(url))
        }
        if let key = NativeTimelineReplyMediaPolicy.avatarKey(
            for: row.replyPreview
        ) {
            keys.append(key)
        }
        for region in layouts[index].linkedImageRegions {
            keys.append(.media(
                region.reference.displayURL,
                maximumPixelDimension: region.reference.isEmoji ? 96 : 720
            ))
        }
        if let model {
            let mentionResolver = MessageMentionResolver(
                model: model,
                message: message
            )
            for token in row.textPlan.preparedText?.tokens ?? [] {
                switch token {
                case let .customEmoji(emoji):
                    let reference = EmojiReference(rawToken: emoji.rawToken)
                    guard let url =
                        reference.id.flatMap({ model.customEmojiURLsByID[$0] })
                        ?? reference.imageURL(size: 64)
                    else { continue }
                    keys.append(.media(url, maximumPixelDimension: 64))
                case let .mention(mention):
                    if let url = mentionResolver.presentation(mention).avatarURL {
                        keys.append(.avatar(url))
                    }
                }
            }
        }
        for attachment in message.attachments {
            guard NativeTimelineSpoilerConcealmentPolicy
                .shouldLoadOrAnimate(
                    messageID: message.id,
                    contentID:
                        NativeTimelineComponentRevealKey
                            .attachmentComponentID(attachment.id),
                    isSpoiler: attachment.isSpoiler,
                    store: spoilerRevealStore
                )
            else { continue }
            switch attachment.mediaKind {
            case .image, .animatedImage, .video:
                keys.append(.media(attachment.proxyURL ?? attachment.url))
            case .audio, .file:
                break
            }
        }
        for region in layouts[index].embedRegions {
            for image in region.imageRegions {
                keys.append(
                    .media(
                        image.url,
                        maximumPixelDimension: image.maximumPixelDimension
                    )
                )
            }
            for textRegion in region.textRegions {
                let value = textRegion.text.value
                let range = NSRange(location: 0, length: value.length)
                value.enumerateAttribute(
                    .discordEmojiToken,
                    in: range
                ) { rawValue, _, _ in
                    guard let rawToken = rawValue as? String else { return }
                    let reference = EmojiReference(rawToken: rawToken)
                    let customURL = reference.id.flatMap { id in
                        model?.customEmojiURLsByID[id]
                    }
                    guard let url = customURL
                        ?? reference.imageURL(size: 64)
                    else { return }
                    keys.append(.media(url, maximumPixelDimension: 64))
                }
                value.enumerateAttribute(
                    .nativeTimelineMention,
                    in: range
                ) { rawValue, _, _ in
                    guard let mention =
                        (rawValue as? NativeTimelineMentionBox)?
                        .presentation,
                        let url = mention.avatarURL
                    else { return }
                    keys.append(.avatar(url))
                }
            }
            if !region.mediaIsVideo,
               let url = region.mediaURL
            {
                keys.append(.media(url))
            }
        }
        for componentLayout in layouts[index].componentLayouts {
            let hiddenContainerFrames =
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: componentLayout,
                        messageID: message.id,
                        store: spoilerRevealStore
                    )
            for image in componentLayout.images {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        image.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    ),
                      !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                          messageID: message.id,
                          contentID: image.componentID,
                          isSpoiler: image.isSpoiler,
                          store: spoilerRevealStore
                      )
                else { continue }
                keys.append(
                    .media(
                        image.displayURL,
                        maximumPixelDimension: image.maximumPixelDimension
                    )
                )
            }
            for media in componentLayout.media {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        media.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    ),
                      !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                          messageID: message.id,
                          contentID: media.componentID,
                          isSpoiler: media.isSpoiler,
                          store: spoilerRevealStore
                      )
                else { continue }
                keys.append(.media(media.displayURL))
            }
            for button in componentLayout.buttons {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        button.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    )
                else { continue }
                guard let emoji = button.emoji,
                      emoji.id != nil,
                      let url = emoji.imageURL(size: 32)
                else { continue }
                keys.append(.media(url, maximumPixelDimension: 64))
            }
            for textRegion in componentLayout.textRegions {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        textRegion.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    )
                else { continue }
                appendInlineMediaKeys(
                    from: textRegion.text.value,
                    model: model,
                    into: &keys
                )
            }
        }
        for sticker in message.stickers where sticker.format != .lottie {
            if let url = sticker.mediaURL {
                keys.append(.media(url, maximumPixelDimension: 384))
            }
        }
        for region in layouts[index].reactionRegions {
            let reference = region.reaction.emojiReference
            if let id = reference.id,
               let url = model?.customEmojiURLsByID[id]
                    ?? reference.imageURL(size: 64)
            {
                keys.append(.media(url, maximumPixelDimension: 64))
            }
            for avatar in region.avatarRegions {
                if let url = avatar.reactor.avatarURL {
                    keys.append(.avatar(url))
                }
            }
        }

        return Set(keys)
    }

    private func appendInlineMediaKeys(
        from value: NSAttributedString,
        model: AppModel?,
        into keys: inout [NativeTimelineMediaKey]
    ) {
        let range = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(
            .discordEmojiToken,
            in: range
        ) { rawValue, _, _ in
            guard let rawToken = rawValue as? String else { return }
            let reference = EmojiReference(rawToken: rawToken)
            let customURL = reference.id.flatMap { id in
                model?.customEmojiURLsByID[id]
            }
            guard let url = customURL
                ?? reference.imageURL(size: 64)
            else { return }
            keys.append(.media(url, maximumPixelDimension: 64))
        }
        value.enumerateAttribute(
            .nativeTimelineMention,
            in: range
        ) { rawValue, _, _ in
            guard let mention =
                (rawValue as? NativeTimelineMentionBox)?.presentation,
                let url = mention.avatarURL
            else { return }
            keys.append(.avatar(url))
        }
    }

    private func invalidateBitmap(
        _ identifier: NativeMessageTimelineItem.Identifier
    ) {
        guard let removed = bitmapCache.removeValue(forKey: identifier) else {
            return
        }
        bitmapCost -= removed.cost
        NativeTimelineMediaStore.shared.releasePinnedImages(
            owner: removed.mediaPinOwner
        )
    }

    override func updateTrackingAreas() {
        guard !suppressesHoverPresentation else {
            if let tracking {
                removeTrackingArea(tracking)
                self.tracking = nil
            }
            for area in rowTrackingAreas {
                removeTrackingArea(area)
            }
            rowTrackingAreas.removeAll(keepingCapacity: true)
            return
        }
        if let tracking {
            removeTrackingArea(tracking)
        }
        for area in rowTrackingAreas {
            removeTrackingArea(area)
        }
        rowTrackingAreas.removeAll(keepingCapacity: true)
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self,
            userInfo: ["nativeTimelineTrackingKind": "canvas"]
        )
        addTrackingArea(tracking)
        self.tracking = tracking
        installVisibleRowTrackingAreas()
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        guard !suppressesHoverPresentation else { return }
        super.resetCursorRects()
        guard var index = rowIndex(at: max(0, visibleRect.minY)) else {
            return
        }
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            if layouts.indices.contains(index) {
                for selectable in selectableTextRegions(
                    for: items[index],
                    layout: layouts[index]
                ) {
                    addCursorRect(
                        textSelectionInteractionFrame(
                            region: selectable.region,
                            frame: selectable.interactionFrame,
                            rowIndex: index
                        ),
                        cursor: .iBeam
                    )
                }
                for mention in mentionPointerRegions(at: index) {
                    addCursorRect(
                        mention.frame,
                        cursor: .pointingHand
                    )
                }
                for codeBlock in codeBlockPointerTargets(at: index) {
                    addCursorRect(
                        codeBlock.copyButtonFrame,
                        cursor: .pointingHand
                    )
                }
            }
            if layouts.indices.contains(index) {
                let rowOrigin = displayedRowOrigin(at: index)
                if case let .loader(isLoading, _) = items[index],
                   !isLoading,
                   let frame = layouts[index].loaderLayout?.controlFrame
                {
                    addCursorRect(
                        frame.offsetBy(dx: 0, dy: rowOrigin),
                        cursor: .pointingHand
                    )
                }
                if case let .message(row, _, _) = items[index],
                   row.startsGroup,
                   !row.message.type.hasGeneratedContent
                {
                    for frame in
                        NativeTimelineAuthorProfileGeometry.hitFrames(
                            avatarFrame: layouts[index].avatarFrame,
                            authorFrame: layouts[index].authorFrame
                        )
                    {
                        addCursorRect(
                            frame.offsetBy(dx: 0, dy: rowOrigin),
                            cursor: .pointingHand
                        )
                    }
                }
                if let frame = layouts[index]
                    .commandInvocationRegion?.profileFrame
                {
                    addCursorRect(
                        frame.offsetBy(dx: 0, dy: rowOrigin),
                        cursor: .pointingHand
                    )
                }
                if let frame = layouts[index]
                    .ephemeralRegion?.dismissFrame
                {
                    addCursorRect(
                        frame.offsetBy(dx: 0, dy: rowOrigin),
                        cursor: .pointingHand
                    )
                }
            }
            index += 1
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !suppressesHoverPresentation,
              editingMessageID == nil,
              event.trackingArea?.userInfo?["nativeTimelineTrackingKind"]
                as? String == "row",
              let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
              ] as? Int
        else { return }
        setHoveredRow(index)
        setHoveredCompactTimestampRow(
            compactTimestampRowIndex(
                at: currentMouseLocationInCanvas()
            )
        )
        setHoveredMention(
            mentionPointerHit(at: currentMouseLocationInCanvas())
        )
        setHoveredTextSpoiler(
            textSpoilerPointerHit(at: currentMouseLocationInCanvas())
        )
        setHoveredCodeBlock(
            codeBlockPointerHit(at: currentMouseLocationInCanvas())
        )
        setHoveredComponentButton(
            componentButtonPointerHit(
                at: currentMouseLocationInCanvas()
            )?.target
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard !suppressesHoverPresentation, editingMessageID == nil else {
            return
        }
        let point = currentMouseLocationInCanvas()
        setHoveredCompactTimestampRow(
            compactTimestampRowIndex(at: point)
        )
        setHoveredMention(mentionPointerHit(at: point))
        setHoveredTextSpoiler(textSpoilerPointerHit(at: point))
        setHoveredCodeBlock(codeBlockPointerHit(at: point))
        setHoveredComponentButton(
            componentButtonPointerHit(at: point)?.target
        )
        setHoveredReaction(
            reactionPointerHit(at: point),
            mouseLocationInScreen: NSEvent.mouseLocation
        )
    }

    override func mouseExited(with event: NSEvent) {
        let kind = event.trackingArea?.userInfo?[
            "nativeTimelineTrackingKind"
        ] as? String
        if kind == "row" {
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               hoveredRow == index
            {
                setHoveredRow(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               hoveredCompactTimestampRow == index
            {
                setHoveredCompactTimestampRow(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               hoveredMention?.itemIdentifier == items[index].identifier
            {
                setHoveredMention(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               hoveredTextSpoiler?.itemIdentifier
                    == items[index].identifier
            {
                setHoveredTextSpoiler(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               hoveredCodeBlock?.itemIdentifier
                    == items[index].identifier
            {
                setHoveredCodeBlock(nil)
            }
            if let index = event.trackingArea?.userInfo?[
                "nativeTimelineRowIndex"
            ] as? Int,
               items.indices.contains(index),
               items[index].messageID
                    == hoveredComponentButton?.messageID
            {
                setHoveredComponentButton(nil)
            }
            return
        }
        if kind == "canvas" {
            setHoveredCompactTimestampRow(nil)
            setHoveredMention(nil)
            setHoveredTextSpoiler(nil)
            setHoveredCodeBlock(nil)
            setHoveredComponentButton(nil)
            setHoveredReaction(nil)
            setHoveredRow(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard event.buttonNumber == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        pressedActivationTarget = nil
        if let target = codeBlockCopyButtonHit(at: point) {
            setHoveredCodeBlock(target)
            pressedCodeBlockCopyButton = target
            textSelectionGesture = nil
            didDragTextSelection = false
            setTextSelection(nil)
            return
        }
        if let hit = componentButtonPointerHit(at: point),
           !hit.region.isDisabled
        {
            setHoveredComponentButton(hit.target)
            pressedComponentButton = hit.target
            animateComponentButtonPress(
                hit.target,
                to: 1
            )
            return
        }
        pressedActivationTarget = pointerActivationTarget(at: point)
        if pressedActivationTarget?.supportsTextSelection == false {
            textSelectionGesture = nil
            didDragTextSelection = false
            setTextSelection(nil)
            return
        }
        guard let candidate = timelineTextCaret(
            at: point,
            itemIdentifier: nil,
            region: nil,
            clampsToText: true,
            requiresPointInTextContainer: true
        ) else {
            textSelectionGesture = nil
            didDragTextSelection = false
            setTextSelection(nil)
            return
        }
        textSelectionGesture = TextSelectionGesture(
            itemIdentifier: candidate.itemIdentifier,
            region: candidate.region,
            anchor: candidate.caret
        )
        didDragTextSelection = false
        if event.clickCount >= 3 {
            setTextSelection(NativeTimelineTextSelection(
                itemIdentifier: candidate.itemIdentifier,
                region: candidate.region,
                range: NSRange(
                    location: 0,
                    length: candidate.value.length
                )
            ))
        } else if event.clickCount == 2 {
            setTextSelection(NativeTimelineTextSelection(
                itemIdentifier: candidate.itemIdentifier,
                region: candidate.region,
                range: Self.wordRange(
                    at: candidate.caret,
                    in: candidate.value.string
                )
            ))
        } else {
            setTextSelection(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedCodeBlockCopyButton != nil {
            let point = convert(event.locationInWindow, from: nil)
            setHoveredCodeBlock(codeBlockPointerHit(at: point))
            return
        }
        if let pressedComponentButton {
            let point = convert(event.locationInWindow, from: nil)
            let hit = componentButtonPointerHit(at: point)
            setHoveredComponentButton(hit?.target)
            let isInside = hit?.target == pressedComponentButton
            animateComponentButtonPress(
                pressedComponentButton,
                to: isInside ? 1 : 0
            )
            return
        }
        guard let gesture = textSelectionGesture else {
            super.mouseDragged(with: event)
            return
        }
        didDragTextSelection = true
        _ = autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let candidate = timelineTextCaret(
            at: point,
            itemIdentifier: gesture.itemIdentifier,
            region: gesture.region,
            clampsToText: true,
            requiresPointInTextContainer: false
        ) else { return }
        let location = min(gesture.anchor, candidate.caret)
        let length = abs(candidate.caret - gesture.anchor)
        setTextSelection(
            length > 0
                ? NativeTimelineTextSelection(
                    itemIdentifier: gesture.itemIdentifier,
                    region: gesture.region,
                    range: NSRange(location: location, length: length)
                )
                : nil
        )
    }

    override func mouseUp(with event: NSEvent) {
        if let pressedCodeBlockCopyButton {
            let point = convert(event.locationInWindow, from: nil)
            let released = codeBlockCopyButtonHit(at: point)
            self.pressedCodeBlockCopyButton = nil
            setHoveredCodeBlock(codeBlockPointerHit(at: point))
            if released?.itemIdentifier
                    == pressedCodeBlockCopyButton.itemIdentifier,
               released?.region == pressedCodeBlockCopyButton.region,
               released?.rangeLocation
                    == pressedCodeBlockCopyButton.rangeLocation
            {
                Self.copyText(pressedCodeBlockCopyButton.content)
            }
            return
        }
        if let pressedComponentButton {
            let point = convert(event.locationInWindow, from: nil)
            let hit = componentButtonPointerHit(at: point)
            setHoveredComponentButton(hit?.target)
            self.pressedComponentButton = nil
            animateComponentButtonPress(
                pressedComponentButton,
                to: 0
            )
            if NativeTimelineComponentButtonActivationPolicy.activates(
                pressed: pressedComponentButton,
                released: hit?.target
            ), let hit
            {
                _ = activateComponentButton(
                    hit.region,
                    message: hit.message
                )
            }
            return
        }
        if textSelectionGesture != nil {
            let consumesClick =
                didDragTextSelection
                || (textSelection?.range.length ?? 0) > 0
            textSelectionGesture = nil
            didDragTextSelection = false
            if consumesClick {
                pressedActivationTarget = nil
                return
            }
        }
        let point = convert(event.locationInWindow, from: nil)
        let pressedActivationTarget = pressedActivationTarget
        self.pressedActivationTarget = nil
        guard NativeTimelinePointerActivationPolicy.activates(
            pressed: pressedActivationTarget,
            released: pointerActivationTarget(at: point)
        ) else { return }
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              let actions
        else { return }
        let item = items[index]
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        if case let .loader(isLoading, _) = item {
            if !isLoading,
               layouts[index].loaderLayout?.controlFrame.contains(local)
                    == true
            {
                actions.loadEarlier()
            }
            return
        }
        guard case let .message(row, _, _) = item else { return }
        let layout = layouts[index]
        if handleComponentClick(
            in: layout,
            message: row.message,
            point: local,
            rowIndex: index
        ) {
            return
        }
        if handleTextClick(
            in: layout,
            message: row.message,
            point: local,
            rowIdentifier: item.identifier
        ) {
            return
        }
        if let dismissFrame = layout.ephemeralRegion?.dismissFrame,
           dismissFrame.contains(local)
        {
            model?.dismissEphemeralMessage(row.message)
            return
        }
        if row.startsGroup,
           !row.message.type.hasGeneratedContent,
           let authorFrame =
               NativeTimelineAuthorProfileGeometry.hitFrame(
                   at: local,
                   avatarFrame: layout.avatarFrame,
                   authorFrame: layout.authorFrame
               )
        {
            let author =
                model?.authorPresentation(for: row.message).user
                ?? row.message.author
            showMessageProfile(
                for: author,
                anchor: authorFrame.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
            )
            return
        }
        if let invocation = layout.commandInvocationRegion,
           invocation.profileFrame.contains(local),
           let user = row.message.interactionMetadata?.user
        {
            showMessageProfile(
                for: user,
                anchor: invocation.profileFrame.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
            )
            return
        }
        if let replyFrame = layout.replyFrame,
           replyFrame.contains(local),
           let replyID = row.replyPreview?.messageID
        {
            actions.openReply(replyID)
            return
        }
        if let linkedImage = layout.linkedImageRegions.first(
            where: { $0.frame.contains(local) }
        ) {
            NSWorkspace.shared.open(linkedImage.reference.url)
            return
        }
        if let attachment = layout.attachmentRegions.first(
            where: { $0.frame.contains(local) }
        )?.attachment {
            let revealKey = NativeTimelineComponentRevealKey.attachment(
                messageID: row.id,
                attachmentID: attachment.id
            )
            if attachment.isSpoiler,
               !spoilerRevealStore.isMediaRevealed(revealKey)
            {
                reveal(revealKey, rowIndex: index)
            } else if let presentation =
                NativeTimelineMediaViewerPlan.attachments(
                    in: row.message,
                    selectedAttachmentID: attachment.id
                )
            {
                mediaViewerState.present(presentation)
            } else {
                NSWorkspace.shared.open(attachment.url)
            }
            return
        }
        if let embedRegion = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(local) == true
        }) {
            if let presentation = NativeTimelineMediaViewerPlan.embed(
                in: row.message,
                id: embedRegion.embedID
            ) {
                mediaViewerState.present(presentation)
            } else if let mediaURL = embedRegion.mediaURL {
                NSWorkspace.shared.open(mediaURL)
            }
            return
        }
        if let threadFrame = layout.threadFrame,
           threadFrame.contains(local),
           let thread = row.message.thread
        {
            actions.openThread(thread)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           let selectedText = selectedTextValue()
        {
            Self.copyText(selectedText)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func activateReactionPointerHit(_ hit: ReactionPointerHit) {
        switch hit.target {
        case .reaction:
            if let reaction = hit.reaction {
                actions?.react(reaction.emoji, hit.message)
            }
        case .add:
            showReactionPicker(
                for: hit.message,
                anchor: hit.frame,
                preferredEdge: .maxX
            )
        }
    }

    private func showMessageProfile(
        for user: User,
        anchor: CGRect
    ) {
        guard let model else { return }
        closeMentionPopover()
        closeMessageProfilePopover()
        model.showProfile(for: user)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MessageProfilePopoverContent(
                model: model,
                userID: user.id
            )
        )
        messageProfilePopover = popover
        popover.show(
            relativeTo: anchor,
            of: self,
            preferredEdge: .maxX
        )
    }

    private func closeMessageProfilePopover() {
        messageProfilePopover?.performClose(nil)
        messageProfilePopover = nil
    }

    private func showMentionProfile(
        for user: User,
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        closeMessageProfilePopover()
        model.showProfile(for: user)
        showMentionPopover(
            AnyView(
                MessageProfilePopoverContent(
                    model: model,
                    userID: user.id
                )
            ),
            anchor: anchor
        )
    }

    private func showMentionRole(
        _ roleID: RoleID,
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        closeMessageProfilePopover()
        model.showMembers(withRole: roleID)
        showMentionPopover(
            AnyView(
                RoleMembersPopover(
                    model: model,
                    roleID: roleID
                )
            ),
            anchor: anchor
        )
    }

    private func showMentionPopover(
        _ content: AnyView,
        anchor: StablePopoverAnchor
    ) {
        activeMentionPopoverAnchor = anchor
        mentionPopoverCoordinator.update(
            anchor: anchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .interactive,
            onDismiss: { [weak self] in
                self?.activeMentionPopoverAnchor = nil
            },
            content: content
        )
    }

    private func closeMentionPopover() {
        mentionPopoverCoordinator.close()
        activeMentionPopoverAnchor = nil
    }

    private func currentMouseLocationInCanvas() -> CGPoint {
        guard let window else { return .zero }
        return convert(
            window.convertPoint(fromScreen: NSEvent.mouseLocation),
            from: nil
        )
    }

    private func installReactionMouseMonitor() {
        guard reactionMouseMonitor == nil else { return }
        reactionMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.editingMessageID == nil
            else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            let hit = self.reactionPointerHit(at: point)
                ?? self.hoveredReaction.flatMap {
                self.reactionPointerHit(for: $0)
            }
            guard let hit else {
                return event
            }
            self.window?.makeFirstResponder(self)
            self.activateReactionPointerHit(hit)
            return nil
        }
    }

    private func removeReactionMouseMonitor() {
        guard let reactionMouseMonitor else { return }
        NSEvent.removeMonitor(reactionMouseMonitor)
        self.reactionMouseMonitor = nil
    }

    private func hoveredRowIndex(at point: CGPoint) -> Int? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index)
        else { return nil }
        guard case .message = items[index] else { return index }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        guard NativeTimelineHoverHitTesting.contains(
            local,
            in: layouts[index].highlightFrame
        ) else {
            return nil
        }
        return index
    }

    private func compactTimestampRowIndex(
        at point: CGPoint
    ) -> Int? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              case .message = items[index],
              NativeTimelineCompactTimestampHitTesting.contains(
                  point,
                  rowOrigin: displayedRowOrigin(at: index),
                  frame: layouts[index].compactTimestampFrame
              )
        else { return nil }
        return index
    }

    private func installVisibleRowTrackingAreas() {
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else { return }
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            if case .message = items[index],
               let highlight = layouts[index].highlightFrame
            {
                let paintedFrame = highlight.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
                // CoreText's optical text bounds sit one point below the
                // logical line box used by row layout. Align pointer ownership
                // with those visible bounds so the boundary between adjacent
                // messages is not perceived one point above the text.
                let frame = NativeTimelineHoverHitTesting.pointerFrame(
                    for: paintedFrame
                ) ?? paintedFrame
                if frame.intersects(visibleRect) {
                    let area = NSTrackingArea(
                        rect: frame,
                        options: [
                            .activeInKeyWindow,
                            .mouseEnteredAndExited,
                        ],
                        owner: self,
                        userInfo: [
                            "nativeTimelineTrackingKind": "row",
                            "nativeTimelineRowIndex": index,
                        ]
                    )
                    addTrackingArea(area)
                    rowTrackingAreas.append(area)
                }
            }
            index += 1
        }
    }

    private func synchronizeHoverWithCurrentPointer() {
        guard !suppressesHoverPresentation,
              editingMessageID == nil,
              window?.isKeyWindow == true
        else { return }
        let point = currentMouseLocationInCanvas()
        setHoveredRow(
            visibleRect.contains(point)
                ? hoveredRowIndex(at: point)
                : nil
        )
        setHoveredCompactTimestampRow(
            visibleRect.contains(point)
                ? compactTimestampRowIndex(at: point)
                : nil
        )
        setHoveredMention(
            visibleRect.contains(point)
                ? mentionPointerHit(at: point)
                : nil
        )
        setHoveredTextSpoiler(
            visibleRect.contains(point)
                ? textSpoilerPointerHit(at: point)
                : nil
        )
        setHoveredCodeBlock(
            visibleRect.contains(point)
                ? codeBlockPointerHit(at: point)
                : nil
        )
        setHoveredComponentButton(
            visibleRect.contains(point)
                ? componentButtonPointerHit(at: point)?.target
                : nil
        )
        setHoveredReaction(
            reactionPointerHit(at: point),
            mouseLocationInScreen: NSEvent.mouseLocation
        )
    }

    private func mentionPointerHit(
        at point: CGPoint
    ) -> NativeTimelineMentionHover? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              case .message = items[index]
        else { return nil }
        for mention in mentionPointerRegions(at: index)
        where mention.frame.contains(point) {
            return NativeTimelineMentionHover(
                itemIdentifier: items[index].identifier,
                region: mention.region,
                characterIndex: mention.characterIndex,
                rawToken: mention.rawToken
            )
        }
        return nil
    }

    private func textSpoilerPointerHit(
        at point: CGPoint
    ) -> NativeTimelineTextSpoilerHover? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              items[index].messageID != nil
        else { return nil }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        guard let hit = textPointerHit(
            in: layouts[index],
            point: local
        ),
              let spoilerRange = hit.hit.spoilerRange,
              let key = textSpoilerRevealKey(
                  itemIdentifier: items[index].identifier,
                  region: hit.region,
                  rangeLocation: spoilerRange.location
              ),
              !spoilerRevealStore.isTextRevealed(key)
        else { return nil }
        return NativeTimelineTextSpoilerHover(
            itemIdentifier: items[index].identifier,
            region: hit.region,
            rangeLocation: spoilerRange.location
        )
    }

    private func mentionPointerRegions(
        at index: Int
    ) -> [MentionPointerRegion] {
        guard items.indices.contains(index),
              layouts.indices.contains(index)
        else { return [] }
        let identifier = items[index].identifier
        if let cached = mentionPointerRegionCache[identifier] {
            return cached
        }
        let rowOrigin = displayedRowOrigin(at: index)
        let regions = selectableTextRegions(
            for: items[index],
            layout: layouts[index]
        ).flatMap { selectable in
            NativeTimelineTextHitTester.mentionRegions(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame
            ).map { mention in
                MentionPointerRegion(
                    region: selectable.region,
                    characterIndex: mention.characterIndex,
                    rawToken: mention.presentation.rawToken,
                    frame: mention.frame.offsetBy(
                        dx: 0,
                        dy: rowOrigin
                    )
                )
            }
        }
        mentionPointerRegionCache[identifier] = regions
        return regions
    }

    private func codeBlockPointerHit(
        at point: CGPoint
    ) -> CodeBlockPointerTarget? {
        guard let index = rowIndex(at: point.y) else { return nil }
        return codeBlockPointerTargets(at: index).first {
            $0.blockFrame.contains(point)
        }
    }

    private func codeBlockCopyButtonHit(
        at point: CGPoint
    ) -> CodeBlockPointerTarget? {
        guard let index = rowIndex(at: point.y) else { return nil }
        return codeBlockPointerTargets(at: index).first {
            $0.copyButtonFrame.contains(point)
        }
    }

    private func codeBlockPointerTargets(
        at index: Int
    ) -> [CodeBlockPointerTarget] {
        guard items.indices.contains(index),
              layouts.indices.contains(index)
        else { return [] }
        let identifier = items[index].identifier
        if let cached = codeBlockPointerRegionCache[identifier] {
            return cached
        }
        let rowOrigin = displayedRowOrigin(at: index)
        let targets = selectableTextRegions(
            for: items[index],
            layout: layouts[index]
        ).flatMap { selectable in
            NativeTimelineCodeBlockGeometry.regions(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame
            ).map { codeBlock in
                CodeBlockPointerTarget(
                    itemIdentifier: identifier,
                    region: selectable.region,
                    rangeLocation: codeBlock.range.location,
                    blockFrame: codeBlock.backgroundFrame.offsetBy(
                        dx: 0,
                        dy: rowOrigin
                    ),
                    copyButtonFrame:
                        codeBlock.copyButtonFrame.offsetBy(
                            dx: 0,
                            dy: rowOrigin
                        ),
                    content: codeBlock.content
                )
            }
        }
        codeBlockPointerRegionCache[identifier] = targets
        return targets
    }

    private func pointerActivationTarget(
        at point: CGPoint
    ) -> NativeTimelinePointerActivationTarget? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index)
        else { return nil }
        let item = items[index]
        let layout = layouts[index]
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        if case let .loader(isLoading, _) = item {
            guard !isLoading,
                  layout.loaderLayout?.controlFrame.contains(local) == true
            else { return nil }
            return .loader
        }
        guard case let .message(row, _, _) = item else { return nil }
        let message = row.message

        for componentLayout in layout.componentLayouts {
            for container in componentLayout.containers
            where container.isSpoiler && container.frame.contains(local) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: container.componentID
                )
                if !spoilerRevealStore.isMediaRevealed(key) {
                    return .componentReveal(
                        message.id,
                        container.componentID
                    )
                }
            }
            if let region = componentLayout.images.first(where: {
                $0.frame.contains(local)
            }) {
                return .componentImage(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.media.first(where: {
                $0.frame.contains(local)
            }) {
                return .componentMedia(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.files.first(where: {
                $0.frame.contains(local)
            }) {
                return .componentFile(
                    message.id,
                    region.componentID
                )
            }
            if let region = componentLayout.selects.first(where: {
                $0.frame.contains(local)
            }) {
                return .componentSelect(
                    message.id,
                    region.componentID
                )
            }
        }
        if let text = textPointerHit(in: layout, point: local) {
            if let spoilerRange = text.hit.spoilerRange {
                if let key = textSpoilerRevealKey(
                    itemIdentifier: item.identifier,
                    region: text.region,
                    rangeLocation: spoilerRange.location
                ), !spoilerRevealStore.isTextRevealed(key) {
                    return .textSpoiler(
                        message.id,
                        text.region,
                        rangeLocation: spoilerRange.location
                    )
                }
            }
            if let mention = text.hit.mention {
                return .textMention(
                    message.id,
                    text.region,
                    characterIndex: text.hit.characterIndex,
                    rawToken: mention.rawToken
                )
            }
            if let url = text.hit.url {
                return .textURL(
                    message.id,
                    text.region,
                    characterIndex: text.hit.characterIndex,
                    url: url
                )
            }
        }
        if layout.ephemeralRegion?.dismissFrame.contains(local) == true {
            return .ephemeralDismiss(message.id)
        }
        if row.startsGroup,
           !message.type.hasGeneratedContent,
           NativeTimelineAuthorProfileGeometry.hitFrame(
               at: local,
               avatarFrame: layout.avatarFrame,
               authorFrame: layout.authorFrame
           ) != nil
        {
            return .authorProfile(message.id)
        }
        if layout.commandInvocationRegion?.profileFrame.contains(local)
            == true
        {
            return .invocationProfile(message.id)
        }
        if layout.replyFrame?.contains(local) == true,
           let replyID = row.replyPreview?.messageID
        {
            return .reply(message.id, replyID)
        }
        if let region = layout.linkedImageRegions.first(where: {
            $0.frame.contains(local)
        }) {
            return .linkedImage(
                message.id,
                region.reference.url
            )
        }
        if let region = layout.attachmentRegions.first(where: {
            $0.frame.contains(local)
        }) {
            return .attachment(
                message.id,
                region.attachment.id
            )
        }
        if let region = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(local) == true
        }) {
            return .embedMedia(message.id, region.embedID)
        }
        if layout.threadFrame?.contains(local) == true,
           let thread = message.thread
        {
            return .thread(message.id, thread.id)
        }
        return nil
    }

    private func componentButtonPointerHit(
        at point: CGPoint
    ) -> ComponentButtonPointerHit? {
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              case let .message(row, _, _) = items[index]
        else { return nil }
        let rowOrigin = displayedRowOrigin(at: index)
        let local = CGPoint(
            x: point.x,
            y: point.y - rowOrigin
        )
        for layout in layouts[index].componentLayouts {
            if layout.containers.contains(where: { container in
                guard container.isSpoiler,
                      container.frame.contains(local)
                else { return false }
                return !spoilerRevealStore.isMediaRevealed(
                    NativeTimelineComponentRevealKey(
                        messageID: row.id,
                        componentID: container.componentID
                    )
                )
            }) {
                return nil
            }
            for region in layout.buttons
            where region.frame.contains(local) {
                return ComponentButtonPointerHit(
                    target: NativeTimelineComponentButtonTarget(
                        messageID: row.id,
                        componentID: region.componentID
                    ),
                    rowIndex: index,
                    message: row.message,
                    region: region,
                    frame: region.frame.offsetBy(
                        dx: 0,
                        dy: rowOrigin
                    )
                )
            }
        }
        return nil
    }

    private func reactionPointerHit(at point: CGPoint) -> ReactionPointerHit? {
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
        if let region = layouts[index].reactionRegions.first(where: {
            $0.frame.contains(local)
        }) {
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
        }
        if let frame = layouts[index].addReactionFrame,
           frame.contains(local)
        {
            return ReactionPointerHit(
                target: .add(messageID: row.id),
                rowIndex: index,
                message: row.message,
                reaction: nil,
                frame: frame.offsetBy(dx: 0, dy: rowOrigin)
            )
        }
        return nil
    }

    private func reactionPointerHit(
        for target: ReactionPointerTarget
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

    private func rowIndex(for target: ReactionPointerTarget) -> Int? {
        if let hoveredRow,
           items.indices.contains(hoveredRow),
           items[hoveredRow].messageID == target.messageID
        {
            return hoveredRow
        }
        return items.firstIndex { $0.messageID == target.messageID }
    }

    private func hoveredReactionID(inMessageAt index: Int) -> String? {
        guard items.indices.contains(index),
              let messageID = items[index].messageID,
              case let .reaction(targetMessageID, reactionID) = hoveredReaction,
              targetMessageID == messageID
        else { return nil }
        return reactionID
    }

    private func isAddReactionHovered(inMessageAt index: Int) -> Bool {
        guard items.indices.contains(index),
              let messageID = items[index].messageID,
              case let .add(targetMessageID) = hoveredReaction
        else { return false }
        return targetMessageID == messageID
    }

    private func reactionCountSnapshot() -> ReactionCountSnapshot? {
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

    private func reconcileReactionCountAnimations(
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

    private func scheduleInitialReactionCountCapture() {
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

    private func startReactionCountAnimation(
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
            ? .controlAccentColor
            : .labelColor
        let animationState = NativeTimelineReactionCountAnimationState(
            from: from,
            to: to
        )
        let root = AnyView(NativeTimelineReactionCountAnimationView(
            state: animationState,
            color: color
        ))
        let host = NativeTimelineReactionCountAnimationHost(rootView: root)
        let countFont = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
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
        DispatchQueue.main.async {
            @MainActor [weak host, weak animationState] in
            guard host?.superview != nil else { return }
            animationState?.start()
        }
        setNeedsDisplay(rowFrame(at: rowIndex))

        reactionCountAnimationTasks[key] = Task {
            @MainActor [weak self, weak host] in
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

    private func cancelReactionCountAnimations() {
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

    private func reconcileAnimatedMedia(
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
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceAnimatedMedia")

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
                layouts[index].embedRegions.compactMap {
                    region -> URL? in
                    guard region.mediaIsVideo,
                          region.mediaAutoplaysInline
                    else { return nil }
                    return region.mediaURL
                }
            )
            if !videoURLs.isEmpty {
                videoRows[identifier] = videoURLs
            }
            let stickerURLs = Set(row.message.stickers.compactMap {
                sticker -> URL? in
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
            reconcileInlineVideoOverlays(plays: !reduceMotion)
            reconcileLottieStickerOverlays(reduceMotion: reduceMotion)
        }
    }

    private func scheduleAnimatedMediaReconciliation() {
        animatedMediaReconcileTask?.cancel()
        animatedMediaReconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.animatedMediaReconcileTask = nil
            self.reconcileAnimatedMedia()
        }
    }

    private func startVisibleInlineVideosImmediately() {
        guard !suppressesHoverPresentation else { return }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceAnimatedMedia")
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            inlineVideoRows.removeAll()
            removeInlineVideoOverlays()
            return
        }

        var rows:
            [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
        var videoCount = 0
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY,
              videoCount < Self.maximumInlineVideoOverlayCount
        {
            guard layouts.indices.contains(index) else {
                index += 1
                continue
            }
            let urls = Set(layouts[index].embedRegions.compactMap {
                region -> URL? in
                guard region.mediaIsVideo,
                      region.mediaAutoplaysInline
                else { return nil }
                return region.mediaURL
            })
            if !urls.isEmpty {
                let remaining =
                    Self.maximumInlineVideoOverlayCount - videoCount
                let boundedURLs = Set(urls.prefix(remaining))
                rows[items[index].identifier] = boundedURLs
                videoCount += boundedURLs.count
            }
            index += 1
        }
        inlineVideoRows = rows
        reconcileInlineVideoOverlays(plays: !reduceMotion)
    }

    private struct DesiredAnimatedMediaOverlay {
        let key: AnimatedMediaOverlayKey
        let mediaFrame: CGRect
        let selectionFrame: CGRect?
        let cornerRadius: CGFloat
        let isLooping: Bool
        let opacity: CGFloat
        let fillsFrame: Bool
        let image: DecodedAnimatedImage
    }

    private static let maximumAnimatedMediaOverlayCount = 48

    private func reconcileAnimatedMediaOverlays(reduceMotion: Bool) {
        guard !reduceMotion,
              !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeAnimatedMediaOverlays()
            return
        }

        var desired: [DesiredAnimatedMediaOverlay] = []
        desired.reserveCapacity(Self.maximumAnimatedMediaOverlayCount)

        func append(
            row: NativeMessageTimelineItem.Identifier,
            role: AnimatedMediaOverlayRole,
            media: NativeTimelineMediaKey,
            frame: CGRect,
            selectionFrame: CGRect? = nil,
            cornerRadius: CGFloat,
            isLooping: Bool,
            opacity: CGFloat = 1,
            fillsFrame: Bool = false,
            allowsStaticImage: Bool = false
        ) {
            let image = allowsStaticImage
                ? NativeTimelineMediaStore.shared.decodedImage(for: media)
                : NativeTimelineMediaStore.shared
                    .decodedAnimatedImage(for: media)
            guard desired.count < Self.maximumAnimatedMediaOverlayCount,
                  animatedMediaRows[row]?.contains(media) == true,
                  let image
            else { return }
            desired.append(DesiredAnimatedMediaOverlay(
                key: AnimatedMediaOverlayKey(
                    row: row,
                    role: role,
                    media: media
                ),
                mediaFrame: frame,
                selectionFrame: selectionFrame,
                cornerRadius: cornerRadius,
                isLooping: isLooping,
                opacity: opacity,
                fillsFrame: fillsFrame,
                image: image
            ))
        }

        func appendInlineEmoji(
            row: NativeMessageTimelineItem.Identifier,
            role: (Int, Int) -> AnimatedMediaOverlayRole,
            value: NSAttributedString,
            framesetter: CTFramesetter,
            frame: CGRect,
            selectionRange: NSRange?
        ) {
            for (ordinal, region) in NativeTimelineInlineEmojiGeometry.regions(
                in: value,
                framesetter: framesetter,
                frame: frame,
                selectionRange: selectionRange
            ).enumerated() {
                let reference = EmojiReference(rawToken: region.rawToken)
                guard reference.isAnimated,
                      let url = reference.id.flatMap({
                          model?.customEmojiURLsByID[$0]
                      }) ?? reference.imageURL(size: 64)
                else { continue }
                append(
                    row: row,
                    role: role(ordinal, region.characterRange.location),
                    media: .media(url, maximumPixelDimension: 64),
                    frame: region.mediaFrame,
                    selectionFrame: region.selectionFrame,
                    cornerRadius: 0,
                    isLooping: true
                )
            }
        }

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY,
              desired.count < Self.maximumAnimatedMediaOverlayCount
        {
            guard layouts.indices.contains(index),
                  case let .message(row, _, _) = items[index]
            else {
                index += 1
                continue
            }
            let identifier = items[index].identifier
            let layout = layouts[index]
            guard animatedMediaRows[identifier] != nil else {
                index += 1
                continue
            }

            let author =
                model?.authorPresentation(for: row.message).user
                ?? row.message.author
            if let frame = layout.avatarFrame {
                if let url =
                    author.avatarURL
                        ?? row.message.author.avatarURL,
                   NativeTimelineAvatarPresentation
                    .shouldDecodeAnimation(for: url)
                {
                    append(
                        row: identifier,
                        role: .authorAvatar,
                        media: .avatar(url),
                        frame: frame,
                        cornerRadius: frame.width / 2,
                        isLooping: true,
                        fillsFrame: true
                    )
                }
                if let decorationURL =
                    author.avatarDecorationURL
                        ?? row.message.author.avatarDecorationURL
                {
                    append(
                        row: identifier,
                        role: .authorAvatarDecoration,
                        media: .avatarDecoration(decorationURL),
                        frame:
                            NativeTimelineAvatarPresentation
                                .decorationFrame(around: frame),
                        cornerRadius: 0,
                        isLooping: true,
                        allowsStaticImage: true
                    )
                }
            }
            if let preview = row.replyPreview,
               let url = preview.author.avatarURL,
               let replyFrame = layout.replyFrame,
               NativeTimelineAvatarPresentation
                .shouldDecodeAnimation(for: url)
            {
                let frame =
                    NativeTimelineAvatarPresentation
                        .replyAvatarFrame(in: replyFrame)
                append(
                    row: identifier,
                    role: .replyAvatar,
                    media: .avatar(url),
                    frame: frame,
                    cornerRadius: frame.width / 2,
                    isLooping: true,
                    fillsFrame: true
                )
            }
            if let frame = layout.commandInvocationRegion?.avatarFrame,
               let url = row.message.interactionMetadata?.user?.avatarURL,
               NativeTimelineAvatarPresentation
                .shouldDecodeAnimation(for: url)
            {
                append(
                    row: identifier,
                    role: .invocationAvatar,
                    media: .avatar(url),
                    frame: frame,
                    cornerRadius: frame.width / 2,
                    isLooping: true,
                    fillsFrame: true
                )
            }
            for reaction in layout.reactionRegions {
                for (avatarIndex, avatar) in
                    reaction.avatarRegions.enumerated()
                {
                    guard let url = avatar.reactor.avatarURL,
                          NativeTimelineAvatarPresentation
                            .shouldDecodeAnimation(for: url)
                    else { continue }
                    append(
                        row: identifier,
                        role: .reactionAvatar(
                            reaction.reaction.id,
                            avatarIndex
                        ),
                        media: .avatar(url),
                        frame: avatar.frame,
                        cornerRadius: avatar.frame.width / 2,
                        isLooping: true,
                        fillsFrame: true
                    )
                }
            }

            for (linkedIndex, region) in
                layout.linkedImageRegions.enumerated()
            where Self.isPotentiallyAnimated(region.reference.displayURL) {
                append(
                    row: identifier,
                    role: .linkedImage(linkedIndex),
                    media: .media(
                        region.reference.displayURL,
                        maximumPixelDimension:
                            region.reference.isEmoji ? 96 : 720
                    ),
                    frame: region.frame,
                    cornerRadius: region.reference.isEmoji ? 7 : 10,
                    isLooping: true
                )
            }

            for region in layout.attachmentRegions
            where region.attachment.mediaKind == .animatedImage {
                append(
                    row: identifier,
                    role: .attachment(region.attachment.id),
                    media: .media(
                        region.attachment.proxyURL ?? region.attachment.url
                    ),
                    frame: region.frame,
                    cornerRadius: 8,
                    isLooping: true,
                    opacity: CGFloat(
                        MessageOutboxPresentation.mediaOpacity(
                            for: row.message.outboxState
                        )
                    )
                )
            }

            if let contentFrame = layout.contentFrame,
               let attributedContent = layout.attributedContent,
               let framesetter = layout.contentFramesetter
            {
                let drawingFrame = NativeTimelineTextGeometry
                    .messageContentDrawingFrame(contentFrame)
                appendInlineEmoji(
                    row: identifier,
                    role: { _, location in .messageEmoji(location) },
                    value: attributedContent,
                    framesetter: framesetter,
                    frame: drawingFrame,
                    selectionRange:
                        textSelection?.itemIdentifier
                            == .message(row.message.id)
                            && textSelection?.region == .content
                            ? textSelection?.range
                            : nil
                )
            }

            for embed in layout.embedRegions {
                for (imageIndex, imageRegion) in
                    embed.imageRegions.enumerated()
                where Self.isPotentiallyAnimated(imageRegion.url) {
                    append(
                        row: identifier,
                        role: .embedImage(embed.embedID, imageIndex),
                        media: .media(
                            imageRegion.url,
                            maximumPixelDimension:
                                imageRegion.maximumPixelDimension
                        ),
                        frame: imageRegion.frame,
                        cornerRadius: imageRegion.cornerRadius,
                        isLooping: false
                    )
                }
                if !embed.mediaIsVideo,
                   let mediaURL = embed.mediaURL,
                   let mediaFrame = embed.mediaFrame,
                   Self.isPotentiallyAnimated(mediaURL)
                {
                    append(
                        row: identifier,
                        role: .embedMedia(embed.embedID),
                        media: .media(mediaURL),
                        frame: mediaFrame,
                        cornerRadius: 8,
                        isLooping: true
                    )
                }
                for (textIndex, textRegion) in
                    embed.textRegions.enumerated()
                {
                    var drawingFrame = textRegion.frame
                    drawingFrame.size.height +=
                        textRegion.text.layoutHeightAdjustment
                    appendInlineEmoji(
                        row: identifier,
                        role: { _, location in
                            .embedEmoji(
                                embed.embedID,
                                textIndex,
                                location
                            )
                        },
                        value: textRegion.text.value,
                        framesetter: textRegion.text.framesetter,
                        frame: drawingFrame,
                        selectionRange:
                            textSelection?.itemIdentifier
                                == .message(row.message.id)
                                && textSelection?.region == .embed(
                                    embedID: embed.embedID,
                                    textIndex: textIndex
                                )
                            ? textSelection?.range
                            : nil
                    )
                }
            }

            for (componentIndex, component) in
                layout.componentLayouts.enumerated()
            {
                for imageRegion in component.images
                where Self.isPotentiallyAnimated(
                    imageRegion.displayURL
                ) {
                    append(
                        row: identifier,
                        role: .componentImage(
                            componentIndex,
                            imageRegion.componentID
                        ),
                        media: .media(
                            imageRegion.displayURL,
                            maximumPixelDimension:
                                imageRegion.maximumPixelDimension
                        ),
                        frame: imageRegion.frame,
                        cornerRadius: imageRegion.cornerRadius,
                        isLooping: false
                    )
                }
                for mediaRegion in component.media
                where !mediaRegion.isVideo
                    && Self.isPotentiallyAnimated(
                        mediaRegion.displayURL
                    )
                {
                    append(
                        row: identifier,
                        role: .componentMedia(
                            componentIndex,
                            mediaRegion.componentID
                        ),
                        media: .media(mediaRegion.displayURL),
                        frame: mediaRegion.frame,
                        cornerRadius: 8,
                        isLooping: true
                    )
                }
                for (textIndex, textRegion) in
                    component.textRegions.enumerated()
                {
                    var drawingFrame = textRegion.frame
                    drawingFrame.size.height +=
                        textRegion.text.layoutHeightAdjustment
                    appendInlineEmoji(
                        row: identifier,
                        role: { _, location in
                            .componentEmoji(
                                componentIndex,
                                textIndex,
                                location
                            )
                        },
                        value: textRegion.text.value,
                        framesetter: textRegion.text.framesetter,
                        frame: drawingFrame,
                        selectionRange:
                            textSelection?.itemIdentifier
                                == .message(row.message.id)
                                && textSelection?.region == .component(
                                    layoutIndex: componentIndex,
                                    textIndex: textIndex
                                )
                            ? textSelection?.range
                            : nil
                    )
                }
                for button in component.buttons {
                    guard let emoji = button.emoji,
                          emoji.isAnimated,
                          let url = emoji.imageURL(size: 32)
                    else { continue }
                    let box = CGRect(
                        x: button.frame.minX + 12,
                        y: button.frame.midY
                            - DiscordComponentEmojiMetrics.buttonSize / 2,
                        width: DiscordComponentEmojiMetrics.buttonSize,
                        height: DiscordComponentEmojiMetrics.buttonSize
                    )
                    let opticalInset = (
                        DiscordComponentEmojiMetrics.buttonSize
                            - DiscordComponentEmojiMetrics.opticalSize(
                                for: DiscordComponentEmojiMetrics.buttonSize
                            )
                    ) / 2
                    append(
                        row: identifier,
                        role: .componentButton(
                            componentIndex,
                            button.componentID
                        ),
                        media: .media(
                            url,
                            maximumPixelDimension: 64
                        ),
                        frame: box.insetBy(
                            dx: opticalInset,
                            dy: opticalInset
                        ),
                        cornerRadius: 3,
                        isLooping: true
                    )
                }
            }

            for (stickerIndex, sticker) in
                row.message.stickers.enumerated()
            where sticker.format == .apng || sticker.format == .gif {
                guard layout.stickerFrames.indices.contains(stickerIndex),
                      let url = sticker.mediaURL
                else { continue }
                append(
                    row: identifier,
                    role: .sticker(sticker.id),
                    media: .media(
                        url,
                        maximumPixelDimension: 384
                    ),
                    frame: layout.stickerFrames[stickerIndex],
                    cornerRadius: 8,
                    isLooping: true
                )
            }

            for reaction in layout.reactionRegions {
                let reference = reaction.reaction.emojiReference
                guard reference.isAnimated,
                      let url = reference.id.flatMap({
                          model?.customEmojiURLsByID[$0]
                      }) ?? reference.imageURL(size: 64)
                else { continue }
                append(
                    row: identifier,
                    role: .reaction(reaction.reaction.id),
                    media: .media(
                        url,
                        maximumPixelDimension: 64
                    ),
                    frame: reaction.emojiFrame,
                    cornerRadius: 0,
                    isLooping: true
                )
            }
            index += 1
        }

        let desiredKeys = Set(desired.map(\.key))
        for key in Array(animatedMediaOverlays.keys)
        where !desiredKeys.contains(key) {
            animatedMediaOverlays.removeValue(forKey: key)?
                .removeFromSuperview()
        }

        var didCreateOverlay = false
        for item in desired {
            let rowOrigin: CGFloat
            guard let rowIndex = items.firstIndex(where: {
                $0.identifier == item.key.row
            }) else { continue }
            rowOrigin = displayedRowOrigin(at: rowIndex)
            let mediaFrame = item.mediaFrame.offsetBy(
                dx: 0,
                dy: rowOrigin
            )
            let selectionFrame = item.selectionFrame?.offsetBy(
                dx: 0,
                dy: rowOrigin
            )
            let hostFrame = selectionFrame.map {
                mediaFrame.union($0)
            } ?? mediaFrame
            let localMediaFrame = mediaFrame.offsetBy(
                dx: -hostFrame.minX,
                dy: -hostFrame.minY
            )
            let localSelectionFrame = selectionFrame?.offsetBy(
                dx: -hostFrame.minX,
                dy: -hostFrame.minY
            )
            let overlay: NativeTimelineAnimatedMediaOverlay
            if let existing = animatedMediaOverlays[item.key] {
                overlay = existing
            } else {
                overlay = NativeTimelineAnimatedMediaOverlay(
                    frame: hostFrame
                )
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                animatedMediaOverlays[item.key] = overlay
                didCreateOverlay = true
            }
            overlay.frame = hostFrame
            overlay.display(
                item.image,
                mediaFrame: localMediaFrame,
                selectionFrame: localSelectionFrame,
                cornerRadius: item.cornerRadius,
                isLooping: item.isLooping,
                opacity: item.opacity,
                fillsFrame: item.fillsFrame
            )
        }
        if didCreateOverlay {
            // A decoration can decode before its avatar (or vice versa).
            // Restore the desired order whenever a late result creates a new
            // overlay so decorations always remain above avatar frames while
            // the media viewer remains the topmost interaction surface.
            for item in desired {
                guard let overlay = animatedMediaOverlays[item.key] else {
                    continue
                }
                overlay.removeFromSuperview()
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
            }
        }
        // Animated frames are native subviews while spoiler materials are
        // separate native overlays. Loading may complete after the spoiler
        // was installed, so restore the required preview < animation <
        // spoiler stacking order deterministically.
        for spoiler in spoilerOverlays.values {
            addSubview(
                spoiler,
                positioned: .below,
                relativeTo: mediaViewerHost
            )
        }
    }

    private func positionAnimatedMediaOverlays() {
        guard !animatedMediaOverlays.isEmpty else { return }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceAnimatedMedia")
        reconcileAnimatedMediaOverlays(reduceMotion: reduceMotion)
    }

    private func removeAnimatedMediaOverlays() {
        for overlay in animatedMediaOverlays.values {
            overlay.removeFromSuperview()
        }
        animatedMediaOverlays.removeAll()
    }

    private static let maximumLoadingIndicatorCount = 32

    private func reconcileLoadingIndicators() {
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeLoadingIndicators()
            return
        }

        var desired:
            [NativeMessageTimelineItem.Identifier: CGRect] = [:]
        desired.reserveCapacity(Self.maximumLoadingIndicatorCount)
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY,
              desired.count < Self.maximumLoadingIndicatorCount
        {
            if layouts.indices.contains(index),
               let frame = layouts[index].loadingIndicatorFrame
            {
                desired[items[index].identifier] = frame.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
            }
            index += 1
        }

        let desiredKeys = Set(desired.keys)
        for key in Array(loadingIndicators.keys)
        where !desiredKeys.contains(key) {
            loadingIndicators.removeValue(forKey: key)?
                .removeFromSuperview()
        }
        for (key, frame) in desired {
            let indicator: NativeTimelineLoadingIndicator
            if let existing = loadingIndicators[key] {
                indicator = existing
            } else {
                indicator = NativeTimelineLoadingIndicator(frame: frame)
                addSubview(
                    indicator,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                loadingIndicators[key] = indicator
            }
            if case .loader = key {
                indicator.controlSize = .small
            } else {
                indicator.controlSize = .mini
            }
            indicator.frame = frame
        }
    }

    private func removeLoadingIndicators() {
        for indicator in loadingIndicators.values {
            indicator.removeFromSuperview()
        }
        loadingIndicators.removeAll()
    }

    private static let maximumInlineVideoOverlayCount = 4

    private func reconcileInlineVideoOverlays(plays: Bool) {
        var desired: [(InlineVideoOverlayKey, CGRect)] = []
        desired.reserveCapacity(Self.maximumInlineVideoOverlayCount)

        guard var index = rowIndex(at: max(0, visibleRect.minY)) else {
            removeInlineVideoOverlays()
            return
        }
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            let identifier = items[index].identifier
            if let urls = inlineVideoRows[identifier],
               layouts.indices.contains(index)
            {
                for region in layouts[index].embedRegions {
                    guard region.mediaIsVideo,
                          region.mediaAutoplaysInline,
                          let url = region.mediaURL,
                          urls.contains(url),
                          let frame = region.mediaFrame
                    else { continue }
                    desired.append((
                        InlineVideoOverlayKey(
                            row: identifier,
                            embedID: region.embedID,
                            url: url
                        ),
                        frame.offsetBy(
                            dx: 0,
                            dy: displayedRowOrigin(at: index)
                        )
                    ))
                    if desired.count == Self.maximumInlineVideoOverlayCount {
                        break
                    }
                }
            }
            if desired.count == Self.maximumInlineVideoOverlayCount {
                break
            }
            index += 1
        }

        let desiredKeys = Set(desired.map(\.0))
        for key in Array(inlineVideoOverlays.keys)
        where !desiredKeys.contains(key) {
            guard let overlay = inlineVideoOverlays.removeValue(forKey: key)
            else { continue }
            overlay.stop()
            overlay.removeFromSuperview()
        }
        for (key, frame) in desired {
            let overlay: NativeTimelineInlineVideoOverlay
            if let existing = inlineVideoOverlays[key] {
                overlay = existing
            } else {
                overlay = NativeTimelineInlineVideoOverlay(frame: frame)
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                inlineVideoOverlays[key] = overlay
            }
            overlay.frame = frame
            overlay.display(key.url, plays: plays)
        }
    }

    private func positionInlineVideoOverlays() {
        var removed: [InlineVideoOverlayKey] = []
        for (key, overlay) in inlineVideoOverlays {
            guard let index = items.firstIndex(where: {
                $0.identifier == key.row
            }),
               layouts.indices.contains(index),
               let frame = layouts[index].embedRegions.first(where: {
                   $0.embedID == key.embedID
                       && $0.mediaURL == key.url
               })?.mediaFrame
            else {
                overlay.stop()
                overlay.removeFromSuperview()
                removed.append(key)
                continue
            }
            overlay.frame = frame.offsetBy(
                dx: 0,
                dy: displayedRowOrigin(at: index)
            )
        }
        for key in removed {
            inlineVideoOverlays[key] = nil
        }
    }

    private func removeInlineVideoOverlays() {
        for overlay in inlineVideoOverlays.values {
            overlay.stop()
            overlay.removeFromSuperview()
        }
        inlineVideoOverlays.removeAll()
    }

    private static let maximumLottieStickerOverlayCount = 4

    private func reconcileLottieStickerOverlays(reduceMotion: Bool) {
        var desired: [(LottieStickerOverlayKey, CGRect)] = []
        desired.reserveCapacity(Self.maximumLottieStickerOverlayCount)

        guard var index = rowIndex(at: max(0, visibleRect.minY)) else {
            removeLottieStickerOverlays()
            return
        }
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            let identifier = items[index].identifier
            if let urls = lottieStickerRows[identifier],
               layouts.indices.contains(index),
               case let .message(row, _, _) = items[index]
            {
                for (sticker, frame) in zip(
                    row.message.stickers,
                    layouts[index].stickerFrames
                ) {
                    guard sticker.format == .lottie,
                          let url = sticker.mediaURL,
                          urls.contains(url)
                    else { continue }
                    desired.append((
                        LottieStickerOverlayKey(
                            row: identifier,
                            stickerID: sticker.id,
                            url: url
                        ),
                        frame.offsetBy(
                            dx: 0,
                            dy: displayedRowOrigin(at: index)
                        )
                    ))
                    if desired.count == Self.maximumLottieStickerOverlayCount {
                        break
                    }
                }
            }
            if desired.count == Self.maximumLottieStickerOverlayCount {
                break
            }
            index += 1
        }

        let desiredKeys = Set(desired.map(\.0))
        for key in Array(lottieStickerOverlays.keys)
        where !desiredKeys.contains(key) {
            guard let overlay = lottieStickerOverlays.removeValue(forKey: key)
            else { continue }
            overlay.stop()
            overlay.removeFromSuperview()
        }
        for (key, frame) in desired {
            let overlay: NativeTimelineLottieStickerOverlay
            if let existing = lottieStickerOverlays[key] {
                overlay = existing
            } else {
                overlay = NativeTimelineLottieStickerOverlay(frame: frame)
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                lottieStickerOverlays[key] = overlay
            }
            overlay.frame = frame
            overlay.display(key.url, reduceMotion: reduceMotion)
        }
    }

    private func positionLottieStickerOverlays() {
        var removed: [LottieStickerOverlayKey] = []
        for (key, overlay) in lottieStickerOverlays {
            guard let index = items.firstIndex(where: {
                $0.identifier == key.row
            }),
               layouts.indices.contains(index),
               case let .message(row, _, _) = items[index],
               let stickerIndex = row.message.stickers.firstIndex(where: {
                   $0.id == key.stickerID && $0.mediaURL == key.url
               }),
               layouts[index].stickerFrames.indices.contains(stickerIndex)
            else {
                overlay.stop()
                overlay.removeFromSuperview()
                removed.append(key)
                continue
            }
            overlay.frame = layouts[index].stickerFrames[stickerIndex]
                .offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
        }
        for key in removed {
            lottieStickerOverlays[key] = nil
        }
    }

    private func removeLottieStickerOverlays() {
        for overlay in lottieStickerOverlays.values {
            overlay.stop()
            overlay.removeFromSuperview()
        }
        lottieStickerOverlays.removeAll()
    }

    private func reconcileSpoilerOverlays() {
        typealias Desired = (
            key: NativeTimelineComponentRevealKey,
            frame: CGRect,
            presentation: NativeTimelineSpoilerOverlayPresentation
        )
        var desired: [Desired] = []
        desired.reserveCapacity(16)
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeSpoilerOverlays()
            return
        }

        func append(
            _ key: NativeTimelineComponentRevealKey,
            frame: CGRect,
            cornerRadius: CGFloat,
            rowOrigin: CGFloat
        ) {
            guard !spoilerRevealStore.isMediaRevealed(key)
            else { return }
            desired.append((
                key,
                frame.offsetBy(dx: 0, dy: rowOrigin),
                NativeTimelineSpoilerOverlayPresentation(
                    cornerRadius: cornerRadius
                )
            ))
        }

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            guard layouts.indices.contains(index),
                  case let .message(row, _, _) = items[index]
            else {
                index += 1
                continue
            }
            let message = row.message
            let rowOrigin = displayedRowOrigin(at: index)
            for region in layouts[index].attachmentRegions
            where region.attachment.isSpoiler {
                append(
                    .attachment(
                        messageID: message.id,
                        attachmentID: region.attachment.id
                    ),
                    frame: region.frame,
                    cornerRadius: 8,
                    rowOrigin: rowOrigin
                )
            }
            for component in layouts[index].componentLayouts {
                let hiddenContainerFrames =
                    NativeTimelineSpoilerConcealmentPolicy
                        .hiddenContainerFrames(
                            in: component,
                            messageID: message.id,
                            store: spoilerRevealStore
                        )
                for container in component.containers
                where hiddenContainerFrames.contains(container.frame) {
                    let key = NativeTimelineComponentRevealKey(
                        messageID: message.id,
                        componentID: container.componentID
                    )
                    append(
                        key,
                        frame: container.frame,
                        cornerRadius:
                            DiscordRichMessageMetrics.cardCornerRadius,
                        rowOrigin: rowOrigin
                    )
                }
                for region in component.images
                where region.isSpoiler
                    && !hiddenContainerFrames.contains(where: {
                        $0.contains(
                            CGPoint(
                                x: region.frame.midX,
                                y: region.frame.midY
                            )
                        )
                    }) {
                    append(
                        NativeTimelineComponentRevealKey(
                            messageID: message.id,
                            componentID: region.componentID
                        ),
                        frame: region.frame,
                        cornerRadius: region.cornerRadius,
                        rowOrigin: rowOrigin
                    )
                }
                for region in component.media
                where region.isSpoiler
                    && !hiddenContainerFrames.contains(where: {
                        $0.contains(
                            CGPoint(
                                x: region.frame.midX,
                                y: region.frame.midY
                            )
                        )
                    }) {
                    append(
                        NativeTimelineComponentRevealKey(
                            messageID: message.id,
                            componentID: region.componentID
                        ),
                        frame: region.frame,
                        cornerRadius: 8,
                        rowOrigin: rowOrigin
                    )
                }
                for region in component.files
                where region.isSpoiler
                    && !hiddenContainerFrames.contains(where: {
                        $0.contains(
                            CGPoint(
                                x: region.frame.midX,
                                y: region.frame.midY
                            )
                        )
                    }) {
                    append(
                        NativeTimelineComponentRevealKey(
                            messageID: message.id,
                            componentID: region.componentID
                        ),
                        frame: region.frame,
                        cornerRadius:
                            DiscordRichMessageMetrics.cardCornerRadius,
                        rowOrigin: rowOrigin
                    )
                }
            }
            index += 1
        }

        let desiredKeys = Set(desired.map(\.key))
        for key in Array(spoilerOverlays.keys)
        where !desiredKeys.contains(key) {
            spoilerOverlays.removeValue(forKey: key)?.removeFromSuperview()
            spoilerOverlayPresentations[key] = nil
        }
        for item in desired {
            let overlay: NativeTimelineSpoilerOverlayHost
            if let existing = spoilerOverlays[item.key],
               spoilerOverlayPresentations[item.key] == item.presentation
            {
                overlay = existing
            } else {
                spoilerOverlays.removeValue(forKey: item.key)?
                    .removeFromSuperview()
                overlay = NativeTimelineSpoilerOverlayHost(
                    frame: item.frame,
                    cornerRadius: item.presentation.cornerRadius
                ) { [weak self] in
                    self?.reveal(item.key)
                }
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                spoilerOverlays[item.key] = overlay
                spoilerOverlayPresentations[item.key] = item.presentation
            }
            overlay.frame = item.frame
        }
    }

    private func positionSpoilerOverlays() {
        guard !spoilerOverlays.isEmpty else { return }
        reconcileSpoilerOverlays()
    }

    private func removeSpoilerOverlays() {
        for overlay in spoilerOverlays.values {
            overlay.removeFromSuperview()
        }
        spoilerOverlays.removeAll()
        spoilerOverlayPresentations.removeAll()
    }

    private func scheduleAnimatedMediaScrollReconciliation() {
        guard animatedMediaScrollReconcileTask == nil else { return }
        animatedMediaScrollReconcileTask = Task {
            @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.animatedMediaScrollReconcileTask = nil
            guard self.suppressesHoverPresentation else { return }
            self.reconcileAnimatedMedia(allowsScrolling: true)
        }
    }

    private func animatedMediaKeys(
        for row: MessageRowPresentation,
        layout: NativeTimelineRowLayout
    ) -> Set<NativeTimelineMediaKey> {
        let message = row.message
        var keys: Set<NativeTimelineMediaKey> = []

        let author =
            model?.authorPresentation(for: message).user
            ?? message.author
        if layout.avatarFrame != nil {
            if let url =
                author.avatarURL
                    ?? message.author.avatarURL,
               NativeTimelineAvatarPresentation
                .shouldDecodeAnimation(for: url)
            {
                keys.insert(.avatar(url))
            }
            if let url =
                author.avatarDecorationURL
                    ?? message.author.avatarDecorationURL
            {
                // Discord serves both static PNG and animated APNG decoration
                // assets from this route. Decode only for visible rows; the
                // media store discards single-frame results from overlay use.
                keys.insert(.avatarDecoration(url))
            }
        }
        if layout.replyFrame != nil,
           let url = row.replyPreview?.author.avatarURL,
           NativeTimelineAvatarPresentation
            .shouldDecodeAnimation(for: url)
        {
            keys.insert(.avatar(url))
        }
        if layout.commandInvocationRegion?.avatarFrame != nil,
           let url = message.interactionMetadata?.user?.avatarURL,
           NativeTimelineAvatarPresentation
            .shouldDecodeAnimation(for: url)
        {
            keys.insert(.avatar(url))
        }
        for reaction in layout.reactionRegions {
            for avatar in reaction.avatarRegions {
                if let url = avatar.reactor.avatarURL,
                   NativeTimelineAvatarPresentation
                    .shouldDecodeAnimation(for: url)
                {
                    keys.insert(.avatar(url))
                }
            }
        }

        for region in layout.linkedImageRegions
        where Self.isPotentiallyAnimated(region.reference.displayURL) {
            keys.insert(.media(
                region.reference.displayURL,
                maximumPixelDimension: region.reference.isEmoji ? 96 : 720
            ))
        }
        for attachment in message.attachments
        where attachment.mediaKind == .animatedImage {
            if NativeTimelineSpoilerConcealmentPolicy
                .shouldLoadOrAnimate(
                    messageID: message.id,
                    contentID:
                        NativeTimelineComponentRevealKey
                            .attachmentComponentID(attachment.id),
                    isSpoiler: attachment.isSpoiler,
                    store: spoilerRevealStore
                ) {
                keys.insert(.media(attachment.proxyURL ?? attachment.url))
            }
        }
        if let model {
            for token in row.textPlan.preparedText?.tokens ?? [] {
                guard case let .customEmoji(emoji) = token else { continue }
                let reference = EmojiReference(rawToken: emoji.rawToken)
                guard reference.isAnimated,
                      let url =
                        reference.id.flatMap({ model.customEmojiURLsByID[$0] })
                        ?? reference.imageURL(size: 64)
                else { continue }
                keys.insert(.media(url, maximumPixelDimension: 64))
            }
        }
        for region in layout.embedRegions {
            for image in region.imageRegions
            where Self.isPotentiallyAnimated(image.url) {
                keys.insert(.media(
                    image.url,
                    maximumPixelDimension: image.maximumPixelDimension
                ))
            }
            if !region.mediaIsVideo,
               let url = region.mediaURL,
               Self.isPotentiallyAnimated(url)
            {
                keys.insert(.media(url))
            }
            for textRegion in region.textRegions {
                appendAnimatedInlineKeys(
                    from: textRegion.text.value,
                    into: &keys
                )
            }
        }
        for component in layout.componentLayouts {
            let hiddenContainerFrames =
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: component,
                        messageID: message.id,
                        store: spoilerRevealStore
                    )
            for image in component.images
            where Self.isPotentiallyAnimated(image.displayURL)
                && !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        image.frame,
                        hiddenContainerFrames: hiddenContainerFrames
                    )
                && !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                    messageID: message.id,
                    contentID: image.componentID,
                    isSpoiler: image.isSpoiler,
                    store: spoilerRevealStore
                ) {
                keys.insert(.media(
                    image.displayURL,
                    maximumPixelDimension: image.maximumPixelDimension
                ))
            }
            for media in component.media
            where Self.isPotentiallyAnimated(media.displayURL)
                && !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        media.frame,
                        hiddenContainerFrames: hiddenContainerFrames
                    )
                && !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                    messageID: message.id,
                    contentID: media.componentID,
                    isSpoiler: media.isSpoiler,
                    store: spoilerRevealStore
                ) {
                keys.insert(.media(media.displayURL))
            }
            for button in component.buttons {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        button.frame,
                        hiddenContainerFrames: hiddenContainerFrames
                    )
                else { continue }
                guard let emoji = button.emoji,
                      emoji.isAnimated,
                      let url = emoji.imageURL(size: 32)
                else { continue }
                keys.insert(.media(url, maximumPixelDimension: 64))
            }
            for textRegion in component.textRegions {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        textRegion.frame,
                        hiddenContainerFrames: hiddenContainerFrames
                    )
                else { continue }
                appendAnimatedInlineKeys(
                    from: textRegion.text.value,
                    into: &keys
                )
            }
        }
        for sticker in message.stickers
        where sticker.format == .apng || sticker.format == .gif {
            if let url = sticker.mediaURL {
                keys.insert(.media(url, maximumPixelDimension: 384))
            }
        }
        for region in layout.reactionRegions {
            let reference = region.reaction.emojiReference
            guard reference.isAnimated,
                  let url = reference.id.flatMap({
                      model?.customEmojiURLsByID[$0]
                  }) ?? reference.imageURL(size: 64)
            else { continue }
            keys.insert(.media(url, maximumPixelDimension: 64))
        }
        return keys
    }

    private func appendAnimatedInlineKeys(
        from value: NSAttributedString,
        into keys: inout Set<NativeTimelineMediaKey>
    ) {
        let range = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(
            .discordEmojiToken,
            in: range
        ) { rawValue, _, _ in
            guard let rawToken = rawValue as? String else { return }
            let reference = EmojiReference(rawToken: rawToken)
            guard reference.isAnimated,
                  let url = reference.id.flatMap({
                      model?.customEmojiURLsByID[$0]
                  }) ?? reference.imageURL(size: 64)
            else { return }
            keys.insert(.media(url, maximumPixelDimension: 64))
        }
    }

    private static func isPotentiallyAnimated(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "gif", "apng", "webp":
            true
        default:
            false
        }
    }

    private func reactionCountTransitions(
        inMessageAt index: Int
    ) -> [String: NativeTimelineReactionCountTransition] {
        guard items.indices.contains(index),
              let messageID = items[index].messageID
        else { return [:] }
        var result: [String: NativeTimelineReactionCountTransition] = [:]
        for (key, animation) in activeReactionCountAnimations
        where key.messageID == messageID {
            result[key.reactionID] = NativeTimelineReactionCountTransition(
                from: animation.from,
                to: animation.to,
                progress: 0
            )
        }
        return result
    }

    private func setHoveredReaction(
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

    private func reconcileReactionHover() {
        guard let target = hoveredReaction,
              let hit = reactionPointerHit(for: target)
        else {
            hoveredReaction = nil
            reactionHoverCoordinator.close()
            return
        }
        setHoveredReaction(hit)
    }

    private func presentReactionHover(
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
        let reference = reaction.emojiReference
        let emojiURL = reference.id.flatMap { id in
            model?.customEmojiURLsByID[id]
        } ?? reference.imageURL(size: 64)
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

    private func showReactionPicker(
        for message: Message,
        anchor: CGRect,
        preferredEdge: NSRectEdge
    ) {
        guard let model else { return }
        reactionPickerSource.frame = anchor
        let content = EmojiPickerView(
            model: model,
            useCase: .reaction(
                guildID: message.guildID ?? model.selectedGuildID
            ),
            allowsPersistentSelection: true
        ) { [weak self] activation in
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
        reactionPickerCoordinator.update(
            sourceView: reactionPickerSource,
            isPresented: true,
            preferredEdge: preferredEdge,
            accessibilityIdentifier:
                preferredEdge == .maxX
                    ? "reaction-picker-inline"
                    : "reaction-picker-toolbar",
            content: content,
            setPresented: { [weak self] isPresented in
                if !isPresented {
                    self?.reactionPickerSource.frame = .zero
                }
            }
        )
    }

    private func handleComponentClick(
        in layout: NativeTimelineRowLayout,
        message: Message,
        point: CGPoint,
        rowIndex: Int
    ) -> Bool {
        for componentLayout in layout.componentLayouts {
            for container in componentLayout.containers
            where container.isSpoiler && container.frame.contains(point) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: container.componentID
                )
                if !spoilerRevealStore.isMediaRevealed(key) {
                    reveal(key, rowIndex: rowIndex)
                    return true
                }
            }
            for region in componentLayout.images
            where region.frame.contains(point) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: region.componentID
                )
                if region.isSpoiler,
                   !spoilerRevealStore.isMediaRevealed(key) {
                    reveal(key, rowIndex: rowIndex)
                } else {
                    NSWorkspace.shared.open(region.openURL)
                }
                return true
            }
            for region in componentLayout.media
            where region.frame.contains(point) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: region.componentID
                )
                if region.isSpoiler,
                   !spoilerRevealStore.isMediaRevealed(key) {
                    reveal(key, rowIndex: rowIndex)
                } else {
                    NSWorkspace.shared.open(region.openURL)
                }
                return true
            }
            for region in componentLayout.files
            where region.frame.contains(point) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: region.componentID
                )
                if region.isSpoiler,
                   !spoilerRevealStore.isMediaRevealed(key) {
                    reveal(key, rowIndex: rowIndex)
                } else {
                    NSWorkspace.shared.open(region.openURL)
                }
                return true
            }
            for region in componentLayout.selects
            where region.frame.contains(point) {
                guard !region.isDisabled else { return true }
                showMenu(
                    for: region,
                    message: message,
                    rowIndex: rowIndex
                )
                return true
            }
        }
        return false
    }

    private func handleTextClick(
        in layout: NativeTimelineRowLayout,
        message: Message,
        point: CGPoint,
        rowIdentifier: NativeMessageTimelineItem.Identifier
    ) -> Bool {
        guard let pointerHit = textPointerHit(
            in: layout,
            point: point
        ) else { return false }
        return activateTextHit(
            pointerHit.hit,
            message: message,
            rowIdentifier: rowIdentifier,
            region: pointerHit.region
        )
    }

    private func textPointerHit(
        in layout: NativeTimelineRowLayout,
        point: CGPoint
    ) -> TextPointerHit? {
        if let frame = layout.contentFrame,
           let value = layout.attributedContent,
           let framesetter = layout.contentFramesetter,
           let hit = NativeTimelineTextHitTester.hit(
               value: value,
               framesetter: framesetter,
               frame: NativeTimelineTextGeometry
                   .messageContentDrawingFrame(frame),
               point: point
           ),
           hit.mention != nil
                || hit.url != nil
                || hit.spoilerRange != nil
        {
            return TextPointerHit(hit: hit, region: .content)
        }
        for embed in layout.embedRegions {
            for (textIndex, region) in embed.textRegions.enumerated() {
                if let hit = NativeTimelineTextHitTester.hit(
                    box: region.text,
                    frame: region.frame,
                    point: point
                ), hit.mention != nil
                    || hit.url != nil
                    || hit.spoilerRange != nil
                {
                    return TextPointerHit(
                        hit: hit,
                        region: .embed(
                           embedID: embed.embedID,
                           textIndex: textIndex
                       )
                    )
                }
            }
        }
        for (layoutIndex, component) in
            layout.componentLayouts.enumerated()
        {
            for (textIndex, region) in component.textRegions.enumerated() {
                if let hit = NativeTimelineTextHitTester.hit(
                    box: region.text,
                    frame: region.frame,
                    point: point
                ), hit.mention != nil
                    || hit.url != nil
                    || hit.spoilerRange != nil
                {
                    return TextPointerHit(
                        hit: hit,
                        region: .component(
                           layoutIndex: layoutIndex,
                           textIndex: textIndex
                       )
                    )
                }
            }
        }
        return nil
    }

    private func activateTextHit(
        _ hit: NativeTimelineTextHit,
        message: Message,
        rowIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion
    ) -> Bool {
        if let spoilerRange = hit.spoilerRange {
            revealTextSpoiler(
                itemIdentifier: rowIdentifier,
                region: region,
                rangeLocation: spoilerRange.location
            )
            return true
        }
        if let mention = hit.mention {
            let anchor = StablePopoverAnchor(
                sourceView: self
            ) { [weak self] in
                self?.mentionAnchorFrame(
                    rowIdentifier: rowIdentifier,
                    region: region,
                    characterIndex: hit.characterIndex,
                    rawToken: mention.rawToken
                )
            }
            activateMention(
                mention,
                message: message,
                anchor: anchor
            )
            return true
        }
        guard let url = hit.url else { return false }
        if let channelLink = DiscordChannelLink(url) {
            model?.navigate(
                to: channelLink.guildID,
                linkedChannelID: channelLink.channelID
            )
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    private func revealTextSpoiler(
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        rangeLocation: Int
    ) {
        guard let key = textSpoilerRevealKey(
            itemIdentifier: itemIdentifier,
            region: region,
            rangeLocation: rangeLocation
        ),
              spoilerRevealStore.revealText(key)
        else { return }
    }

    private func activateMention(
        _ mention: MentionPresentation,
        message: Message,
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        switch mention.target {
        case .unresolved:
            break
        case let .user(id):
            let resolver = MessageMentionResolver(
                model: model,
                message: message
            )
            if let user = resolver.user(id) {
                showMentionProfile(
                    for: user,
                    anchor: anchor
                )
            }
        case let .role(id):
            showMentionRole(id, anchor: anchor)
        case let .channel(id):
            model.navigate(to: id)
        case let .linkedChannel(guildID, channelID):
            model.navigate(to: guildID, linkedChannelID: channelID)
        case let .message(guildID, channelID, messageID):
            model.navigate(
                to: guildID,
                channelID: channelID,
                messageID: messageID
            )
        }
    }

    private func mentionAnchorFrame(
        rowIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        characterIndex: Int,
        rawToken: String
    ) -> CGRect? {
        guard let index = items.firstIndex(where: {
            $0.identifier == rowIdentifier
        }),
           layouts.indices.contains(index)
        else { return nil }
        let layout = layouts[index]
        let localFrame: CGRect?
        switch region {
        case .beginningTitle, .beginningDescription:
            return nil
        case .content:
            guard let value = layout.attributedContent,
                  let framesetter = layout.contentFramesetter,
                  let frame = layout.contentFrame
            else { return nil }
            localFrame = NativeTimelineTextHitTester.mentionAnchorFrame(
                value: value,
                framesetter: framesetter,
                frame: NativeTimelineTextGeometry
                    .messageContentDrawingFrame(frame),
                characterIndex: characterIndex,
                rawToken: rawToken
            )
        case let .embed(embedID, textIndex):
            guard let embed = layout.embedRegions.first(where: {
                $0.embedID == embedID
            }),
               embed.textRegions.indices.contains(textIndex)
            else { return nil }
            let text = embed.textRegions[textIndex]
            localFrame = NativeTimelineTextHitTester.mentionAnchorFrame(
                box: text.text,
                frame: text.frame,
                characterIndex: characterIndex,
                rawToken: rawToken
            )
        case let .component(layoutIndex, textIndex):
            guard layout.componentLayouts.indices.contains(layoutIndex),
                  layout.componentLayouts[layoutIndex]
                      .textRegions.indices.contains(textIndex)
            else { return nil }
            let text = layout.componentLayouts[layoutIndex]
                .textRegions[textIndex]
            localFrame = NativeTimelineTextHitTester.mentionAnchorFrame(
                box: text.text,
                frame: text.frame,
                characterIndex: characterIndex,
                rawToken: rawToken
            )
        }
        return localFrame?.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
    }

    private func reveal(
        _ key: NativeTimelineComponentRevealKey
    ) {
        guard let rowIndex = items.firstIndex(where: {
            $0.messageID == key.messageID
        }) else { return }
        reveal(key, rowIndex: rowIndex)
    }

    private func reveal(
        _ key: NativeTimelineComponentRevealKey,
        rowIndex: Int
    ) {
        guard items.indices.contains(rowIndex),
              items[rowIndex].messageID == key.messageID
        else { return }
        guard spoilerRevealStore.revealMedia(key) else { return }
    }

    private func installSpoilerRevealStore(
        _ store: NativeTimelineSpoilerRevealStore
    ) {
        guard spoilerRevealStore !== store else { return }
        if let spoilerRevealObserverID {
            spoilerRevealStore.removeObserver(spoilerRevealObserverID)
        }
        spoilerRevealStore = store
        spoilerRevealObserverID = store.observe { [weak self] messageID in
            self?.spoilerRevealStateDidChange(messageID: messageID)
        }
    }

    private func spoilerRevealStateDidChange(messageID: MessageID) {
        guard let rowIndex = items.firstIndex(where: {
            $0.messageID == messageID
        }) else { return }
        let identifier = items[rowIndex].identifier
        invalidateBitmap(identifier)
        requestMedia(for: items[rowIndex], at: rowIndex)
        setNeedsDisplay(rowFrame(at: rowIndex))
        reconcileAnimatedMedia()
        reconcileSpoilerOverlays()
        rebuildAccessibilityProxy(for: identifier)
    }

    private func showMenu(
        for region: NativeTimelineComponentLayout.SelectRegion,
        message: Message,
        rowIndex: Int
    ) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in region.options {
            let title = option.emoji.map {
                "\($0.name) \(option.label)"
            } ?? option.label
            let item = actionItem(
                title,
                systemImage: option.isDefault
                    ? "checkmark.circle.fill"
                    : "circle"
            ) { [weak self] in
                guard let self else { return }
                self.actions?.submitComponent(
                    message,
                    region.customID,
                    self.interactionKind(region.kind),
                    [option.value]
                )
            }
            item.state = option.isDefault ? .on : .off
            item.toolTip = option.description
            menu.addItem(item)
        }
        let point = CGPoint(
            x: region.frame.minX,
            y: displayedRowOrigin(at: rowIndex) + region.frame.maxY + 2
        )
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func interactionKind(
        _ kind: ComponentSelectKind
    ) -> ComponentInteractionKind {
        switch kind {
        case .string: .stringSelect
        case .user: .userSelect
        case .role: .roleSelect
        case .mentionable: .mentionableSelect
        case .channel: .channelSelect
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point.y),
              case let .message(row, _, _) = items[index],
              let actions
        else { return nil }
        let canEdit =
            row.message.author.id == model?.snapshot?.currentUser.id
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in NativeTimelineMessageMenuPolicy.entries(
            canEdit: canEdit,
            canRetry: row.message.outboxState == .failed,
            canReply: actions.reply != nil
        ) {
            guard case let .action(
                action,
                title,
                systemImage,
                isDestructive
            ) = entry
            else {
                menu.addItem(.separator())
                continue
            }
            let handler: () -> Void
            switch action {
            case .retrySending:
                handler = {
                    actions.retry(row.message)
                }
            case .addReaction:
                handler = {
                    actions.react("👍", row.message)
                }
            case .reply:
                handler = {
                    guard let reply = actions.reply else { return }
                    reply(row.message)
                }
            case .markUnread:
                handler = {
                    actions.markUnread(row.message)
                }
            case .editMessage:
                handler = { [weak self] in
                    self?.beginEditing(row: row, at: index)
                }
            case .copyText:
                handler = {
                    Self.copyText(row.message.content)
                }
            case .deleteMessage:
                handler = { [weak self] in
                    self?.confirmDelete(row.message)
                }
            }
            menu.addItem(
                actionItem(
                    title,
                    systemImage: systemImage,
                    isDestructive: isDestructive,
                    action: handler
                )
            )
        }
        return menu
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .list
    }

    override func accessibilityLabel() -> String? {
        "Message timeline"
    }

    override func accessibilityChildren() -> [Any]? {
        var orderedChildren = accessibilityProxyRowsInTimelineOrder()
        var additionalChildren = (super.accessibilityChildren() ?? []).filter {
            child in
            guard let childView = child as? NSView else { return true }
            return !accessibilityProxyRows.values.contains {
                $0 === childView
            }
        }
        if let editingRowHost,
           let hostIndex = additionalChildren.firstIndex(where: {
               ($0 as? NSView) === editingRowHost
           }),
           let insertionIndex =
               NativeTimelineAccessibilityPolicy
                   .editingOverlayInsertionIndex(
                       in: accessibilityProxyOrder,
                       editingMessageID: editingMessageID
                   )
        {
            let editingChild = additionalChildren.remove(at: hostIndex)
            orderedChildren.insert(
                editingChild,
                at: min(insertionIndex, orderedChildren.endIndex)
            )
        }
        return orderedChildren + additionalChildren
    }

    override func accessibilityRows() -> [Any]? {
        accessibilityProxyRowsInTimelineOrder()
    }

    override func accessibilityVisibleRows() -> [Any]? {
        let viewport =
            enclosingScrollView?.documentVisibleRect ?? visibleRect
        return accessibilityProxyRowsInTimelineOrder().filter {
            ($0 as? NSView)?.frame.intersects(viewport) == true
        }
    }

    private func reconcileAccessibilityProxies() {
        let viewport =
            enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard viewport.height > 0,
              !items.isEmpty,
              !layouts.isEmpty
        else {
            removeAccessibilityProxies()
            return
        }
        var bufferedViewport =
            NativeTimelineAccessibilityPolicy.bufferedViewport(
                around: viewport,
                contentHeight: displayedContentHeight
            )
        bufferedViewport.size.width = max(
            bounds.width,
            bufferedViewport.width
        )
        guard var index = rowIndex(at: bufferedViewport.minY) else {
            removeAccessibilityProxies()
            return
        }
        var desired: Set<NativeMessageTimelineItem.Identifier> = []
        var desiredOrder: [NativeMessageTimelineItem.Identifier] = []
        while items.indices.contains(index),
              layouts.indices.contains(index),
              displayedRowOrigin(at: index) < bufferedViewport.maxY
        {
            let identifier = items[index].identifier
            let item = items[index]
            let frame = rowFrame(at: index)
            desired.insert(identifier)
            desiredOrder.append(identifier)
            if accessibilityProxyItems[identifier] != item {
                accessibilityProxyRows
                    .removeValue(forKey: identifier)?
                    .removeFromSuperview()
                let source = accessibilityRow(at: index)
                let rowProxy = accessibilityProxy(
                    for: source,
                    canvasFrame: frame
                )
                addSubview(rowProxy)
                accessibilityProxyRows[identifier] = rowProxy
                accessibilityProxyItems[identifier] = item
            } else if accessibilityProxyRows[identifier]?.frame != frame {
                // Child accessibility frames are relative to the row proxy.
                // Prepending history or changing an earlier row's height only
                // moves this row; rebuilding it would needlessly re-resolve
                // mentions and Markdown for every buffered message.
                accessibilityProxyRows[identifier]?.frame = frame
            }
            index += 1
        }
        let obsolete = accessibilityProxyRows.keys.filter {
            !desired.contains($0)
        }
        for identifier in obsolete {
            accessibilityProxyRows
                .removeValue(forKey: identifier)?
                .removeFromSuperview()
            accessibilityProxyItems.removeValue(forKey: identifier)
        }
        accessibilityProxyOrder = desiredOrder
    }

    private func accessibilityProxy(
        for source: NSAccessibilityElement,
        canvasFrame: CGRect
    ) -> NativeTimelineAccessibilityProxyView {
        let proxy = NativeTimelineAccessibilityProxyView(source: source)
        proxy.frame = canvasFrame
        if let children = source.accessibilityChildren() {
            for case let child as NSAccessibilityElement in children {
                let childCanvasFrame = accessibilityCanvasFrame(
                    for: child
                )
                let childProxy = accessibilityProxy(
                    for: child,
                    canvasFrame: childCanvasFrame
                )
                childProxy.frame = childCanvasFrame.offsetBy(
                    dx: -canvasFrame.minX,
                    dy: -canvasFrame.minY
                )
                proxy.addSubview(childProxy)
            }
        }
        return proxy
    }

    private func accessibilityCanvasFrame(
        for element: NSAccessibilityElement
    ) -> CGRect {
        guard let window else {
            return element.accessibilityFrame()
        }
        return convert(
            window.convertFromScreen(element.accessibilityFrame()),
            from: nil
        )
    }

    private func accessibilityProxyRowsInTimelineOrder() -> [Any] {
        accessibilityProxyOrder.compactMap {
            accessibilityProxyRows[$0]
        }
    }

    private func removeAccessibilityProxies() {
        for proxy in accessibilityProxyRows.values {
            proxy.removeFromSuperview()
        }
        accessibilityProxyRows.removeAll()
        accessibilityProxyItems.removeAll()
        accessibilityProxyOrder.removeAll()
    }

    private func rebuildAccessibilityProxy(
        for identifier: NativeMessageTimelineItem.Identifier
    ) {
        accessibilityProxyRows
            .removeValue(forKey: identifier)?
            .removeFromSuperview()
        accessibilityProxyItems.removeValue(forKey: identifier)
        reconcileAccessibilityProxies()
        NSAccessibility.post(
            element: self,
            notification: .layoutChanged
        )
    }

    private func accessibilityRow(at index: Int) -> NSAccessibilityElement {
        let item = items[index]
        let layout = layouts[index]
        let rowFrame = rowFrame(at: index)
        switch item {
        case let .beginning(beginning):
            return accessibilityElement(
                role: .row,
                label: "\(beginning.title). \(beginning.description)",
                identifier: "timeline-beginning-\(beginning.id)",
                frame: rowFrame,
                parent: self
            )
        case let .loader(isLoading, kind):
            let element = accessibilityElement(
                role: .row,
                label: "",
                value: isLoading ? "Busy" : nil,
                identifier: "timeline-earlier-loader",
                frame: rowFrame,
                parent: self,
                isEnabled: false
            )
            guard isLoading,
                  let loaderLayout = layout.loaderLayout
            else {
                return element
            }
            let label = kind.loadingLabel
            var children: [Any] = []
            if let spinnerFrame = loaderLayout.spinnerFrame {
                children.append(accessibilityElement(
                    role: .progressIndicator,
                    label: "Loading",
                    frame: accessibilityChildFrame(
                        spinnerFrame,
                        rowIndex: index
                    ),
                    parent: element
                ))
            }
            children.append(accessibilityElement(
                role: .staticText,
                label: label,
                frame: accessibilityChildFrame(
                    loaderLayout.labelFrame,
                    rowIndex: index
                ),
                parent: element
            ))
            element.setAccessibilityChildren(children)
            return element
        case let .message(row, isUnreadBoundary, _):
            return accessibilityMessage(
                row,
                isUnreadBoundary: isUnreadBoundary,
                layout: layout,
                rowFrame: rowFrame,
                rowIndex: index
            )
        }
    }

    private func accessibilityMessage(
        _ row: MessageRowPresentation,
        isUnreadBoundary: Bool,
        layout: NativeTimelineRowLayout,
        rowFrame: CGRect,
        rowIndex: Int
    ) -> NSAccessibilityElement {
        let message = row.message
        let itemIdentifier =
            NativeMessageTimelineItem.Identifier.message(message.id)
        let revealedTextSpoilerState =
            textSpoilerRevealState(for: itemIdentifier)
        let author =
            model?.authorPresentation(for: message).user
            ?? message.author
        let timestamp = NativeTimelineTimestamp.text(
            for: message.timestamp
        )
        let generatedLabel = SystemMessagePresentation.label(
            for: message,
            currentUserID: model?.snapshot?.currentUser.id
        )
        let rowLabel = message.type.hasGeneratedContent
            ? "System message, \(generatedLabel)"
            : "Message from \(author.displayName), \(timestamp)"
        let element = accessibilityElement(
            role: .row,
            label: rowLabel,
            value: MessageOutboxPresentation.accessibilityStatus(
                for: message.outboxState
            ),
            identifier: "timeline-message-\(message.id)",
            frame: rowFrame,
            parent: self
        )
        element.setAccessibilityCustomActions(
            accessibilityMessageActions(
                row,
                rowFrame: rowFrame,
                rowIndex: rowIndex
            )
        )
        var children: [Any] = []
        if let frame = layout.daySeparatorFrame {
            let dateLabel = message.timestamp.formatted(
                date: .long,
                time: .omitted
            )
            children.append(accessibilityElement(
                role: .staticText,
                label: "Messages from \(dateLabel)",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element
            ))
        }
        if isUnreadBoundary, let frame = layout.unreadSeparatorFrame {
            children.append(accessibilityElement(
                role: .staticText,
                label: "New messages",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element
            ))
        }
        if let preview = row.replyPreview,
           let frame = layout.replyFrame
        {
            let summary = accessibilityResolvedText(
                preview.content,
                message: message
            )
            children.append(accessibilityElement(
                role: .button,
                label: row.isReplyAvailable
                    ? "Replying to \(preview.author.displayName): \(summary)"
                    : "Original reply unavailable",
                help: row.isReplyAvailable
                    ? "Jump to original message"
                    : "Original message unavailable",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element,
                isEnabled: row.isReplyAvailable
            ) { [weak self] in
                guard row.isReplyAvailable, let self else { return false }
                self.actions?.openReply(preview.messageID)
                return true
            })
        }
        if let region = layout.commandInvocationRegion {
            let invokingUser =
                message.interactionMetadata?.user?.displayName
                ?? "Someone"
            let commandName =
                message.interactionMetadata?.displayName
                ?? "command"
            children.append(accessibilityElement(
                role: .button,
                label: "\(invokingUser) used /\(commandName)",
                help: "Show profile",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: element
            ) { [weak self] in
                guard let self,
                      let user = message.interactionMetadata?.user
                else { return false }
                self.showMessageProfile(
                    for: user,
                    anchor: self.accessibilityChildFrame(
                        region.profileFrame,
                        rowIndex: rowIndex
                    )
                )
                return true
            })
        }
        if row.startsGroup, !message.type.hasGeneratedContent {
            let help = "View \(author.displayName)'s profile"
            let frames =
                NativeTimelineAuthorProfileGeometry.hitFrames(
                    avatarFrame: layout.avatarFrame,
                    authorFrame: layout.authorFrame
                )
            for (index, authorFrame) in frames.enumerated() {
                children.append(accessibilityElement(
                    role: .button,
                    label: index == 0 && layout.avatarFrame != nil
                        ? "\(author.displayName) avatar"
                        : author.displayName,
                    help: help,
                    frame: accessibilityChildFrame(
                        authorFrame,
                        rowIndex: rowIndex
                    ),
                    parent: element
                ) { [weak self] in
                    guard let self else { return false }
                    self.showMessageProfile(
                        for: author,
                        anchor: self.accessibilityChildFrame(
                            authorFrame,
                            rowIndex: rowIndex
                        )
                    )
                    return true
                })
            }
            if let frame = layout.timestampFrame {
                children.append(accessibilityElement(
                    role: .staticText,
                    label: timestamp,
                    frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                    parent: element
                ))
            }
        }
        guard NativeTimelineAccessibilityPolicy.showsMessageBody(
            messageID: message.id,
            editingMessageID: editingMessageID
        ) else {
            element.setAccessibilityChildren(children)
            return element
        }
        if let frame = layout.loadingIndicatorFrame {
            children.append(accessibilityElement(
                role: .progressIndicator,
                label: "Loading",
                frame: accessibilityChildFrame(
                    frame,
                    rowIndex: rowIndex
                ),
                parent: element
            ))
        }
        if let frame = layout.contentFrame,
           let value = layout.attributedContent,
           let framesetter = layout.contentFramesetter
        {
            appendTextAccessibility(
                to: &children,
                value: value,
                framesetter: framesetter,
                drawingFrame: NativeTimelineTextGeometry
                    .messageContentDrawingFrame(frame),
                accessibilityFrame: frame,
                itemIdentifier: itemIdentifier,
                region: .content,
                revealedLocations: revealedTextSpoilerState.locations(
                    in: .content
                ),
                rowIndex: rowIndex,
                parent: element
            )
        } else if let frame = layout.contentFrame {
            let content = accessibilityMessageText(message)
            if !content.isEmpty {
                children.append(accessibilityElement(
                    role: .staticText,
                    label: content,
                    frame: accessibilityChildFrame(
                        frame,
                        rowIndex: rowIndex
                    ),
                    parent: element
                ))
            }
        }
        for region in layout.linkedImageRegions {
            children.append(accessibilityElement(
                role: .link,
                label: region.reference.label,
                help: "Open image",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: element
            ) {
                NSWorkspace.shared.open(region.reference.url)
                return true
            })
        }
        if !layout.attachmentRegions.isEmpty {
            let galleryFrame = layout.attachmentRegions
                .map(\.frame)
                .dropFirst()
                .reduce(layout.attachmentRegions[0].frame) {
                    $0.union($1)
                }
            let gallery = accessibilityElement(
                role: .group,
                label:
                    "Media gallery, \(layout.attachmentRegions.count) items",
                frame: accessibilityChildFrame(
                    galleryFrame,
                    rowIndex: rowIndex
                ),
                parent: element
            )
            let attachmentChildren = layout.attachmentRegions.map { region in
                let attachment = region.attachment
                let revealKey =
                    NativeTimelineComponentRevealKey.attachment(
                        messageID: message.id,
                        attachmentID: attachment.id
                    )
                let isHiddenSpoiler =
                    attachment.isSpoiler
                    && !spoilerRevealStore.isMediaRevealed(revealKey)
                let contentLabel =
                    attachment.description
                    ?? attachment.title
                    ?? attachment.filename
                let label = isHiddenSpoiler
                    ? "Reveal spoiler media"
                    : contentLabel
                return accessibilityElement(
                    role: .button,
                    label: label,
                    help: isHiddenSpoiler
                        ? "Reveals this media without opening it"
                        : "Open \(contentLabel)",
                    frame: accessibilityChildFrame(
                        region.frame,
                        rowIndex: rowIndex
                    ),
                    parent: gallery
                ) { [weak self] in
                    self?.activateAttachment(
                        attachment,
                        in: message,
                        rowIndex: rowIndex
                    ) ?? false
                }
            }
            gallery.setAccessibilityChildren(attachmentChildren)
            children.append(gallery)
        }
        appendEmbedAccessibility(
            to: &children,
            message: message,
            layout: layout,
            itemIdentifier: itemIdentifier,
            revealedTextSpoilerState: revealedTextSpoilerState,
            rowIndex: rowIndex,
            parent: element
        )
        appendComponentAccessibility(
            to: &children,
            message: message,
            layout: layout,
            itemIdentifier: itemIdentifier,
            revealedTextSpoilerState: revealedTextSpoilerState,
            rowIndex: rowIndex,
            parent: element
        )
        for (sticker, frame) in zip(message.stickers, layout.stickerFrames) {
            children.append(accessibilityElement(
                role: .image,
                label: NativeTimelineAccessibilityPresentation
                    .stickerLabel(sticker),
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element
            ))
        }
        if let thread = message.thread,
           let frame = layout.threadFrame
        {
            children.append(accessibilityElement(
                role: .button,
                label: NativeTimelineAccessibilityPresentation
                    .threadLabel(thread),
                help: "Open thread",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element
            ) { [weak self] in
                self?.actions?.openThread(thread)
                return self != nil
            })
        }
        for region in layout.reactionRegions {
            let reaction = region.reaction
            children.append(accessibilityElement(
                role: .button,
                label: MessageReactionPresentation
                    .accessibilityLabel(for: reaction),
                value: reaction.didCurrentUserReact
                    ? "You reacted"
                    : "You have not reacted",
                help: reaction.didCurrentUserReact
                    ? "Remove your reaction"
                    : "Add the same reaction",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: element
            ) { [weak self] in
                self?.actions?.react(reaction.emoji, message)
                return self != nil
            })
        }
        if let frame = layout.addReactionFrame {
            children.append(accessibilityElement(
                role: .button,
                label: "Add reaction",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element
            ) { [weak self] in
                guard let self else { return false }
                self.showReactionPicker(
                    for: message,
                    anchor: frame.offsetBy(
                        dx: 0,
                        dy: self.displayedRowOrigin(at: rowIndex)
                    ),
                    preferredEdge: .maxX
                )
                return true
            })
        }
        if let region = layout.ephemeralRegion {
            children.append(accessibilityElement(
                role: .staticText,
                label: "Only you can see this",
                frame: accessibilityChildFrame(
                    region.visibilityFrame,
                    rowIndex: rowIndex
                ),
                parent: element
            ))
            children.append(accessibilityElement(
                role: .button,
                label: "Dismiss message",
                frame: accessibilityChildFrame(
                    region.dismissFrame,
                    rowIndex: rowIndex
                ),
                parent: element
            ) { [weak self] in
                guard let self else { return false }
                self.model?.dismissEphemeralMessage(message)
                return true
            })
        }
        if let frame = layout.failedFrame {
            children.append(accessibilityElement(
                role: .staticText,
                label: "Failed",
                frame: accessibilityChildFrame(
                    frame,
                    rowIndex: rowIndex
                ),
                parent: element
            ))
        }
        element.setAccessibilityChildren(children)
        return element
    }

    private func appendTextAccessibility(
        to children: inout [Any],
        value: NSAttributedString,
        framesetter: CTFramesetter,
        drawingFrame: CGRect,
        accessibilityFrame: CGRect,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        revealedLocations: Set<Int>,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        let label = NativeTimelineTextAccessibilityPresentation.text(
            value,
            revealedLocations: revealedLocations
        )
        if !label.isEmpty {
            children.append(accessibilityElement(
                role: .staticText,
                label: label,
                frame: accessibilityChildFrame(
                    accessibilityFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ))
        }
        for codeBlock in NativeTimelineCodeBlockGeometry.regions(
            value: value,
            framesetter: framesetter,
            frame: drawingFrame
        ) {
            children.append(accessibilityElement(
                role: .button,
                label: "Copy code",
                help: "Copy code block",
                frame: accessibilityChildFrame(
                    codeBlock.copyButtonFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ) {
                Self.copyText(codeBlock.content)
                return true
            })
        }
        let hiddenRanges =
            NativeTimelineTextAccessibilityPresentation
                .hiddenSpoilerRanges(
                    in: value,
                    revealedLocations: revealedLocations
                )
        for range in hiddenRanges {
            let localFrame = NativeTimelineTextHitTester.rangeFrame(
                value: value,
                framesetter: framesetter,
                frame: drawingFrame,
                range: range
            ) ?? accessibilityFrame
            children.append(accessibilityElement(
                role: .button,
                label: "Reveal spoiler",
                frame: accessibilityChildFrame(
                    localFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ) { [weak self] in
                guard let self else { return false }
                self.revealTextSpoiler(
                    itemIdentifier: itemIdentifier,
                    region: region,
                    rangeLocation: range.location
                )
                return true
            })
        }
    }

    private func appendEmbedAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        for region in layout.embedRegions {
            let embed = message.embeds.first { $0.id == region.embedID }
            let group = accessibilityElement(
                role: .group,
                label: embed?.title ?? "Embed",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: parent
            )
            var groupChildren: [Any] = []
            for (textIndex, textRegion) in
                region.textRegions.enumerated()
            {
                let textRegionID = NativeTimelineTextRegion.embed(
                    embedID: region.embedID,
                    textIndex: textIndex
                )
                var drawingFrame = textRegion.frame
                drawingFrame.size.height +=
                    textRegion.text.layoutHeightAdjustment
                appendTextAccessibility(
                    to: &groupChildren,
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter,
                    drawingFrame: drawingFrame,
                    accessibilityFrame: textRegion.frame,
                    itemIdentifier: itemIdentifier,
                    region: textRegionID,
                    revealedLocations:
                        revealedTextSpoilerState.locations(
                            in: textRegionID
                        ),
                    rowIndex: rowIndex,
                    parent: group
                )
            }
            group.setAccessibilityChildren(groupChildren)
            children.append(group)
            if let frame = region.mediaFrame {
                children.append(accessibilityElement(
                    role: .button,
                    label: embed?.image?.description
                        ?? embed?.video?.description
                        ?? embed?.title
                        ?? "Embed media",
                    help: "Open media",
                    frame: accessibilityChildFrame(
                        frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent
                ) { [weak self] in
                    self?.activateEmbedMedia(
                        id: region.embedID,
                        in: message
                    ) ?? false
                })
            }
        }
    }

    private func appendComponentAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        for (layoutIndex, component) in
            layout.componentLayouts.enumerated()
        {
            let hiddenContainerFrames =
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: component,
                        messageID: message.id,
                        store: spoilerRevealStore
                    )
            func isInsideHiddenContainer(_ frame: CGRect) -> Bool {
                NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    )
            }
            for hiddenContainer in component.containers
            where hiddenContainerFrames.contains(hiddenContainer.frame) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: hiddenContainer.componentID
                )
                children.append(accessibilityElement(
                    role: .button,
                    label: "Reveal spoiler",
                    help: "Reveals this content without activating it",
                    frame: accessibilityChildFrame(
                        hiddenContainer.frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent
                ) { [weak self] in
                    guard let self else { return false }
                    self.reveal(key, rowIndex: rowIndex)
                    return true
                })
            }
            for (textIndex, textRegion) in
                component.textRegions.enumerated()
            where !textRegion.text.value.string.isEmpty
                && !isInsideHiddenContainer(textRegion.frame) {
                let textRegionID = NativeTimelineTextRegion.component(
                    layoutIndex: layoutIndex,
                    textIndex: textIndex
                )
                var drawingFrame = textRegion.frame
                drawingFrame.size.height +=
                    textRegion.text.layoutHeightAdjustment
                appendTextAccessibility(
                    to: &children,
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter,
                    drawingFrame: drawingFrame,
                    accessibilityFrame: textRegion.frame,
                    itemIdentifier: itemIdentifier,
                    region: textRegionID,
                    revealedLocations:
                        revealedTextSpoilerState.locations(
                            in: textRegionID
                        ),
                    rowIndex: rowIndex,
                    parent: parent
                )
            }
            for region in component.buttons
            where !isInsideHiddenContainer(region.frame) {
                children.append(accessibilityElement(
                    role: .button,
                    label: region.label.isEmpty ? "Button" : region.label,
                    frame: accessibilityChildFrame(
                        region.frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent,
                    isEnabled: !region.isDisabled
                ) { [weak self] in
                    self?.activateComponentButton(
                        region,
                        message: message
                    ) ?? false
                })
            }
            for region in component.selects
            where !isInsideHiddenContainer(region.frame) {
                children.append(accessibilityElement(
                    role: .popUpButton,
                    label: region.placeholder,
                    value: region.options.filter(\.isDefault)
                        .map(\.label)
                        .joined(separator: ", "),
                    frame: accessibilityChildFrame(
                        region.frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent,
                    isEnabled: !region.isDisabled
                ) { [weak self] in
                    guard let self, !region.isDisabled else {
                        return false
                    }
                    self.showMenu(
                        for: region,
                        message: message,
                        rowIndex: rowIndex
                    )
                    return true
                })
            }
            for region in component.images
            where !isInsideHiddenContainer(region.frame) {
                appendComponentMediaAccessibility(
                    to: &children,
                    label: region.description,
                    frame: region.frame,
                    componentID: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    message: message,
                    rowIndex: rowIndex,
                    parent: parent,
                    usesFileActionLabels: false
                )
            }
            for region in component.media
            where !isInsideHiddenContainer(region.frame) {
                appendComponentMediaAccessibility(
                    to: &children,
                    label: region.description,
                    frame: region.frame,
                    componentID: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    message: message,
                    rowIndex: rowIndex,
                    parent: parent,
                    usesFileActionLabels: false
                )
            }
            for region in component.files
            where !isInsideHiddenContainer(region.frame) {
                appendComponentMediaAccessibility(
                    to: &children,
                    label: region.title,
                    frame: region.frame,
                    componentID: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    message: message,
                    rowIndex: rowIndex,
                    parent: parent,
                    usesFileActionLabels: true
                )
            }
        }
    }

    private func appendComponentMediaAccessibility(
        to children: inout [Any],
        label: String,
        frame: CGRect,
        componentID: String,
        openURL: URL,
        isSpoiler: Bool,
        message: Message,
        rowIndex: Int,
        parent: NSAccessibilityElement,
        usesFileActionLabels: Bool
    ) {
        let key = NativeTimelineComponentRevealKey(
            messageID: message.id,
            componentID: componentID
        )
        let isHiddenSpoiler =
            isSpoiler && !spoilerRevealStore.isMediaRevealed(key)
        let accessibilityLabel =
            if usesFileActionLabels {
                isHiddenSpoiler ? "Reveal spoiler file" : "Open \(label)"
            } else {
                isHiddenSpoiler ? "Reveal spoiler media" : label
            }
        children.append(accessibilityElement(
            role: .button,
            label: accessibilityLabel,
            help: usesFileActionLabels
                ? (isHiddenSpoiler ? "Reveal spoiler" : "Open \(label)")
                : (
                    isHiddenSpoiler
                        ? "Reveals this media without opening it"
                        : "Open \(label)"
                ),
            frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
            parent: parent
        ) { [weak self] in
            guard let self else { return false }
            if isHiddenSpoiler {
                self.reveal(key, rowIndex: rowIndex)
            } else {
                NSWorkspace.shared.open(openURL)
            }
            return true
        })
    }

    private func accessibilityMessageActions(
        _ row: MessageRowPresentation,
        rowFrame: CGRect,
        rowIndex: Int
    ) -> [NSAccessibilityCustomAction] {
        let message = row.message
        let canEdit =
            message.author.id == model?.snapshot?.currentUser.id
        var result: [NSAccessibilityCustomAction] = []
        if message.outboxState == .failed {
            result.append(NSAccessibilityCustomAction(
                name: "Retry Sending"
            ) { [weak self] in
                self?.actions?.retry(message)
                return self != nil
            })
        }
        result.append(NSAccessibilityCustomAction(
            name: "Add Reaction"
        ) { [weak self] in
            guard let self else { return false }
            self.showReactionPicker(
                for: message,
                anchor: CGRect(
                    x: rowFrame.maxX - 32,
                    y: rowFrame.minY,
                    width: 28,
                    height: 28
                ),
                preferredEdge: .minY
            )
            return true
        })
        if let reply = actions?.reply {
            result.append(NSAccessibilityCustomAction(name: "Reply") {
                reply(message)
                return true
            })
        }
        result.append(NSAccessibilityCustomAction(
            name: "Mark Unread"
        ) { [weak self] in
            self?.actions?.markUnread(message)
            return self != nil
        })
        if canEdit {
            result.append(NSAccessibilityCustomAction(
                name: "Edit Message"
            ) { [weak self] in
                guard let self else { return false }
                self.beginEditing(row: row, at: rowIndex)
                return true
            })
        }
        result.append(NSAccessibilityCustomAction(
            name: "Copy Text"
        ) {
            Self.copyText(message.content)
            return true
        })
        result.append(NSAccessibilityCustomAction(
            name: "Copy Message Link"
        ) { [weak self] in
            guard let self else { return false }
            Self.copyText(self.messageLink(for: message))
            return true
        })
        if canEdit {
            result.append(NSAccessibilityCustomAction(
                name: "Delete Message"
            ) { [weak self] in
                self?.confirmDelete(message)
                return self != nil
            })
        }
        return result
    }

    private func accessibilityMessageText(_ message: Message) -> String {
        if message.type.hasGeneratedContent {
            return SystemMessagePresentation.label(
                for: message,
                currentUserID: model?.snapshot?.currentUser.id
            )
        }
        if message.flags.contains(.isComponentsV2) {
            return ""
        }
        let content =
            MessageEmbedPresentation.visibleMessageContent(for: message)
        guard !content.isEmpty else { return "" }
        return accessibilityResolvedText(content, message: message)
    }

    private func accessibilityResolvedText(
        _ content: String,
        message: Message
    ) -> String {
        guard let model else {
            return MessageReplySummary.text(content: content)
        }
        return MessageReplySummary.text(
            content: content,
            mentionLabel: MessageMentionResolver(
                model: model,
                message: message
            ).label
        )
    }

    private func accessibilityChildFrame(
        _ frame: CGRect,
        rowIndex: Int
    ) -> CGRect {
        frame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: rowIndex)
        )
    }

    private func accessibilityScreenFrame(_ frame: CGRect) -> CGRect {
        guard let window else { return frame }
        return window.convertToScreen(convert(frame, to: nil))
    }

    private func accessibilityElement(
        role: NSAccessibility.Role,
        label: String,
        value: String? = nil,
        help: String? = nil,
        identifier: String? = nil,
        frame: CGRect,
        parent: Any?,
        isEnabled: Bool = true,
        press: (@MainActor @Sendable () -> Bool)? = nil
    ) -> NSAccessibilityElement {
        let element: NSAccessibilityElement =
            if let press {
                NativeTimelineAccessibilityElement(press: press)
            } else {
                NSAccessibilityElement()
            }
        element.setAccessibilityRole(role)
        element.setAccessibilityLabel(label)
        element.setAccessibilityValue(value)
        element.setAccessibilityHelp(help)
        element.setAccessibilityIdentifier(identifier)
        element.setAccessibilityFrame(accessibilityScreenFrame(frame))
        element.setAccessibilityParent(
            parent.flatMap {
                NSAccessibility.unignoredAncestor(of: $0) ?? $0
            }
        )
        element.setAccessibilityWindow(window)
        element.setAccessibilityTopLevelUIElement(window)
        element.setAccessibilityEnabled(isEnabled)
        return element
    }

    private func activateAttachment(
        _ attachment: Attachment,
        in message: Message,
        rowIndex: Int
    ) -> Bool {
        let revealKey = NativeTimelineComponentRevealKey.attachment(
            messageID: message.id,
            attachmentID: attachment.id
        )
        if attachment.isSpoiler,
           !spoilerRevealStore.isMediaRevealed(revealKey)
        {
            reveal(revealKey, rowIndex: rowIndex)
        } else if let presentation =
            NativeTimelineMediaViewerPlan.attachments(
                in: message,
                selectedAttachmentID: attachment.id
            )
        {
            mediaViewerState.present(presentation)
        } else {
            NSWorkspace.shared.open(attachment.url)
        }
        return true
    }

    private func activateEmbedMedia(
        id: String,
        in message: Message
    ) -> Bool {
        if let presentation = NativeTimelineMediaViewerPlan.embed(
            in: message,
            id: id
        ) {
            mediaViewerState.present(presentation)
            return true
        }
        guard let region = layouts.lazy
            .flatMap(\.embedRegions)
            .first(where: { $0.embedID == id }),
              let url = region.mediaURL
        else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private func activateComponentButton(
        _ region: NativeTimelineComponentLayout.ButtonRegion,
        message: Message
    ) -> Bool {
        guard !region.isDisabled else { return false }
        if let url = region.url {
            NSWorkspace.shared.open(url)
            return true
        }
        guard let customID = region.customID else { return false }
        actions?.submitComponent(message, customID, .button, [])
        return true
    }

    private func setHoveredRow(_ value: Int?) {
        guard hoveredRow != value else { return }
        let old = hoveredRow
        hoveredRow = value
        if let old {
            setNeedsDisplay(rowFrame(at: old))
        }
        if let value {
            setNeedsDisplay(rowFrame(at: value))
        }
        if value == nil, actionCapsuleState?.isReactionPickerPresented == true {
            return
        }
        reconcileActionCapsule()
    }

    private func setHoveredCompactTimestampRow(_ value: Int?) {
        guard hoveredCompactTimestampRow != value else { return }
        let old = hoveredCompactTimestampRow
        hoveredCompactTimestampRow = value
        if let old {
            setNeedsDisplay(rowFrame(at: old))
        }
        if let value {
            setNeedsDisplay(rowFrame(at: value))
        }
    }

    private func setHoveredMention(
        _ value: NativeTimelineMentionHover?
    ) {
        guard hoveredMention != value else { return }
        let oldIdentifier = hoveredMention?.itemIdentifier
        hoveredMention = value
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    private func setHoveredTextSpoiler(
        _ value: NativeTimelineTextSpoilerHover?
    ) {
        guard hoveredTextSpoiler != value else { return }
        let oldIdentifier = hoveredTextSpoiler?.itemIdentifier
        hoveredTextSpoiler = value
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    private func setHoveredCodeBlock(
        _ value: CodeBlockPointerTarget?
    ) {
        guard hoveredCodeBlock != value else { return }
        let oldIdentifier = hoveredCodeBlock?.itemIdentifier
        hoveredCodeBlock = value
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    private func setHoveredComponentButton(
        _ value: NativeTimelineComponentButtonTarget?
    ) {
        guard hoveredComponentButton != value else { return }
        let old = hoveredComponentButton
        hoveredComponentButton = value
        for target in [old, value].compactMap({ $0 }) {
            invalidateComponentButton(target)
        }
    }

    private func animateComponentButtonPress(
        _ target: NativeTimelineComponentButtonTarget,
        to destination: CGFloat
    ) {
        let destination = min(max(destination, 0), 1)
        if visualPressedComponentButton != target {
            if let old = visualPressedComponentButton {
                invalidateComponentButton(old)
            }
            componentButtonPressAnimationTask?.cancel()
            componentButtonPressProgress = 0
            visualPressedComponentButton = target
        }
        if abs(componentButtonPressProgress - destination) < 0.001 {
            componentButtonPressAnimationDestination = nil
            if destination == 0 {
                visualPressedComponentButton = nil
            }
            invalidateComponentButton(target)
            return
        }
        guard componentButtonPressAnimationDestination != destination else {
            return
        }
        componentButtonPressAnimationTask?.cancel()
        componentButtonPressAnimationDestination = destination
        let start = componentButtonPressProgress
        let startTime = ProcessInfo.processInfo.systemUptime
        componentButtonPressAnimationTask = Task {
            @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let elapsed =
                    ProcessInfo.processInfo.systemUptime - startTime
                let linear = min(
                    1,
                    elapsed
                        / NativeTimelineComponentButtonVisualState
                            .pressAnimationDuration
                )
                let progress =
                    NativeTimelineComponentButtonVisualState
                        .easeOut(linear)
                self.componentButtonPressProgress =
                    start + (destination - start) * progress
                self.invalidateComponentButton(target)
                if linear >= 1 {
                    self.componentButtonPressProgress = destination
                    self.componentButtonPressAnimationDestination = nil
                    self.componentButtonPressAnimationTask = nil
                    if destination == 0,
                       self.visualPressedComponentButton == target
                    {
                        self.visualPressedComponentButton = nil
                    }
                    self.invalidateComponentButton(target)
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func invalidateComponentButton(
        _ target: NativeTimelineComponentButtonTarget
    ) {
        guard let index = items.firstIndex(where: {
            $0.messageID == target.messageID
        }) else { return }
        setNeedsDisplay(rowFrame(at: index))
    }

    private func reconcileActionCapsule() {
        guard editingMessageID == nil,
              let index = hoveredRow,
              items.indices.contains(index),
              case let .message(row, _, _) = items[index],
              let model,
              let actions
        else {
            if actionCapsuleState?.isReactionPickerPresented != true {
                removeActionCapsule()
            }
            return
        }

        if actionCapsuleMessageID == row.id {
            positionActionCapsule(at: index)
            return
        }
        removeActionCapsule()

        let state = NativeTimelineActionCapsuleState()
        state.presentationDidChange = { [weak self] isPresented in
            guard let self else { return }
            if !isPresented, self.hoveredRow == nil {
                self.removeActionCapsule()
            }
        }
        let canEdit = row.message.author.id == model.snapshot?.currentUser.id
        let root = NativeTimelineActionCapsuleOverlay(
            model: model,
            message: row.message,
            canEdit: canEdit,
            state: state,
            retry: row.message.outboxState == .failed
                ? { actions.retry(row.message) }
                : nil,
            edit: { [weak self] in
                self?.beginEditing(row: row, at: index)
            },
            reply: actions.reply.map { reply in
                { reply(row.message) }
            },
            react: { emoji in actions.react(emoji, row.message) },
            copy: { Self.copyText(row.message.content) },
            copyLink: { [weak self] in
                guard let self else { return }
                Self.copyText(self.messageLink(for: row.message))
            },
            openThread: row.message.thread.map { thread in
                { actions.openThread(thread) }
            },
            delete: { [weak self] in self?.confirmDelete(row.message) }
        )
        let host = NSHostingView(rootView: AnyView(root))
        host.setContentHuggingPriority(.required, for: .horizontal)
        host.setContentHuggingPriority(.required, for: .vertical)
        host.setContentCompressionResistancePriority(.required, for: .horizontal)
        host.setContentCompressionResistancePriority(.required, for: .vertical)
        host.setAccessibilityIdentifier("message-action-capsule-\(row.id)")
        addSubview(host, positioned: .above, relativeTo: nil)
        actionCapsuleState = state
        actionCapsuleHost = host
        actionCapsuleMessageID = row.id
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        actionCapsuleSize = NSSize(
            width: max(36, fitting.width),
            height: max(36, fitting.height)
        )
        positionActionCapsule(at: index)
    }

    private func positionActionCapsule(at knownIndex: Int? = nil) {
        guard let host = actionCapsuleHost,
              let size = actionCapsuleSize,
              let messageID = actionCapsuleMessageID,
              let index =
                knownIndex.flatMap({ candidate in
                    guard items.indices.contains(candidate),
                          items[candidate].messageID == messageID
                    else { return nil }
                    return candidate
                })
                ?? items.firstIndex(where: { $0.messageID == messageID })
        else { return }
        host.frame = CGRect(
            x: max(0, bounds.width - 14 - size.width),
            y: displayedRowOrigin(at: index)
                + (layouts[index].highlightFrame?.minY ?? 0)
                - 13,
            width: size.width,
            height: size.height
        )
    }

    private func removeActionCapsule() {
        actionCapsuleState?.presentationDidChange = nil
        actionCapsuleHost?.removeFromSuperview()
        actionCapsuleHost = nil
        actionCapsuleState = nil
        actionCapsuleMessageID = nil
        actionCapsuleSize = nil
    }

    private func timelineTextCaret(
        at point: CGPoint,
        itemIdentifier: NativeMessageTimelineItem.Identifier?,
        region requestedRegion: NativeTimelineTextRegion?,
        clampsToText: Bool,
        requiresPointInTextContainer: Bool
    ) -> TextCaretCandidate? {
        let index: Int?
        if let itemIdentifier {
            index = items.firstIndex {
                $0.identifier == itemIdentifier
            }
        } else {
            index = rowIndex(at: point.y)
        }
        guard let index,
              items.indices.contains(index),
              layouts.indices.contains(index),
              itemIdentifier == nil
                  || items[index].identifier == itemIdentifier
        else { return nil }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        for selectable in selectableTextRegions(
            for: items[index],
            layout: layouts[index]
        )
        where requestedRegion == nil || selectable.region == requestedRegion {
            if requiresPointInTextContainer {
                let interactionFrame = textSelectionInteractionFrame(
                    region: selectable.region,
                    frame: selectable.interactionFrame,
                    rowIndex: index
                )
                guard interactionFrame.contains(point) else { continue }
            }
            guard let caret = NativeTimelineTextHitTester.caretIndex(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame,
                point: local,
                clampsToText: clampsToText
            ) else { continue }
            return TextCaretCandidate(
                itemIdentifier: items[index].identifier,
                region: selectable.region,
                rowIndex: index,
                caret: caret,
                value: selectable.value
            )
        }
        return nil
    }

    private func textSelectionInteractionFrame(
        region: NativeTimelineTextRegion,
        frame: CGRect,
        rowIndex: Int
    ) -> CGRect {
        guard region == .content else {
            return frame.offsetBy(
                dx: 0,
                dy: displayedRowOrigin(at: rowIndex)
            )
        }
        return NativeTimelineTextSelectionGeometry.interactionFrame(
            contentFrame: frame,
            rowOrigin: displayedRowOrigin(at: rowIndex),
            canvasWidth: bounds.width
        )
    }

    private func selectableTextRegions(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout
    ) -> [SelectableTextRegion] {
        var result: [SelectableTextRegion] = []
        if case let .beginning(beginning) = item,
           let beginningLayout = layout.beginningLayout
        {
            let title = NativeTimelineBeginningText.title(beginning)
            result.append(SelectableTextRegion(
                region: .beginningTitle,
                frame: beginningLayout.titleFrame,
                interactionFrame: beginningLayout.titleFrame,
                value: title.value,
                framesetter: title.framesetter
            ))
            if beginning.isDescriptionSelectable {
                let description = NativeTimelineBeginningText.description(
                    beginning
                )
                result.append(SelectableTextRegion(
                    region: .beginningDescription,
                    frame: beginningLayout.descriptionFrame,
                    interactionFrame: beginningLayout.descriptionFrame,
                    value: description.value,
                    framesetter: description.framesetter
                ))
            }
            return result
        }
        if let frame = layout.contentFrame,
           let value = layout.attributedContent,
           let framesetter = layout.contentFramesetter
        {
            result.append(SelectableTextRegion(
                region: .content,
                frame: NativeTimelineTextGeometry
                    .messageContentDrawingFrame(frame),
                interactionFrame: frame,
                value: value,
                framesetter: framesetter
            ))
        }
        for embed in layout.embedRegions {
            for (textIndex, textRegion) in
                embed.textRegions.enumerated()
            where textRegion.isSelectable {
                var frame = textRegion.frame
                frame.size.height +=
                    textRegion.text.layoutHeightAdjustment
                result.append(SelectableTextRegion(
                    region: .embed(
                        embedID: embed.embedID,
                        textIndex: textIndex
                    ),
                    frame: frame,
                    interactionFrame: textRegion.frame,
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter
                ))
            }
        }
        for (layoutIndex, component) in
            layout.componentLayouts.enumerated()
        {
            for (textIndex, textRegion) in
                component.textRegions.enumerated()
            where textRegion.isSelectable {
                var frame = textRegion.frame
                frame.size.height +=
                    textRegion.text.layoutHeightAdjustment
                result.append(SelectableTextRegion(
                    region: .component(
                        layoutIndex: layoutIndex,
                        textIndex: textIndex
                    ),
                    frame: frame,
                    interactionFrame: textRegion.frame,
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter
                ))
            }
        }
        return result
    }

    private func setTextSelection(
        _ selection: NativeTimelineTextSelection?
    ) {
        guard textSelection != selection else { return }
        let oldIdentifier = textSelection?.itemIdentifier
        textSelection = selection
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        for identifier
            in [oldIdentifier, selection?.itemIdentifier].compactMap({
            $0
        }) {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    private func reconcileBeginningSelectionOverlay() {
        guard let selection = textSelection,
              let index = items.firstIndex(where: {
                  $0.identifier == selection.itemIdentifier
              }),
              layouts.indices.contains(index),
              case let .beginning(beginning) = items[index],
              let layout = layouts[index].beginningLayout
        else {
            beginningSelectionOverlay.image = nil
            beginningSelectionOverlay.isHidden = true
            return
        }

        let box: NativeTimelineAttributedTextBox
        let localFrame: CGRect
        switch selection.region {
        case .beginningTitle:
            box = NativeTimelineBeginningText.title(beginning)
            localFrame = layout.titleFrame
        case .beginningDescription:
            box = NativeTimelineBeginningText.description(beginning)
            localFrame = layout.descriptionFrame
        default:
            beginningSelectionOverlay.image = nil
            beginningSelectionOverlay.isHidden = true
            return
        }

        var overlayFrame = localFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
        overlayFrame.size.height += box.layoutHeightAdjustment
        beginningSelectionOverlay.frame = overlayFrame
        beginningSelectionOverlay.image =
            NativeTimelineRowPainter.selectionOverlayImage(
                box,
                size: overlayFrame.size,
                selectionRange: selection.range
            )
        beginningSelectionOverlay.isHidden = false
    }

    private func selectedTextValue() -> String? {
        guard let selection = textSelection,
              selection.range.length > 0,
              let index = items.firstIndex(where: {
                  $0.identifier == selection.itemIdentifier
              }),
              layouts.indices.contains(index),
              let value = selectableTextRegions(
                  for: items[index],
                  layout: layouts[index]
              )
                  .first(where: {
                      $0.region == selection.region
                  })?.value,
              selection.range.location >= 0,
              NSMaxRange(selection.range) <= value.length
        else { return nil }
        return RichMessageCopySerializer.string(
            from: value,
            range: selection.range
        )
    }

    private static func wordRange(
        at caret: Int,
        in string: String
    ) -> NSRange {
        let value = string as NSString
        guard value.length > 0 else { return NSRange(location: 0, length: 0) }
        var index = min(max(0, caret), value.length - 1)
        if value.character(at: index) == 0xFFFC {
            return NSRange(location: index, length: 1)
        }
        let wordCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_")
        )
        func isWordCharacter(at location: Int) -> Bool {
            let range = value.rangeOfComposedCharacterSequence(
                at: location
            )
            return value.substring(with: range).rangeOfCharacter(
                from: wordCharacters
            ) != nil
        }
        guard isWordCharacter(at: index) else {
            return value.rangeOfComposedCharacterSequence(at: index)
        }
        var start = index
        while start > 0 {
            let previous = value.rangeOfComposedCharacterSequence(
                at: start - 1
            )
            guard isWordCharacter(at: previous.location) else { break }
            start = previous.location
        }
        var end = NSMaxRange(
            value.rangeOfComposedCharacterSequence(at: index)
        )
        while end < value.length, isWordCharacter(at: end) {
            end = NSMaxRange(
                value.rangeOfComposedCharacterSequence(at: end)
            )
        }
        index = start
        return NSRange(location: index, length: end - index)
    }

    private static func copyText(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func messageLink(for message: Message) -> String {
        let guild = (message.guildID ?? model?.selectedGuildID)?.description ?? "@me"
        return "https://discord.com/channels/\(guild)/\(message.channelID)/\(message.id)"
    }

    private func beginEditing(
        row: MessageRowPresentation,
        at index: Int
    ) {
        guard editingMessageID == nil,
              items.indices.contains(index),
              items[index].messageID == row.id,
              let model,
              let actions
        else { return }
        removeActionCapsule()
        setTextSelection(nil)
        textSelectionGesture = nil
        hoveredRow = nil
        hoveredCompactTimestampRow = nil
        setHoveredMention(nil)
        setHoveredTextSpoiler(nil)
        setHoveredCodeBlock(nil)
        setHoveredComponentButton(nil)
        pressedCodeBlockCopyButton = nil
        pressedComponentButton = nil
        pressedActivationTarget = nil
        visualPressedComponentButton = nil
        componentButtonPressProgress = 0
        componentButtonPressAnimationDestination = nil
        componentButtonPressAnimationTask?.cancel()
        componentButtonPressAnimationTask = nil

        let layout = layouts[index]
        let contentOrigin = editingContentOrigin(in: layout)
        let width = max(80, bounds.width - contentOrigin.x - 14)
        let root = NativeTimelineEditingMessageContent(
            model: model,
            message: row.message,
            save: { [weak self] value in
                self?.endEditing(commit: value)
            },
            cancel: { [weak self] in
                self?.endEditing(commit: nil)
            },
            react: { emoji in
                actions.react(emoji, row.message)
            }
        )
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        let host = NativeTimelineEditingHost(rootView: AnyView(root))
        host.setAccessibilityIdentifier("message-editing-row-\(row.id)")
        host.fittingHeightDidChange = { [weak self, weak host] height in
            guard let host else { return }
            self?.updateEditingRowHeight(
                to: height,
                for: host
            )
        }
        host.frame = CGRect(
            x: contentOrigin.x,
            y: displayedRowOrigin(at: index) + contentOrigin.y,
            width: width,
            height: max(1, layout.contentFrame?.height ?? 24)
        )
        addSubview(host, positioned: .above, relativeTo: nil)
        host.layoutSubtreeIfNeeded()
        let fittedHeight = max(1, ceil(host.fittingSize.height))
        let fittedRowHeight = NativeTimelineEditingGeometry.rowHeight(
            avatarMaxY: layout.avatarFrame?.maxY,
            contentOriginY: contentOrigin.y,
            contentHeight: fittedHeight
        )
        editingMessageID = row.id
        editingRowIndexCache = index
        editingRowHost = host
        editingRowHeight = fittedRowHeight
        editingOverlayLocalFrame = CGRect(
            x: contentOrigin.x,
            y: contentOrigin.y,
            width: width,
            height: fittedHeight
        )
        editingRowScrollSnapshot = nil
        host.frame.size.height = fittedHeight
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        resizeForEditingChange(
            by: fittedRowHeight - layout.height
        )
        rebuildAccessibilityProxy(for: items[index].identifier)
        setNeedsDisplay(CGRect(
            x: 0,
            y: displayedRowOrigin(at: index),
            width: bounds.width,
            height: max(fittedRowHeight, layout.height)
        ))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusEditingTextView(in: host)
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host,
                  self.editingRowHost === host
            else { return }
            self.focusEditingTextView(in: host)
        }
    }

    private func reconcileEditingRow() {
        guard let messageID = editingMessageID else { return }
        if let index = editingRowIndexCache,
           items.indices.contains(index),
           items[index].messageID == messageID
        {
            positionEditingRow()
            return
        }
        guard let index = items.firstIndex(where: {
            $0.messageID == messageID
        }) else {
            endEditing(commit: nil)
            return
        }
        editingRowIndexCache = index
        positionEditingRow()
    }

    private func positionEditingRow() {
        guard let host = editingRowHost,
              editingMessageID != nil,
              let index = editingRowIndexCache,
              items.indices.contains(index),
              let localFrame = editingOverlayLocalFrame
        else { return }
        let frame = localFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
        if host.frame != frame {
            host.frame = frame
        }
    }

    private func updateEditingRowHeight(
        to fittedHeight: CGFloat,
        for host: NativeTimelineEditingHost
    ) {
        guard editingRowHost === host,
              let index = editingRowIndexCache,
              items.indices.contains(index),
              let localFrame = editingOverlayLocalFrame,
              let previousRowHeight = editingRowHeight
        else { return }
        let fittedHeight = max(1, ceil(fittedHeight))
        let nextRowHeight = NativeTimelineEditingGeometry.rowHeight(
            avatarMaxY: layouts[index].avatarFrame?.maxY,
            contentOriginY: localFrame.minY,
            contentHeight: fittedHeight
        )
        let delta = nextRowHeight - previousRowHeight
        guard abs(delta) > 0.5
                || abs(fittedHeight - localFrame.height) > 0.5
        else { return }

        editingRowHeight = nextRowHeight
        editingOverlayLocalFrame?.size.height = fittedHeight
        host.frame.size.height = fittedHeight
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        resizeForEditingChange(by: delta)
        rebuildAccessibilityProxy(for: items[index].identifier)
        setNeedsDisplay(visibleRect)
    }

    private func endEditing(commit value: String?) {
        guard let messageID = editingMessageID else { return }
        let index =
            editingRowIndexCache.flatMap { cachedIndex in
                guard items.indices.contains(cachedIndex),
                      items[cachedIndex].messageID == messageID
                else { return nil }
                return cachedIndex
            }
            ?? items.firstIndex(where: { $0.messageID == messageID })
        let message: Message?
        if let index,
           case let .message(row, _, _) = items[index]
        {
            message = row.message
        } else {
            message = nil
        }
        let delta: CGFloat
        if let index, let editingRowHeight {
            delta = editingRowHeight - layouts[index].height
        } else {
            delta = 0
        }
        editingRowHost?.removeFromSuperview()
        editingRowHost = nil
        editingTextView = nil
        editingMessageID = nil
        editingRowIndexCache = nil
        editingRowHeight = nil
        editingOverlayLocalFrame = nil
        editingRowScrollSnapshot = nil
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        resizeForEditingChange(by: -delta)
        window?.invalidateCursorRects(for: self)
        if let index {
            rebuildAccessibilityProxy(for: items[index].identifier)
        } else {
            reconcileAccessibilityProxies()
        }
        setNeedsDisplay(visibleRect)
        if let value, let message {
            actions?.edit(message, value)
        }
    }

    private var editingRowIndex: Int? {
        guard let index = editingRowIndexCache,
              items.indices.contains(index),
              layouts.indices.contains(index),
              rowOrigins.indices.contains(index),
              items[index].messageID == editingMessageID
        else { return nil }
        return index
    }

#if DEBUG
    var spoilerOverlayFramesForTesting:
        [NativeTimelineComponentRevealKey: CGRect]
    {
        spoilerOverlays.mapValues(\.frame)
    }

    var spoilerOverlayPillKeysForTesting:
        Set<NativeTimelineComponentRevealKey>
    {
        Set(
            spoilerOverlays.compactMap { key, overlay in
                overlay.hasPersistentPillForTesting ? key : nil
            }
        )
    }

    func reconcileSpoilerOverlaysForTesting() {
        reconcileSpoilerOverlays()
    }

    func animatedMediaKeysForTesting(
        row: MessageRowPresentation,
        layout: NativeTimelineRowLayout
    ) -> Set<NativeTimelineMediaKey> {
        animatedMediaKeys(for: row, layout: layout)
    }

    func installEditingGeometryForTesting(
        messageID: MessageID,
        rowIndex: Int,
        rowHeight: CGFloat
    ) {
        editingMessageID = messageID
        editingRowIndexCache = rowIndex
        editingRowHeight = rowHeight
    }

    var hasEditingGeometryForTesting: Bool {
        editingMessageID != nil
    }
#endif

    private var editingHeightDelta: CGFloat {
        guard let index = editingRowIndex,
              let editingRowHeight
        else { return 0 }
        return editingRowHeight - layouts[index].height
    }

    private var transientContentOriginY: CGFloat {
        NativeTimelineTransientRowGeometry.contentOriginY(
            base: baseContentOriginY,
            heightDelta: editingHeightDelta,
            minimum: ChatDetailLayoutPolicy.timelineTopPadding
        )
    }

    private var displayedContentHeight: CGFloat {
        contentOriginY
            + NativeTimelineTransientRowGeometry.contentHeight(
                base: contentHeight,
                replacementHeight: editingRowHeight,
                baseRowHeight: editingRowIndex.map { layouts[$0].height }
            )
            + bottomSpacerHeight
    }

    private func displayedRowOrigin(at index: Int) -> CGFloat {
        contentOriginY
            + NativeTimelineTransientRowGeometry.rowOrigin(
                base: rowOrigins[index],
                rowIndex: index,
                replacementIndex: editingRowIndex,
                replacementHeight: editingRowHeight,
                baseRowHeight: editingRowIndex.map { layouts[$0].height }
            )
    }

    private func displayedRowHeight(at index: Int) -> CGFloat {
        NativeTimelineTransientRowGeometry.rowHeight(
            base: layouts[index].height,
            rowIndex: index,
            replacementIndex: editingRowIndex,
            replacementHeight: editingRowHeight
        )
    }

    private func resizeForEditingChange(by delta: CGFloat) {
        guard abs(delta) > 0.5 else { return }
        let previousOriginY = contentOriginY
        contentOriginY = transientContentOriginY
        let size = NSSize(
            width: frame.width,
            height: max(displayedContentHeight, minimumHeight)
        )
        applyDocumentSize(size)
        enclosingScrollView?.tile()
        positionEditingRow()
        if abs(previousOriginY - contentOriginY) >= 0.5 {
            mentionPointerRegionCache.removeAll(keepingCapacity: true)
            codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            reconcileAccessibilityProxies()
            positionAnimatedMediaOverlays()
            reconcileBeginningSelectionOverlay()
            positionInlineVideoOverlays()
            positionLottieStickerOverlays()
            reconcileLoadingIndicators()
            positionSpoilerOverlays()
            needsDisplay = true
        }
    }

    private func editingContentOrigin(
        in layout: NativeTimelineRowLayout
    ) -> CGPoint {
        var frames: [CGRect] = []
        if let frame = layout.contentFrame {
            frames.append(frame)
        }
        frames.append(contentsOf: layout.linkedImageRegions.map(\.frame))
        frames.append(contentsOf: layout.attachmentRegions.map(\.frame))
        frames.append(contentsOf: layout.embedFrames)
        frames.append(contentsOf: layout.componentFrames)
        frames.append(contentsOf: layout.stickerFrames)
        if let frame = layout.threadFrame {
            frames.append(frame)
        }
        frames.append(contentsOf: layout.reactionRegions.map(\.frame))
        if let frame = layout.addReactionFrame {
            frames.append(frame)
        }
        if let first = frames.min(by: {
            $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
        }) {
            return first.origin
        }
        return CGPoint(
            x: layout.authorFrame?.minX ?? 64,
            y: (layout.authorFrame?.maxY ?? layout.replyFrame?.maxY ?? 3) + 3
        )
    }

    private func editingOverlayFrame(at index: Int) -> CGRect {
        guard let localFrame = editingOverlayLocalFrame else {
            return .zero
        }
        return localFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
    }

    private func freezeEditingRowForScroll() {
        guard editingRowScrollSnapshot == nil,
              let host = editingRowHost,
              host.alphaValue > 0.5,
              host.bounds.width > 0,
              host.bounds.height > 0,
              let representation = host.bitmapImageRepForCachingDisplay(
                  in: host.bounds
              )
        else { return }
        host.cacheDisplay(in: host.bounds, to: representation)
        representation.size = host.bounds.size
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(representation)
        editingRowScrollSnapshot = image
        host.alphaValue = 0
        if let index = editingRowIndexCache, items.indices.contains(index) {
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    private func restoreEditingRowAfterScroll() {
        guard let host = editingRowHost, host.alphaValue < 0.5 else {
            return
        }
        host.alphaValue = 1
        editingRowScrollSnapshot = nil
        if window?.isKeyWindow == true,
           let editingTextView,
           window?.firstResponder !== editingTextView
        {
            window?.makeFirstResponder(editingTextView)
        }
        if let index = editingRowIndexCache, items.indices.contains(index) {
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    private func focusEditingTextView(
        in host: NSView
    ) {
        guard let textView = firstDescendant(
            of: ComposerNSTextView.self,
            in: host
        ) else { return }
        editingTextView = textView
        guard let window = textView.window ?? self.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    private func firstDescendant<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        if let match = root as? View {
            return match
        }
        for child in root.subviews {
            if let match = firstDescendant(of: type, in: child) {
                return match
            }
        }
        return nil
    }

    private func actionItem(
        _ title: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let target = NativeTimelineMenuAction(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(NativeTimelineMenuAction.performAction),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        item.isEnabled = true
        let baseConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular
        )
        let configuration = isDestructive
            ? baseConfiguration.applying(
                NSImage.SymbolConfiguration(
                    paletteColors: [.systemRed]
                )
            )
            : baseConfiguration
        if let image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: title
        )?.withSymbolConfiguration(configuration) {
            image.isTemplate = !isDestructive
            item.image = image
        }
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
        if isDestructive {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        return item
    }

    private func confirmDelete(_ message: Message) {
        guard let window, let actions else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this message?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Message")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            actions.delete(message)
        }
    }
}

@MainActor
private final class NativeTimelineMenuAction: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func performAction() {
        handler()
    }
}

private struct NativeTimelineTextHit {
    let characterIndex: Int
    let url: URL?
    let mention: MentionPresentation?
    let spoilerRange: NSRange?
}

enum NativeTimelineTextGeometry {
    static func messageContentDrawingFrame(_ frame: CGRect) -> CGRect {
        var drawingFrame = frame
        drawingFrame.size.height = max(drawingFrame.height + 1, 20)
        return drawingFrame
    }
}

enum NativeTimelineBeginningText {
    static func title(
        _ beginning: NativeTimelineBeginning
    ) -> NativeTimelineAttributedTextBox {
        box(
            beginning.title,
            font: .systemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .largeTitle
                ).pointSize,
                weight: .bold
            ),
            color: .labelColor
        )
    }

    static func description(
        _ beginning: NativeTimelineBeginning
    ) -> NativeTimelineAttributedTextBox {
        box(
            beginning.description,
            font: .preferredFont(forTextStyle: .body),
            color: .secondaryLabelColor
        )
    }

    private static func box(
        _ value: String,
        font: NSFont,
        color: NSColor
    ) -> NativeTimelineAttributedTextBox {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NativeTimelineAttributedTextBox(
            NSAttributedString(
                string: value,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            )
        )
    }
}

nonisolated enum NativeTimelineTextSelectionGeometry {
    static func interactionFrame(
        contentFrame: CGRect,
        rowOrigin: CGFloat,
        canvasWidth: CGFloat
    ) -> CGRect {
        CGRect(
            x: contentFrame.minX,
            y: rowOrigin + contentFrame.minY,
            width: max(1, canvasWidth - contentFrame.minX),
            height: max(1, contentFrame.height)
        )
    }

    static func intersects(
        characterRange: CFRange,
        selectionRange: NSRange?
    ) -> Bool {
        guard let selectionRange else { return false }
        return NSIntersectionRange(
            selectionRange,
            NSRange(
                location: characterRange.location,
                length: max(1, characterRange.length)
            )
        ).length > 0
    }

    static func backgroundRanges(
        in value: NSAttributedString,
        selectionRange: NSRange
    ) -> [NSRange] {
        let available = NSRange(location: 0, length: value.length)
        let selection = NSIntersectionRange(selectionRange, available)
        guard selection.length > 0 else { return [] }

        var attachments: [NSRange] = []
        value.enumerateAttributes(in: selection) { attributes, range, _ in
            guard attributes[.discordEmojiToken] != nil
                    || attributes[.nativeTimelineMention] != nil
            else { return }
            let clipped = NSIntersectionRange(range, selection)
            if clipped.length > 0 {
                attachments.append(clipped)
            }
        }
        guard !attachments.isEmpty else { return [selection] }
        attachments.sort {
            $0.location == $1.location
                ? $0.length < $1.length
                : $0.location < $1.location
        }

        var result: [NSRange] = []
        var cursor = selection.location
        let selectionEnd = NSMaxRange(selection)
        for attachment in attachments {
            if attachment.location > cursor {
                result.append(NSRange(
                    location: cursor,
                    length: attachment.location - cursor
                ))
            }
            cursor = max(cursor, NSMaxRange(attachment))
        }
        if cursor < selectionEnd {
            result.append(NSRange(
                location: cursor,
                length: selectionEnd - cursor
            ))
        }
        return result
    }

    static func rects(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        range: NSRange
    ) -> [CGRect] {
        guard range.length > 0 else { return [] }
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return [] }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        let selectionStart = range.location
        let selectionEnd = NSMaxRange(range)
        var result: [CGRect] = []
        result.reserveCapacity(lines.count)

        for index in 0 ..< lines.count {
            let line = lines[index] as! CTLine
            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length
            let start = max(selectionStart, lineStart)
            let end = min(selectionEnd, lineEnd)
            guard start < end else { continue }

            let origin = origins[index]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
            let startOffset = CTLineGetOffsetForStringIndex(
                line,
                start,
                nil
            )
            let endOffset = CTLineGetOffsetForStringIndex(
                line,
                end,
                nil
            )
            let minX = outerFrame.minX
                + origin.x
                + min(startOffset, endOffset)
            let width = max(1, abs(endOffset - startOffset))
            result.append(CGRect(
                x: minX,
                y: outerFrame.maxY - origin.y - ascent - 0.5,
                width: width,
                height: max(1, ascent + descent + 1)
            ))
        }
        return result
    }
}

nonisolated struct NativeTimelineCodeBlockRegion: Equatable {
    let range: NSRange
    let backgroundFrame: CGRect
    let copyButtonFrame: CGRect
    let content: String
}

nonisolated enum NativeTimelineCodeBlockGeometry {
    private struct LineRange {
        let range: NSRange
        let startsBlock: Bool
    }

    static func regions(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect
    ) -> [NativeTimelineCodeBlockRegion] {
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0,
              containsCodeBlock(value)
        else { return [] }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        return regions(
            in: textFrame,
            outerFrame: frame,
            value: value
        )
    }

    static func regions(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        value: NSAttributedString
    ) -> [NativeTimelineCodeBlockRegion] {
        guard value.length > 0 else { return [] }
        let fullRange = NSRange(location: 0, length: value.length)
        var lines: [LineRange] = []
        value.enumerateAttribute(
            .discordMarkdownBlock,
            in: fullRange
        ) { rawValue, range, _ in
            guard rawValue as? String == "code",
                  range.length > 0
            else { return }
            let paragraph = value.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            lines.append(LineRange(
                range: range,
                startsBlock:
                    (paragraph?.paragraphSpacingBefore ?? 0) > 0
            ))
        }
        guard !lines.isEmpty else { return [] }

        var groups: [[LineRange]] = []
        for line in lines {
            if line.startsBlock || groups.isEmpty {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }

        let source = value.string as NSString
        return groups.compactMap { group in
            guard let first = group.first,
                  let last = group.last
            else { return nil }
            let range = NSRange(
                location: first.range.location,
                length: NSMaxRange(last.range)
                    - first.range.location
            )
            let rects = group.flatMap {
                NativeTimelineTextSelectionGeometry.rects(
                    in: textFrame,
                    outerFrame: outerFrame,
                    range: $0.range
                )
            }
            guard let firstRect = rects.first else { return nil }
            let union = rects.dropFirst().reduce(firstRect) {
                $0.union($1)
            }
            let backgroundFrame = CGRect(
                x: outerFrame.minX,
                y: union.minY
                    - NativeTimelineMarkdownChromeMetrics
                        .codeBlockInset,
                width: outerFrame.width,
                height: union.height
                    + NativeTimelineMarkdownChromeMetrics
                        .codeBlockInset * 2
            )
            let buttonWidth: CGFloat = 28
            let buttonFrame = CGRect(
                x: max(
                    backgroundFrame.minX,
                    backgroundFrame.maxX - buttonWidth - 4
                ),
                y: backgroundFrame.minY + 4,
                width: buttonWidth,
                height: buttonWidth
            )
            return NativeTimelineCodeBlockRegion(
                range: range,
                backgroundFrame: backgroundFrame,
                copyButtonFrame: buttonFrame,
                content: source.substring(with: range)
            )
        }
    }

    private static func containsCodeBlock(
        _ value: NSAttributedString
    ) -> Bool {
        var result = false
        value.enumerateAttribute(
            .discordMarkdownBlock,
            in: NSRange(location: 0, length: value.length),
            options: .longestEffectiveRangeNotRequired
        ) { rawValue, _, stop in
            guard rawValue as? String == "code" else { return }
            result = true
            stop.pointee = true
        }
        return result
    }
}

enum NativeTimelineTextHitTester {
    static func mention(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        point: CGPoint
    ) -> MentionPresentation? {
        hit(
            value: value,
            framesetter: framesetter,
            frame: frame,
            point: point
        )?.mention
    }

    static func mentionRegions(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect
    ) -> [NativeTimelineMentionHitRegion] {
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0
        else { return [] }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return [] }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var result: [NativeTimelineMentionHitRegion] = []
        for index in 0 ..< lines.count {
            let line = lines[index] as! CTLine
            let lineOrigin = origins[index]
            for case let run as CTRun
                in CTLineGetGlyphRuns(line) as NSArray
            {
                let range = CTRunGetStringRange(run)
                guard range.location >= 0,
                      range.location < value.length,
                      let mention = (
                          value.attribute(
                              .nativeTimelineMention,
                              at: range.location,
                              effectiveRange: nil
                          ) as? NativeTimelineMentionBox
                      )?.presentation
                else { continue }
                result.append(NativeTimelineMentionHitRegion(
                    characterIndex: range.location,
                    presentation: mention,
                    frame: inlineAttachmentFrame(
                        run: run,
                        line: line,
                        lineOrigin: lineOrigin,
                        outerFrame: frame
                    )
                ))
            }
        }
        return result
    }

    static func mentionAnchorFrame(
        box: NativeTimelineAttributedTextBox,
        frame: CGRect,
        characterIndex: Int,
        rawToken: String
    ) -> CGRect? {
        var drawingFrame = frame
        drawingFrame.size.height += box.layoutHeightAdjustment
        return mentionAnchorFrame(
            value: box.value,
            framesetter: box.framesetter,
            frame: drawingFrame,
            characterIndex: characterIndex,
            rawToken: rawToken
        )
    }

    static func rangeFrame(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        range: NSRange
    ) -> CGRect? {
        guard value.length > 0,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= value.length,
              frame.width > 0,
              frame.height > 0
        else { return nil }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return nil }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var result: CGRect?
        for lineIndex in 0 ..< lines.count {
            let line = lines[lineIndex] as! CTLine
            let lineRange = NSRange(
                location: CTLineGetStringRange(line).location,
                length: CTLineGetStringRange(line).length
            )
            let intersection = NSIntersectionRange(lineRange, range)
            guard intersection.length > 0 else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
            let lineOrigin = origins[lineIndex]
            let startX = lineOrigin.x + CTLineGetOffsetForStringIndex(
                line,
                intersection.location,
                nil
            )
            let endX = lineOrigin.x + CTLineGetOffsetForStringIndex(
                line,
                NSMaxRange(intersection),
                nil
            )
            let height = max(1, ascent + descent + leading)
            let localBottom = lineOrigin.y - descent
            let segment = CGRect(
                x: frame.minX + min(startX, endX),
                y: frame.maxY - localBottom - height,
                width: max(1, abs(endX - startX)),
                height: height
            )
            result = result.map { $0.union(segment) } ?? segment
        }
        guard let result,
              [result.minX, result.minY, result.width, result.height]
                .allSatisfy(\.isFinite),
              !result.isEmpty
        else { return nil }
        return result
    }

    static func mentionAnchorFrame(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        characterIndex: Int,
        rawToken: String
    ) -> CGRect? {
        guard value.length > 0,
              value.string.indices.isEmpty == false,
              value.length > characterIndex,
              characterIndex >= 0,
              frame.width > 0,
              frame.height > 0
        else { return nil }
        var effectiveRange = NSRange(location: 0, length: 0)
        guard let mention = value.attribute(
            .nativeTimelineMention,
            at: characterIndex,
            effectiveRange: &effectiveRange
        ) as? NativeTimelineMentionBox,
            mention.presentation.rawToken == rawToken,
            effectiveRange.length > 0
        else { return nil }

        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return nil }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var anchor: CGRect?
        for lineIndex in 0 ..< lines.count {
            let line = lines[lineIndex] as! CTLine
            let lineOrigin = origins[lineIndex]
            for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
                let range = CTRunGetStringRange(run)
                guard range.location <= characterIndex,
                      characterIndex
                        < range.location + max(1, range.length)
                else { continue }
                anchor = inlineAttachmentFrame(
                    run: run,
                    line: line,
                    lineOrigin: lineOrigin,
                    outerFrame: frame
                )
                break
            }
            if anchor != nil { break }
        }
        guard let anchor else { return nil }
        let values = [
            anchor.minX,
            anchor.minY,
            anchor.width,
            anchor.height,
        ]
        return values.allSatisfy(\.isFinite) && !anchor.isEmpty
            ? anchor
            : nil
    }

    private static func inlineAttachmentFrame(
        run: CTRun,
        line: CTLine,
        lineOrigin: CGPoint,
        outerFrame: CGRect
    ) -> CGRect {
        let range = CTRunGetStringRange(run)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTRunGetTypographicBounds(
            run,
            CFRange(location: 0, length: 0),
            &ascent,
            &descent,
            &leading
        ))
        let x = lineOrigin.x + CTLineGetOffsetForStringIndex(
            line,
            range.location,
            nil
        )
        let height = max(1, ascent + descent)
        let localBottom = lineOrigin.y - descent
        return CGRect(
            x: outerFrame.minX + x,
            y: outerFrame.maxY - localBottom - height,
            width: max(1, width),
            height: height
        )
    }

    fileprivate static func hit(
        box: NativeTimelineAttributedTextBox,
        frame: CGRect,
        point: CGPoint
    ) -> NativeTimelineTextHit? {
        var drawingFrame = frame
        drawingFrame.size.height += box.layoutHeightAdjustment
        return hit(
            value: box.value,
            framesetter: box.framesetter,
            frame: drawingFrame,
            point: point
        )
    }

    fileprivate static func hit(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        point: CGPoint
    ) -> NativeTimelineTextHit? {
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0,
              frame.contains(point)
        else { return nil }

        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return nil }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        // Inline mentions are taller than the surrounding text line. Check
        // their exact painted run rectangles first so the whole visible pill,
        // including its top and bottom padding, is clickable.
        for index in 0 ..< lines.count {
            let line = lines[index] as! CTLine
            let lineOrigin = origins[index]
            for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
                let range = CTRunGetStringRange(run)
                let attachmentFrame = inlineAttachmentFrame(
                    run: run,
                    line: line,
                    lineOrigin: lineOrigin,
                    outerFrame: frame
                )
                guard range.location >= 0,
                      range.location < value.length,
                      attachmentFrame.contains(point)
                else { continue }
                var spoilerRange = NSRange(location: 0, length: 0)
                let isSpoiler = (
                    value.attribute(
                        .discordMarkdownSpoiler,
                        at: range.location,
                        effectiveRange: &spoilerRange
                    ) as? NSNumber
                )?.boolValue == true
                if isSpoiler, spoilerRange.length > 0 {
                    return NativeTimelineTextHit(
                        characterIndex: range.location,
                        url: nil,
                        mention: nil,
                        spoilerRange: spoilerRange
                    )
                }
                guard
                      let mention = (
                          value.attribute(
                              .nativeTimelineMention,
                              at: range.location,
                              effectiveRange: nil
                          ) as? NativeTimelineMentionBox
                      )?.presentation
                else { continue }
                return NativeTimelineTextHit(
                    characterIndex: range.location,
                    url: nil,
                    mention: mention,
                    spoilerRange: nil
                )
            }
        }
        let local = CGPoint(
            x: point.x - frame.minX,
            y: frame.maxY - point.y
        )
        for index in 0 ..< lines.count {
            let line = lines[index] as! CTLine
            let origin = origins[index]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            ))
            guard local.y >= origin.y - descent,
                  local.y <= origin.y + ascent + leading,
                  local.x >= origin.x,
                  local.x <= origin.x + max(1, width)
            else { continue }

            let stringIndex = CTLineGetStringIndexForPosition(
                line,
                CGPoint(x: local.x - origin.x, y: 0)
            )
            guard stringIndex != kCFNotFound else { return nil }
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.length > 0 else { return nil }
            let characterIndex = min(
                value.length - 1,
                max(
                    lineRange.location,
                    min(
                        stringIndex,
                        lineRange.location + lineRange.length - 1
                    )
                )
            )
            let mention = (
                value.attribute(
                    .nativeTimelineMention,
                    at: characterIndex,
                    effectiveRange: nil
                ) as? NativeTimelineMentionBox
            )?.presentation
            let rawLink = value.attribute(
                .link,
                at: characterIndex,
                effectiveRange: nil
            )
            var spoilerRange = NSRange(location: 0, length: 0)
            let isSpoiler = (
                value.attribute(
                    .discordMarkdownSpoiler,
                    at: characterIndex,
                    effectiveRange: &spoilerRange
                ) as? NSNumber
            )?.boolValue == true
            let url: URL? = switch rawLink {
            case let value as URL:
                value
            case let value as NSURL:
                value as URL
            case let value as String:
                URL(string: value)
            default:
                nil
            }
            return NativeTimelineTextHit(
                characterIndex: characterIndex,
                url: url,
                mention: mention,
                spoilerRange:
                    isSpoiler && spoilerRange.length > 0
                        ? spoilerRange
                        : nil
            )
        }
        return nil
    }

    static func caretIndex(
        box: NativeTimelineAttributedTextBox,
        frame: CGRect,
        point: CGPoint,
        clampsToText: Bool
    ) -> Int? {
        var drawingFrame = frame
        drawingFrame.size.height += box.layoutHeightAdjustment
        return caretIndex(
            value: box.value,
            framesetter: box.framesetter,
            frame: drawingFrame,
            point: point,
            clampsToText: clampsToText
        )
    }

    static func caretIndex(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        point: CGPoint,
        clampsToText: Bool
    ) -> Int? {
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0,
              clampsToText || frame.contains(point)
        else { return nil }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return nil }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        let local = CGPoint(
            x: point.x - frame.minX,
            y: frame.maxY - point.y
        )
        if clampsToText {
            let firstLine = lines[0] as! CTLine
            let lastLine = lines[lines.count - 1] as! CTLine
            let firstOrigin = origins[0]
            let lastOrigin = origins[lines.count - 1]
            var firstAscent: CGFloat = 0
            var firstDescent: CGFloat = 0
            var firstLeading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                firstLine,
                &firstAscent,
                &firstDescent,
                &firstLeading
            )
            var lastAscent: CGFloat = 0
            var lastDescent: CGFloat = 0
            var lastLeading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                lastLine,
                &lastAscent,
                &lastDescent,
                &lastLeading
            )
            if local.y > firstOrigin.y + firstAscent + firstLeading {
                return max(0, CTLineGetStringRange(firstLine).location)
            }
            if local.y < lastOrigin.y - lastDescent {
                let range = CTLineGetStringRange(lastLine)
                return min(value.length, range.location + range.length)
            }
        }
        var selectedLineIndex: Int?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0 ..< lines.count {
            let line = lines[index] as! CTLine
            let origin = origins[index]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
            let lower = origin.y - descent
            let upper = origin.y + ascent + leading
            if local.y >= lower, local.y <= upper {
                selectedLineIndex = index
                break
            }
            guard clampsToText else { continue }
            let distance = local.y < lower
                ? lower - local.y
                : local.y - upper
            if distance < nearestDistance {
                nearestDistance = distance
                selectedLineIndex = index
            }
        }
        guard let selectedLineIndex else { return nil }
        let line = lines[selectedLineIndex] as! CTLine
        let origin = origins[selectedLineIndex]
        let lineRange = CTLineGetStringRange(line)
        guard lineRange.length > 0 else { return nil }
        let width = CGFloat(CTLineGetTypographicBounds(
            line,
            nil,
            nil,
            nil
        ))
        if !clampsToText,
           (local.x < origin.x || local.x > origin.x + max(1, width))
        {
            return nil
        }
        if local.x <= origin.x {
            return lineRange.location
        }
        if local.x >= origin.x + width {
            return min(
                value.length,
                lineRange.location + lineRange.length
            )
        }
        let index = CTLineGetStringIndexForPosition(
            line,
            CGPoint(x: local.x - origin.x, y: 0)
        )
        guard index != kCFNotFound else { return nil }
        return min(value.length, max(0, index))
    }
}

@MainActor
private enum NativeTimelineRowPainter {
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
            drawMessage(
                row,
                layout: layout,
                bounds: bounds,
                model: model,
                highlighted: isHighlighted,
                isHovered: isHovered,
                showsCompactTimestamp: showsCompactTimestamp,
                hoveredMention: hoveredMention,
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
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBeginning(
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

    private static func drawLoader(
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

    private static func drawMessage(
        _ row: MessageRowPresentation,
        layout: NativeTimelineRowLayout,
        bounds: CGRect,
        model: AppModel?,
        highlighted: Bool,
        isHovered: Bool,
        showsCompactTimestamp: Bool,
        hoveredMention: NativeTimelineMentionHover?,
        hoveredTextSpoiler: NativeTimelineTextSpoilerHover?,
        hoveredComponentButton: NativeTimelineComponentButtonTarget?,
        pressedComponentButton: NativeTimelineComponentButtonTarget?,
        componentButtonPressProgress: CGFloat,
        hidesMessageContent: Bool,
        hoveredReactionID: String?,
        isAddReactionHovered: Bool,
        textSelection: NativeTimelineTextSelection?,
        revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState,
        spoilerRevealStore: NativeTimelineSpoilerRevealStore?,
        reactionCountTransitions:
            [String: NativeTimelineReactionCountTransition]
    ) {
        let message = row.message
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }
        if let frame = layout.daySeparatorFrame {
            dateSeparator(date: message.timestamp, frame: frame)
        }
        if let frame = layout.unreadSeparatorFrame {
            newMessagesSeparator(frame: frame)
        }

        let author = model?.authorPresentation(for: message)
        if let frame = layout.avatarFrame {
            let presentedAuthor =
                author?.user
                ?? message.author
            avatar(
                name: presentedAuthor.displayName,
                url:
                    presentedAuthor.avatarURL
                        ?? message.author.avatarURL,
                in: frame
            )
            if let decorationURL =
                presentedAuthor.avatarDecorationURL
                    ?? message.author.avatarDecorationURL
            {
                avatarDecoration(
                    url: decorationURL,
                    around: frame
                )
            }
        }
        if let frame = layout.authorFrame {
            let presentedAuthor =
                author?.user
                ?? message.author
            text(
                presentedAuthor.displayName,
                in: frame,
                font: .systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                    weight: .semibold
                ),
                color: presentedAuthor.isBot
                    ? .controlAccentColor
                    : roleColor(author?.roleColorHex) ?? .labelColor
            )
        }
        if let frame = layout.botBadgeFrame {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                concentricRoundedRect: frame,
                cornerRadius: 3
            ).fill()
            text(
                "APP",
                in: frame,
                font: .systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
                    weight: .bold
                ),
                color: .white,
                alignment: .center
            )
        }
        if let frame = layout.timestampFrame {
            text(
                NativeTimelineTimestamp.text(for: message.timestamp),
                in: frame,
                font: .preferredFont(forTextStyle: .caption1),
                color: .secondaryLabelColor
            )
        }
        if showsCompactTimestamp,
           let frame = layout.compactTimestampFrame
        {
            text(
                NativeTimelineTimestamp.text(for: message.timestamp),
                in: frame,
                font: NativeTimelineCompactTimestampMetrics.font,
                color: .tertiaryLabelColor,
                alignment: .center,
                lineBreakMode: .byClipping
            )
        }
        if let frame = layout.editedFrame {
            text(
                "(edited)",
                in: frame,
                font: .preferredFont(forTextStyle: .caption2),
                color: .tertiaryLabelColor
            )
        }
        if let frame = layout.replyFrame, let preview = row.replyPreview {
            replyContext(
                preview: preview,
                isAvailable: row.isReplyAvailable,
                frame: frame,
                model: model
            )
        }
        if let region = layout.commandInvocationRegion {
            commandInvocation(
                region,
                message: message
            )
        }
        if hidesMessageContent {
            return
        }
        if let frame = layout.systemIconFrame {
            let currentUserID = model?.snapshot?.currentUser.id
            systemSymbol(
                SystemMessagePresentation.systemImage(
                    for: message,
                    currentUserID: currentUserID
                ),
                in: frame,
                color:
                    SystemMessagePresentation.usesSuccessColor(
                        for: message,
                        currentUserID: currentUserID
                    )
                        ? .systemGreen
                        : .secondaryLabelColor,
                inset: 1
            )
        }
        if let frame = layout.contentFrame,
           let attributedContent = layout.attributedContent,
           let contentFramesetter = layout.contentFramesetter
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(
                CGFloat(
                    MessageOutboxPresentation.textOpacity(
                        for: message.outboxState
                    )
                )
            )
            // CoreText requires the full fractional typographic line box to
            // produce a CTLine. The established compact row is 18 points high,
            // so give the frame a little layout headroom without changing the
            // visible row geometry or adding spacing between grouped messages.
            let drawingFrame = NativeTimelineTextGeometry
                .messageContentDrawingFrame(frame)
            attributedText(
                attributedContent,
                framesetter: contentFramesetter,
                in: drawingFrame,
                model: model,
                selectionRange:
                    textSelection?.itemIdentifier == .message(message.id)
                        && textSelection?.region == .content
                    ? textSelection?.range
                    : nil,
                hoveredMentionCharacterIndex:
                    hoveredMention?.itemIdentifier == .message(message.id)
                        && hoveredMention?.region == .content
                    ? hoveredMention?.characterIndex
                    : nil,
                hoveredSpoilerRangeLocation:
                    hoveredTextSpoiler?.itemIdentifier
                        == .message(message.id)
                        && hoveredTextSpoiler?.region == .content
                    ? hoveredTextSpoiler?.rangeLocation
                    : nil,
                revealedSpoilerLocations:
                    revealedTextSpoilerState.locations(in: .content)
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        for region in layout.linkedImageRegions {
            let key = NativeTimelineMediaKey.media(
                region.reference.displayURL,
                maximumPixelDimension: region.reference.isEmoji ? 96 : 720
            )
            if let image = mediaImage(for: key) {
                drawImage(
                    image,
                    in: region.frame,
                    cornerRadius: region.reference.isEmoji ? 7 : 10,
                    fillsFrame: !region.reference.isEmoji && !region.reference.isSticker
                )
            } else {
                card(
                    region.frame,
                    tint: region.reference.isEmoji || region.reference.isSticker
                        ? .clear
                        : .secondaryLabelColor
                )
                text(
                    region.reference.label,
                    in: region.frame.insetBy(dx: 12, dy: 10),
                    font: .systemFont(ofSize: 12, weight: .medium),
                    color: .secondaryLabelColor,
                    lineBreakMode: .byTruncatingMiddle
                )
            }
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(
            CGFloat(
                MessageOutboxPresentation.mediaOpacity(
                    for: message.outboxState
                )
            )
        )
        for region in layout.attachmentRegions {
            let attachment = region.attachment
            let isConcealed =
                spoilerRevealStore.map {
                    NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                        messageID: message.id,
                        contentID: "attachment:\(attachment.id)",
                        isSpoiler: attachment.isSpoiler,
                        store: $0
                    )
                } ?? false
            if isConcealed {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius: 8
                )
                continue
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(
                concentricRoundedRect: region.frame,
                cornerRadius: 8
            ).fill()
            let key = NativeTimelineMediaKey.media(
                attachment.proxyURL ?? attachment.url
            )
            switch attachment.mediaKind {
            case .image, .animatedImage:
                if let image = mediaImage(for: key) {
                    drawImage(
                        image,
                        in: region.frame,
                        cornerRadius: 8,
                        fillsFrame: false
                    )
                }
            case .video:
                systemSymbol(
                    "film",
                    in: region.frame,
                    color: .secondaryLabelColor,
                    inset: 30
                )
                mediaPlayGlyph(in: region.frame)
            case .audio:
                attachmentAudio(
                    attachment,
                    in: region.frame
                )
            case .file:
                systemSymbol(
                    "doc",
                    in: CGRect(
                        x: region.frame.midX - 19,
                        y: region.frame.midY - 34,
                        width: 38,
                        height: 38
                    ),
                    color: .labelColor,
                    inset: 1
                )
                text(
                    attachment.filename,
                    in: CGRect(
                        x: region.frame.minX + 12,
                        y: region.frame.midY + 11,
                        width: max(1, region.frame.width - 24),
                        height: 38
                    ),
                    font: .preferredFont(forTextStyle: .body),
                    color: .labelColor,
                    alignment: .center,
                    lineBreakMode: .byTruncatingTail
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        for region in layout.embedRegions {
            if region.kind == .card {
                embedCard(region.frame, accentColor: region.accentColor)
            }
            for (textIndex, textRegion) in
                region.textRegions.enumerated()
            {
                attributedText(
                    textRegion.text,
                    in: textRegion.frame,
                    model: model,
                    selectionRange:
                        textSelection?.itemIdentifier
                            == .message(message.id)
                            && textSelection?.region == .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        ? textSelection?.range
                        : nil,
                    hoveredMentionCharacterIndex:
                        hoveredMention?.itemIdentifier
                            == .message(message.id)
                            && hoveredMention?.region == .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        ? hoveredMention?.characterIndex
                        : nil,
                    hoveredSpoilerRangeLocation:
                        hoveredTextSpoiler?.itemIdentifier
                            == .message(message.id)
                            && hoveredTextSpoiler?.region == .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        ? hoveredTextSpoiler?.rangeLocation
                        : nil,
                    revealedSpoilerLocations:
                        revealedTextSpoilerState.locations(
                            in: .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        )
                )
            }
            for imageRegion in region.imageRegions {
                if let image = mediaImage(
                    for: .media(
                        imageRegion.url,
                        maximumPixelDimension:
                            imageRegion.maximumPixelDimension
                    )
                ) {
                    drawImage(
                        image,
                        in: imageRegion.frame,
                        cornerRadius: imageRegion.cornerRadius,
                        fillsFrame: false
                    )
                } else {
                    systemSymbol(
                        imageRegion.fallbackSystemImage,
                        in: imageRegion.frame,
                        color: .secondaryLabelColor,
                        inset: imageRegion.frame.width >= 70 ? 22 : 2
                    )
                }
            }
            if let frame = region.mediaFrame,
               let url = region.mediaURL
            {
                // The native player overlay owns both the loading surface and
                // playback for autoplay video. Painting another rounded
                // placeholder into the cached row leaves a highlighted slice
                // behind if the bottom-anchored row moves before the player
                // layer is repositioned.
                if NativeTimelineInlineVideoPresentationPolicy
                    .canvasOwnsLoadingSurface(
                        mediaIsVideo: region.mediaIsVideo,
                        autoplaysInline: region.mediaAutoplaysInline
                    )
                {
                    NativeTimelineSemanticColor.opacity(
                        .secondaryLabelColor,
                        0.10
                    ).setFill()
                    NSBezierPath(
                        concentricRoundedRect: frame,
                        cornerRadius: 8
                    ).fill()
                    let image = mediaImage(for: .media(url))
                    if let image {
                        drawImage(
                            image,
                            in: frame,
                            cornerRadius: 8,
                            fillsFrame: false
                        )
                        if region.mediaIsVideo {
                            mediaPlayGlyph(in: frame)
                        }
                    } else if region.mediaIsVideo {
                        systemSymbol(
                            "film",
                            in: frame,
                            color: .secondaryLabelColor,
                            inset: 30
                        )
                        mediaPlayGlyph(in: frame)
                    }
                }
            }
        }
        for (layoutIndex, componentLayout) in
            layout.componentLayouts.enumerated()
        {
            drawComponents(
                componentLayout,
                model: model,
                messageID: message.id,
                layoutIndex: layoutIndex,
                textSelection: textSelection,
                hoveredMention: hoveredMention,
                hoveredTextSpoiler: hoveredTextSpoiler,
                revealedTextSpoilerState:
                    revealedTextSpoilerState,
                spoilerRevealStore: spoilerRevealStore,
                hoveredComponentButton: hoveredComponentButton,
                pressedComponentButton: pressedComponentButton,
                componentButtonPressProgress:
                    componentButtonPressProgress
            )
        }
        for (index, frame) in layout.stickerFrames.enumerated() {
            let sticker = message.stickers.indices.contains(index)
                ? message.stickers[index]
                : nil
            if sticker?.format == .lottie {
                // A bounded native Lottie overlay owns loading, playback, and
                // reduced-motion presentation for this exact layout frame.
                continue
            }
            let image = sticker?.mediaURL.flatMap {
                mediaImage(
                    for: .media($0, maximumPixelDimension: 384)
                )
            }
            if let image {
                drawImage(image, in: frame, cornerRadius: 8, fillsFrame: false)
            } else {
                card(frame, tint: .systemPink)
                text(
                    sticker?.name ?? "Sticker",
                    in: frame.insetBy(dx: 12, dy: 10),
                    font: .systemFont(ofSize: 13, weight: .medium),
                    color: .secondaryLabelColor
                )
            }
        }
        if let frame = layout.threadFrame {
            if let thread = message.thread {
                threadSummary(thread, in: frame)
            }
        }
        for region in layout.reactionRegions {
            reaction(
                region,
                model: model,
                isHovered: hoveredReactionID == region.reaction.id,
                countTransition: reactionCountTransitions[
                    region.reaction.id
                ]
            )
        }
        if let frame = layout.addReactionFrame {
            reactionAddControl(
                in: frame,
                isHovered: isAddReactionHovered
            )
        }
        if let region = layout.ephemeralRegion {
            ephemeralFooter(region)
        }
        if let frame = layout.failedFrame {
            systemSymbol(
                "exclamationmark.circle",
                in: CGRect(
                    x: frame.minX,
                    y: frame.minY + 1,
                    width: 12,
                    height: 12
                ),
                color: .systemRed,
                inset: 0
            )
            text(
                "Failed",
                in: CGRect(
                    x: frame.minX + 16,
                    y: frame.minY,
                    width: max(0, frame.width - 16),
                    height: frame.height
                ),
                font: .preferredFont(forTextStyle: .caption2),
                color: .systemRed
            )
        }
    }

    private static func avatar(
        name: String,
        url: URL?,
        in frame: CGRect
    ) {
        if let url,
           let image = mediaImage(for: .avatar(url))
        {
            drawImage(image, in: frame, cornerRadius: frame.width / 2, fillsFrame: true)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: frame).addClip()
        let accent = NSColor.controlAccentColor
        let lighter =
            accent.blended(withFraction: 0.28, of: .white)
            ?? accent
        let darker =
            accent.blended(withFraction: 0.18, of: .black)
            ?? accent
        NSGradient(starting: darker, ending: lighter)?
            .draw(in: frame, angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        text(
            String(name.prefix(1)).uppercased(),
            in: frame.insetBy(
                dx: 4,
                dy: frame.height * 0.26
            ),
            font: .systemFont(
                ofSize: frame.height * 0.42,
                weight: .semibold
            ),
            color: .labelColor,
            alignment: .center
        )
    }

    private static func avatarDecoration(
        url: URL,
        around avatarFrame: CGRect
    ) {
        guard let image = mediaImage(for: .avatarDecoration(url)) else {
            return
        }
        drawImage(
            image,
            in:
                NativeTimelineAvatarPresentation
                    .decorationFrame(around: avatarFrame),
            cornerRadius: 0,
            fillsFrame: false
        )
    }

    private static func replyContext(
        preview: MessageReplyPreview,
        isAvailable: Bool,
        frame: CGRect,
        model: AppModel?
    ) {
        let connectorFrame = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: 30,
            height: 20
        )
        replyConnector(in: connectorFrame)

        let avatarFrame =
            NativeTimelineAvatarPresentation
                .replyAvatarFrame(in: frame)
        avatar(
            name: preview.author.displayName,
            url: preview.author.avatarURL,
            in: avatarFrame
        )

        let authorFont = NativeTimelineReplyMetrics.authorFont
        let authorWidth = NativeTimelineReplyMetrics.textWidth(
            preview.author.displayName,
            font: authorFont
        )
        let authorFrame = CGRect(
            x: avatarFrame.maxX + 5,
            y: frame.minY,
            width: min(authorWidth, max(0, frame.maxX - avatarFrame.maxX - 5)),
            height: 20
        )
        text(
            preview.author.displayName,
            in: authorFrame,
            font: authorFont,
            color: .labelColor
        )

        let summary: String
        if isAvailable, let model {
            summary = MessageReplySummary.text(
                content: preview.content,
                mentionLabel: MessageMentionResolver(model: model).label
            )
        } else if isAvailable {
            summary = MessageReplySummary.text(content: preview.content)
        } else {
            summary = "Original unavailable"
        }
        text(
            summary,
            in: CGRect(
                x: authorFrame.maxX + 5,
                y: frame.minY,
                width: max(0, frame.maxX - 48 - authorFrame.maxX - 5),
                height: 20
            ),
            font: NativeTimelineReplyMetrics.summaryFont,
            color: .secondaryLabelColor
        )
    }

    private static func replyConnector(in connectorFrame: CGRect) {
        let stemX = connectorFrame.minX + 19
        let horizontalY = connectorFrame.minY + connectorFrame.height * 0.46
        let connector = NSBezierPath()
        connector.lineWidth = 1.25
        connector.lineCapStyle = .round
        connector.move(to: CGPoint(x: stemX, y: connectorFrame.maxY))
        connector.line(to: CGPoint(x: stemX, y: horizontalY + 4))
        connector.curve(
            to: CGPoint(x: stemX + 4, y: horizontalY),
            controlPoint1: CGPoint(x: stemX, y: horizontalY + 1.8),
            controlPoint2: CGPoint(x: stemX + 2.2, y: horizontalY)
        )
        connector.line(to: CGPoint(x: connectorFrame.maxX, y: horizontalY))
        NSColor.tertiaryLabelColor.setStroke()
        connector.stroke()
    }

    private static func commandInvocation(
        _ region: NativeTimelineRowLayout.CommandInvocationRegion,
        message: Message
    ) {
        replyConnector(in: region.connectorFrame)
        let user = message.interactionMetadata?.user
        if let frame = region.avatarFrame, let user {
            avatar(
                name: user.displayName,
                url: user.avatarURL,
                in: frame
            )
        } else if let frame = region.fallbackAvatarFrame {
            systemSymbol(
                "person.crop.circle",
                in: frame,
                color: .secondaryLabelColor,
                inset: 0
            )
        }
        text(
            user?.displayName ?? "Someone",
            in: region.userFrame,
            font: .systemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .caption2
                ).pointSize,
                weight: .semibold
            ),
            color: .labelColor
        )
        text(
            "used",
            in: region.usedFrame,
            font: .preferredFont(forTextStyle: .caption1),
            color: .secondaryLabelColor
        )
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(
            roundedRect: region.pillFrame,
            xRadius: 4,
            yRadius: 4
        ).fill()
        systemSymbol(
            "xmark.triangle.circle.square.fill",
            in: region.commandSymbolFrame,
            color: .controlAccentColor,
            inset: 0,
            weight: .semibold
        )
        text(
            message.interactionMetadata?.displayName ?? "command",
            in: region.commandFrame,
            font: .systemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .caption1
                ).pointSize,
                weight: .semibold
            ),
            color: .controlAccentColor,
            lineBreakMode: .byTruncatingTail
        )
    }

    private static func ephemeralFooter(
        _ region: NativeTimelineRowLayout.EphemeralRegion
    ) {
        systemSymbol(
            "eye",
            in: region.eyeFrame,
            color: .secondaryLabelColor,
            inset: 0
        )
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        text(
            "Only you can see this",
            in: region.visibilityFrame,
            font: font,
            color: .secondaryLabelColor
        )
        text(
            "•",
            in: region.bulletFrame,
            font: font,
            color: .secondaryLabelColor
        )
        text(
            "Dismiss message",
            in: region.dismissFrame,
            font: font,
            color: .controlAccentColor
        )
    }

    private static func dateSeparator(date: Date, frame: CGRect) {
        let label = date.formatted(
            .dateTime.day().month(.wide).year()
        )
        let labelFrame = NativeTimelineDateSeparatorMetrics.labelFrame(
            for: label,
            in: frame
        )
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        CGRect(
            x: frame.minX,
            y: frame.midY,
            width: max(
                0,
                labelFrame.minX
                    - NativeTimelineDateSeparatorMetrics.lineSpacing
                    - frame.minX
            ),
            height: 1
        ).fill()
        CGRect(
            x: labelFrame.maxX
                + NativeTimelineDateSeparatorMetrics.lineSpacing,
            y: frame.midY,
            width: max(
                0,
                frame.maxX
                    - labelFrame.maxX
                    - NativeTimelineDateSeparatorMetrics.lineSpacing
            ),
            height: 1
        ).fill()
        text(
            label,
            in: labelFrame,
            font: NativeTimelineDateSeparatorMetrics.font,
            color: .secondaryLabelColor,
            alignment: .center,
            lineBreakMode: .byClipping
        )
    }

    private static func newMessagesSeparator(frame: CGRect) {
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let labelWidth = ceil(
            measuredTextWidth("NEW", font: font) + 14
        )
        let capsuleFrame = CGRect(
            x: frame.maxX - labelWidth,
            y: frame.minY
                + NativeTimelineUnreadSeparatorMetrics.verticalPadding,
            width: labelWidth,
            height: NativeTimelineUnreadSeparatorMetrics.capsuleHeight
        )
        NSColor.systemRed.setFill()
        CGRect(
            x: frame.minX,
            y: frame.midY,
            width: max(0, capsuleFrame.minX - 8 - frame.minX),
            height: 1
        ).fill()
        NSBezierPath(
            roundedRect: capsuleFrame,
            xRadius: capsuleFrame.height / 2,
            yRadius: capsuleFrame.height / 2
        ).fill()
        text(
            "NEW",
            in: capsuleFrame,
            font: font,
            color: .white,
            alignment: .center,
            lineBreakMode: .byClipping
        )
    }

    private static func card(_ frame: CGRect, tint: NSColor) {
        tint.withAlphaComponent(0.09).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 8
        ).fill()
        tint.withAlphaComponent(0.55).setStroke()
        let edge = NSBezierPath()
        edge.lineWidth = 3
        edge.move(to: CGPoint(x: frame.minX + 1.5, y: frame.minY + 7))
        edge.line(to: CGPoint(x: frame.minX + 1.5, y: frame.maxY - 7))
        edge.stroke()
    }

    private static func embedCard(
        _ frame: CGRect,
        accentColor: UInt32?
    ) {
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius
        )
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NativeTimelineSemanticColor.opacity(
            .secondaryLabelColor,
            0.08
        ).setFill()
        frame.fill()
        (
            roleColor(accentColor)
                ?? NativeTimelineSemanticColor.opacity(
                    .secondaryLabelColor,
                    0.5
                )
        ).setFill()
        CGRect(
            x: frame.minX,
            y: frame.minY,
            width: 4,
            height: frame.height
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        NativeTimelineSemanticColor.opacity(
            .labelColor,
            0.08
        ).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius - 0.5
        )
        border.lineWidth = 1
        border.stroke()
    }

    private static func drawComponents(
        _ layout: NativeTimelineComponentLayout,
        model: AppModel?,
        messageID: MessageID,
        layoutIndex: Int,
        textSelection: NativeTimelineTextSelection?,
        hoveredMention: NativeTimelineMentionHover?,
        hoveredTextSpoiler: NativeTimelineTextSpoilerHover?,
        revealedTextSpoilerState:
            NativeTimelineTextSpoilerRevealState,
        spoilerRevealStore: NativeTimelineSpoilerRevealStore?,
        hoveredComponentButton: NativeTimelineComponentButtonTarget?,
        pressedComponentButton: NativeTimelineComponentButtonTarget?,
        componentButtonPressProgress: CGFloat
    ) {
        let hiddenContainerFrames =
            spoilerRevealStore.map {
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: layout,
                        messageID: messageID,
                        store: $0
                    )
            } ?? []
        func isInsideHiddenContainer(_ frame: CGRect) -> Bool {
            NativeTimelineSpoilerConcealmentPolicy
                .isInsideHiddenContainer(
                    frame,
                    hiddenContainerFrames: hiddenContainerFrames
                )
        }
        func isConcealed(
            contentID: String,
            isSpoiler: Bool
        ) -> Bool {
            spoilerRevealStore.map {
                NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                    messageID: messageID,
                    contentID: contentID,
                    isSpoiler: isSpoiler,
                    store: $0
                )
            } ?? false
        }

        for container in layout.containers {
            let isHidden = hiddenContainerFrames.contains(container.frame)
            if !isHidden, isInsideHiddenContainer(container.frame) {
                continue
            }
            componentContainer(
                container.frame,
                accentColor: container.accentColor
            )
            if isHidden {
                spoilerConcealedBase(
                    in: container.frame,
                    cornerRadius:
                        DiscordRichMessageMetrics.cardCornerRadius
                )
            }
        }
        for separator in layout.separators
        where separator.drawsDivider
            && !isInsideHiddenContainer(separator.frame) {
            NSColor.separatorColor.setFill()
            CGRect(
                x: separator.frame.minX,
                y: separator.frame.midY - 0.5,
                width: separator.frame.width,
                height: 1
            ).fill()
        }
        for (textIndex, region) in layout.textRegions.enumerated()
        where !isInsideHiddenContainer(region.frame) {
            attributedText(
                region.text,
                in: region.frame,
                model: model,
                selectionRange:
                    textSelection?.itemIdentifier == .message(messageID)
                        && textSelection?.region == .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    ? textSelection?.range
                    : nil,
                hoveredMentionCharacterIndex:
                    hoveredMention?.itemIdentifier == .message(messageID)
                        && hoveredMention?.region == .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    ? hoveredMention?.characterIndex
                    : nil,
                hoveredSpoilerRangeLocation:
                    hoveredTextSpoiler?.itemIdentifier
                        == .message(messageID)
                        && hoveredTextSpoiler?.region == .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    ? hoveredTextSpoiler?.rangeLocation
                    : nil,
                revealedSpoilerLocations:
                    revealedTextSpoilerState.locations(
                        in: .component(
                            layoutIndex: layoutIndex,
                            textIndex: textIndex
                        )
                    )
            )
        }
        for region in layout.images
        where !isInsideHiddenContainer(region.frame) {
            if isConcealed(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler
            ) {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius: region.cornerRadius
                )
                continue
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(
                concentricRoundedRect: region.frame,
                cornerRadius: region.cornerRadius
            ).fill()
            if let image = mediaImage(
                for: .media(
                    region.displayURL,
                    maximumPixelDimension: region.maximumPixelDimension
                )
            ) {
                drawImage(
                    image,
                    in: region.frame,
                    cornerRadius: region.cornerRadius,
                    fillsFrame: false
                )
            } else {
                systemSymbol(
                    "photo",
                    in: region.frame,
                    color: .secondaryLabelColor,
                    inset: 22
                )
            }
        }
        for region in layout.media
        where !isInsideHiddenContainer(region.frame) {
            if isConcealed(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler
            ) {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius: 8
                )
                continue
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(
                concentricRoundedRect: region.frame,
                cornerRadius: 8
            ).fill()
            if let image = mediaImage(
                for: .media(region.displayURL)
            ) {
                drawImage(
                    image,
                    in: region.frame,
                    cornerRadius: 8,
                    fillsFrame: true
                )
            } else if region.isVideo {
                systemSymbol(
                    "film",
                    in: region.frame,
                    color: .secondaryLabelColor,
                    inset: 30
                )
            }
            if region.isVideo {
                mediaPlayGlyph(in: region.frame)
            }
        }
        for region in layout.files
        where !isInsideHiddenContainer(region.frame) {
            if isConcealed(
                contentID: region.componentID,
                isSpoiler: region.isSpoiler
            ) {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius:
                        DiscordRichMessageMetrics.cardCornerRadius
                )
                continue
            }
            componentFile(region)
        }
        for region in layout.buttons
        where !isInsideHiddenContainer(region.frame) {
            let target = NativeTimelineComponentButtonTarget(
                messageID: messageID,
                componentID: region.componentID
            )
            componentButton(
                region,
                isHovered: hoveredComponentButton == target,
                pressProgress:
                    pressedComponentButton == target
                        ? componentButtonPressProgress
                        : 0
            )
        }
        for region in layout.selects
        where !isInsideHiddenContainer(region.frame) {
            componentSelect(region)
        }
        for region in layout.unsupported
        where !isInsideHiddenContainer(region.frame) {
            systemSymbol(
                "questionmark.square.dashed",
                in: CGRect(
                    x: region.frame.minX,
                    y: region.frame.minY,
                    width: 16,
                    height: region.frame.height
                ),
                color: .secondaryLabelColor,
                inset: 1
            )
            text(
                region.label,
                in: CGRect(
                    x: region.frame.minX + 22,
                    y: region.frame.minY,
                    width: max(1, region.frame.width - 22),
                    height: region.frame.height
                ),
                font: .systemFont(ofSize: 11),
                color: .secondaryLabelColor
            )
        }
    }

    private static func componentContainer(
        _ frame: CGRect,
        accentColor: UInt32?
    ) {
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius
        )
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        frame.fill()
        if let accent = roleColor(accentColor) {
            accent.setFill()
            CGRect(
                x: frame.minX,
                y: frame.minY,
                width: 4,
                height: frame.height
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.labelColor.withAlphaComponent(0.13).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius - 0.5
        )
        border.lineWidth = 1
        border.stroke()
    }

    private static func spoilerConcealedBase(
        in frame: CGRect,
        cornerRadius: CGFloat
    ) {
        NSColor(
            srgbRed: 0.12,
            green: 0.125,
            blue: 0.14,
            alpha: 1
        ).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: cornerRadius
        ).fill()
    }

    private static func threadSummary(
        _ thread: MessageThreadSummary,
        in frame: CGRect
    ) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 8
        ).fill()
        systemSymbol(
            "bubble.left.and.bubble.right",
            in: CGRect(
                x: frame.minX + 9,
                y: frame.midY - 9,
                width: 18,
                height: 18
            ),
            color: .labelColor,
            inset: 1
        )
        text(
            thread.name,
            in: CGRect(
                x: frame.minX + 35,
                y: frame.minY + 6,
                width: max(1, frame.width - 70),
                height: 18
            ),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )
        text(
            "\(thread.messageCount) replies · \(thread.memberCount) participants",
            in: CGRect(
                x: frame.minX + 35,
                y: frame.minY + 23,
                width: max(1, frame.width - 70),
                height: 16
            ),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        systemSymbol(
            "chevron.right",
            in: CGRect(
                x: frame.maxX - 25,
                y: frame.midY - 7,
                width: 14,
                height: 14
            ),
            color: .secondaryLabelColor,
            inset: 2
        )
    }

    private static func reaction(
        _ region: NativeTimelineRowLayout.ReactionRegion,
        model: AppModel?,
        isHovered: Bool,
        countTransition: NativeTimelineReactionCountTransition?
    ) {
        let selected = region.reaction.didCurrentUserReact
        let shape = NSBezierPath(
            roundedRect: region.frame,
            xRadius: 9,
            yRadius: 9
        )
        (
            selected
                ? NSColor.controlAccentColor.withAlphaComponent(
                    isHovered ? 0.22 : 0.16
                )
                : NSColor.labelColor.withAlphaComponent(
                    isHovered ? 0.14 : 0.09
                )
        ).setFill()
        shape.fill()
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }

        let reference = region.reaction.emojiReference
        if let id = reference.id {
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(
                concentricRoundedRect: region.emojiFrame,
                cornerRadius: 5
            ).fill()
            systemSymbol(
                "face.smiling",
                in: region.emojiFrame,
                color: .secondaryLabelColor,
                inset: 4,
                weight: .medium
            )
            if let url = model?.customEmojiURLsByID[id]
                    ?? reference.imageURL(size: 64),
               let image = mediaImage(
                   for: .media(url, maximumPixelDimension: 64)
               )
            {
                drawImage(
                    image,
                    in: region.emojiFrame,
                    cornerRadius: 0,
                    fillsFrame: false
                )
            }
        } else {
            let image = ComponentUnicodeEmojiRenderer.image(
                for: reference.name
            )
            let optical = region.emojiFrame.insetBy(
                dx: region.emojiFrame.width
                    * (1 - MessageReactionMetrics.nativeEmojiVisualScale) / 2,
                dy: region.emojiFrame.height
                    * (1 - MessageReactionMetrics.nativeEmojiVisualScale) / 2
            )
            drawImage(
                image,
                in: optical,
                cornerRadius: 0,
                fillsFrame: false
            )
        }
        if let countFrame = region.countFrame, countTransition == nil {
            reactionCount(
                region.reaction.count,
                in: countFrame,
                color: selected ? .controlAccentColor : .labelColor
            )
        }
        for avatarRegion in region.avatarRegions {
            avatar(
                name: avatarRegion.reactor.displayName,
                url: avatarRegion.reactor.avatarURL,
                in: avatarRegion.frame
            )
            NSColor.labelColor.withAlphaComponent(0.24).setStroke()
            let border = NSBezierPath(ovalIn: avatarRegion.frame.insetBy(
                dx: 0.5,
                dy: 0.5
            ))
            border.lineWidth = 1
            border.stroke()
        }
        if let overflowFrame = region.overflowFrame {
            let overflow = MessageReactionPresentation.previewPlan(
                for: region.reaction
            ).overflowCount
            text(
                "+\(overflow)",
                in: overflowFrame,
                font: .monospacedDigitSystemFont(
                    ofSize: 10,
                    weight: .bold
                ),
                color: .secondaryLabelColor,
                alignment: .center
            )
        }
    }

    private static func reactionAddControl(
        in frame: CGRect,
        isHovered: Bool
    ) {
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 9
        )
        NSColor.labelColor.withAlphaComponent(
            isHovered ? 0.14 : 0.09
        ).setFill()
        shape.fill()
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        systemSymbol(
            "face.smiling.inverse",
            in: NativeTimelineReactionAddControlGeometry.iconFrame(in: frame),
            color: .labelColor,
            inset: 0,
            weight: .medium
        )
    }

    private static func reactionCount(
        _ count: Int,
        in frame: CGRect,
        color: NSColor
    ) {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
        text(
            String(count),
            in: frame,
            font: font,
            color: color,
            alignment: .center
        )
    }

    private static func componentButton(
        _ region: NativeTimelineComponentLayout.ButtonRegion,
        isHovered: Bool,
        pressProgress: CGFloat
    ) {
        let pressProgress = min(max(pressProgress, 0), 1)
        let scale = NativeTimelineComponentButtonVisualState.scale(
            pressProgress: pressProgress
        )
        let brightness =
            NativeTimelineComponentButtonVisualState.brightness(
                isHovered: isHovered,
                pressProgress: pressProgress
            )
        let opacity: CGFloat = region.isDisabled ? 0.65 : 1
        let background = adjustedBrightness(
            roleColor(
                DiscordComponentButtonAppearance.backgroundHex(
                    for: region.style
                )
            ) ?? .secondaryLabelColor,
            amount: brightness
        )

        NSGraphicsContext.saveGraphicsState()
        if abs(scale - 1) > 0.0001 {
            let transform = NSAffineTransform()
            transform.translateX(
                by: region.frame.midX,
                yBy: region.frame.midY
            )
            transform.scaleX(by: scale, yBy: scale)
            transform.translateX(
                by: -region.frame.midX,
                yBy: -region.frame.midY
            )
            transform.concat()
        }

        background.withAlphaComponent(opacity).setFill()
        NSBezierPath(
            concentricRoundedRect: region.frame,
            cornerRadius: 6
        ).fill()
        adjustedBrightness(
            .white,
            amount: brightness
        ).withAlphaComponent(
            NativeTimelineComponentButtonVisualState.borderAlpha(
                isHovered: isHovered,
                isEnabled: !region.isDisabled
            ) * opacity
        ).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: region.frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: 5.5
        )
        border.lineWidth = 1
        border.stroke()

        var x = region.frame.minX + 12
        if let emoji = region.emoji {
            componentEmoji(emoji, in: CGRect(
                x: x,
                y: region.frame.midY - 8,
                width: 16,
                height: 16
            ))
            x += 22
        } else if region.style == .premium {
            systemSymbol(
                "sparkles",
                in: CGRect(
                    x: x,
                    y: region.frame.midY - 8,
                    width: 16,
                    height: 16
                ),
                color: adjustedBrightness(
                    .white,
                    amount: brightness
                ).withAlphaComponent(opacity),
                inset: 1
            )
            x += 22
        }
        let trailingAllowance: CGFloat = region.url == nil ? 12 : 30
        text(
            region.label,
            in: CGRect(
                x: x,
                y: region.frame.minY,
                width: max(
                    1,
                    region.frame.maxX - x - trailingAllowance
                ),
                height: region.frame.height
            ),
            font: NativeTimelineComponentButtonMetrics.font,
            color: adjustedBrightness(
                .white,
                amount: brightness
            ).withAlphaComponent(
                region.isDisabled ? 0.62 : 1
            )
        )
        if region.url != nil {
            systemSymbol(
                "arrow.up.right",
                in: CGRect(
                    x: region.frame.maxX - 22,
                    y: region.frame.midY - 7,
                    width: 14,
                    height: 14
                ),
                color: adjustedBrightness(
                    .white,
                    amount: brightness
                ).withAlphaComponent(opacity),
                inset: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func adjustedBrightness(
        _ color: NSColor,
        amount: CGFloat
    ) -> NSColor {
        guard abs(amount) > 0.0001,
              let rgb = color.usingColorSpace(.deviceRGB)
        else { return color }
        return NSColor(
            deviceRed: min(max(rgb.redComponent + amount, 0), 1),
            green: min(max(rgb.greenComponent + amount, 0), 1),
            blue: min(max(rgb.blueComponent + amount, 0), 1),
            alpha: rgb.alphaComponent
        )
    }

    private static func componentSelect(
        _ region: NativeTimelineComponentLayout.SelectRegion
    ) {
        let opacity: CGFloat = region.isDisabled ? 0.65 : 1
        NSColor.labelColor.withAlphaComponent(0.075 * opacity).setFill()
        NSBezierPath(
            concentricRoundedRect: region.frame,
            cornerRadius: 7
        ).fill()
        NSColor.labelColor.withAlphaComponent(0.16 * opacity).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: region.frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: 6.5
        )
        border.lineWidth = 1
        border.stroke()
        text(
            region.placeholder,
            in: CGRect(
                x: region.frame.minX + 12,
                y: region.frame.minY,
                width: max(1, region.frame.width - 54),
                height: region.frame.height
            ),
            font: .systemFont(ofSize: 13),
            color: NSColor.labelColor.withAlphaComponent(opacity)
        )
        systemSymbol(
            "chevron.down",
            in: CGRect(
                x: region.frame.maxX - 26,
                y: region.frame.midY - 7,
                width: 14,
                height: 14
            ),
            color: NSColor.secondaryLabelColor.withAlphaComponent(opacity),
            inset: 1
        )
    }

    private static func componentFile(
        _ region: NativeTimelineComponentLayout.FileRegion
    ) {
        componentContainer(region.frame, accentColor: nil)
        systemSymbol(
            "doc.fill",
            in: CGRect(
                x: region.frame.minX + 10,
                y: region.frame.midY - 12,
                width: 24,
                height: 24
            ),
            color: .secondaryLabelColor,
            inset: 1
        )
        text(
            region.title,
            in: CGRect(
                x: region.frame.minX + 44,
                y: region.frame.minY + 8,
                width: max(1, region.frame.width - 88),
                height: 18
            ),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        if let description = region.description, !description.isEmpty {
            text(
                description,
                in: CGRect(
                    x: region.frame.minX + 44,
                    y: region.frame.minY + 27,
                    width: max(1, region.frame.width - 88),
                    height: max(14, region.frame.height - 33)
                ),
                font: .systemFont(ofSize: 11),
                color: .secondaryLabelColor,
                lineBreakMode: .byWordWrapping
            )
        }
        systemSymbol(
            "arrow.down.circle",
            in: CGRect(
                x: region.frame.maxX - 32,
                y: region.frame.midY - 10,
                width: 20,
                height: 20
            ),
            color: .secondaryLabelColor,
            inset: 1
        )
    }

    private static func componentEmoji(
        _ emoji: EmojiReference,
        in frame: CGRect
    ) {
        if emoji.id != nil,
           let url = emoji.imageURL(size: 32),
           let image = mediaImage(
               for: .media(url, maximumPixelDimension: 64)
           )
        {
            drawImage(
                image,
                in: frame.insetBy(dx: 1, dy: 1),
                cornerRadius: 3,
                fillsFrame: false
            )
            return
        }
        drawImage(
            ComponentUnicodeEmojiRenderer.image(for: emoji.name),
            in: frame.insetBy(dx: 1, dy: 1),
            cornerRadius: 0,
            fillsFrame: false
        )
    }

    private static func systemSymbol(
        _ name: String,
        in frame: CGRect,
        color: NSColor,
        inset: CGFloat,
        weight: NSFont.Weight = .regular
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        let pointSize = max(
            10,
            min(frame.width, frame.height) - max(0, inset) * 2
        )
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: weight
        ).applying(
            NSImage.SymbolConfiguration(paletteColors: [color])
        )
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        else { return }
        let target = frame.insetBy(
            dx: min(max(0, inset), frame.width / 2 - 1),
            dy: min(max(0, inset), frame.height / 2 - 1)
        )
        let fittedTarget = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: image.size,
            alignmentRect: image.alignmentRect,
            in: target
        )
        image.draw(
            in: fittedTarget,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private static func pill(_ frame: CGRect, selected: Bool) {
        let color = selected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor
        color.withAlphaComponent(selected ? 0.22 : 0.18).setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
            .fill()
    }

    private static func mediaImage(
        for key: NativeTimelineMediaKey
    ) -> NSImage? {
        NativeTimelineMediaStore.shared.firstAnimatedFrame(for: key)
            ?? NativeTimelineMediaStore.shared.image(for: key)
    }

    private static func drawImage(
        _ image: NSImage,
        in frame: CGRect,
        cornerRadius: CGFloat,
        fillsFrame: Bool
    ) {
        guard frame.width > 0, frame.height > 0,
              image.size.width > 0, image.size.height > 0
        else { return }
        let scale = fillsFrame
            ? max(frame.width / image.size.width, frame.height / image.size.height)
            : min(frame.width / image.size.width, frame.height / image.size.height)
        let destination = CGRect(
            x: frame.midX - image.size.width * scale / 2,
            y: frame.midY - image.size.height * scale / 2,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: cornerRadius
        ).addClip()
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func attachmentAudio(
        _ attachment: Attachment,
        in frame: CGRect
    ) {
        let title = attachment.title ?? attachment.filename
        let font = NSFont.preferredFont(forTextStyle: .body)
        let symbolSize: CGFloat = 18
        let spacing: CGFloat = 6
        let titleWidth = min(
            measuredTextWidth(title, font: font),
            max(1, frame.width - 24 - symbolSize - spacing)
        )
        let totalWidth = symbolSize + spacing + titleWidth
        let x = frame.midX - totalWidth / 2
        systemSymbol(
            "waveform",
            in: CGRect(
                x: x,
                y: frame.midY - symbolSize / 2,
                width: symbolSize,
                height: symbolSize
            ),
            color: .labelColor,
            inset: 1
        )
        text(
            title,
            in: CGRect(
                x: x + symbolSize + spacing,
                y: frame.midY - 10,
                width: titleWidth,
                height: 20
            ),
            font: font,
            color: .labelColor
        )
    }

    private static func mediaPlayGlyph(in frame: CGRect) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 36,
            weight: .regular
        ).applying(
            NSImage.SymbolConfiguration(
                paletteColors: [.labelColor]
            )
        )
        guard let image = NSImage(
            systemSymbolName: "play.circle.fill",
            accessibilityDescription: "Play"
        )?.withSymbolConfiguration(configuration)
        else { return }
        let imageSize = image.size
        let imageFrame = CGRect(
            x: frame.midX - imageSize.width / 2,
            y: frame.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        image.draw(in: imageFrame)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func text(
        _ value: String,
        in frame: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var textAlignment: CTTextAlignment = switch alignment {
        case .center: .center
        case .right: .right
        case .justified: .justified
        case .natural: .natural
        default: .left
        }
        var breakMode: CTLineBreakMode = switch lineBreakMode {
        case .byCharWrapping: .byCharWrapping
        case .byClipping: .byClipping
        case .byTruncatingHead: .byTruncatingHead
        case .byTruncatingMiddle: .byTruncatingMiddle
        case .byWordWrapping: .byWordWrapping
        default: .byTruncatingTail
        }
        let paragraph = withUnsafePointer(to: &textAlignment) { alignmentPointer in
            withUnsafePointer(to: &breakMode) { breakPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: breakPointer
                    ),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        // NSFont and CTFont are toll-free bridged. Recreating the font from
        // `fontName` turns system fonts into private `.SFNS-*` names, which
        // CoreText explicitly rejects and may substitute with Times New Roman.
        let coreFont = font as CTFont
        let attributed = CFAttributedStringCreate(
            nil,
            value as CFString,
            [
                kCTFontAttributeName: coreFont,
                kCTForegroundColorAttributeName: color.cgColor,
                kCTParagraphStyleAttributeName: paragraph,
            ] as CFDictionary
        )!
        let sourceLine = CTLineCreateWithAttributedString(attributed)
        let sourceWidth = CGFloat(CTLineGetTypographicBounds(
            sourceLine,
            nil,
            nil,
            nil
        ))
        let usesSingleLine =
            !value.contains("\n")
            && (lineBreakMode != .byWordWrapping || sourceWidth <= frame.width)
        if usesSingleLine {
            let line: CTLine = {
                guard sourceWidth > frame.width,
                      lineBreakMode == .byTruncatingHead
                        || lineBreakMode == .byTruncatingMiddle
                        || lineBreakMode == .byTruncatingTail
                else { return sourceLine }
                let token = CTLineCreateWithAttributedString(
                    CFAttributedStringCreate(
                        nil,
                        "…" as CFString,
                        [
                            kCTFontAttributeName: coreFont,
                            kCTForegroundColorAttributeName: color.cgColor,
                        ] as CFDictionary
                    )!
                )
                let truncation: CTLineTruncationType = switch lineBreakMode {
                case .byTruncatingHead: .start
                case .byTruncatingMiddle: .middle
                default: .end
                }
                return CTLineCreateTruncatedLine(
                    sourceLine,
                    Double(frame.width),
                    truncation,
                    token
                ) ?? sourceLine
            }()
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            ))
            let x: CGFloat = switch alignment {
            case .center: max(0, (frame.width - lineWidth) / 2)
            case .right: max(0, frame.width - lineWidth)
            default: 0
            }
            let baseline = max(
                descent,
                (frame.height - ascent - descent - leading) / 2 + descent
            )
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
            return
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(textFrame, context)
        context.restoreGState()
    }

    private static func attributedText(
        _ box: NativeTimelineAttributedTextBox,
        in frame: CGRect,
        model: AppModel?,
        selectionRange: NSRange? = nil,
        hoveredMentionCharacterIndex: Int? = nil,
        hoveredSpoilerRangeLocation: Int? = nil,
        revealedSpoilerLocations: Set<Int> = []
    ) {
        var drawingFrame = frame
        drawingFrame.size.height += box.layoutHeightAdjustment
        attributedText(
            box.value,
            framesetter: box.framesetter,
            in: drawingFrame,
            model: model,
            selectionRange: selectionRange,
            hoveredMentionCharacterIndex:
                hoveredMentionCharacterIndex,
            hoveredSpoilerRangeLocation:
                hoveredSpoilerRangeLocation,
            revealedSpoilerLocations: revealedSpoilerLocations
        )
    }

    private static func attributedText(
        _ value: NSAttributedString,
        in frame: CGRect,
        model: AppModel?
    ) {
        attributedText(
            value,
            framesetter: CTFramesetterCreateWithAttributedString(value),
            in: frame,
            model: model
        )
    }

    private static func attributedText(
        _ value: NSAttributedString,
        framesetter: CTFramesetter,
        in frame: CGRect,
        model: AppModel?,
        selectionRange: NSRange? = nil,
        hoveredMentionCharacterIndex: Int? = nil,
        hoveredSpoilerRangeLocation: Int? = nil,
        revealedSpoilerLocations: Set<Int> = []
    ) {
        guard frame.width > 0, frame.height > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let drawingValue: NSAttributedString
        let drawingFramesetter: CTFramesetter
        let fullRange = NSRange(location: 0, length: value.length)
        var spoilerRanges: [NSRange] = []
        value.enumerateAttribute(
            .discordMarkdownSpoiler,
            in: fullRange
        ) { rawValue, range, _ in
            if (rawValue as? NSNumber)?.boolValue == true {
                spoilerRanges.append(range)
            }
        }
        if spoilerRanges.isEmpty {
            drawingValue = value
            drawingFramesetter = framesetter
        } else {
            let revealed = NSMutableAttributedString(
                attributedString: value
            )
            for range in spoilerRanges {
                revealed.removeAttribute(
                    .backgroundColor,
                    range: range
                )
                guard revealedSpoilerLocations.contains(range.location)
                else { continue }
                revealed.removeAttribute(
                    .discordMarkdownSpoiler,
                    range: range
                )
                revealed.addAttribute(
                    .foregroundColor,
                    value: revealed.attribute(
                        .link,
                        at: range.location,
                        effectiveRange: nil
                    ) == nil
                        ? NSColor.labelColor
                        : NSColor.linkColor,
                    range: range
                )
                revealed.addAttribute(
                    .underlineColor,
                    value: NSColor.labelColor,
                    range: range
                )
                revealed.addAttribute(
                    .strikethroughColor,
                    value: NSColor.labelColor,
                    range: range
                )
            }
            drawingValue = revealed
            drawingFramesetter =
                CTFramesetterCreateWithAttributedString(revealed)
        }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            drawingFramesetter,
            CFRange(location: 0, length: drawingValue.length),
            path,
            nil
        )
        drawMarkdownBlocks(
            in: textFrame,
            outerFrame: frame,
            attributedText: drawingValue,
            hoveredSpoilerRangeLocation:
                hoveredSpoilerRangeLocation
        )
        if let selectionRange, selectionRange.length > 0 {
            textSelectionHighlightColor.setFill()
            for backgroundRange
                in NativeTimelineTextSelectionGeometry.backgroundRanges(
                    in: drawingValue,
                    selectionRange: selectionRange
                )
            {
                for selectionRect in NativeTimelineTextSelectionGeometry.rects(
                    in: textFrame,
                    outerFrame: frame,
                    range: backgroundRange
                ) {
                    selectionRect.fill()
                }
            }
        }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(textFrame, context)
        context.restoreGState()
        drawInlineAttachments(
            in: textFrame,
            outerFrame: frame,
            attributedText: drawingValue,
            model: model,
            selectionRange: selectionRange,
            hoveredMentionCharacterIndex:
                hoveredMentionCharacterIndex
        )
    }

    private static func drawMarkdownBlocks(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        attributedText: NSAttributedString,
        hoveredSpoilerRangeLocation: Int? = nil
    ) {
        guard attributedText.length > 0 else { return }
        let fullRange = NSRange(
            location: 0,
            length: attributedText.length
        )
        var quoteRects: [CGRect] = []
        var inlineCodeRects: [CGRect] = []
        var spoilerRects: [(CGRect, Bool)] = []
        var listMarkerRects: [CGRect] = []
        let codeBlocks = NativeTimelineCodeBlockGeometry.regions(
            in: textFrame,
            outerFrame: outerFrame,
            value: attributedText
        )
        attributedText.enumerateAttribute(
            .discordMarkdownInlineCode,
            in: fullRange
        ) { rawValue, range, _ in
            guard (rawValue as? NSNumber)?.boolValue == true else {
                return
            }
            inlineCodeRects.append(
                contentsOf:
                    NativeTimelineTextSelectionGeometry.rects(
                        in: textFrame,
                        outerFrame: outerFrame,
                        range: range
                )
            )
        }
        attributedText.enumerateAttribute(
            .discordMarkdownSpoiler,
            in: fullRange
        ) { rawValue, range, _ in
            guard (rawValue as? NSNumber)?.boolValue == true else {
                return
            }
            spoilerRects.append(
                contentsOf:
                    NativeTimelineTextSelectionGeometry.rects(
                        in: textFrame,
                        outerFrame: outerFrame,
                        range: range
                    ).map {
                        (
                            $0,
                            hoveredSpoilerRangeLocation == range.location
                        )
                    }
            )
        }
        attributedText.enumerateAttribute(
            .discordMarkdownListMarker,
            in: fullRange
        ) { rawValue, range, _ in
            guard (rawValue as? NSNumber)?.boolValue == true else {
                return
            }
            listMarkerRects.append(
                contentsOf:
                    NativeTimelineTextSelectionGeometry.rects(
                        in: textFrame,
                        outerFrame: outerFrame,
                        range: range
                    )
            )
        }
        attributedText.enumerateAttribute(
            .discordMarkdownBlock,
            in: fullRange
        ) { rawValue, range, _ in
            guard let block = rawValue as? String else { return }
            let rects = NativeTimelineTextSelectionGeometry.rects(
                in: textFrame,
                outerFrame: outerFrame,
                range: range
            )
            switch block {
            case "quote":
                quoteRects.append(contentsOf: rects)
            default:
                break
            }
        }

        for inlineRect in inlineCodeRects {
            let backgroundFrame = inlineRect.insetBy(dx: -4, dy: -2)
            discordCodeBackgroundColor.setFill()
            NSBezierPath(
                concentricRoundedRect: backgroundFrame,
                cornerRadius: 4
            ).fill()
            discordCodeBorderColor.setStroke()
            let border = NSBezierPath(
                concentricRoundedRect: backgroundFrame.insetBy(dx: 0.5, dy: 0.5),
                cornerRadius: 4
            )
            border.lineWidth = 1
            border.stroke()
        }

        for (spoilerRect, isHovered) in spoilerRects {
            let backgroundFrame = spoilerRect.insetBy(dx: -2, dy: -1)
            NSColor.secondaryLabelColor.withAlphaComponent(
                NativeTimelineSpoilerAppearance.textBackgroundAlpha(
                    isHovered: isHovered
                )
            ).setFill()
            NSBezierPath(
                concentricRoundedRect: backgroundFrame,
                cornerRadius:
                    NativeTimelineSpoilerAppearance.textCornerRadius
            ).fill()
        }

        for codeBlock in codeBlocks {
            let backgroundFrame = codeBlock.backgroundFrame
            discordCodeBackgroundColor.setFill()
            NSBezierPath(
                concentricRoundedRect: backgroundFrame,
                cornerRadius: 4
            ).fill()
            discordCodeBorderColor.setStroke()
            let border = NSBezierPath(
                concentricRoundedRect: backgroundFrame.insetBy(dx: 0.5, dy: 0.5),
                cornerRadius: 4
            )
            border.lineWidth = 1
            border.stroke()
        }

        NSColor.labelColor.setFill()
        for markerRect in listMarkerRects {
            let diameter: CGFloat = 6
            NSBezierPath(ovalIn: CGRect(
                x: markerRect.midX - diameter / 2,
                y: markerRect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )).fill()
        }

        for group in verticallyContiguousGroups(quoteRects) {
            guard let union = group.reduce(nil, {
                ($0 as CGRect?)?.union($1) ?? $1
            }) else { continue }
            let bar = CGRect(
                x: outerFrame.minX + 1,
                y: union.minY - 1,
                width: 4,
                height: union.height + 2
            )
            NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
            NSBezierPath(
                roundedRect: bar,
                xRadius: 2,
                yRadius: 2
            ).fill()
        }
    }

    private static let discordCodeBackgroundColor = NSColor(
        srgbRed: 13 / 255,
        green: 14 / 255,
        blue: 27 / 255,
        alpha: 1
    )

    private static let discordCodeBorderColor = NSColor(
        srgbRed: 46 / 255,
        green: 47 / 255,
        blue: 59 / 255,
        alpha: 1
    )

    private static func verticallyContiguousGroups(
        _ rects: [CGRect]
    ) -> [[CGRect]] {
        let sorted = rects.sorted {
            if abs($0.minY - $1.minY) >= 0.5 {
                return $0.minY < $1.minY
            }
            return $0.minX < $1.minX
        }
        var groups: [[CGRect]] = []
        for rect in sorted {
            guard let last = groups.last,
                  let union = last.reduce(nil, {
                      ($0 as CGRect?)?.union($1) ?? $1
                  }),
                  rect.minY - union.maxY <= 4
            else {
                groups.append([rect])
                continue
            }
            groups[groups.count - 1].append(rect)
        }
        return groups
    }

    private enum InlineAttachmentDraw {
        case image(NSImage, CGRect, selectionFrame: CGRect?)
        case mention(
            MentionPresentation,
            CGRect,
            characterIndex: Int,
            selectionFrame: CGRect?
        )
        case emojiFallback(CGRect, selectionFrame: CGRect?)

        var selectionFrame: CGRect? {
            switch self {
            case let .image(_, _, selectionFrame),
                 let .mention(_, _, _, selectionFrame),
                 let .emojiFallback(_, selectionFrame):
                selectionFrame
            }
        }
    }

    private static func drawInlineAttachments(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        attributedText: NSAttributedString,
        model: AppModel?,
        selectionRange: NSRange?,
        hoveredMentionCharacterIndex: Int?
    ) {
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var draws: [InlineAttachmentDraw] = []
        draws.reserveCapacity(4)

        for index in 0 ..< lines.count {
            let line = lines[index] as! CTLine
            let lineOrigin = origins[index]
            let runs = CTLineGetGlyphRuns(line) as NSArray
            for case let run as CTRun in runs {
                let range = CTRunGetStringRange(run)
                guard range.location >= 0,
                      range.location < attributedText.length
                else { continue }
                let mention = (
                    attributedText.attribute(
                        .nativeTimelineMention,
                        at: range.location,
                        effectiveRange: nil
                    ) as? NativeTimelineMentionBox
                )?.presentation
                let emojiToken = attributedText.attribute(
                    .discordEmojiToken,
                    at: range.location,
                    effectiveRange: nil
                ) as? String
                guard mention != nil || emojiToken != nil else { continue }
                let isHiddenSpoiler = (
                    attributedText.attribute(
                        .discordMarkdownSpoiler,
                        at: range.location,
                        effectiveRange: nil
                    ) as? NSNumber
                )?.boolValue == true
                guard !isHiddenSpoiler else { continue }

                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(
                    run,
                    CFRange(location: 0, length: 0),
                    &ascent,
                    &descent,
                    &leading
                ))
                let x = lineOrigin.x + CTLineGetOffsetForStringIndex(
                    line,
                    range.location,
                    nil
                )
                let size = CGSize(
                    width: max(1, width),
                    height: max(1, ascent + descent)
                )
                let localBottom = lineOrigin.y - descent
                let attachmentFrame = CGRect(
                    x: outerFrame.minX + x,
                    y: outerFrame.maxY - localBottom - size.height,
                    width: size.width,
                    height: size.height
                )
                let isSelected =
                    NativeTimelineTextSelectionGeometry.intersects(
                        characterRange: range,
                        selectionRange: selectionRange
                    )
                let selectionFrame = isSelected
                    ? NativeTimelineTextSelectionGeometry.rects(
                        in: textFrame,
                        outerFrame: outerFrame,
                        range: NSRange(
                            location: range.location,
                            length: max(1, range.length)
                        )
                    ).first
                    : nil
                if let mention {
                    draws.append(.mention(
                        mention,
                        attachmentFrame,
                        characterIndex: range.location,
                        selectionFrame: selectionFrame
                    ))
                } else if let emojiToken,
                          let image = inlineEmojiImage(
                              token: emojiToken,
                              model: model
                          )
                {
                    draws.append(.image(
                        image,
                        attachmentFrame,
                        selectionFrame: selectionFrame
                    ))
                } else {
                    draws.append(.emojiFallback(
                        attachmentFrame,
                        selectionFrame: selectionFrame
                    ))
                }
            }
        }

        for draw in draws {
            switch draw {
            case let .image(image, frame, _):
                drawImage(
                    image,
                    in: frame,
                    cornerRadius: 0,
                    fillsFrame: false
                )
            case let .mention(
                presentation,
                frame,
                characterIndex,
                _
            ):
                drawMention(
                    presentation,
                    in: frame,
                    isHovered:
                        hoveredMentionCharacterIndex == characterIndex
                )
            case let .emojiFallback(frame, _):
                text(
                    "🙂",
                    in: frame,
                    font: .systemFont(ofSize: max(11, frame.height * 0.8)),
                    color: .labelColor,
                    alignment: .center
                )
            }
            if let selectionFrame = draw.selectionFrame {
                attachmentSelectionHighlightColor.setFill()
                selectionFrame.fill()
            }
        }
    }

    private static var textSelectionHighlightColor: NSColor {
        NSColor.selectedTextBackgroundColor
    }

    private static var attachmentSelectionHighlightColor: NSColor {
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5)
    }

    private static func drawMention(
        _ presentation: MentionPresentation,
        in frame: CGRect,
        isHovered: Bool
    ) {
        let color = roleColor(presentation.colorHex) ?? .controlAccentColor
        color.withAlphaComponent(
            NativeTimelineMentionAppearance.backgroundAlpha(
                isHovered: isHovered
            )
        ).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 5.5
        ).fill()

        var labelX = frame.minX + 6
        if let systemImage = presentation.systemImage {
            let iconSize = max(10, frame.height - 7)
            let iconFrame = CGRect(
                x: labelX,
                y: frame.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            let configuration = NSImage.SymbolConfiguration(
                pointSize: iconSize,
                weight: .semibold
            ).applying(
                NSImage.SymbolConfiguration(paletteColors: [color])
            )
            if let image = NSImage(
                systemSymbolName: systemImage,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(configuration) {
                drawImage(
                    image,
                    in: iconFrame,
                    cornerRadius: 0,
                    fillsFrame: false
                )
            }
            labelX = iconFrame.maxX + 4
        } else if case .user = presentation.target {
            let avatarSize = max(10, frame.height - 6)
            let avatarFrame = CGRect(
                x: labelX,
                y: frame.midY - avatarSize / 2,
                width: avatarSize,
                height: avatarSize
            )
            if let url = presentation.avatarURL,
               let image = mediaImage(for: .avatar(url))
            {
                drawImage(
                    image,
                    in: avatarFrame,
                    cornerRadius: avatarSize / 2,
                    fillsFrame: true
                )
            } else {
                color.withAlphaComponent(0.38).setFill()
                NSBezierPath(ovalIn: avatarFrame).fill()
            }
            labelX = avatarFrame.maxX + 4
        }
        text(
            presentation.label,
            in: CGRect(
                x: labelX,
                y: frame.minY,
                width: max(1, frame.maxX - labelX - 6),
                height: frame.height
            ),
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: color
        )
    }

    private static func inlineEmojiImage(
        token: String,
        model: AppModel?
    ) -> NSImage? {
        let reference = EmojiReference(rawToken: token)
        if let url =
            reference.id.flatMap({ model?.customEmojiURLsByID[$0] })
                ?? reference.imageURL(size: 64),
           let image = mediaImage(
               for: .media(url, maximumPixelDimension: 64)
           )
        {
            return image
        }
        return nil
    }

    private static func roleColor(_ value: UInt32?) -> NSColor? {
        guard let value, value != 0 else { return nil }
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func measuredTextWidth(
        _ value: String,
        font: NSFont
    ) -> CGFloat {
        let attributed = NSAttributedString(
            string: value,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

}
