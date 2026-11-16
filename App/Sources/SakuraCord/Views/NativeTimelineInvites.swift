import AppKit
import SakuraCordModels

extension NativeMessageTimelineCoordinator {
    func refreshServerInvites(_ reference: ServerInviteReference?) {
        guard let canvas, let scrollView, layoutWidth > 0 else { return }
        relayRows(
            where: { item in
                guard let row = item.messageRow, !row.serverInvites.isEmpty || row.message.hasActivityInstance else { return false }
                return reference.map { row.serverInvites.contains($0) } ?? true
            },
            on: canvas, in: scrollView,
            layout: { layout(for: $0, width: layoutWidth) }
        )
    }
}

extension NativeTimelineCanvasView {
    func installInviteCursors(at index: Int, rowOrigin: CGFloat) {
        for card in layouts[index].inviteRegions {
            if !card.isDisabled {
                addCursorRect(card.buttonFrame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
            }
            if let frame = card.detailsFrame {
                addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
            }
        }
    }

    func activateInvite(_ card: NativeTimelineInviteLayout, message: Message, expands: Bool) {
        guard let model else { return }
        if let instanceID = card.content?.activityInstanceID {
            guard !card.isDisabled, !expands else { return }
            model.startAccountChildTask(account: model.accountSession()) { model, _ in
                await model.joinActivityInstance(instanceID, from: message)
            }
            return
        }
        guard let reference = card.reference else { return }
        if expands {
            if !model.serverInvites.expanded.insert(reference).inserted {
                model.serverInvites.expanded.remove(reference)
            }
            model.serverInvites.changed(reference)
            return
        }
        guard !card.isDisabled else { return }
        if let invite = card.invite, invite.activity != nil, model.presentationGuild(invite.guildID) != nil {
            model.startAccountChildTask(account: model.accountSession()) { model, _ in
                await model.joinActivityInvite(invite)
            }
            return
        }
        if card.invite?.unsupportedJoinReason != nil,
           card.invite.flatMap({ model.serverRailGuildsByID[$0.guildID] }) == nil {
            NSWorkspace.shared.open(reference.url)
            return
        }
        let session = model.accountSession()
        model.startAccountChildTask(account: session) { model, _ in
            _ = await model.activateServerInvite(reference, messageID: message.id)
        }
    }

    func appendInviteAccessibility(message: Message, to children: inout [Any], layout: NativeTimelineRowLayout,
                                   rowIndex: Int, parent: NSAccessibilityElement) {
        for card in layout.inviteRegions {
            let group = accessibilityElement(role: .group,
                label: (card.content?.activity == nil ? "Server invite. " : "Activity. ") + card.accessibilityLabel,
                frame: accessibilityChildFrame(card.frame, rowIndex: rowIndex), parent: parent)
            var controls: [Any] = []
            if card.buttonFrame.height > 0 {
                let button = accessibilityElement(role: .button, label: card.buttonTitle,
                    frame: accessibilityChildFrame(card.buttonFrame, rowIndex: rowIndex), parent: group) { [weak self] in
                    guard !card.isDisabled else { return false }
                    self?.activateInvite(card, message: message, expands: false)
                    return true
                }
                button.setAccessibilityEnabled(!card.isDisabled)
                controls.append(button)
            }
            if let details = card.detailsFrame {
                controls.append(accessibilityElement(role: .button, label: card.isExpanded ? "Hide Details" : "Show Details",
                    frame: accessibilityChildFrame(details, rowIndex: rowIndex), parent: group) { [weak self] in
                    self?.activateInvite(card, message: message, expands: true)
                    return true
                })
            }
            group.setAccessibilityChildren(controls)
            children.append(group)
        }
    }
}
