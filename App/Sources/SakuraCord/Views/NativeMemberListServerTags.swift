import AppKit
import SakuraCordModels
import SwiftUI

@MainActor
extension NativeMemberListCanvasView {
    struct MemberNameGeometry {
        let viewportWidth: CGFloat
        let nameX: CGFloat
        let layout: NativeMemberNameLayout.Result
        let serverTagFrame: CGRect?
        let roleIconFrame: CGRect?
        let botBadgeFrame: CGRect?
        let topRoleWithIcon: GuildRole?
    }

    struct ServerTagCardPresentation {
        let requestID: UUID
        let itemID: ItemID
        let identity: PrimaryGuildIdentity
        let account: AppModelAccountSession
    }

    func memberNameGeometry(
        _ member: Member,
        prepared: PreparedText,
        at index: Int
    ) -> MemberNameGeometry {
        let itemID = items[index].id
        if let cached = memberNameGeometries[itemID],
           cached.viewportWidth == bounds.width
        {
            return cached
        }
        let row = paintedRowRect(at: index)
        let textX = row.minX + 4 + NativeMemberListMetrics.avatarContainerSize + 8
        let hasRoleIndicator = presentation.roleColorDisplay == .nextToNames
            && MessageAuthorPresentation.topRoleColor(in: member.roles) != nil
        let nameX = textX + (hasRoleIndicator ? InterfaceScale.metric(13) : 0)
        let role = MessageAuthorPresentation.topRoleWithIcon(in: member.roles)
        let roleIconSize: CGFloat = role != nil ? InterfaceScale.metric(14) : 0

        var accessoryWidths: [CGFloat] = []
        var tagIndex: Int?
        var roleIndex: Int?
        var botIndex: Int?

        if let tag = prepared.serverTag {
            tagIndex = accessoryWidths.count
            accessoryWidths.append(tag.width)
        }
        if role != nil {
            roleIndex = accessoryWidths.count
            accessoryWidths.append(roleIconSize)
        }
        if member.user.isBot {
            botIndex = accessoryWidths.count
            accessoryWidths.append(NativeAppBadgePresentation.width)
        }

        let layout = NativeMemberNameLayout.layout(
            measuredNameWidth: prepared.nameWidth,
            availableWidth: max(0, row.maxX - 4 - nameX - InterfaceScale.metric(presentation.trailingAccessoryWidth)),
            accessoryWidths: accessoryWidths
        )
        let nameY = prepared.activity == nil ? row.minY + 13 : row.minY + 5
        let nameCenterY = nameY + prepared.nameFont.ascender - prepared.nameFont.capHeight / 2.0

        let tagFrame: CGRect? = if let tagIndex, let tag = prepared.serverTag,
           layout.accessoryFrames.indices.contains(tagIndex),
           layout.accessoryFrames[tagIndex].width >= tag.width {
            CGRect(
                x: nameX + layout.accessoryFrames[tagIndex].minX,
                y: (nameCenterY - NativeServerTagPresentation.height / 2).rounded(),
                width: tag.width,
                height: NativeServerTagPresentation.height
            )
        } else { nil }

        let roleIconFrame: CGRect? = if let roleIndex,
           layout.accessoryFrames.indices.contains(roleIndex),
           layout.accessoryFrames[roleIndex].width >= roleIconSize {
            CGRect(
                x: nameX + layout.accessoryFrames[roleIndex].minX,
                y: (nameCenterY - roleIconSize / 2).rounded(),
                width: roleIconSize,
                height: roleIconSize
            )
        } else { nil }

        let botBadgeFrame: CGRect? = if let botIndex,
           layout.accessoryFrames.indices.contains(botIndex),
           layout.accessoryFrames[botIndex].width >= NativeAppBadgePresentation.width {
            CGRect(
                x: nameX + layout.accessoryFrames[botIndex].minX,
                y: (nameCenterY - ServerTagAppearance.height / 2).rounded(),
                width: NativeAppBadgePresentation.width,
                height: ServerTagAppearance.height
            )
        } else { nil }

        let geometry = MemberNameGeometry(
            viewportWidth: bounds.width,
            nameX: nameX,
            layout: layout,
            serverTagFrame: tagFrame,
            roleIconFrame: roleIconFrame,
            botBadgeFrame: botBadgeFrame,
            topRoleWithIcon: role
        )
        memberNameGeometries[itemID] = geometry
        return geometry
    }

