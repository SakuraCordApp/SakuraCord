import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
final class NativeMemberAccessibilityProxyView: NSButton {
    var member: Member? {
        didSet {
            guard let member else { return }
            setAccessibilityLabel(member.user.displayName)
            setAccessibilityHelp(member.user.username)
            let activity = member.memberListActivityText.flatMap {
                $0.isEmpty ? nil : NativeMemberActivityPresentation.accessibilityText($0)
            }
            let presence = member.memberListStatus.map {
                PresenceIndicatorPresentation.accessibilityLabel(for: $0, isMobile: member.showsMobileIndicator)
            }
            let activityLabel = activity.map {
                member.isListeningToMusic ? "Listening to music, \($0)" : $0
            }
            setAccessibilityValue([presence, activityLabel].compactMap { $0 }.joined(separator: ", "))
            toolTip = member.memberListTooltip
        }
    }
    var activation: ((Member) -> Void)?
    var customActions: ((Member) -> [NSAccessibilityCustomAction])?

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let member else { return nil }
        return customActions?(member)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.backgroundColor = .clear
        setAccessibilityRole(.button)
        target = self
        action = #selector(activateMember)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func activateMember() {
        guard let member else { return }
        activation?(member)
    }
}
