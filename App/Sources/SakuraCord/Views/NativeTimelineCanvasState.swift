import AppKit
import SakuraCordModels

nonisolated enum NativeTimelineReactionPointerTarget: Equatable {
    case reaction(messageID: MessageID, reactionID: String)
    case add(messageID: MessageID)

    var messageID: MessageID {
        switch self {
        case let .reaction(messageID, _), let .add(messageID):
            messageID
        }
    }
}

nonisolated struct NativeTimelineCodeBlockPointerTarget: Equatable {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let rangeLocation: Int
    let blockFrame: CGRect
    let copyButtonFrame: CGRect
    let content: String
}

nonisolated struct NativeTimelineTextSelectionGesture {
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let anchor: Int
}

@MainActor
final class NativeTimelinePointerState {
    struct ClearedTargets {
        let row: Int?
        let compactTimestampRow: Int?
        let mention: NativeTimelineMentionHover?
        let textLink: NativeTimelineTextLinkHover?
        let textSpoiler: NativeTimelineTextSpoilerHover?
        let codeBlock: NativeTimelineCodeBlockPointerTarget?
        let componentButton: NativeTimelineComponentButtonTarget?
        let forwardedSourceMessageID: MessageID?
    }

    var hoveredRow: Int?
    var hoveredCompactTimestampRow: Int?
    var hoveredAuthorMessageID: MessageID?
    var hoveredMention: NativeTimelineMentionHover?
    var hoveredTextLink: NativeTimelineTextLinkHover?
    var hoveredTextSpoiler: NativeTimelineTextSpoilerHover?
    var hoveredCodeBlock: NativeTimelineCodeBlockPointerTarget?
    var pressedCodeBlockCopyButton: NativeTimelineCodeBlockPointerTarget?
    var hoveredComponentButton: NativeTimelineComponentButtonTarget?
    var hoveredForwardedSourceMessageID: MessageID?
    var pressedComponentButton: NativeTimelineComponentButtonTarget?
    var visualPressedComponentButton: NativeTimelineComponentButtonTarget?
    var componentButtonPressProgress: CGFloat = 0
    var componentButtonPressAnimationTask: Task<Void, Never>?
    var componentButtonPressAnimationDestination: CGFloat?
    var pressedActivationTarget: NativeTimelinePointerActivationTarget?
    var hoveredReaction: NativeTimelineReactionPointerTarget?
    var suppressesHoverPresentation = false
    var overlayBlocksInteractions = false
    var textSelection: NativeTimelineTextSelection?
    var textSelectionGesture: NativeTimelineTextSelectionGesture?
    var didDragTextSelection = false
    var trackingArea: NSTrackingArea?
    var rowTrackingAreas: [NSTrackingArea] = []
    var reactionMouseMonitor: Any?

    @discardableResult
    func clearHoverAndPressTargets() -> ClearedTargets {
        let cleared = ClearedTargets(
            row: hoveredRow,
            compactTimestampRow: hoveredCompactTimestampRow,
            mention: hoveredMention,
            textLink: hoveredTextLink,
            textSpoiler: hoveredTextSpoiler,
            codeBlock: hoveredCodeBlock,
            componentButton:
                visualPressedComponentButton ?? hoveredComponentButton,
            forwardedSourceMessageID: hoveredForwardedSourceMessageID
        )
        hoveredRow = nil
        hoveredCompactTimestampRow = nil
        hoveredAuthorMessageID = nil
        hoveredMention = nil
        hoveredTextLink = nil
        hoveredTextSpoiler = nil
        hoveredCodeBlock = nil
        pressedCodeBlockCopyButton = nil
        hoveredComponentButton = nil
        hoveredForwardedSourceMessageID = nil
        pressedComponentButton = nil
        visualPressedComponentButton = nil
        componentButtonPressProgress = 0
        componentButtonPressAnimationDestination = nil
        componentButtonPressAnimationTask?.cancel()
        componentButtonPressAnimationTask = nil
        pressedActivationTarget = nil
        hoveredReaction = nil
        return cleared
    }

