import AppKit
import Combine
import CoreText
import MessageRendering
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    func reconcileActionCapsule() {
        guard !glideBlocksPointer,
              model?.featuresSettings.messageHoverActions == true
        else {
            removeActionCapsule()
            return
        }
        if let state = actionCapsuleState,
           let model,
           state.isGuildTimedOut != (model.guildTimeoutUntil(
               in: state.message.channelID,
               guildID: state.message.guildID
           ) != nil) {
            // Keep a presented picker across ordinary row updates, but dismiss
            // it when a timeout changes which actions this capsule can offer.
            removeActionCapsule()
        }
        if actionCapsuleState?.isPresentationActive == true {
            // An edited row shows Cancel and Save where its actions would be.
            guard let messageID = actionCapsuleMessageID,
                  messageID != editingMessageID,
                  let index = items.firstIndex(where: {
                      $0.messageID == messageID
                  }),
                  case let .message(row, _, _) = items[index],
                  MessageOutboxPresentation.interactionMode(
                    for: row.message
                  ).allowsHoverActions
            else {
                removeActionCapsule()
                return
            }
            refreshActionCapsuleMessage(row.message)
            positionActionCapsule(at: index)
            return
        }
        guard let index = hoveredRow
                ?? mediaViewerHighlightedMessageID.flatMap({ messageID in
                    items.firstIndex(where: {
                        $0.messageID == messageID
                    })
                }),
              items.indices.contains(index),
              case let .message(row, _, _) = items[index],
              row.message.id != editingMessageID,
              MessageOutboxPresentation.interactionMode(
                for: row.message
              ).allowsHoverActions,
              let model,
              let actions
        else {
            if actionCapsuleState?.isPresentationActive != true {
                removeActionCapsule()
            }
            return
        }

        if actionCapsuleMessageID == row.id,
           actionCapsuleState?.message.canRetrySending == row.message.canRetrySending {
            refreshActionCapsuleMessage(row.message)
            positionActionCapsule(at: index)
            return
        }
        removeActionCapsule()

        installActionCapsule(
            for: row,
            at: index,
            model: model,
            actions: actions
        )
    }

    private func installActionCapsule(
        for row: MessageRowPresentation,
        at index: Int,
        model: AppModel,
        actions: NativeTimelineRowActions
    ) {
        let canEdit = row.message.author.id == model.currentUser?.id
            && !row.message.hasPoll
            && !row.message.flags.contains(.voiceMessage)
            && model.guildTimeoutUntil(in: row.message.channelID, guildID: row.message.guildID) == nil
            && MessageReplyPresentationPolicy.allowsReplyAction(for: row.message)
        let canDelete = model.canDeleteMessage(row.message)
        let jumpToMessage = actions.openMessage.map { openMessage in
            { openMessage(row.message) }
        }
        let isFailed = row.message.outboxState == .failed
        let offersShiftActions = jumpToMessage == nil && !isFailed
        let canPin = (offersShiftActions || messageInteractionContext == .pinnedResult)
            && model.canManagePins(for: row.message)
        let unpinMessage: (() -> Void)? = messageInteractionContext == .pinnedResult && canPin
            ? messageMenuHandler(action: .unpinMessage, row: row, index: index, actions: actions)
            : nil
        let retry = row.message.canRetrySending
            ? { actions.retry(row.message) }
            : nil
        let isGuildTimedOut = model.guildTimeoutUntil(
            in: row.message.channelID,
            guildID: row.message.guildID
        ) != nil
        let canReact = model.canCreateReactions(on: row.message)
        let reply = MessageReplyPresentationPolicy.allowsReplyAction(
            for: row.message
        ) && !isGuildTimedOut ? actions.reply.map { reply in
            { reply(row.message) }
        } : nil
        let forward = model.canForward(row.message)
            ? actions.forward.map { forward in
                { forward(row.message) }
            }
            : nil
        let togglePin: (() -> Void)? = offersShiftActions && canPin
            ? messageMenuHandler(action: .pinMessage, row: row, index: index, actions: actions)
            : nil
        // Copy Message ID, Copy Link and Mark Unread, plus Pin when allowed.
        let shiftActionCount = offersShiftActions ? 3 + (togglePin == nil ? 0 : 1) : 0
        let controlCount = jumpToMessage == nil
            ? (isFailed ? 1 + (retry == nil ? 0 : 1) : 1 + (canReact ? 1 : 0) + (reply == nil ? 0 : 1) + (forward == nil ? 0 : 1) + (canEdit ? 1 : 0))
            : 1 + (unpinMessage == nil ? 0 : 1) + (messageInteractionContext == .inboxMention ? 1 : 0)
        let state = NativeTimelineActionCapsuleState(
            message: row.message,
            controlCount: controlCount,
            shiftActionCount: shiftActionCount,
            allowsQuickReactions: jumpToMessage == nil && canReact,
            isGuildTimedOut: isGuildTimedOut
        )
        // A capsule that appears while Shift is already held starts in the
        // Shift variant without animating.
        state.isShiftHeld = MessageActionShiftPolicy.isActive(NSEvent.modifierFlags)
        state.updateAvailableWidth(bounds.width)
        if shiftActionCount > 0 {
            installActionCapsuleModifierMonitor()
        }
        state.presentationDidChange = { [weak self, weak state] isPresented in
            Task { @MainActor [weak self, weak state] in
                await Task.yield()
                guard let self,
                      let state,
                      self.actionCapsuleState === state
                else { return }
                if isPresented {
                    self.positionActionCapsule()
                } else {
                    self.reconcileActionCapsule()
                }
            }
        }
        let root = NativeTimelineActionCapsuleOverlay(
            model: model,
            canEdit: canEdit,
            canDelete: canDelete,
            state: state,
            jumpToMessage: jumpToMessage,
            unpinMessage: unpinMessage,
            dismissInboxMention: messageInteractionContext == .inboxMention ? { model.dismissInboxMention(row.message) } : nil,
            retry: retry,
            edit: { [weak self] in
                self?.beginEditing(row: row, at: index)
            },
            reply: reply,
            forward: forward,
            react: { emoji in actions.react(emoji, row.message) },
            copy: { Self.copyText(row.message.content) },
            copyLink: { [weak self] in
                guard let self else { return }
                Self.copyText(self.messageLink(for: row.message))
            },
            copyMessageID: messageMenuHandler(action: .copyMessageID, row: row, index: index, actions: actions),
            markUnread: messageMenuHandler(action: .markUnread, row: row, index: index, actions: actions),
            togglePin: togglePin,
            showMoreActions: { [weak self] in
                self?.presentActionCapsuleMenu(forMessageID: row.id)
            },
            delete: messageMenuHandler(action: .deleteMessage, row: row, index: index, actions: actions)
        )
        actionCapsuleState = state
        actionCapsuleHost = addActionCapsuleHost(root, identifier: "message-action-capsule-\(row.id)")
        actionCapsuleMessageID = row.id
        positionActionCapsule(at: index)
    }

    private func addActionCapsuleHost(_ root: some View, identifier: String) -> NativeTimelineActionCapsuleHost {
        // The canvas owns the capsule's exact document-coordinate frame.
        // Nested thread timelines extend beneath their top toolbar, so this
        // host must not inherit that container's safe-area displacement.
        let host = NativeTimelineActionCapsuleHost(rootView: AnyView(root))
        host.setContentHuggingPriority(.required, for: .horizontal)
        host.setContentHuggingPriority(.required, for: .vertical)
        host.setContentCompressionResistancePriority(.required, for: .horizontal)
        host.setContentCompressionResistancePriority(.required, for: .vertical)
        host.setAccessibilityIdentifier(identifier)
        addSubview(host, positioned: .above, relativeTo: nil)
        return host
    }

    func positionActionCapsule(at knownIndex: Int? = nil) {
        guard let state = actionCapsuleState,
              let host = actionCapsuleHost,
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
        state.updateAvailableWidth(bounds.width)
        let size = state.hostSize
        host.frame = rowActionsFrame(size: size, at: index)
        // A capsule clamped against the leading side grows away from it.
        let pinsLeadingEdge = host.frame.minX > rowActionsAnchorMaxX(at: index) - size.width
        if state.pinsLeadingEdge != pinsLeadingEdge {
            state.pinsLeadingEdge = pinsLeadingEdge
        }
        updateActionCapsuleInteractiveFrame()
    }

    private func rowActionsAnchorMaxX(at index: Int) -> CGFloat {
        if let bubble = layouts[index].bubbleRegion {
            return min(bubble.frame.maxX, bounds.width - InterfaceScale.metric(8))
        }
        return bounds.width - InterfaceScale.metric(14)
    }

    /// Where a row's hover actions, or an edit's Cancel and Save, sit: over
    /// the row's top trailing corner, below the window toolbar.
    func rowActionsFrame(size: CGSize, at index: Int) -> CGRect {
        let layout = layouts[index]
        let origin = displayedRowOrigin(at: index)
        let minX: CGFloat
        let originY: CGFloat
        if let bubble = layout.bubbleRegion {
            minX = InterfaceScale.metric(8)
            originY = max(0, origin + bubble.frame.minY - size.height + InterfaceScale.metric(7))
        } else {
            minX = 0
            originY = origin + (layout.highlightFrame?.minY ?? 0) - InterfaceScale.metric(13)
        }
        let originX = max(minX, rowActionsAnchorMaxX(at: index) - size.width)
        // Keep the capsule below the window toolbar when the row reaches it.
        let unobscuredMinY = visibleRect.minY + (enclosingScrollView?.scrollerInsets.top ?? 0)
        let clampedOriginY = visibleRect.isEmpty ? originY : max(originY, unobscuredMinY + InterfaceScale.metric(4))
        return CGRect(x: originX, y: clampedOriginY, width: size.width, height: size.height)
    }

    /// Only the visible pill takes pointer input; the rest of the host is
    /// room for the other variant.
    private func updateActionCapsuleInteractiveFrame() {
        guard let state = actionCapsuleState, let host = actionCapsuleHost else { return }
        let pillWidth = state.actionSize.width
        host.interactiveFrame = CGRect(
            x: state.pinsLeadingEdge ? host.frame.minX : host.frame.maxX - pillWidth,
            y: host.frame.minY,
            width: pillWidth,
            height: host.frame.height
        )
    }

    /// Lives as long as the canvas once installed; without a capsule it
    /// does nothing.
    func installActionCapsuleModifierMonitor() {
        guard actionCapsuleModifierMonitor == nil else { return }
        actionCapsuleModifierMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            self?.setActionCapsuleShiftHeld(
                MessageActionShiftPolicy.isActive(event.modifierFlags)
            )
            return event
        }
    }

    func setActionCapsuleShiftHeld(_ isHeld: Bool) {
        guard let state = actionCapsuleState, state.isShiftHeld != isHeld else { return }
        state.isShiftHeld = isHeld
        updateActionCapsuleInteractiveFrame()
    }

    /// Modifier changes are not delivered while another app is active or a
    /// menu is tracking, so re-read Shift when either ends.
    @objc func synchronizeActionCapsuleShiftState() {
        setActionCapsuleShiftHeld(MessageActionShiftPolicy.isActive(NSEvent.modifierFlags))
    }

    /// The capsule's More button opens the same menu as a right click.
    func presentActionCapsuleMenu(forMessageID messageID: MessageID) {
        guard let host = actionCapsuleHost,
              let actions,
              let index = items.firstIndex(where: { $0.messageID == messageID }),
              case let .message(row, _, _) = items[index],
              let menu = messageContextMenu(
                for: row,
                at: index,
                targetsAuthor: false,
                actions: actions,
                failedMediaActions: nil
              )
        else { return }
        let pillFrame = host.interactiveFrame ?? host.frame
        menu.popUp(
            positioning: nil,
            at: NSPoint(
                x: pillFrame.maxX - HoverActionPillMetrics.padding - HoverActionPillMetrics.controlDiameter,
                y: pillFrame.maxY + InterfaceScale.metric(4)
            ),
            in: self
        )
    }

    /// Keeps a shown capsule on the row's current message, such as after a
    /// reaction toggles, without reinstalling it.
    private func refreshActionCapsuleMessage(_ message: Message) {
        guard let state = actionCapsuleState, state.message != message else { return }
        state.message = message
    }

    func removeActionCapsule() {
        actionCapsuleState?.presentationDidChange = nil
        actionCapsuleHost?.removeFromSuperview()
        actionCapsuleHost = nil
        actionCapsuleState = nil
        actionCapsuleMessageID = nil
    }
}
