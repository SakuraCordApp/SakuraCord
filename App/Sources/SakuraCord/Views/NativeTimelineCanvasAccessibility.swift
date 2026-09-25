import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

nonisolated enum TimelineAccessibilityWorkPolicy {
    static func reconcilesEagerly(
        isVoiceOverEnabled: Bool,
        isSwitchControlEnabled: Bool
    ) -> Bool {
        isVoiceOverEnabled || isSwitchControlEnabled
    }
}

struct NativeTimelineTextAccessibilityInput {
    let value: NSAttributedString
    let framesetter: CTFramesetter
    let drawingFrame: CGRect
    let accessibilityFrame: CGRect
    let sourceMessage: Message?
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let region: NativeTimelineTextRegion
    let revealedLocations: Set<Int>
    let rowIndex: Int
    let parent: NSAccessibilityElement
}

struct ComponentMediaA11yInput {
    let label: String
    let frame: CGRect
    let componentID: String
    let openURL: URL
    let isSpoiler: Bool
    let message: Message
    let rowIndex: Int
    let parent: NSAccessibilityElement
    let usesFileActionLabels: Bool
    let viewerPresentation: NativeTimelineMediaViewerPresentation?
}

private struct MessageIdentityA11yInput {
    let message: Message
    let layout: NativeTimelineRowLayout
    let author: User
    let timestamp: String
    let settings: AccessibilitySettingsSnapshot
    let rowIndex: Int
    let parent: NSAccessibilityElement
}

private struct ComponentTextA11yInput {
    let component: NativeTimelineComponentLayout
    let hiddenContainerFrames: [CGRect]
    let layoutIndex: Int
    let itemIdentifier: NativeMessageTimelineItem.Identifier
    let revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState
    let rowIndex: Int
    let parent: NSAccessibilityElement
}

extension NativeTimelineCanvasView {
    private struct MessageAccessibilityHeader {
        let element: NSAccessibilityElement
        let author: User
        let timestamp: String
        let settings: AccessibilitySettingsSnapshot
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .list
    }

    override func accessibilityLabel() -> String? {
        "Message timeline"
    }

    override func accessibilityChildren() -> [Any]? {
        reconcileInboxHeaders()
        reconcileAccessibilityProxies()
        var orderedChildren = accessibilityProxyRowsInTimelineOrder()
        var additionalChildren = (super.accessibilityChildren() ?? []).filter { child in
            guard let childView = child as? NSView else { return true }
            return !accessibilityProxies.contains(childView)
                && !inboxHeaderHosts.values.contains { $0 === childView }
                && !inboxEventHosts.values.contains { $0 === childView }
                && !inboxForumPostHosts.values.contains { $0 === childView }
        }
        if let editingRowHost,
           let hostIndex = additionalChildren.firstIndex(where: {
               ($0 as? NSView) === editingRowHost
           }),
           let insertionIndex =
               NativeTimelineAccessibilityPolicy
                   .editingOverlayInsertionIndex(
                       in: accessibilityProxies.order,
                       editingItemIdentifier: editingMessageID.flatMap { messageID in
                           items.first(where: {
                               $0.messageID == messageID
                           })?.identifier
                       }
                   )
        {
            let editingChild = additionalChildren.remove(at: hostIndex)
            orderedChildren.insert(
                editingChild,
                at: min(insertionIndex, orderedChildren.endIndex)
            )
        }
        return orderedChildren + additionalChildren
    }

    override func accessibilityRows() -> [Any]? {
        reconcileAccessibilityProxies()
        return accessibilityProxyRowsInTimelineOrder()
    }

    override func accessibilityVisibleRows() -> [Any]? {
        reconcileAccessibilityProxies()
        let viewport =
            enclosingScrollView?.documentVisibleRect ?? visibleRect
        return accessibilityProxyRowsInTimelineOrder().filter {
            ($0 as? NSView)?.frame.intersects(viewport) == true
        }
    }

    func reconcileAccessibilityProxies() {
        let viewport =
            enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard viewport.height > 0,
              !items.isEmpty,
              !layouts.isEmpty
        else {
            removeAccessibilityProxies()
            return
        }
        var bufferedViewport =
            NativeTimelineAccessibilityPolicy.bufferedViewport(
                around: viewport,
                contentHeight: displayedContentHeight
            )
        bufferedViewport.size.width = max(
            bounds.width,
            bufferedViewport.width
        )
        guard var index = rowIndex(at: bufferedViewport.minY) else {
            removeAccessibilityProxies()
            return
        }
        var desired: Set<NativeMessageTimelineItem.Identifier> = []
        var desiredOrder: [NativeMessageTimelineItem.Identifier] = []
        while items.indices.contains(index),
              layouts.indices.contains(index),
              displayedRowOrigin(at: index) < bufferedViewport.maxY
        {
            let identifier = items[index].identifier
            let item = items[index]
            let frame = rowFrame(at: index)
            desired.insert(identifier)
            desiredOrder.append(identifier)
            if accessibilityProxies.item(for: identifier) != item {
                accessibilityProxies.remove(identifier)
                let source = accessibilityRow(at: index)
                let rowProxy = accessibilityProxy(
                    for: source,
                    canvasFrame: frame
                )
                addSubview(rowProxy)
                accessibilityProxies.install(
                    rowProxy,
                    item: item,
                    for: identifier
                )
            } else if accessibilityProxies.row(for: identifier)?.frame
                != frame {
                // Child accessibility frames are relative to the row proxy.
                // Prepending history or changing an earlier row's height only
                // moves this row; rebuilding it would needlessly re-resolve
                // mentions and Markdown for every buffered message.
                accessibilityProxies.row(for: identifier)?.frame = frame
            }
            index += 1
        }
        let obsolete = accessibilityProxies.identifiers.filter {
            !desired.contains($0)
        }
        for identifier in obsolete {
            accessibilityProxies.remove(identifier)
        }
        accessibilityProxies.setOrder(desiredOrder)
    }

