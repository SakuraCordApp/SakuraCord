import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    func appendComponentMediaAccessibility(
        to children: inout [Any],
        input: ComponentMediaA11yInput
    ) {
        let label = input.label
        let frame = input.frame
        let componentID = input.componentID
        let openURL = input.openURL
        let isSpoiler = input.isSpoiler
        let message = input.message
        let rowIndex = input.rowIndex
        let parent = input.parent
        let usesFileActionLabels = input.usesFileActionLabels
        let viewerPresentation = input.viewerPresentation
        let key = NativeTimelineComponentRevealKey(
            messageID: message.id,
            componentID: componentID
        )
        let isHiddenSpoiler =
            isSpoiler && !spoilerRevealStore.isMediaRevealed(key)
        let accessibilityLabel =
            if usesFileActionLabels {
                isHiddenSpoiler ? "Reveal spoiler file" : "Open \(label)"
            } else {
                isHiddenSpoiler ? "Reveal spoiler media" : label
            }
        children.append(accessibilityElement(
            role: .button,
            label: accessibilityLabel,
            help: usesFileActionLabels
                ? (isHiddenSpoiler ? "Reveal spoiler" : "Open \(label)")
                : (
                    isHiddenSpoiler
                        ? "Reveals this media without opening it"
                        : "Open \(label)"
                ),
            frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
            parent: parent
        ) { [weak self] in
            guard let self else { return false }
            if isHiddenSpoiler {
                self.reveal(key, rowIndex: rowIndex)
            } else if let viewerPresentation {
                self.model?.mediaViewerPresentation =
                    self.mediaViewerPresentation(
                        viewerPresentation,
                        componentID: componentID,
                        rowIndex: rowIndex
                    )
            } else {
                NSWorkspace.shared.open(openURL)
            }
            return true
        })
    }

    func accessibilityMessageActions(
        _ row: MessageRowPresentation,
        rowFrame: CGRect,
        rowIndex: Int
    ) -> [NSAccessibilityCustomAction] {
        let message = row.message
        let canEdit = !message.hasPoll && message.author.id == model?.snapshot?.currentUser.id
            && MessageReplyPresentationPolicy.allowsReplyAction(for: message)
        let canDelete = model?.canDeleteMessage(message) == true
        if messageInteractionContext != .conversation {
            return accessibilityInboxOrSearchActions(message, canDelete: canDelete)
        }
        var result: [NSAccessibilityCustomAction] = []
        if message.outboxState == .failed {
            result.append(NSAccessibilityCustomAction(
                name: "Retry Send"
            ) { [weak self] in
                self?.actions?.retry(message)
                return self != nil
            })
            result.append(NSAccessibilityCustomAction(
                name: "Copy Text"
            ) {
                Self.copyText(message.content)
                return true
            })
            return result
        }
        result.append(accessibilityReactionAction(
            for: message,
            rowFrame: rowFrame
        ))
        if MessageReplyPresentationPolicy.allowsReplyAction(for: message),
           let reply = actions?.reply
        {
            result.append(NSAccessibilityCustomAction(name: "Reply") {
                reply(message)
                return true
            })
        }
        if model?.canForward(message) == true, let forward = actions?.forward {
            result.append(NSAccessibilityCustomAction(name: "Forward") {
                forward(message)
                return true
            })
        }
        result.append(NSAccessibilityCustomAction(
            name: "Mark Unread"
        ) { [weak self] in
            self?.actions?.markUnread(message)
            return self != nil
        })
        if message.outboxState == .confirmed, message.author.id == model?.snapshot?.currentUser.id, message.poll?.isClosed() == false {
            result.append(NSAccessibilityCustomAction(name: "End Poll Now") { [weak self] in
                self?.requestEndPoll(message)
                return self != nil
            })
        }
        if canEdit {
            result.append(NSAccessibilityCustomAction(
                name: "Edit Message"
            ) { [weak self] in
                guard let self else { return false }
                self.beginEditing(row: row, at: rowIndex)
                return true
            })
        }
        if let pinAction = pinAccessibilityAction(for: message) {
            result.append(pinAction)
        }
        result.append(contentsOf: translationAccessibilityActions(for: message))
        result.append(NSAccessibilityCustomAction(
            name: "Copy Text"
        ) {
            Self.copyText(message.content)
            return true
        })
        result.append(NSAccessibilityCustomAction(
            name: "Copy Message Link"
        ) { [weak self] in
            guard let self else { return false }
            Self.copyText(self.messageLink(for: message))
            return true
        })
        result.append(NSAccessibilityCustomAction(
            name: "Copy Message ID"
        ) {
            Self.copyText(message.id.description)
            return true
        })
        if canDelete {
            result.append(NSAccessibilityCustomAction(
                name: "Delete Message…"
            ) { [weak self] in
                self?.requestDelete(message)
                return self != nil
            })
        }
        return result
    }

    private func accessibilityReactionAction(
        for message: Message,
        rowFrame: CGRect
    ) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: "Add Reaction") { [weak self] in
            guard let self else { return false }
            self.showReactionPicker(
                for: message,
                anchor: CGRect(
                    x: rowFrame.maxX - 32,
                    y: rowFrame.minY,
                    width: 28,
                    height: 28
                ),
                preferredEdge: .minY
            )
            return true
        }
    }

    private func accessibilitySearchResultActions(
        for message: Message,
        canDelete: Bool,
        includesMarkUnread: Bool
    ) -> [NSAccessibilityCustomAction] {
        var result = [
            NSAccessibilityCustomAction(name: "Jump to Message") { [weak self] in
                guard let openMessage = self?.actions?.openMessage else {
                    return false
                }
                openMessage(message)
                return true
            },
            NSAccessibilityCustomAction(name: "Copy Text") {
                Self.copyText(message.content)
                return true
            },
            NSAccessibilityCustomAction(name: "Copy Link") { [weak self] in
                guard let self else { return false }
                Self.copyText(self.messageLink(for: message))
                return true
            },
        ]
        if includesMarkUnread {
            result.insert(NSAccessibilityCustomAction(name: "Mark Unread") { [weak self] in
                self?.actions?.markUnread(message)
                return self != nil
            }, at: 1)
        }
        if let pinAction = pinAccessibilityAction(for: message) {
            result.insert(pinAction, at: min(2, result.count))
        }
        result.append(contentsOf: [
            NSAccessibilityCustomAction(name: "Copy Message ID") {
                Self.copyText(message.id.description)
                return true
            },
            NSAccessibilityCustomAction(name: "Copy Message Author ID") {
                Self.copyText(message.author.id.description)
                return true
            },
        ])
        if canDelete {
            result.append(NSAccessibilityCustomAction(
                name: "Delete Message…"
            ) { [weak self] in
                self?.requestDelete(message)
                return self != nil
            })
        }
        return result
    }

    private func pinAccessibilityAction(
        for message: Message
    ) -> NSAccessibilityCustomAction? {
        guard model?.canManagePins(for: message) == true else { return nil }
        return NSAccessibilityCustomAction(
            name: message.isPinned ? "Unpin Message" : "Pin Message"
        ) { [weak self] in
            self?.actions?.togglePin(message)
            return self != nil
        }
    }

    func accessibilityMessageText(_ message: Message) -> String {
        if message.type.hasGeneratedContent {
            return SystemMessagePresentation.label(
                for: message,
                currentUserID: model?.snapshot?.currentUser.id
            )
        }
        if message.flags.contains(.isComponentsV2) {
            return ""
        }
        let content =
            MessageEmbedPresentation.visibleMessageContent(for: message)
        guard !content.isEmpty else { return "" }
        return accessibilityResolvedText(content, message: message)
    }

    func accessibilityResolvedText(
        _ content: String,
        message: Message
    ) -> String {
        guard let model else {
            return MessageReplySummary.text(content: content)
        }
        return MessageReplySummary.text(
            content: content,
            mentionLabel: MessageMentionResolver(
                model: model,
                message: message
            ).label
        )
    }

    func accessibilityChildFrame(
        _ frame: CGRect,
        rowIndex: Int
    ) -> CGRect {
        frame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: rowIndex)
        )
    }

    func accessibilityScreenFrame(_ frame: CGRect) -> CGRect {
        guard let window else { return frame }
        return window.convertToScreen(convert(frame, to: nil))
    }

    func accessibilityElement(
        role: NSAccessibility.Role,
        label: String,
        value: String? = nil,
        help: String? = nil,
        identifier: String? = nil,
        frame: CGRect,
        parent: Any?,
        isEnabled: Bool = true,
        press: (@MainActor @Sendable () -> Bool)? = nil
    ) -> NSAccessibilityElement {
        let element: NSAccessibilityElement =
            if let press {
                NativeTimelineAccessibilityElement(press: press)
            } else {
                NSAccessibilityElement()
            }
        element.setAccessibilityRole(role)
        element.setAccessibilityLabel(label)
        element.setAccessibilityValue(value)
        element.setAccessibilityHelp(help)
        element.setAccessibilityIdentifier(identifier)
        element.setAccessibilityFrame(accessibilityScreenFrame(frame))
        element.setAccessibilityParent(
            parent.flatMap {
                NSAccessibility.unignoredAncestor(of: $0) ?? $0
            }
        )
        element.setAccessibilityWindow(window)
        element.setAccessibilityTopLevelUIElement(window)
        element.setAccessibilityEnabled(isEnabled)
        return element
    }

    func activateAttachment(
        _ attachment: Attachment,
        in message: Message,
        rowIndex: Int
    ) -> Bool {
        let revealKey = NativeTimelineComponentRevealKey.attachment(
            messageID: message.id,
            attachmentID: attachment.id
        )
        if attachment.isSpoiler,
           !spoilerRevealStore.isMediaRevealed(revealKey)
        {
            reveal(revealKey, rowIndex: rowIndex)
        } else if let presentation =
            NativeTimelineMediaViewerPlan.attachments(
                in: message,
                selectedAttachmentID: attachment.id,
                isRevealed: { [spoilerRevealStore] componentID in
                    spoilerRevealStore.isMediaRevealed(
                        NativeTimelineComponentRevealKey(
                            messageID: message.id,
                            componentID: componentID
                        )
                    )
                }
            )
        {
            let frame = layouts[rowIndex].attachmentRegions.first(where: {
                $0.attachment.id == attachment.id
            })?.frame
            model?.mediaViewerPresentation = mediaViewerPresentation(
                presentation,
                sourceFrame: frame ?? .zero,
                rowIndex: rowIndex,
                mediaKey: NativeTimelineMediaKey.attachment(attachment),
                cornerRadius: 8,
                fillsFrame: MediaGalleryImagePresentation.fillsFrame(
                    itemCount: layouts[rowIndex].attachmentRegions.count
                )
            )
        } else {
            NSWorkspace.shared.open(attachment.url)
        }
        return true
    }

    func activateEmbedMedia(
        id: String,
        in message: Message,
        rowIndex: Int
    ) -> Bool {
        if let presentation = NativeTimelineMediaViewerPlan.embed(
            in: message,
            id: id
        ) {
            let region = layouts[rowIndex].embedRegions.first(where: {
                $0.embedID == id
            })
            model?.mediaViewerPresentation = mediaViewerPresentation(
                presentation,
                sourceFrame: region?.mediaFrame ?? .zero,
                rowIndex: rowIndex,
                mediaKey: region?.mediaURL.map {
                    NativeTimelineMediaKey.media($0)
                },
                cornerRadius: 8,
                fillsFrame: false
            )
            return true
        }
        guard let region = layouts.lazy
            .flatMap(\.embedRegions)
            .first(where: { $0.embedID == id }),
              let url = region.mediaURL
        else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    func activateComponentButton(
        _ region: NativeTimelineComponentLayout.ButtonRegion,
        message: Message
    ) -> Bool {
        guard !region.isDisabled else { return false }
        if let url = region.url {
            return MessageLinkActivator.activate(url, model: model)
        }
        guard let customID = region.customID else { return false }
        actions?.submitComponent(message, customID, .button, [])
        return true
    }

    func setHoveredRow(_ value: Int?) {
        guard hoveredRow != value else { return }
        let old = hoveredRow
        hoveredRow = value
        updateAvatarPlayback()
        if let old {
            setNeedsDisplay(rowFrame(at: old))
        }
        if let value {
            setNeedsDisplay(rowFrame(at: value))
        }
        if value == nil, actionCapsuleState?.isPresentationActive == true {
            return
        }
        reconcileActionCapsule()
    }

}

extension NativeTimelineCanvasView {
    private func accessibilityInboxOrSearchActions(_ message: Message, canDelete: Bool) -> [NSAccessibilityCustomAction] {
        var result = accessibilitySearchResultActions(
            for: message,
            canDelete: canDelete,
            includesMarkUnread: messageInteractionContext == .searchResult
        )
        if messageInteractionContext == .inboxMention {
            result.append(NSAccessibilityCustomAction(name: "Mark as Read") { [weak self] in
                self?.model?.dismissInboxMention(message)
                return self != nil
            })
        }
        return result
    }
}
