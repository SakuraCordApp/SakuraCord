import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

nonisolated func coreTextLine(_ value: Any) -> CTLine {
    let object = value as AnyObject
    precondition(CFGetTypeID(object) == CTLineGetTypeID())
    return unsafeDowncast(object, to: CTLine.self)
}

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

nonisolated enum TimelineInlineVideoPolicy {
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
    static let horizontalSpacing: CGFloat = 5

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

nonisolated enum TimelineContextMenuHitTesting {
    static func contains(
        _ point: CGPoint,
        rowOrigin: CGFloat,
        highlightFrame: CGRect?
    ) -> Bool {
        NativeTimelineHoverHitTesting.contains(
            CGPoint(x: point.x, y: point.y - rowOrigin),
            in: highlightFrame
        )
    }
}

nonisolated enum NativeTimelineCompactTimestampHitTesting {
    static func contains(
        _ point: CGPoint,
        rowOrigin: CGFloat,
        highlightFrame: CGRect?
    ) -> Bool {
        NativeTimelineHoverHitTesting.contains(
            CGPoint(x: point.x, y: point.y - rowOrigin),
            in: highlightFrame
        )
    }
}

nonisolated enum NativeTimelineReactionClickHitTesting {
    enum Target: Equatable, Sendable {
        case reaction(index: Int)
        case add
    }

    static func target(
        at point: CGPoint,
        reactionFrames: [CGRect],
        addReactionFrame: CGRect?
    ) -> Target? {
        if let index = reactionFrames.firstIndex(where: {
            $0.contains(point)
        }) {
            return .reaction(index: index)
        }
        if addReactionFrame?.contains(point) == true {
            return .add
        }
        return nil
    }
}

enum NativeTimelineCompactTimestampMetrics {
    static var font: NSFont {
        .preferredFont(forTextStyle: .caption2)
    }
}

nonisolated enum NativeTimelineMessageMenuAction: Equatable {
    case jumpToMessage
    case retrySending
    case addReaction
    case reply
    case forward
    case markUnread
    case editMessage
    case copyText
    case copyLink
    case copyMessageID
    case copyAuthorID
    case deleteMessage
}

nonisolated enum NativeTimelineSearchResultPresentation {
    static let jumpToMessageSystemImage = "arrow.forward.to.line"
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
        canReply: Bool,
        canForward: Bool = false,
        context: NativeTimelineMessageInteractionContext = .conversation
    ) -> [NativeTimelineMessageMenuEntry] {
        if context == .searchResult {
            return searchResultEntries(canDelete: canEdit)
        }

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
            systemImage: SakuraCordSystemSymbol.emojiFaceGrinning
        ))
        if canReply {
            result.append(.action(
                .reply,
                title: "Reply",
                systemImage: "arrowshape.turn.up.left"
            ))
        }
        if canForward {
            result.append(.action(
                .forward,
                title: "Forward",
                systemImage: "arrowshape.turn.up.right"
            ))
        }
        if canEdit {
            result.append(.action(
                .editMessage,
                title: "Edit Message",
                systemImage: "pencil"
            ))
        }
        result.append(.action(
            .markUnread,
            title: "Mark Unread",
            systemImage: "envelope.badge"
        ))
        result.append(.separator)
        result.append(.action(
            .copyText,
            title: "Copy Text",
            systemImage: "doc.on.doc"
        ))
        result.append(.action(
            .copyLink,
            title: "Copy Link",
            systemImage: "link"
        ))
        result.append(.action(
            .copyMessageID,
            title: "Copy Message ID",
            systemImage: "number.square.fill"
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

    private static func searchResultEntries(
        canDelete: Bool
    ) -> [NativeTimelineMessageMenuEntry] {
        var result: [NativeTimelineMessageMenuEntry] = [
            .action(
                .jumpToMessage,
                title: "Jump to Message",
                systemImage: NativeTimelineSearchResultPresentation
                    .jumpToMessageSystemImage
            ),
            .action(
                .markUnread,
                title: "Mark Unread",
                systemImage: "envelope.badge"
            ),
            .separator,
            .action(
                .copyText,
                title: "Copy Text",
                systemImage: "doc.on.doc"
            ),
            .action(
                .copyLink,
                title: "Copy Link",
                systemImage: "link"
            ),
            .action(
                .copyMessageID,
                title: "Copy Message ID",
                systemImage: "number.square.fill"
            ),
            .action(
                .copyAuthorID,
                title: "Copy Message Author ID",
                systemImage: "number.square.fill"
            ),
        ]
        if canDelete {
            result.append(contentsOf: [
                .separator,
                .action(
                    .deleteMessage,
                    title: "Delete Message",
                    systemImage: "trash",
                    isDestructive: true
                ),
            ])
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
    var locationsByRegion:
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
    var revealedMedia: Set<NativeTimelineComponentRevealKey> = []
    var revealedText: Set<NativeTimelineTextSpoilerRevealKey> = []
    var observers: [UUID: (MessageID) -> Void] = [:]

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

    func reset() {
        let messageIDs = Set(revealedMedia.lazy.map(\.messageID))
            .union(revealedText.lazy.map(\.messageID))
        guard !messageIDs.isEmpty else { return }
        revealedMedia.removeAll(keepingCapacity: true)
        revealedText.removeAll(keepingCapacity: true)
        for messageID in messageIDs {
            notifyObservers(messageID: messageID)
        }
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

    func notifyObservers(messageID: MessageID) {
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

nonisolated enum TimelineTextAccessibility {
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

nonisolated struct NativeTimelineTextLinkHover: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let characterIndex: Int
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

nonisolated enum TimelineButtonActivationPolicy {
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
    case message(MessageID)
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
    case forwardedSource(MessageID, ChannelID, GuildID?, MessageID?)
    case linkedImage(MessageID, URL)
    case attachment(MessageID, String)
    case embedMedia(MessageID, String)
    case thread(MessageID, ChannelID)

    var supportsTextSelection: Bool {
        switch self {
        case .message, .textMention, .textURL:
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

    static func replyAvatarFrame(in replyContentFrame: CGRect) -> CGRect {
        CGRect(
            x: replyContentFrame.minX,
            y: replyContentFrame.minY + 3,
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
        hasCachedBitmap: Bool,
        estimatedBitmapCost: Int,
        cacheCostLimit: Int
    ) -> Bool {
        isScrolling
            && !hasCachedBitmap
            && estimatedBitmapCost > cacheCostLimit / 2
    }
}

nonisolated enum NativeTimelineShortContentRedrawPolicy {
    static func redrawsSynchronously(
        conversationChanged: Bool,
        appendedAtTail: Bool
    ) -> Bool {
        appendedAtTail && !conversationChanged
    }
}

nonisolated struct NativeTimelineTextSelection: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let range: NSRange
}

@MainActor
final class TimelineReactionCountAnimation:
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

struct NativeTimelineReactionCountAnimationView: View {
    @ObservedObject var state: TimelineReactionCountAnimation
    let countsDown: Bool
    let color: Color

    init(
        state: TimelineReactionCountAnimation,
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

final class NativeTimelineReactionCountAnimationHost:
    NSHostingView<AnyView>
{
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class NativeTimelineActionCapsuleHost: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

@MainActor
final class NativeTimelineEditingHost: NSHostingView<AnyView> {
    var fittingHeightDidChange: ((CGFloat) -> Void)?

    var lastReportedFittingHeight: CGFloat = 0
    var isMeasuringFittingHeight = false

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

final class NativeTimelineLoadingIndicator: NSView {
    let replicator = CAReplicatorLayer()
    let spoke = CALayer()
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

    func startAnimating() {
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
final class NativeTimelineInlineVideoOverlay: NSView {
    var player: AVQueuePlayer?
    var playerLayer: AVPlayerLayer?
    var looper: AVPlayerLooper?
    var url: URL?
    var requestedPlayback = false
    var preparationTask: Task<Void, Never>?

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

    func synchronizePlayerLayerFrame() {
        guard let playerLayer else { return }
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
            requestedPlayback = plays
            schedulePreparation(for: url)
            return
        }
        requestedPlayback = plays
        if plays, let player, looper != nil {
            player.playImmediately(atRate: 1)
        } else {
            player?.pause()
        }
    }

    private func schedulePreparation(for url: URL) {
        preparationTask = Task { @MainActor [weak self] in
            let interval = AppPerformanceSignposts.signposter.beginInterval(
                "TimelineInlineVideoPreparation"
            )
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    "TimelineInlineVideoPreparation",
                    interval
                )
            }
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.url == url
            else { return }
            let player = AppPerformanceSignposts.measureSync(
                "TimelineInlineVideoPlayerCreation"
            ) {
                let player = AVQueuePlayer()
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = false
                return player
            }
            self.player = player

            await Task.yield()
            guard !Task.isCancelled, self.url == url else { return }
            let playerLayer = AppPerformanceSignposts.measureSync(
                "TimelineInlineVideoLayerCreation"
            ) {
                let playerLayer = AVPlayerLayer(player: player)
                playerLayer.videoGravity = .resizeAspectFill
                playerLayer.actions = [
                    "bounds": NSNull(),
                    "position": NSNull(),
                ]
                playerLayer.autoresizingMask = [
                    .layerWidthSizable,
                    .layerHeightSizable,
                ]
                return playerLayer
            }
            self.playerLayer = playerLayer
            self.layer?.addSublayer(playerLayer)
            self.synchronizePlayerLayerFrame()

            await Task.yield()
            guard !Task.isCancelled, self.url == url else { return }
            let item = AppPerformanceSignposts.measureSync(
                "TimelineInlineVideoItemCreation"
            ) {
                AVPlayerItem(url: url)
            }

            await Task.yield()
            guard !Task.isCancelled, self.url == url else { return }
            self.looper = AppPerformanceSignposts.measureSync(
                "TimelineInlineVideoLooperCreation"
            ) {
                AVPlayerLooper(player: player, templateItem: item)
            }
            self.preparationTask = nil
            if self.requestedPlayback {
                player.playImmediately(atRate: 1)
            }
        }
    }

    func stop() {
        preparationTask?.cancel()
        preparationTask = nil
        player?.pause()
        player?.removeAllItems()
        looper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        url = nil
        requestedPlayback = false
    }

    func pauseForScroll() {
        requestedPlayback = false
        player?.pause()
    }

    deinit {
        preparationTask?.cancel()
        player?.pause()
        player?.removeAllItems()
    }
}

@MainActor
final class NativeTimelineLottieStickerOverlay: NSView {
    let animationView = LottieAnimationView()
    let progressIndicator = NSProgressIndicator()
    var loadingTask: Task<Void, Never>?
    var url: URL?

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
                let animation = await SharedTimelineLottieAnimationLoader
                    .shared.animation(for: url)
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

    func updatePlayback(reduceMotion: Bool) {
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

nonisolated enum TimelineLottieLoadingPolicy {
    static let maximumCachedAnimations = 12
    static let maximumConcurrentParses = 1
}

actor SharedTimelineLottieAnimationLoader {
    static let shared = SharedTimelineLottieAnimationLoader()

    typealias DataLoader = @Sendable (URL) async throws -> Data

    private let cache: DefaultAnimationCache = {
        let cache = DefaultAnimationCache()
        cache.cacheSize = TimelineLottieLoadingPolicy.maximumCachedAnimations
        return cache
    }()
    private var inFlight: [URL: Task<LottieAnimation?, Never>] = [:]
    private var isParsing = false
    private struct ParseWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var parseWaiters: [ParseWaiter] = []
    private let loadData: DataLoader

    init(
        loadData: @escaping DataLoader = { url in
            try await SharedMediaDataLoader.shared.data(
                for: url,
                priority: .visible
            )
        }
    ) {
        self.loadData = loadData
    }

    func animation(for url: URL) async -> LottieAnimation? {
        if let cached = cache.animation(forKey: url.absoluteString) {
            return cached
        }
        if let task = inFlight[url] {
            return await task.value
        }
        let task = Task<LottieAnimation?, Never> { [weak self] in
            guard let self else { return nil }
            let data = try? await self.loadData(url)
            guard let data, !Task.isCancelled,
                  await self.acquireParseLane()
            else { return nil }
            guard !Task.isCancelled else {
                await self.releaseParseLane()
                return nil
            }
            let animation = try? LottieAnimation.from(data: data)
            if let animation {
                self.cache.setAnimation(
                    animation,
                    forKey: url.absoluteString
                )
            }
            await self.releaseParseLane()
            return animation
        }
        inFlight[url] = task
        let animation = await task.value
        inFlight[url] = nil
        return animation
    }

    private func acquireParseLane() async -> Bool {
        if Task.isCancelled {
            return false
        }
        if !isParsing {
            isParsing = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                parseWaiters.append(
                    ParseWaiter(
                        id: waiterID,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancelParseWaiter(waiterID)
            }
        }
    }

    private func cancelParseWaiter(_ id: UUID) {
        guard let index = parseWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        parseWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseParseLane() {
        if !parseWaiters.isEmpty {
            parseWaiters.removeFirst().continuation.resume(returning: true)
        } else {
            isParsing = false
        }
    }
}

struct NativeTimelineSpoilerOverlayPresentation: Hashable {
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

    static func labelFrame(
        in bounds: CGRect,
        measuredLabelHeight: CGFloat
    ) -> CGRect {
        let height = min(
            max(1, bounds.height),
            ceil(measuredLabelHeight)
        )
        return CGRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
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
    let cornerRadius: CGFloat
    let revealAction: () -> Void
    let pillView = NSView()
    let pillLabel = NSTextField(labelWithString: "SPOILER")
    var trackingArea: NSTrackingArea?
    var isHovered = false
    var isPressed = false
    var didActivate = false

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

        let labelParagraphStyle = NSMutableParagraphStyle()
        labelParagraphStyle.alignment = .center
        pillLabel.attributedStringValue = NSAttributedString(
            string: "SPOILER",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white,
                .kern: 0.4,
                .paragraphStyle: labelParagraphStyle,
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
        pillLabel.frame = NativeTimelineSpoilerAppearance.labelFrame(
            in: pillView.bounds,
            measuredLabelHeight: labelSize.height
        )
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

    func updateAppearance() {
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

    func activate() {
        guard !didActivate else { return }
        didActivate = true
        revealAction()
    }
}

/// Presents decoded raster animation frames on Core Animation's compositor.
/// The outer view is deliberately transparent so the selection tint can
/// extend beyond the clipped media box exactly as the Core Text painter does.
final class NativeTimelineAnimatedMediaOverlay: NSView {
    let imageClipView = NSView()
    let imageView = AnimatedImageCanvas()
    let selectionView = NSView()

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
        imageClipView.layer?.cornerCurve = .continuous
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

    func setPlaybackSuppressed(_ isSuppressed: Bool) {
        imageView.setPlaybackSuppressed(isSuppressed)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