    func serverTagFrame(at index: Int) -> CGRect? {
        guard items.indices.contains(index),
              case .member(let member, _) = items[index],
              let prepared = preparedText[items[index].id]
        else { return nil }
        return memberNameGeometry(member, prepared: prepared, at: index).serverTagFrame
    }

    func canActivateServerTag(at index: Int) -> Bool {
        guard serverTagCardModel != nil,
              items.indices.contains(index),
              let tag = preparedText[items[index].id]?.serverTag,
              tag.identity.guildID != nil
        else { return false }
        return true
    }

    func serverTagIndex(at point: CGPoint) -> Int? {
        guard !isScrolling, !interactionsBlocked,
              WindowModalCoordinator.allowsInput(for: self),
              let index = index(at: point),
              canActivateServerTag(at: index),
              serverTagFrame(at: index)?.contains(point) == true
        else { return nil }
        return index
    }

    func updateServerTagHover(at point: CGPoint) {
        let newID = serverTagIndex(at: point).map { items[$0].id }
        guard hoveredServerTagID != newID else { return }
        let previousID = hoveredServerTagID
        hoveredServerTagID = newID
        for id in [previousID, newID].compactMap({ $0 }) {
            invalidateServerTag(itemID: id)
        }
    }

    func clearServerTagHover() {
        guard let previousID = hoveredServerTagID else { return }
        hoveredServerTagID = nil
        invalidateServerTag(itemID: previousID)
    }

    func invalidateServerTag(itemID: ItemID) {
        guard let index = itemIndexesByID[itemID] else { return }
        setNeedsDisplay(itemRect(at: index))
        if rowOverlayIndex == index { rowForegroundOverlay?.needsDisplay = true }
    }

    func activateServerTag(at index: Int) {
        guard !isScrolling, !interactionsBlocked,
              WindowModalCoordinator.allowsInput(for: self),
              canActivateServerTag(at: index),
              let model = serverTagCardModel,
              let tag = preparedText[items[index].id]?.serverTag,
              let guildID = tag.identity.guildID,
              serverTagFrame(at: index) != nil
        else { return }
        let account = model.accountSession()
        guard model.isCurrentAccountSession(account) else { return }
        let itemID = items[index].id
        if serverTagCardPresentation?.itemID == itemID {
            dismissServerTagCard()
            return
        }
        dismissServerTagCard()
        if isProfilePresented { dismissProfile() }
        profilePopoverCoordinator.close()
        let presentation = ServerTagCardPresentation(
            requestID: UUID(), itemID: itemID, identity: tag.identity,
            account: account
        )
        serverTagCardPresentation = presentation
        invalidateServerTag(itemID: itemID)
        serverTagPopoverCoordinator.update(
            anchor: serverTagPopoverAnchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .interactive,
            onDismiss: { [weak self] in
                self?.dismissServerTagCard(ifCurrent: presentation.requestID)
            },
            presentationIdentity: AnyHashable(presentation.requestID),
            content: AnyView(
                ServerTagCard(model: model, guildID: guildID) { [weak self] in
                    self?.dismissServerTagCard(ifCurrent: presentation.requestID)
                }
            )
        )
    }

    func isCurrentServerTagCardPresentation(_ presentation: ServerTagCardPresentation) -> Bool {
        guard let model = serverTagCardModel,
              model.isCurrentAccountSession(presentation.account),
              let index = itemIndexesByID[presentation.itemID],
              preparedText[presentation.itemID]?.serverTag?.identity == presentation.identity,
              let frame = serverTagFrame(at: index),
              enclosingScrollView?.documentVisibleRect.intersects(frame) == true
        else { return false }
        return true
    }

    func reconcileServerTagCardPresentation() {
        if let presentation = serverTagCardPresentation,
           !isCurrentServerTagCardPresentation(presentation)
        {
            dismissServerTagCard()
        }
    }

    func dismissServerTagCard(ifCurrent requestID: UUID? = nil) {
        if let requestID, serverTagCardPresentation?.requestID != requestID { return }
        let previousID = serverTagCardPresentation?.itemID
        serverTagCardPresentation = nil
        serverTagPopoverCoordinator.close()
        if let previousID { invalidateServerTag(itemID: previousID) }
    }
}

/// A visible-range accessibility proxy; native canvas drawing owns the pill.
@MainActor
final class NativeMemberTagAccessibilityButton: NSButton {
    var activation: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        target = self
        action = #selector(activateTag)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Shows the server’s profile")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {}

    @objc private func activateTag() { activation?() }
}
