import AppKit
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    struct RoleIconCardPresentation: Equatable {
        let requestID: UUID
        let messageID: MessageID
        let role: GuildRole
    }

    func roleIconPopoverSourceRect(for presentation: RoleIconCardPresentation) -> CGRect? {
        guard let index = visibleMessageRowIndex(for: presentation.messageID),
              let region = layouts[index].roleIconRegion,
              region.role.id == presentation.role.id
        else { return nil }
        return region.frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
    }

    func reconcileRoleIconCardPresentation() {
        if let presentation = roleIconCardPresentation, roleIconPopoverSourceRect(for: presentation) == nil {
            closeRoleIconPopover()
        }
    }

    func showRoleIconPopover(role: GuildRole, messageID: MessageID, anchor: CGRect) {
        if roleIconCardPresentation?.messageID == messageID, roleIconCardPresentation?.role.id == role.id {
            closeRoleIconPopover()
            return
        }
        closeMessageProfilePopover()
        closeMentionPopover()
        closeServerTagPopover()
        closeRoleIconPopover()

        let presentation = RoleIconCardPresentation(requestID: UUID(), messageID: messageID, role: role)
        guard roleIconPopoverSourceRect(for: presentation) != nil else { return }
        roleIconCardPresentation = presentation

        let popoverAnchor = StablePopoverAnchor(sourceView: self, sourceRect: { [weak self] in
            self?.roleIconPopoverSourceRect(for: presentation)
        })
        activeRoleIconPopoverAnchor = popoverAnchor
        roleIconPopoverCoordinator.update(
            anchor: popoverAnchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .roleIcon,
            onDismiss: { [weak self] in self?.closeRoleIconPopover(ifCurrent: presentation.requestID) },
            presentationIdentity: AnyHashable(presentation.requestID),
            content: AnyView(RoleIconPopoverView(role: role))
        )
    }

    func closeRoleIconPopover(ifCurrent requestID: UUID? = nil) {
        if let requestID, roleIconCardPresentation?.requestID != requestID { return }
        roleIconCardPresentation = nil
        activeRoleIconPopoverAnchor = nil
        roleIconPopoverCoordinator.close()
    }
}
