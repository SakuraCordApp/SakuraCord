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

    /// Pointer changes only need the bounded visible rows, never a search of
    /// the entire message history. Rows outside the viewport need no redraw.
    func visibleMessageRowIndex(for messageID: MessageID) -> Int? {
        let viewport = enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard viewport.height > 0, var index = rowIndex(at: max(0, viewport.minY)) else { return nil }
        while items.indices.contains(index), layouts.indices.contains(index),
              displayedRowOrigin(at: index) < viewport.maxY {
            if items[index].messageID == messageID, rowFrame(at: index).intersects(viewport) { return index }
            index += 1
        }
        return nil
    }

    func invalidateVisibleMessageRow(messageID: MessageID) {
        guard let index = visibleMessageRowIndex(for: messageID) else { return }
        setNeedsDisplay(rowFrame(at: index))
    }

    func setHoveredServerTagMessageID(_ value: MessageID?) {
        guard hoveredServerTagMessageID != value else { return }
        let old = hoveredServerTagMessageID
        hoveredServerTagMessageID = value
        for messageID in [old, value].compactMap({ $0 }) { invalidateVisibleMessageRow(messageID: messageID) }
    }

    func serverTagPointerHit(at point: CGPoint) -> MessageID? {
        guard let index = rowIndex(at: point.y), items.indices.contains(index), layouts.indices.contains(index),
              let tag = layouts[index].serverTagRegion, tag.presentation.identity.guildID != nil
        else { return nil }
        let local = CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index))
        return tag.frame.contains(local) ? items[index].messageID : nil
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
        closeMessageProfilePopover()
        closeMentionPopover()
        closeServerTagPopover()
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

extension NativeTimelineRowLayout {
    func matchesAuthorPrimaryGuild(for item: NativeMessageTimelineItem, source: AppModel) -> Bool {
        guard authorFrame != nil, let row = item.messageRow else { return true }
        return authorPrimaryGuild == source.authorPresentation(for: row.message).user.primaryGuild
    }
}
