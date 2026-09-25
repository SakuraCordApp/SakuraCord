import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    func installTranslationCursor(at index: Int, rowOrigin: CGFloat) {
        guard let frame = layouts[index].translationRegion?.actionFrame else { return }
        addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
    }

    func translationAccessibilityActions(for message: Message) -> [NSAccessibilityCustomAction] {
        guard let title = model?.messageTranslationMenuTitle(for: message) else { return [] }
        var actions = [NSAccessibilityCustomAction(name: title) { [weak self] in
            self?.model?.toggleMessageTranslation(message)
            return self != nil
        }]
        if model?.translatedMessageText(message) != nil {
            actions.append(NSAccessibilityCustomAction(name: "Copy Translation") { [weak self] in
                guard let text = self?.model?.translatedMessageText(message) else { return false }
                Self.copyText(text)
                return true
            })
        }
        return actions
    }

    func appendTranslationAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        guard let region = layout.translationRegion else { return }
        var label = region.caption
        if let attributed = region.attributedText {
            let text = TimelineTextAccessibility.text(attributed, revealedLocations: textSpoilerRevealState(at: rowIndex).locations(in: region.regionID))
            if !text.isEmpty { label += ": \(text)" }
        }
        children.append(accessibilityElement(
            role: .staticText,
            label: label,
            frame: accessibilityChildFrame(region.frame, rowIndex: rowIndex),
            parent: parent
        ))
        guard let actionTitle = region.actionTitle, let actionFrame = region.actionFrame else { return }
        children.append(accessibilityElement(
            role: .button,
            label: actionTitle,
            frame: accessibilityChildFrame(actionFrame, rowIndex: rowIndex),
            parent: parent
        ) { [weak self] in
            guard let self else { return false }
            self.model?.performMessageTranslationCaptionAction(message)
            return true
        })
    }
}
