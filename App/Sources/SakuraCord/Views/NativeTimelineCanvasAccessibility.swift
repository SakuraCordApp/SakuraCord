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

extension NativeTimelineCanvasView {
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
        reconcileAccessibilityProxies()
        var orderedChildren = accessibilityProxyRowsInTimelineOrder()
        var additionalChildren = (super.accessibilityChildren() ?? []).filter { child in
            guard let childView = child as? NSView else { return true }
            return !accessibilityProxies.contains(childView)
        }
        if let editingRowHost,
           let hostIndex = additionalChildren.firstIndex(where: {
               ($0 as? NSView) === editingRowHost
           }),
           let insertionIndex =
               NativeTimelineAccessibilityPolicy
                   .editingOverlayInsertionIndex(
                       in: accessibilityProxies.order,
                       editingMessageID: editingMessageID
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
        accessibilityProxies.orderedRows()
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

    var accessibilityMessageOperation:
        @MainActor (
            MessageRowPresentation,
            Bool,
            NativeTimelineRowLayout,
            CGRect,
            Int
        ) -> NSAccessibilityElement
    {
        { [self] row, isUnreadBoundary, layout, rowFrame, rowIndex in
        let message = row.message
        let itemIdentifier =
            NativeMessageTimelineItem.Identifier.message(message.id)
        let revealedTextSpoilerState =
            textSpoilerRevealState(for: itemIdentifier)
        let author =
            model?.authorPresentation(for: message).user
            ?? message.author
        let timestamp = NativeTimelineTimestamp.text(
            for: message.timestamp,
            settings: model?.interfaceSettings ?? .defaults
        )
        let generatedLabel = SystemMessagePresentation.label(
            for: message,
            currentUserID: model?.snapshot?.currentUser.id
        )
        let accessibilitySettings =
            model?.accessibilitySettings ?? .defaults
        let metadata = AccessibilityMessageMetadataPolicy.summary(
            for: message,
            timestamp: timestamp,
            settings: accessibilitySettings
        )
        let baseRowLabel = message.type.hasGeneratedContent
            ? "System message, \(generatedLabel)"
            : "Message from \(author.displayName)"
        let rowLabel = ([baseRowLabel] + metadata).joined(separator: ", ")
        let rowPress: (@MainActor @Sendable () -> Bool)? =
            if actions?.openMessage != nil {
                { [weak self] in
                    guard let openMessage = self?.actions?.openMessage else {
                        return false
                    }
                    openMessage(message)
                    return true
                }
            } else {
                nil
            }
        let element = accessibilityElement(
            role: .row,
            label: rowLabel,
            value: MessageOutboxPresentation.accessibilityStatus(
                for: message.outboxState
            ),
            help: row.searchContext == nil ? nil : "Jump to message",
            identifier: "timeline-message-\(message.id)",
            frame: rowFrame,
            parent: self,
            press: rowPress
        )
        element.setAccessibilityCustomActions(
            accessibilityMessageActions(
                row,
                rowFrame: rowFrame,
                rowIndex: rowIndex
            )
        )
        var children: [Any] = []
        if let frame = layout.daySeparatorFrame {
            let dateLabel = message.timestamp.formatted(
                date: .long,
                time: .omitted
            )
            children.append(accessibilityElement(
                role: .staticText,
                label: "Messages from \(dateLabel)",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element
            ))
        }
        if isUnreadBoundary, let frame = layout.unreadSeparatorFrame {
            children.append(accessibilityElement(
                role: .staticText,
                label: "New messages",
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element
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
                parent: element,
                isEnabled: true
            ) { [weak self] in
                guard let self else { return false }
                self.actions?.openReply(replyMessageID)
                return true
            })
        }
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
                parent: element
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
        if row.startsGroup, !message.type.hasGeneratedContent {
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
                    parent: element
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
                    parent: element
                ))
            }
        }
        guard NativeTimelineAccessibilityPolicy.showsMessageBody(
            messageID: message.id,
            editingMessageID: editingMessageID
        ) else {
            element.setAccessibilityChildren(children)
            return element
        }
        if let frame = layout.loadingIndicatorFrame {
            children.append(accessibilityElement(
                role: .progressIndicator,
                label: "Loading",
                frame: accessibilityChildFrame(
                    frame,
                    rowIndex: rowIndex
                ),
                parent: element
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
                itemIdentifier: itemIdentifier,
                region: .content,
                revealedLocations: revealedTextSpoilerState.locations(
                    in: .content
                ),
                rowIndex: rowIndex,
                parent: element
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
                    parent: element
                ))
            }
        }
        for region in layout.linkedImageRegions {
            children.append(accessibilityElement(
                role: .link,
                label: region.reference.label,
                help: "Open image",
                frame: accessibilityChildFrame(
                    region.frame,
                    rowIndex: rowIndex
                ),
                parent: element
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
                parent: element
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
        appendEmbedAccessibility(
            to: &children,
            message: message,
            layout: layout,
            itemIdentifier: itemIdentifier,
            revealedTextSpoilerState: revealedTextSpoilerState,
            rowIndex: rowIndex,
            parent: element
        )
        appendComponentAccessibility(
            to: &children,
            message: message,
            layout: layout,
            itemIdentifier: itemIdentifier,
            revealedTextSpoilerState: revealedTextSpoilerState,
            rowIndex: rowIndex,
            parent: element
        )
        for (sticker, frame) in zip(message.stickers, layout.stickerFrames) {
            children.append(accessibilityElement(
                role: .image,
                label: NativeTimelineAccessibilityPresentation
                    .stickerLabel(sticker),
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex),
                parent: element
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
                parent: element
            ) { [weak self] in
                self?.actions?.openThread(thread)
                return self != nil
            })
        }
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
                parent: element
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
                parent: element
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
                parent: element
            ))
            children.append(accessibilityElement(
                role: .button,
                label: "Dismiss message",
                frame: accessibilityChildFrame(
                    region.dismissFrame,
                    rowIndex: rowIndex
                ),
                parent: element
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
                parent: element
            ))
        }
        element.setAccessibilityChildren(children)
        return element

        }
    }

    func accessibilityMessage(
        _ row: MessageRowPresentation,
        isUnreadBoundary: Bool,
        layout: NativeTimelineRowLayout,
        rowFrame: CGRect,
        rowIndex: Int
    ) -> NSAccessibilityElement {
        accessibilityMessageOperation(row, isUnreadBoundary, layout, rowFrame, rowIndex)
    }

    var textAccessibilityAppendOperation:
        @MainActor (inout [Any], NativeTimelineTextAccessibilityInput) -> Void
    {
        { [self] children, input in
            let value = input.value
            let framesetter = input.framesetter
            let drawingFrame = input.drawingFrame
            let accessibilityFrame = input.accessibilityFrame
            let itemIdentifier = input.itemIdentifier
            let region = input.region
            let revealedLocations = input.revealedLocations
            let rowIndex = input.rowIndex
            let parent = input.parent
        let label = TimelineTextAccessibility.text(
            value,
            revealedLocations: revealedLocations
        )
        if !label.isEmpty {
            children.append(accessibilityElement(
                role: .staticText,
                label: label,
                frame: accessibilityChildFrame(
                    accessibilityFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ))
        }
        for codeBlock in NativeTimelineCodeBlockGeometry.regions(
            value: value,
            framesetter: framesetter,
            frame: drawingFrame
        ) {
            children.append(accessibilityElement(
                role: .button,
                label: "Copy code",
                help: "Copy code block",
                frame: accessibilityChildFrame(
                    codeBlock.copyButtonFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ) {
                Self.copyText(codeBlock.content)
                return true
            })
        }
        let hiddenRanges =
            TimelineTextAccessibility
                .hiddenSpoilerRanges(
                    in: value,
                    revealedLocations: revealedLocations
                )
        for range in hiddenRanges {
            let localFrame = NativeTimelineTextHitTester.rangeFrame(
                value: value,
                framesetter: framesetter,
                frame: drawingFrame,
                range: range
            ) ?? accessibilityFrame
            children.append(accessibilityElement(
                role: .button,
                label: "Reveal spoiler",
                frame: accessibilityChildFrame(
                    localFrame,
                    rowIndex: rowIndex
                ),
                parent: parent
            ) { [weak self] in
                guard let self else { return false }
                self.revealTextSpoiler(
                    itemIdentifier: itemIdentifier,
                    region: region,
                    rangeLocation: range.location
                )
                return true
            })
        }

        }
    }

    func appendTextAccessibility(
        to children: inout [Any],
        input: NativeTimelineTextAccessibilityInput
    ) {
        textAccessibilityAppendOperation(&children, input)
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

    var componentAccessibilityAppendOperation:
        @MainActor (
            inout [Any],
            Message,
            NativeTimelineRowLayout,
            NativeMessageTimelineItem.Identifier,
            NativeTimelineTextSpoilerRevealState,
            Int,
            NSAccessibilityElement
        ) -> Void
    {
        { [self] children, message, layout, itemIdentifier, revealedTextSpoilerState, rowIndex, parent in
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
            @MainActor
            func isInsideHiddenContainer(_ frame: CGRect) -> Bool {
                NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    )
            }
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
            for (textIndex, textRegion) in
                component.textRegions.enumerated()
            where !textRegion.text.value.string.isEmpty
                && !isInsideHiddenContainer(textRegion.frame) {
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
            for region in component.buttons
            where !isInsideHiddenContainer(region.frame) {
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
            where !isInsideHiddenContainer(region.frame) {
                children.append(accessibilityElement(
                    role: .popUpButton,
                    label: region.placeholder,
                    value: region.options.filter(\.isDefault)
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
                    self.showMenu(
                        for: region,
                        message: message,
                        rowIndex: rowIndex
                    )
                    return true
                })
            }
            for region in component.images
            where !isInsideHiddenContainer(region.frame) {
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
                            layouts: layout.componentLayouts,
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
            where !isInsideHiddenContainer(region.frame) {
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
                            layouts: layout.componentLayouts,
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
            where !isInsideHiddenContainer(region.frame) {
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
                            layouts: layout.componentLayouts,
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
        componentAccessibilityAppendOperation(
            &children, message, layout, itemIdentifier,
            revealedTextSpoilerState, rowIndex, parent
        )
    }

    var componentMediaA11yAppendOperation:
        @MainActor (inout [Any], ComponentMediaA11yInput) -> Void
    {
        { [self] children, input in
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
    }

    func appendComponentMediaAccessibility(
        to children: inout [Any],
        input: ComponentMediaA11yInput
    ) {
        componentMediaA11yAppendOperation(&children, input)
    }

    func accessibilityMessageActions(
        _ row: MessageRowPresentation,
        rowFrame: CGRect,
        rowIndex: Int
    ) -> [NSAccessibilityCustomAction] {
        let message = row.message
        let canEdit =
            message.author.id == model?.snapshot?.currentUser.id
        if messageInteractionContext == .searchResult {
            return accessibilitySearchResultActions(
                for: message,
                canDelete: canEdit
            )
        }
        var result: [NSAccessibilityCustomAction] = []
        if message.outboxState == .failed {
            result.append(NSAccessibilityCustomAction(
                name: "Retry Sending"
            ) { [weak self] in
                self?.actions?.retry(message)
                return self != nil
            })
        }
        result.append(NSAccessibilityCustomAction(
            name: "Add Reaction"
        ) { [weak self] in
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
        })
        if let reply = actions?.reply {
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
        if canEdit {
            result.append(NSAccessibilityCustomAction(
                name: "Edit Message"
            ) { [weak self] in
                guard let self else { return false }
                self.beginEditing(row: row, at: rowIndex)
                return true
            })
        }
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
        if canEdit {
            result.append(NSAccessibilityCustomAction(
                name: "Delete Message"
            ) { [weak self] in
                self?.requestDelete(message)
                return self != nil
            })
        }
        return result
    }

    private func accessibilitySearchResultActions(
        for message: Message,
        canDelete: Bool
    ) -> [NSAccessibilityCustomAction] {
        var result = [
            NSAccessibilityCustomAction(name: "Jump to Message") { [weak self] in
                guard let openMessage = self?.actions?.openMessage else {
                    return false
                }
                openMessage(message)
                return true
            },
            NSAccessibilityCustomAction(name: "Mark Unread") { [weak self] in
                self?.actions?.markUnread(message)
                return self != nil
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
                name: "Delete Message"
            ) { [weak self] in
                self?.requestDelete(message)
                return self != nil
            })
        }
        return result
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