    func reconcileAccessibilityProxiesIfActive() {
        let workspace = NSWorkspace.shared
        guard TimelineAccessibilityWorkPolicy
            .reconcilesEagerly(
                isVoiceOverEnabled: workspace.isVoiceOverEnabled,
                isSwitchControlEnabled: workspace.isSwitchControlEnabled
            )
        else { return }
        reconcileAccessibilityProxies()
    }

    func accessibilityProxy(
        for source: NSAccessibilityElement,
        canvasFrame: CGRect
    ) -> NativeTimelineAccessibilityProxyView {
        let proxy = NativeTimelineAccessibilityProxyView(source: source)
        proxy.frame = canvasFrame
        if let children = source.accessibilityChildren() {
            for case let child as NSAccessibilityElement in children {
                let childCanvasFrame = accessibilityCanvasFrame(
                    for: child
                )
                let childProxy = accessibilityProxy(
                    for: child,
                    canvasFrame: childCanvasFrame
                )
                childProxy.frame = childCanvasFrame.offsetBy(
                    dx: -canvasFrame.minX,
                    dy: -canvasFrame.minY
                )
                proxy.addSubview(childProxy)
            }
        }
        return proxy
    }

    func accessibilityCanvasFrame(
        for element: NSAccessibilityElement
    ) -> CGRect {
        guard let window else {
            return element.accessibilityFrame()
        }
        return convert(
            window.convertFromScreen(element.accessibilityFrame()),
            from: nil
        )
    }

    func accessibilityProxyRowsInTimelineOrder() -> [Any] {
        accessibilityProxies.order.compactMap { identifier -> Any? in
            if case let .inboxGroup(channelID) = identifier, let host = inboxHeaderHosts[channelID] { return host }
            if case let .inboxEvent(eventID) = identifier, let host = inboxEventHosts[eventID] { return host }
            if case let .inboxForumPost(threadID) = identifier, let host = inboxForumPostHosts[threadID] { return host }
            return accessibilityProxies.row(for: identifier)
        }
    }

    func removeAccessibilityProxies() {
        accessibilityProxies.removeAll()
    }

    func rebuildAccessibilityProxy(
        for identifier: NativeMessageTimelineItem.Identifier
    ) {
        accessibilityProxies.remove(identifier)
        reconcileAccessibilityProxies()
        NSAccessibility.post(
            element: self,
            notification: .layoutChanged
        )
    }