    func removeTrackingAreas(from view: NSView) {
        if let trackingArea {
            view.removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        for area in rowTrackingAreas {
            view.removeTrackingArea(area)
        }
        rowTrackingAreas.removeAll(keepingCapacity: true)
    }

    func removeReactionMouseMonitor() {
        guard let reactionMouseMonitor else { return }
        NSEvent.removeMonitor(reactionMouseMonitor)
        self.reactionMouseMonitor = nil
    }

    var hasHoverOrPressTargets: Bool {
        hoveredRow != nil
            || hoveredCompactTimestampRow != nil
            || hoveredAuthorMessageID != nil
            || hoveredMention != nil
            || hoveredTextLink != nil
            || hoveredTextSpoiler != nil
            || hoveredCodeBlock != nil
            || pressedCodeBlockCopyButton != nil
            || hoveredComponentButton != nil
            || hoveredForwardedSourceMessageID != nil
            || pressedComponentButton != nil
            || visualPressedComponentButton != nil
            || componentButtonPressProgress != 0
            || componentButtonPressAnimationTask != nil
            || componentButtonPressAnimationDestination != nil
            || pressedActivationTarget != nil
            || hoveredReaction != nil
    }
}

@MainActor
final class NativeTimelineEditingSession {
    var host: NativeTimelineEditingHost?
    weak var textView: ComposerNSTextView?
    var messageID: MessageID?
    var rowIndex: Int?
    var rowHeight: CGFloat?
    var overlayLocalFrame: CGRect?
    var scrollSnapshot: NSImage?

    var isActive: Bool {
        messageID != nil
    }

    func clear() {
        host?.removeFromSuperview()
        host = nil
        textView = nil
        messageID = nil
        rowIndex = nil
        rowHeight = nil
        overlayLocalFrame = nil
        scrollSnapshot = nil
    }
}

@MainActor
final class NativeTimelineAccessibilityProxyStore<
    Identifier: Hashable,
    Item: Equatable
> {
    private var rows: [Identifier: NativeTimelineAccessibilityProxyView] = [:]
    private var items: [Identifier: Item] = [:]
    private(set) var order: [Identifier] = []

    var identifiers: Set<Identifier> {
        Set(rows.keys)
    }

    func contains(_ view: NSView) -> Bool {
        rows.values.contains { $0 === view }
    }

    func item(for identifier: Identifier) -> Item? {
        items[identifier]
    }

    func row(
        for identifier: Identifier
    ) -> NativeTimelineAccessibilityProxyView? {
        rows[identifier]
    }

    func install(
        _ row: NativeTimelineAccessibilityProxyView,
        item: Item,
        for identifier: Identifier
    ) {
        remove(identifier)
        rows[identifier] = row
        items[identifier] = item
    }

    func setOrder(_ identifiers: [Identifier]) {
        var seen: Set<Identifier> = []
        order = identifiers.filter {
            rows[$0] != nil && seen.insert($0).inserted
        }
    }

    func orderedRows() -> [NativeTimelineAccessibilityProxyView] {
        order.compactMap { rows[$0] }
    }

    func remove(_ identifier: Identifier) {
        rows.removeValue(forKey: identifier)?.removeFromSuperview()
        items.removeValue(forKey: identifier)
        order.removeAll { $0 == identifier }
    }

    func removeAll() {
        for row in rows.values {
            row.removeFromSuperview()
        }
        rows.removeAll()
        items.removeAll()
        order.removeAll()
    }

    var isConsistent: Bool {
        Set(rows.keys) == Set(items.keys)
            && Set(order).isSubset(of: Set(rows.keys))
            && order.count == Set(order).count
    }
}

extension NativeTimelineCanvasView {
    var hoveredRow: Int? {
        get { pointer.hoveredRow }
        set { pointer.hoveredRow = newValue }
    }

    var hoveredCompactTimestampRow: Int? {
        get { pointer.hoveredCompactTimestampRow }
        set { pointer.hoveredCompactTimestampRow = newValue }
    }

    var hoveredAuthorMessageID: MessageID? {
        get { pointer.hoveredAuthorMessageID }
        set { pointer.hoveredAuthorMessageID = newValue }
    }

    var hoveredMention: NativeTimelineMentionHover? {
        get { pointer.hoveredMention }
        set { pointer.hoveredMention = newValue }
    }

    var hoveredTextLink: NativeTimelineTextLinkHover? {
        get { pointer.hoveredTextLink }
        set { pointer.hoveredTextLink = newValue }
    }

