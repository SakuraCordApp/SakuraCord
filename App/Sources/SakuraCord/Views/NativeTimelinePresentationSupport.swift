import AppKit
import Combine
import SakuraCordModels
import SwiftUI

@MainActor
final class NativeTimelineCanvasStorage {
    var items: [NativeMessageTimelineItem] = []
    var layouts: [NativeTimelineRowLayout] = []
    var rowHeights: [CGFloat] = []
    var rowOrigins: [CGFloat] = []
    var contentHeight: CGFloat = 0
}

/// The canvas's row layouts, with the row being edited inline laid out
/// around its editor.
@MainActor
struct NativeTimelineCanvasLayouts: @MainActor RandomAccessCollection {
    let storage: NativeTimelineCanvasStorage
    let editing: NativeTimelineEditingSession

    var startIndex: Int { storage.layouts.startIndex }
    var endIndex: Int { storage.layouts.endIndex }

    subscript(index: Int) -> NativeTimelineRowLayout {
        // The edit's row index can trail a storage update until the canvas
        // reconciles it, so the replacement also has to match the message.
        if index == editing.rowIndex, let layout = editing.layout,
           storage.items[index].messageID == editing.messageID {
            return layout
        }
        return storage.layouts[index]
    }
}

nonisolated final class NativeTimelineAccessibilityElement:
    NSAccessibilityElement
{
    let press: (@MainActor @Sendable () -> Bool)?

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
    nonisolated let press: (@MainActor @Sendable () -> Bool)?

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
    static func stickerLabel(_ sticker: MessageSticker) -> String {
        nonblank(sticker.description) ?? sticker.name
    }

    static func threadLabel(_ thread: MessageThreadSummary) -> String {
        let replyCount = thread.messageCount
        var label = "\(thread.name), \(replyCount) "
            + (replyCount == 1 ? "reply" : "replies")
        if thread.isArchived { label += ", archived" }
        if thread.isLocked { label += ", locked" }
        return label
    }

    static func nonblank(_ value: String?) -> String? {
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

    static func editingOverlayInsertionIndex(
        in rowIdentifiers: [NativeMessageTimelineItem.Identifier],
        editingItemIdentifier: NativeMessageTimelineItem.Identifier?
    ) -> Int? {
        guard let editingItemIdentifier,
              let rowIndex = rowIdentifiers.firstIndex(
                  of: editingItemIdentifier
              )
        else { return nil }
        return rowIndex + 1
    }
}

struct NativeTimelineComponentRevealKey: Hashable {
    let messageID: MessageID
    let componentID: String

    /// Keyed by the link, as embed IDs are only positions: an edit that
    /// replaces the link must not inherit the old one's reveal.
    static func embed(messageID: MessageID, url: URL, occurrence: Int) -> Self {
        Self(messageID: messageID, componentID: "embed:\(occurrence):\(url.absoluteString)")
    }

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

    static func heightDelta(
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementHeight, let baseRowHeight else { return 0 }
        return replacementHeight - baseRowHeight
    }
}

final class NativeTimelineBeginningSelectionOverlay: NSImageView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}