    func accessibilityRow(at index: Int) -> NSAccessibilityElement {
        let item = items[index]
        let layout = layouts[index]
        let rowFrame = rowFrame(at: index)
        switch item {
        case let .inboxEvent(event):
            return accessibilityElement(role: .button, label: event.name, frame: rowFrame, parent: self) { [weak self] in
                self?.model?.inbox.selectedEvent = event
                return self != nil
            }
        case let .inboxForumPost(post):
            return accessibilityElement(role: .button, label: post.thread.name, frame: rowFrame, parent: self) { [weak self] in
                self?.model?.openInboxForumPost(post)
                return self != nil
            }
        case let .inboxGroup(header):
            let element = accessibilityElement(role: .row, label: header.title, identifier: "inbox-group-\(header.channelID)", frame: rowFrame, parent: self)
            element.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: header.isCollapsed ? "Expand" : "Collapse") { [weak self] in
                    self?.model?.toggleInboxGroup(header.channelID)
                    return self != nil
                },
                NSAccessibilityCustomAction(name: "Mark Read") { [weak self] in
                    self?.model?.markInboxGroupRead(header.channelID)
                    return self != nil
                },
                NSAccessibilityCustomAction(name: "Open Conversation") { [weak self] in
                    self?.model?.openInboxGroup(header.channelID)
                    return self != nil
                }
            ])
            return element
        case let .beginning(beginning):
            return accessibilityElement(
                role: .row,
                label: "\(beginning.title). \(beginning.description)",
                identifier: "timeline-beginning-\(beginning.id)",
                frame: rowFrame,
                parent: self
            )
        case let .loader(isLoading, kind):
            let element = accessibilityElement(
                role: .row,
                label: "",
                value: isLoading ? "Busy" : nil,
                identifier: "timeline-earlier-loader",
                frame: rowFrame,
                parent: self,
                isEnabled: false
            )
            guard isLoading,
                  let loaderLayout = layout.loaderLayout
            else {
                return element
            }
            let label = kind.loadingLabel
            var children: [Any] = []
            if let spinnerFrame = loaderLayout.spinnerFrame {
                children.append(accessibilityElement(
                    role: .progressIndicator,
                    label: "Loading",
                    frame: accessibilityChildFrame(
                        spinnerFrame,
                        rowIndex: index
                    ),
                    parent: element
                ))
            }
            children.append(accessibilityElement(
                role: .staticText,
                label: label,
                frame: accessibilityChildFrame(
                    loaderLayout.labelFrame,
                    rowIndex: index
                ),
                parent: element
            ))
            element.setAccessibilityChildren(children)
            return element
        case let .message(row, isUnreadBoundary, _):
            return accessibilityMessage(
                row,
                isUnreadBoundary: isUnreadBoundary,
                layout: layout,
                rowFrame: rowFrame,
                rowIndex: index
            )
        }
    }

    func accessibilityMessage(
        _ row: MessageRowPresentation,
        isUnreadBoundary: Bool,
        layout: NativeTimelineRowLayout,
        rowFrame: CGRect,
        rowIndex: Int
    ) -> NSAccessibilityElement {
        let message = row.message
        let itemIdentifier =
            NativeMessageTimelineItem.Identifier.message(row.identity)
        let revealedTextSpoilerState =
            textSpoilerRevealState(at: rowIndex)
        let header = makeMessageAccessibilityHeader(for: row, rowFrame: rowFrame)
        let element = header.element
        element.setAccessibilityCustomActions(
            accessibilityMessageActions(
                row,
                rowFrame: rowFrame,
                rowIndex: rowIndex
            )
        )
        var children: [Any] = []
        appendMessageBoundaryAccessibility(
            to: &children,
            row: row,
            isUnreadBoundary: isUnreadBoundary,
            layout: layout,
            rowIndex: rowIndex,
            parent: element
        )
        appendMessageIdentityAccessibility(
            to: &children,
            input: MessageIdentityA11yInput(
                message: message,
                layout: layout,
                author: header.author,
                timestamp: header.timestamp,
                settings: header.settings,
                rowIndex: rowIndex,
                parent: element
            )
        )
        guard NativeTimelineAccessibilityPolicy.showsMessageBody(
            messageID: message.id,
            editingMessageID: editingMessageID
        ) else {
            element.setAccessibilityChildren(children)
            return element
        }
        appendMessageBodyAccessibility(
            to: &children,
            message: message,
            layout: layout,
            itemIdentifier: itemIdentifier,
            revealedTextSpoilerState: revealedTextSpoilerState,
            rowIndex: rowIndex,
            parent: element
        )
        appendMessageMediaAccessibility(
            to: &children,
            message: message,
            layout: layout,
            rowIndex: rowIndex,
            parent: element
        )
        appendMessageRichContentAccessibility(
            to: &children,
            message: message,
            layout: layout,
            itemIdentifier: itemIdentifier,
            revealedTextSpoilerState: revealedTextSpoilerState,
            rowIndex: rowIndex,
            parent: element
        )
        appendPollAccessibility(to: &children, message: message, layout: layout, rowIndex: rowIndex, parent: element)
        appendMessageActionsAccessibility(
            to: &children,
            message: message,
            layout: layout,
            rowIndex: rowIndex,
            parent: element
        )
        element.setAccessibilityChildren(children)
        return element
    }

    private func makeMessageAccessibilityHeader(
        for row: MessageRowPresentation,
        rowFrame: CGRect
    ) -> MessageAccessibilityHeader {
        let message = row.message
        let author = model?.authorPresentation(for: message).user ?? message.author
        let timestamp = NativeTimelineTimestamp.headerText(
            for: message.timestamp,
            settings: model?.interfaceSettings ?? .defaults
        )
        let settings = model?.accessibilitySettings ?? .defaults
        let metadata = AccessibilityMessageMetadataPolicy.summary(
            for: message,
            timestamp: timestamp,
            settings: settings
        )
        let generatedLabel = SystemMessagePresentation.label(
            for: message,
            currentUserID: model?.snapshot?.currentUser.id
        )
        let baseLabel = message.type.hasGeneratedContent
            ? "System message, \(generatedLabel)"
            : "Message from \(author.displayName)"
        let press: (@MainActor @Sendable () -> Bool)? =
            if actions?.openMessage != nil {
                { [weak self] in
                guard let openMessage = self?.actions?.openMessage else { return false }
                openMessage(message)
                return true
                }
            } else {
                nil
            }
        let element = accessibilityElement(
            role: .row,
            label: ([baseLabel] + metadata).joined(separator: ", "),
            value: MessageOutboxPresentation.accessibilityStatus(for: message.outboxState),
            help: actions?.openMessage == nil ? nil : "Jump to message",
            identifier: "timeline-message-\(message.id)",
            frame: rowFrame,
            parent: self,
            press: press
        )
        return MessageAccessibilityHeader(
            element: element,
            author: author,
            timestamp: timestamp,
            settings: settings
        )
    }

    private func appendMessageBoundaryAccessibility(
        to children: inout [Any],
        row: MessageRowPresentation,
        isUnreadBoundary: Bool,
        layout: NativeTimelineRowLayout,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        let message = row.message
        if let frame = layout.daySeparatorFrame {
            let dateLabel = message.timestamp.formatted(
                date: .long,
                time: .omitted
            )
            children.append(accessibilityElement(
                role: .staticText,
                label: "Messages from \(dateLabel)",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: parent
            ))
        }
        if isUnreadBoundary, let frame = layout.unreadSeparatorFrame {
            children.append(accessibilityElement(
                role: .staticText,
                label: "New messages",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: parent
            ))
        }
        if let replyMessageID = row.replyMessageID,
           let frame = layout.replyFrame
        {
            let label = if let preview = row.replyPreview {
                "Replying to \(preview.author.displayName): \(accessibilityResolvedText(preview.content, message: message))"
            } else {
                "Message could not be loaded"
            }
            children.append(accessibilityElement(
                role: .button,
                label: label,
                help: row.isReplyAvailable
                    ? "Jump to original message"
                    : "Load and jump to original message",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: parent,
                isEnabled: true
            ) { [weak self] in
                guard let self else { return false }
                self.actions?.openReply(replyMessageID)
                return true
            })
        }
    }

    private func appendMessageIdentityAccessibility(
        to children: inout [Any],
        input: MessageIdentityA11yInput
    ) {
        let message = input.message
        let layout = input.layout
        let author = input.author
        let timestamp = input.timestamp
        let accessibilitySettings = input.settings
        let rowIndex = input.rowIndex
        let parent = input.parent
        if let region = layout.commandInvocationRegion {
            let invokingUser =
                message.interactionMetadata?.user?.displayName
                ?? "Someone"
            let commandName =
                message.interactionMetadata?.displayName
                ?? "command"
            children.append(accessibilityElement(
                role: .button,
                label: "\(invokingUser) used /\(commandName)",
                help: "Show profile",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ) { [weak self] in
                guard let self,
                      let user = message.interactionMetadata?.user
                else { return false }
                self.showMessageProfile(
                    for: user,
                    anchor: self.accessibilityChildFrame(
                        region.profileFrame,
                        rowIndex: rowIndex
                    )
                )
                return true
            })
        }
        if !message.type.hasGeneratedContent,
           layout.avatarFrame != nil || layout.authorFrame != nil
        {
            let help = "View \(author.displayName)'s profile"
            let frames =
                NativeTimelineAuthorProfileGeometry.hitFrames(
                    avatarFrame: layout.avatarFrame,
                    authorFrame: layout.authorFrame
                )
            for (index, authorFrame) in frames.enumerated() {
                children.append(accessibilityElement(
                    role: .button,
                    label: index == 0 && layout.avatarFrame != nil
                        ? "\(author.displayName) avatar"
                        : author.displayName,
                    help: help,
                    frame: accessibilityChildFrame(
                        authorFrame,
                        rowIndex: rowIndex
                    ),
                    parent: parent
                ) { [weak self] in
                    guard let self else { return false }
                    self.showMessageProfile(
                        for: author,
                        anchor: self.accessibilityChildFrame(
                            authorFrame,
                            rowIndex: rowIndex
                        )
                    )
                    return true
                })
            }
            if accessibilitySettings.announcesTimestamps,
               let frame = layout.timestampFrame
            {
                children.append(accessibilityElement(
                    role: .staticText,
                    label: timestamp,
                    frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                    parent: parent
                ))
            }
        }
    }

    private func appendMessageBodyAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        if let frame = layout.loadingIndicatorFrame {
            children.append(accessibilityElement(
                role: .progressIndicator,
                label: "Loading",
                frame: accessibilityChildFrame(
                    frame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ))
        }
        if let frame = layout.contentFrame,
           let value = layout.attributedContent,
           let framesetter = layout.contentFramesetter
        {
            appendTextAccessibility(to: &children, input: .init(
                value: value,
                framesetter: framesetter,
                drawingFrame: NativeTimelineTextGeometry
                    .messageContentDrawingFrame(frame),
                accessibilityFrame: frame,
                sourceMessage: message,
                itemIdentifier: itemIdentifier,
                region: .content,
                revealedLocations: revealedTextSpoilerState.locations(
                    in: .content
                ),
                rowIndex: rowIndex,
                parent: parent
            ))
        } else if let frame = layout.contentFrame {
            let content = accessibilityMessageText(message)
            if !content.isEmpty {
                children.append(accessibilityElement(
                    role: .staticText,
                    label: content,
                    frame: accessibilityChildFrame(
                        frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent
                ))
            }
        }
        appendTranslationAccessibility(to: &children, message: message, layout: layout, rowIndex: rowIndex, parent: parent)
    }

    private func appendMessageMediaAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        for region in layout.linkedImageRegions {
            children.append(accessibilityElement(
                role: .link,
                label: region.reference.label,
                help: "Open image",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ) {
                if let presentation =
                    NativeTimelineMediaViewerPlan.linkedImages(
                        in: message,
                        selectedReferenceID: region.reference.id
                    )
                {
                    self.model?.mediaViewerPresentation =
                        self.mediaViewerPresentation(
                            presentation,
                            sourceFrame: region.frame,
                            rowIndex: rowIndex,
                            mediaKey: .media(
                                region.reference.displayURL,
                                maximumPixelDimension:
                                    region.reference.isEmoji ? 96 : 720
                            ),
                            cornerRadius: region.reference.isEmoji ? 7 : 10,
                            fillsFrame: !region.reference.isEmoji
                                && !region.reference.isSticker
                        )
                } else {
                    NSWorkspace.shared.open(region.reference.url)
                }
                return true
            })
        }
        if !layout.attachmentRegions.isEmpty {
            let galleryFrame = layout.attachmentRegions
                .map(\.frame)
                .dropFirst()
                .reduce(layout.attachmentRegions[0].frame) {
                    $0.union($1)
                }
            let gallery = accessibilityElement(
                role: .group,
                label:
                    "Media gallery, \(layout.attachmentRegions.count) items",
                frame: accessibilityChildFrame(
                    galleryFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            )
            let attachmentChildren = layout.attachmentRegions.map { region in
                let attachment = region.attachment
                let revealKey =
                    NativeTimelineComponentRevealKey.attachment(
                        messageID: message.id,
                        attachmentID: attachment.id
                    )
                let isHiddenSpoiler =
                    attachment.isSpoiler
                    && !spoilerRevealStore.isMediaRevealed(revealKey)
                let contentLabel =
                    attachment.description
                    ?? attachment.title
                    ?? attachment.filename
                let label = isHiddenSpoiler
                    ? "Reveal spoiler media"
                    : contentLabel
                return accessibilityElement(
                    role: .button,
                    label: label,
                    help: isHiddenSpoiler
                        ? "Reveals this media without opening it"
                        : "Open \(contentLabel)",
                    frame: accessibilityChildFrame(
                        region.frame,
                        rowIndex: rowIndex
                    ),
                    parent: gallery
                ) { [weak self] in
                    self?.activateAttachment(
                        attachment,
                        in: message,
                        rowIndex: rowIndex
                    ) ?? false
                }
            }
            gallery.setAccessibilityChildren(attachmentChildren)
            children.append(gallery)
        }
    }

    private func appendMessageRichContentAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        appendEmbedAccessibility(
            to: &children,
            message: message,
            layout: layout,
            itemIdentifier: itemIdentifier,
            revealedTextSpoilerState: revealedTextSpoilerState,
            rowIndex: rowIndex,
            parent: parent
        )
        appendSakuraCordDeepLinkAccessibility(
            message: message,
            to: &children,
            layout: layout,
            rowIndex: rowIndex,
            parent: parent
        )
        appendComponentAccessibility(
            to: &children,
            message: message,
            layout: layout,
            itemIdentifier: itemIdentifier,
            revealedTextSpoilerState: revealedTextSpoilerState,
            rowIndex: rowIndex,
            parent: parent
        )
        for (sticker, frame) in zip(message.stickers, layout.stickerFrames) {
            children.append(accessibilityElement(
                role: .image,
                label: NativeTimelineAccessibilityPresentation
                    .stickerLabel(sticker),
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: parent
            ))
        }
        if let thread = message.thread,
           let frame = layout.threadFrame
        {
            children.append(accessibilityElement(
                role: .button,
                label: NativeTimelineAccessibilityPresentation
                    .threadLabel(thread),
                help: "Open thread",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: parent
            ) { [weak self] in
                self?.actions?.openThread(thread)
                return self != nil
            })
        }
    }

    private func appendMessageActionsAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        for region in layout.reactionRegions {
            let reaction = region.reaction
            children.append(accessibilityElement(
                role: .button,
                label: MessageReactionPresentation
                    .accessibilityLabel(for: reaction),
                value: reaction.didCurrentUserReact
                    ? "You reacted"
                    : "You have not reacted",
                help: reaction.didCurrentUserReact
                    ? "Remove your reaction"
                    : "Add the same reaction",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ) { [weak self] in
                self?.actions?.react(reaction.emoji, message)
                return self != nil
            })
        }
        if let frame = layout.addReactionFrame {
            children.append(accessibilityElement(
                role: .button,
                label: "Add reaction",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: parent
            ) { [weak self] in
                guard let self else { return false }
                self.showReactionPicker(
                    for: message,
                    anchor: frame.offsetBy(
                        dx: 0,
                        dy: self.displayedRowOrigin(at: rowIndex)
                    ),
                    preferredEdge: .maxX
                )
                return true
            })
        }
        if let region = layout.ephemeralRegion {
            children.append(accessibilityElement(
                role: .staticText,
                label: "Only you can see this",
                frame: accessibilityChildFrame(
                    region.visibilityFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ))
            children.append(accessibilityElement(
                role: .button,
                label: "Dismiss message",
                frame: accessibilityChildFrame(
                    region.dismissFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ) { [weak self] in
                guard let self else { return false }
                self.model?.dismissEphemeralMessage(message)
                return true
            })
        }
        if let frame = layout.failedFrame {
            children.append(accessibilityElement(
                role: .staticText,
                label: "Failed",
                frame: accessibilityChildFrame(
                    frame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ))
        }
    }

    func appendTextAccessibility(
        to children: inout [Any],
        input: NativeTimelineTextAccessibilityInput
    ) {
        appendTextAccessibilityLabel(to: &children, input: input)
        appendTextAccessibilityLinks(to: &children, input: input)
        appendCodeBlockAccessibility(to: &children, input: input)
        appendTextSpoilerAccessibility(to: &children, input: input)
    }

    private func appendTextAccessibilityLabel(
        to children: inout [Any],
        input: NativeTimelineTextAccessibilityInput
    ) {
        let label = TimelineTextAccessibility.text(
            input.value,
            revealedLocations: input.revealedLocations
        )
        guard !label.isEmpty else { return }
        children.append(accessibilityElement(
            role: .staticText,
            label: label,
            frame: accessibilityChildFrame(input.accessibilityFrame, rowIndex: input.rowIndex),
            parent: input.parent
        ))
    }

    private func appendTextAccessibilityLinks(
        to children: inout [Any],
        input: NativeTimelineTextAccessibilityInput
    ) {
        guard let sourceMessage = input.sourceMessage else { return }
        input.value.enumerateAttribute(
                .link,
                in: NSRange(location: 0, length: input.value.length)
            ) { rawLink, range, _ in
                let url = (rawLink as? URL)
                    ?? (rawLink as? String).flatMap(URL.init(string:))
                guard let url,
                      let localFrame = NativeTimelineTextHitTester.rangeFrame(
                          value: input.value,
                          framesetter: input.framesetter,
                          frame: input.drawingFrame,
                          range: range
                      )
                else { return }
                let linkLabel = input.value.attributedSubstring(from: range).string
                let anchor = accessibilityChildFrame(
                    localFrame,
                    rowIndex: input.rowIndex
                )
                children.append(accessibilityElement(
                    role: .link,
                    label: linkLabel,
                    help: MessageLinkActivator.accessibilityHelp(
                        for: url,
                        label: linkLabel
                    ),
                    frame: anchor,
                    parent: input.parent
                ) { [weak self] in
                    guard let self else { return false }
                    return MessageLinkActivator.activate(
                        url,
                        model: self.model,
                        sourceMessage: sourceMessage,
                        displayedText: linkLabel,
                        presentSystemProfile: { [weak self] user in
                            self?.showMessageProfile(
                                for: user,
                                anchor: anchor
                            )
                        }
                    )
                })
            }
    }

    private func appendCodeBlockAccessibility(
        to children: inout [Any],
        input: NativeTimelineTextAccessibilityInput
    ) {
        for codeBlock in NativeTimelineCodeBlockGeometry.regions(
            value: input.value,
            framesetter: input.framesetter,
            frame: input.drawingFrame
        ) {
            children.append(accessibilityElement(
                role: .button,
                label: "Copy code",
                help: "Copy code block",
                frame: accessibilityChildFrame(
                    codeBlock.copyButtonFrame,
                    rowIndex: input.rowIndex
                ),
                parent: input.parent
            ) {
                Self.copyText(codeBlock.content)
                return true
            })
        }
    }

    private func appendTextSpoilerAccessibility(
        to children: inout [Any],
        input: NativeTimelineTextAccessibilityInput
    ) {
        let hiddenRanges =
            TimelineTextAccessibility
                .hiddenSpoilerRanges(
                    in: input.value,
                    revealedLocations: input.revealedLocations
                )
        for range in hiddenRanges {
            let localFrame = NativeTimelineTextHitTester.rangeFrame(
                value: input.value,
                framesetter: input.framesetter,
                frame: input.drawingFrame,
                range: range
            ) ?? input.accessibilityFrame
            children.append(accessibilityElement(
                role: .button,
                label: "Reveal spoiler",
                frame: accessibilityChildFrame(
                    localFrame,
                    rowIndex: input.rowIndex
                ),
                parent: input.parent
            ) { [weak self] in
                guard let self else { return false }
                self.revealTextSpoiler(
                    itemIdentifier: input.itemIdentifier,
                    region: input.region,
                    rangeLocation: range.location
                )
                return true
            })
        }
    }

    func appendEmbedAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        for region in layout.embedRegions {
            let embed = message.embeds.first { $0.id == region.embedID }
            let group = accessibilityElement(
                role: .group,
                label: embed?.title ?? "Embed",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: parent
            )
            var groupChildren: [Any] = []
            for (textIndex, textRegion) in
                region.textRegions.enumerated()
            {
                let textRegionID = NativeTimelineTextRegion.embed(
                    embedID: region.embedID,
                    textIndex: textIndex
                )
                var drawingFrame = textRegion.frame
                drawingFrame.size.height +=
                    textRegion.text.layoutHeightAdjustment
                appendTextAccessibility(to: &groupChildren, input: .init(
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter,
                    drawingFrame: drawingFrame,
                    accessibilityFrame: textRegion.frame,
                    sourceMessage: nil,
                    itemIdentifier: itemIdentifier,
                    region: textRegionID,
                    revealedLocations:
                        revealedTextSpoilerState.locations(
                            in: textRegionID
                        ),
                    rowIndex: rowIndex,
                    parent: group
                ))
            }
            group.setAccessibilityChildren(groupChildren)
            children.append(group)
            if let frame = region.mediaFrame {
                children.append(accessibilityElement(
                    role: .button,
                    label: embed?.image?.description
                        ?? embed?.video?.description
                        ?? embed?.title
                        ?? "Embed media",
                    help: "Open media",
                    frame: accessibilityChildFrame(
                        frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent
                ) { [weak self] in
                    self?.activateEmbedMedia(
                        id: region.embedID,
                        in: message,
                        rowIndex: rowIndex
                    ) ?? false
                })
            }
        }
    }

    func appendSakuraCordDeepLinkAccessibility(
        message: Message,
        to children: inout [Any],
        layout: NativeTimelineRowLayout,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        for region in layout.sakuraCordDeepLinkRegions {
            let group = accessibilityElement(
                role: .group,
                label: "SakuraCord deeplink, \(region.action.title)",
                frame: accessibilityChildFrame(
                    region.cardFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            )
            let button = accessibilityElement(
                role: .button,
                label: region.action.buttonTitle,
                help: region.action.accessibilityHelp,
                frame: accessibilityChildFrame(
                    region.buttonFrame,
                    rowIndex: rowIndex
                ),
                parent: group
            ) { [weak self] in
                self?.activateSakuraCordDeepLink(region.action, message: message) ?? false
            }
            group.setAccessibilityChildren([button])
            children.append(group)
        }
        appendInviteAccessibility(message: message, to: &children, layout: layout, rowIndex: rowIndex, parent: parent)
    }

    func appendComponentAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        for (layoutIndex, component) in
            layout.componentLayouts.enumerated()
        {
            let hiddenContainerFrames =
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: component,
                        messageID: message.id,
                        store: spoilerRevealStore
                    )
            appendHiddenComponentAccessibility(
                to: &children,
                component: component,
                hiddenContainerFrames: hiddenContainerFrames,
                message: message,
                rowIndex: rowIndex,
                parent: parent
            )
            appendComponentTextAccessibility(
                to: &children,
                input: ComponentTextA11yInput(
                    component: component,
                    hiddenContainerFrames: hiddenContainerFrames,
                    layoutIndex: layoutIndex,
                    itemIdentifier: itemIdentifier,
                    revealedTextSpoilerState: revealedTextSpoilerState,
                    rowIndex: rowIndex,
                    parent: parent
                )
            )
            appendComponentControlAccessibility(
                to: &children,
                component: component,
                hiddenContainerFrames: hiddenContainerFrames,
                message: message,
                rowIndex: rowIndex,
                parent: parent
            )
            appendComponentContentAccessibility(
                to: &children,
                component: component,
                hiddenContainerFrames: hiddenContainerFrames,
                message: message,
                layouts: layout.componentLayouts,
                rowIndex: rowIndex,
                parent: parent
            )
        }
    }

    private func appendHiddenComponentAccessibility(
        to children: inout [Any],
        component: NativeTimelineComponentLayout,
        hiddenContainerFrames: [CGRect],
        message: Message,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
            for hiddenContainer in component.containers
            where hiddenContainerFrames.contains(hiddenContainer.frame) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: hiddenContainer.componentID
                )
                children.append(accessibilityElement(
                    role: .button,
                    label: "Reveal spoiler",
                    help: "Reveals this content without activating it",
                    frame: accessibilityChildFrame(
                        hiddenContainer.frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent
                ) { [weak self] in
                    guard let self else { return false }
                    self.reveal(key, rowIndex: rowIndex)
                    return true
                })
            }
    }

    private func appendComponentTextAccessibility(
        to children: inout [Any],
        input: ComponentTextA11yInput
    ) {
        let component = input.component
        let hiddenContainerFrames = input.hiddenContainerFrames
        let layoutIndex = input.layoutIndex
        let itemIdentifier = input.itemIdentifier
        let revealedTextSpoilerState = input.revealedTextSpoilerState
        let rowIndex = input.rowIndex
        let parent = input.parent
            for (textIndex, textRegion) in
                component.textRegions.enumerated()
            where !textRegion.text.value.string.isEmpty
                && !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                    textRegion.frame,
                    hiddenContainerFrames: hiddenContainerFrames
                ) {
                let textRegionID = NativeTimelineTextRegion.component(
                    layoutIndex: layoutIndex,
                    textIndex: textIndex
                )
                var drawingFrame = textRegion.frame
                drawingFrame.size.height +=
                    textRegion.text.layoutHeightAdjustment
                appendTextAccessibility(to: &children, input: .init(
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter,
                    drawingFrame: drawingFrame,
                    accessibilityFrame: textRegion.frame,
                    sourceMessage: nil,
                    itemIdentifier: itemIdentifier,
                    region: textRegionID,
                    revealedLocations:
                        revealedTextSpoilerState.locations(
                            in: textRegionID
                        ),
                    rowIndex: rowIndex,
                    parent: parent
                ))
            }
    }

    private func appendComponentControlAccessibility(
        to children: inout [Any],
        component: NativeTimelineComponentLayout,
        hiddenContainerFrames: [CGRect],
        message: Message,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
            for region in component.buttons
            where !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                region.frame,
                hiddenContainerFrames: hiddenContainerFrames
            ) {
                children.append(accessibilityElement(
                    role: .button,
                    label: region.label.isEmpty ? "Button" : region.label,
                    frame: accessibilityChildFrame(
                        region.frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent,
                    isEnabled: !region.isDisabled
                ) { [weak self] in
                    self?.activateComponentButton(
                        region,
                        message: message
                    ) ?? false
                })
            }
            for region in component.selects
            where !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                region.frame,
                hiddenContainerFrames: hiddenContainerFrames
            ) {
                children.append(accessibilityElement(
                    role: .popUpButton,
                    label: region.placeholder,
                    value: region.selectedOptions
                        .map(\.label)
                        .joined(separator: ", "),
                    frame: accessibilityChildFrame(
                        region.frame,
                        rowIndex: rowIndex
                    ),
                    parent: parent,
                    isEnabled: !region.isDisabled
                ) { [weak self] in
                    guard let self, !region.isDisabled else {
                        return false
                    }
                    self.showComponentChoicePicker(
                        for: region,
                        message: message
                    )
                    return true
                })
            }
    }

    private func appendComponentContentAccessibility(
        to children: inout [Any],
        component: NativeTimelineComponentLayout,
        hiddenContainerFrames: [CGRect],
        message: Message,
        layouts: [NativeTimelineComponentLayout],
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
            for region in component.images
            where !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                region.frame,
                hiddenContainerFrames: hiddenContainerFrames
            ) {
                appendComponentMediaAccessibility(to: &children, input: .init(
                    label: region.description,
                    frame: region.frame,
                    componentID: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    message: message,
                    rowIndex: rowIndex,
                    parent: parent,
                    usesFileActionLabels: false,
                    viewerPresentation:
                        NativeTimelineMediaViewerPlan.components(
                            in: message,
                            layouts: layouts,
                            selectedComponentID: region.componentID,
                            isRevealed: { [spoilerRevealStore] componentID in
                                spoilerRevealStore.isMediaRevealed(
                                    NativeTimelineComponentRevealKey(
                                        messageID: message.id,
                                        componentID: componentID
                                    )
                                )
                            }
                        )
                ))
            }
            for region in component.media
            where !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                region.frame,
                hiddenContainerFrames: hiddenContainerFrames
            ) {
                appendComponentMediaAccessibility(to: &children, input: .init(
                    label: region.description,
                    frame: region.frame,
                    componentID: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    message: message,
                    rowIndex: rowIndex,
                    parent: parent,
                    usesFileActionLabels: false,
                    viewerPresentation:
                        NativeTimelineMediaViewerPlan.components(
                            in: message,
                            layouts: layouts,
                            selectedComponentID: region.componentID,
                            isRevealed: { [spoilerRevealStore] componentID in
                                spoilerRevealStore.isMediaRevealed(
                                    NativeTimelineComponentRevealKey(
                                        messageID: message.id,
                                        componentID: componentID
                                    )
                                )
                            }
                        )
                ))
            }
            for region in component.files
            where !NativeTimelineSpoilerConcealmentPolicy.isInsideHiddenContainer(
                region.frame,
                hiddenContainerFrames: hiddenContainerFrames
            ) {
                appendComponentMediaAccessibility(to: &children, input: .init(
                    label: region.title,
                    frame: region.frame,
                    componentID: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    message: message,
                    rowIndex: rowIndex,
                    parent: parent,
                    usesFileActionLabels: true,
                    viewerPresentation:
                        NativeTimelineMediaViewerPlan.components(
                            in: message,
                            layouts: layouts,
                            selectedComponentID: region.componentID,
                            isRevealed: { [spoilerRevealStore] componentID in
                                spoilerRevealStore.isMediaRevealed(
                                    NativeTimelineComponentRevealKey(
                                        messageID: message.id,
                                        componentID: componentID
                                    )
                                )
                            }
                        )
                ))
            }
    }

}