    var hoveredTextSpoiler: NativeTimelineTextSpoilerHover? {
        get { pointer.hoveredTextSpoiler }
        set { pointer.hoveredTextSpoiler = newValue }
    }

    var hoveredCodeBlock: NativeTimelineCodeBlockPointerTarget? {
        get { pointer.hoveredCodeBlock }
        set { pointer.hoveredCodeBlock = newValue }
    }

    var pressedCodeBlockCopyButton: NativeTimelineCodeBlockPointerTarget? {
        get { pointer.pressedCodeBlockCopyButton }
        set { pointer.pressedCodeBlockCopyButton = newValue }
    }

    var hoveredComponentButton: NativeTimelineComponentButtonTarget? {
        get { pointer.hoveredComponentButton }
        set { pointer.hoveredComponentButton = newValue }
    }

    var hoveredForwardedSourceMessageID: MessageID? {
        get { pointer.hoveredForwardedSourceMessageID }
        set { pointer.hoveredForwardedSourceMessageID = newValue }
    }

    var pressedComponentButton: NativeTimelineComponentButtonTarget? {
        get { pointer.pressedComponentButton }
        set { pointer.pressedComponentButton = newValue }
    }

    var visualPressedComponentButton: NativeTimelineComponentButtonTarget? {
        get { pointer.visualPressedComponentButton }
        set { pointer.visualPressedComponentButton = newValue }
    }

    var componentButtonPressProgress: CGFloat {
        get { pointer.componentButtonPressProgress }
        set { pointer.componentButtonPressProgress = newValue }
    }

    var componentButtonPressAnimationTask: Task<Void, Never>? {
        get { pointer.componentButtonPressAnimationTask }
        set { pointer.componentButtonPressAnimationTask = newValue }
    }

    var componentButtonPressAnimationDestination: CGFloat? {
        get { pointer.componentButtonPressAnimationDestination }
        set { pointer.componentButtonPressAnimationDestination = newValue }
    }

    var pressedActivationTarget: NativeTimelinePointerActivationTarget? {
        get { pointer.pressedActivationTarget }
        set { pointer.pressedActivationTarget = newValue }
    }

    var hoveredReaction: NativeTimelineReactionPointerTarget? {
        get { pointer.hoveredReaction }
        set { pointer.hoveredReaction = newValue }
    }

    var suppressesHoverPresentation: Bool {
        get { pointer.suppressesHoverPresentation }
        set { pointer.suppressesHoverPresentation = newValue }
    }

    var overlayBlocksInteractions: Bool {
        get { pointer.overlayBlocksInteractions }
        set { pointer.overlayBlocksInteractions = newValue }
    }

    var textSelection: NativeTimelineTextSelection? {
        get { pointer.textSelection }
        set { pointer.textSelection = newValue }
    }

    var textSelectionGesture: NativeTimelineTextSelectionGesture? {
        get { pointer.textSelectionGesture }
        set { pointer.textSelectionGesture = newValue }
    }

    var didDragTextSelection: Bool {
        get { pointer.didDragTextSelection }
        set { pointer.didDragTextSelection = newValue }
    }

    var tracking: NSTrackingArea? {
        get { pointer.trackingArea }
        set { pointer.trackingArea = newValue }
    }

    var rowTrackingAreas: [NSTrackingArea] {
        get { pointer.rowTrackingAreas }
        set { pointer.rowTrackingAreas = newValue }
    }

    var editingRowHost: NativeTimelineEditingHost? {
        get { editing.host }
        set { editing.host = newValue }
    }

    var editingTextView: ComposerNSTextView? {
        get { editing.textView }
        set { editing.textView = newValue }
    }

    var editingMessageID: MessageID? {
        get { editing.messageID }
        set { editing.messageID = newValue }
    }

    var editingRowIndexCache: Int? {
        get { editing.rowIndex }
        set { editing.rowIndex = newValue }
    }

    var editingRowHeight: CGFloat? {
        get { editing.rowHeight }
        set { editing.rowHeight = newValue }
    }

    var editingOverlayLocalFrame: CGRect? {
        get { editing.overlayLocalFrame }
        set { editing.overlayLocalFrame = newValue }
    }

    var editingRowScrollSnapshot: NSImage? {
        get { editing.scrollSnapshot }
        set { editing.scrollSnapshot = newValue }
    }
}
