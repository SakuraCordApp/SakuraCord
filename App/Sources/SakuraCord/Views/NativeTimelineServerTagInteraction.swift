import AppKit
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    struct ServerTagCardPresentation {
        let requestID: UUID
        let messageID: MessageID
        let identity: PrimaryGuildIdentity
        let account: AppModelAccountSession
    }

    func setHoveredServerTagMessageID(_ value: MessageID?) {
        guard hoveredServerTagMessageID != value else { return }
        let old = hoveredServerTagMessageID
        hoveredServerTagMessageID = value
        for messageID in [old, value].compactMap({ $0 }) { invalidateVisibleMessageRow(messageID: messageID) }
    }

    func serverTagPointerHit(at point: CGPoint) -> MessageID? {
        messageID(at: point) { index in
            layouts[index].serverTagRegion.flatMap { $0.presentation.identity.guildID == nil ? nil : $0.frame }
        }
    }

    func serverTagPopoverSourceRect(for presentation: ServerTagCardPresentation) -> CGRect? {
        guard let model, model.isCurrentAccountSession(presentation.account),
              let index = visibleMessageRowIndex(for: presentation.messageID),
              let row = items[index].messageRow,
              let tag = layouts[index].serverTagRegion,
              tag.presentation.identity == presentation.identity,
              model.authorPresentation(for: row.message).user.primaryGuild == presentation.identity
        else { return nil }
        return tag.frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
    }

    func reconcileServerTagCardPresentation() {
        if let presentation = serverTagCardPresentation, serverTagPopoverSourceRect(for: presentation) == nil {
            closeServerTagPopover()
        }
    }

    func showServerTagCard(guildID: GuildID, anchor: CGRect) {
        guard let model, let index = rowIndex(at: anchor.midY),
              items.indices.contains(index), layouts.indices.contains(index),
              let messageID = items[index].messageID,
              let tag = layouts[index].serverTagRegion, tag.presentation.identity.guildID == guildID
        else { return }
        let account = model.accountSession()
        guard model.isCurrentAccountSession(account) else { return }
        if serverTagCardPresentation?.messageID == messageID, serverTagCardPresentation?.identity == tag.presentation.identity {
            closeServerTagPopover()
            return
        }
        closeCanvasPopovers()
        let presentation = ServerTagCardPresentation(requestID: UUID(), messageID: messageID,
                                                   identity: tag.presentation.identity, account: account)
        guard serverTagPopoverSourceRect(for: presentation) != nil else { return }
        serverTagCardPresentation = presentation
        invalidateVisibleMessageRow(messageID: messageID)
        let popoverAnchor = StablePopoverAnchor(sourceView: self, sourceRect: { [weak self] in
            self?.serverTagPopoverSourceRect(for: presentation)
        })
        activeServerTagPopoverAnchor = popoverAnchor
        serverTagPopoverCoordinator.update(
            anchor: popoverAnchor, anchorSnapshot: nil, isPresented: true,
            configuration: .interactive,
            onDismiss: { [weak self] in self?.closeServerTagPopover(ifCurrent: presentation.requestID) },
            presentationIdentity: AnyHashable(presentation.requestID),
            content: AnyView(ServerTagCard(model: model, guildID: guildID) { [weak self] in
                self?.closeServerTagPopover(ifCurrent: presentation.requestID)
            })
        )
    }

    func closeServerTagPopover(ifCurrent requestID: UUID? = nil) {
        if let requestID, serverTagCardPresentation?.requestID != requestID { return }
        let previousMessageID = serverTagCardPresentation?.messageID
        serverTagCardPresentation = nil
        activeServerTagPopoverAnchor = nil
        serverTagPopoverCoordinator.close()
        if let previousMessageID { invalidateVisibleMessageRow(messageID: previousMessageID) }
    }
}
