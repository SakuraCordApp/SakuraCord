import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    var animatedMediaKeysOperation:
        @MainActor (MessageRowPresentation, NativeTimelineRowLayout) -> Set<NativeTimelineMediaKey>
    {
        { [self] row, layout in
        let message = row.message
        var keys: Set<NativeTimelineMediaKey> = []

        let author =
            model?.authorPresentation(for: message).user
            ?? message.author
        if layout.avatarFrame != nil {
            if let url =
                author.avatarURL
                    ?? message.author.avatarURL,
               NativeTimelineAvatarPresentation
                .shouldDecodeAnimation(for: url)
            {
                keys.insert(.avatar(url))
            }
            if let url =
                author.avatarDecorationURL
                    ?? message.author.avatarDecorationURL
            {
                // Discord serves both static PNG and animated APNG decoration
                // assets from this route. Decode only for visible rows; the
                // media store discards single-frame results from overlay use.
                keys.insert(.avatarDecoration(url))
            }
        }
        if layout.replyFrame != nil,
           let url = row.replyPreview?.author.avatarURL,
           NativeTimelineAvatarPresentation
            .shouldDecodeAnimation(for: url)
        {
            keys.insert(.avatar(url))
        }
        if layout.commandInvocationRegion?.avatarFrame != nil,
           let url = message.interactionMetadata?.user?.avatarURL,
           NativeTimelineAvatarPresentation
            .shouldDecodeAnimation(for: url)
        {
            keys.insert(.avatar(url))
        }
        for reaction in layout.reactionRegions {
            for avatar in reaction.avatarRegions {
                if let url = avatar.reactor.avatarURL,
                   NativeTimelineAvatarPresentation
                    .shouldDecodeAnimation(for: url)
                {
                    keys.insert(.avatar(url))
                }
            }
        }

        for region in layout.linkedImageRegions
        where Self.isPotentiallyAnimated(region.reference.displayURL) {
            keys.insert(.media(
                region.reference.displayURL,
                maximumPixelDimension: region.reference.isEmoji ? 96 : 720
            ))
        }
        for attachment in message.attachments
        where attachment.mediaKind == .animatedImage {
            if NativeTimelineSpoilerConcealmentPolicy
                .shouldLoadOrAnimate(
                    messageID: message.id,
                    contentID:
                        NativeTimelineComponentRevealKey
                            .attachmentComponentID(attachment.id),
                    isSpoiler: attachment.isSpoiler,
                    store: spoilerRevealStore
                ) {
                if let key = NativeTimelineMediaKey.attachment(attachment) {
                    keys.insert(key)
                }
            }
        }
        if let model {
            for token in row.textPlan.preparedText?.tokens ?? [] {
                guard case let .customEmoji(emoji) = token else { continue }
                let reference = EmojiReference(rawToken: emoji.rawToken)
                guard reference.isAnimated,
                      let url =
                        reference.id.flatMap({ model.customEmojiURLsByID[$0] })
                        ?? reference.imageURL(size: 64)
                else { continue }
                keys.insert(.media(url, maximumPixelDimension: 64))
            }
        }
        for region in layout.embedRegions {
            for image in region.imageRegions
            where Self.isPotentiallyAnimated(image.url) {
                keys.insert(.media(
                    image.url,
                    maximumPixelDimension: image.maximumPixelDimension
                ))
            }
            if !region.mediaIsVideo,
               let url = region.mediaURL,
               Self.isPotentiallyAnimated(url)
            {
                keys.insert(.media(url))
            }
            for textRegion in region.textRegions {
                appendAnimatedInlineKeys(
                    from: textRegion.text.value,
                    into: &keys
                )
            }
        }
        for component in layout.componentLayouts {
            let hiddenContainerFrames =
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: component,
                        messageID: message.id,
                        store: spoilerRevealStore
                    )
            for image in component.images
            where Self.isPotentiallyAnimated(image.displayURL)
                && !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        image.frame,
                        hiddenContainerFrames: hiddenContainerFrames
                    )
                && !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                    messageID: message.id,
                    contentID: image.componentID,
                    isSpoiler: image.isSpoiler,
                    store: spoilerRevealStore
                ) {
                keys.insert(.media(
                    image.displayURL,
                    maximumPixelDimension: image.maximumPixelDimension
                ))
            }
            for media in component.media
            where Self.isPotentiallyAnimated(media.displayURL)
                && !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        media.frame,
                        hiddenContainerFrames: hiddenContainerFrames
                    )
                && !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                    messageID: message.id,
                    contentID: media.componentID,
                    isSpoiler: media.isSpoiler,
                    store: spoilerRevealStore
                ) {
                keys.insert(.media(media.displayURL))
            }
            for button in component.buttons {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        button.frame,
                        hiddenContainerFrames: hiddenContainerFrames
                    )
                else { continue }
                guard let emoji = button.emoji,
                      emoji.isAnimated,
                      let url = emoji.imageURL(size: 32)
                else { continue }
                keys.insert(.media(url, maximumPixelDimension: 64))
            }
            for textRegion in component.textRegions {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        textRegion.frame,
                        hiddenContainerFrames: hiddenContainerFrames
                    )
                else { continue }
                appendAnimatedInlineKeys(
                    from: textRegion.text.value,
                    into: &keys
                )
            }
        }
        for sticker in message.stickers
        where sticker.format == .apng || sticker.format == .gif {
            if let url = sticker.mediaURL {
                keys.insert(.media(url, maximumPixelDimension: 384))
            }
        }
        for region in layout.reactionRegions {
            let reference = region.reaction.emojiReference
            guard reference.isAnimated,
                  let url = reference.id.flatMap({
                      model?.customEmojiURLsByID[$0]
                  }) ?? reference.imageURL(size: 64)
            else { continue }
            keys.insert(.media(url, maximumPixelDimension: 64))
        }
        return keys

        }
    }

    func animatedMediaKeys(
        for row: MessageRowPresentation,
        layout: NativeTimelineRowLayout
    ) -> Set<NativeTimelineMediaKey> {
        animatedMediaKeysOperation(row, layout)
    }

    func appendAnimatedInlineKeys(
        from value: NSAttributedString,
        into keys: inout Set<NativeTimelineMediaKey>
    ) {
        let range = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(
            .discordEmojiToken,
            in: range
        ) { rawValue, _, _ in
            guard let rawToken = rawValue as? String else { return }
            let reference = EmojiReference(rawToken: rawToken)
            guard reference.isAnimated,
                  let url = reference.id.flatMap({
                      model?.customEmojiURLsByID[$0]
                  }) ?? reference.imageURL(size: 64)
            else { return }
            keys.insert(.media(url, maximumPixelDimension: 64))
        }
    }

    static func isPotentiallyAnimated(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "gif", "apng", "webp":
            true
        default:
            false
        }
    }

    func reactionCountTransitions(
        inMessageAt index: Int
    ) -> [String: NativeTimelineReactionCountTransition] {
        guard items.indices.contains(index),
              let messageID = items[index].messageID
        else { return [:] }
        var result: [String: NativeTimelineReactionCountTransition] = [:]
        for (key, animation) in activeReactionCountAnimations
        where key.messageID == messageID {
            result[key.reactionID] = NativeTimelineReactionCountTransition(
                from: animation.from,
                to: animation.to,
                progress: 0
            )
        }
        return result
    }

    func setHoveredReaction(
        _ hit: ReactionPointerHit?,
        mouseLocationInScreen: CGPoint = NSEvent.mouseLocation
    ) {
        let oldTarget = hoveredReaction
        let newTarget = hit?.target
        hoveredReaction = newTarget
        if oldTarget != newTarget {
            if let oldTarget, let index = rowIndex(for: oldTarget) {
                setNeedsDisplay(rowFrame(at: index))
            }
            if let hit {
                setNeedsDisplay(rowFrame(at: hit.rowIndex))
            }
        }

        guard let hit,
              let reaction = hit.reaction,
              case .reaction = hit.target
        else {
            reactionHoverCoordinator.close()
            return
        }
        presentReactionHover(
            hit,
            reaction: reaction,
            mouseLocationInScreen: mouseLocationInScreen
        )
        if oldTarget != newTarget {
            Task { [weak model] in
                await model?.loadReactionReactors(reaction, on: hit.message)
            }
        }
    }

    func reconcileReactionHover() {
        guard let target = hoveredReaction,
              let hit = reactionPointerHit(for: target)
        else {
            hoveredReaction = nil
            reactionHoverCoordinator.close()
            return
        }
        setHoveredReaction(hit)
    }

    func presentReactionHover(
        _ hit: ReactionPointerHit,
        reaction: Reaction,
        mouseLocationInScreen: CGPoint
    ) {
        let target = hit.target
        let anchor = StablePopoverAnchor(sourceView: self) { [weak self] in
            self?.reactionPointerHit(for: target)?.frame
        }
        let mouseInWindow = window?.convertPoint(
            fromScreen: mouseLocationInScreen
        ) ?? .zero
        let mouseInCanvas = convert(mouseInWindow, from: nil)
        let snapshot = StablePopoverAnchorSnapshot(
            mouseLocationInScreen: mouseLocationInScreen,
            mouseLocationInSource: CGPoint(
                x: mouseInCanvas.x - hit.frame.minX,
                y: mouseInCanvas.y - hit.frame.minY
            )
        )
        let reference = reaction.emojiReference
        let emojiURL = reference.id.flatMap { id in
            model?.customEmojiURLsByID[id]
        } ?? reference.imageURL(size: 64)
        reactionHoverCoordinator.update(
            anchor: anchor,
            anchorSnapshot: snapshot,
            isPresented: true,
            configuration: .hover,
            onDismiss: {},
            content: MessageReactionTooltip(
                reaction: reaction,
                emojiURL: emojiURL
            )
        )
    }

    func showReactionPicker(
        for message: Message,
        anchor: CGRect,
        preferredEdge: NSRectEdge
    ) {
        guard let model else { return }
        reactionPickerSource.frame = anchor
        let content = EmojiPickerView(
            model: model,
            useCase: .reaction(
                guildID: message.guildID ?? model.selectedGuildID
            ),
            allowsPersistentSelection: true
        ) { [weak self] activation in
            guard let self else { return }
            let value = switch activation.selection {
            case let .native(value): value
            case let .custom(emoji): emoji.messageToken
            }
            self.actions?.react(value, message)
            if !activation.keepsPickerPresented {
                self.reactionPickerCoordinator.close(
                    notifyBinding: false
                )
                self.reactionPickerSource.frame = .zero
            }
        }
        reactionPickerCoordinator.update(
            sourceView: reactionPickerSource,
            isPresented: true,
            preferredEdge: preferredEdge,
            accessibilityIdentifier:
                preferredEdge == .maxX
                    ? "reaction-picker-inline"
                    : "reaction-picker-toolbar",
            content: content,
            setPresented: { [weak self] isPresented in
                if !isPresented {
                    self?.reactionPickerSource.frame = .zero
                }
            }
        )
    }

    func handleComponentClick(
        in layout: NativeTimelineRowLayout,
        message: Message,
        point: CGPoint,
        rowIndex: Int
    ) -> Bool {
        for componentLayout in layout.componentLayouts {
            for container in componentLayout.containers
            where container.isSpoiler && container.frame.contains(point) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: container.componentID
                )
                if !spoilerRevealStore.isMediaRevealed(key) {
                    reveal(key, rowIndex: rowIndex)
                    return true
                }
            }
            for region in componentLayout.images
            where region.frame.contains(point) {
                return activateComponentMedia(
                    id: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    layout: layout,
                    message: message,
                    rowIndex: rowIndex
                )
            }
            for region in componentLayout.media
            where region.frame.contains(point) {
                return activateComponentMedia(
                    id: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    layout: layout,
                    message: message,
                    rowIndex: rowIndex
                )
            }
            for region in componentLayout.files
            where region.frame.contains(point) {
                return activateComponentMedia(
                    id: region.componentID,
                    openURL: region.openURL,
                    isSpoiler: region.isSpoiler,
                    layout: layout,
                    message: message,
                    rowIndex: rowIndex
                )
            }
            for region in componentLayout.selects
            where region.frame.contains(point) {
                guard !region.isDisabled else { return true }
                showMenu(
                    for: region,
                    message: message,
                    rowIndex: rowIndex
                )
                return true
            }
        }
        return false
    }

    private func activateComponentMedia(
        id: String,
        openURL: URL,
        isSpoiler: Bool,
        layout: NativeTimelineRowLayout,
        message: Message,
        rowIndex: Int
    ) -> Bool {
        let key = NativeTimelineComponentRevealKey(
            messageID: message.id,
            componentID: id
        )
        if isSpoiler, !spoilerRevealStore.isMediaRevealed(key) {
            reveal(key, rowIndex: rowIndex)
        } else if let presentation = NativeTimelineMediaViewerPlan.components(
            in: message,
            layouts: layout.componentLayouts,
            selectedComponentID: id,
            isRevealed: { [spoilerRevealStore] componentID in
                spoilerRevealStore.isMediaRevealed(
                    NativeTimelineComponentRevealKey(
                        messageID: message.id,
                        componentID: componentID
                    )
                )
            }
        ) {
            model?.mediaViewerPresentation = presentation
        } else {
            NSWorkspace.shared.open(openURL)
        }
        return true
    }

    func handleTextClick(
        in layout: NativeTimelineRowLayout,
        message: Message,
        point: CGPoint,
        rowIdentifier: NativeMessageTimelineItem.Identifier
    ) -> Bool {
        guard let pointerHit = textPointerHit(
            in: layout,
            point: point
        ) else { return false }
        return activateTextHit(
            pointerHit.hit,
            message: message,
            rowIdentifier: rowIdentifier,
            region: pointerHit.region
        )
    }

    func textPointerHit(
        in layout: NativeTimelineRowLayout,
        point: CGPoint
    ) -> TextPointerHit? {
        if let frame = layout.contentFrame,
           let value = layout.attributedContent,
           let framesetter = layout.contentFramesetter,
           let hit = NativeTimelineTextHitTester.hit(
               value: value,
               framesetter: framesetter,
               frame: NativeTimelineTextGeometry
                   .messageContentDrawingFrame(frame),
               point: point
           ),
           hit.mention != nil
                || hit.url != nil
                || hit.spoilerRange != nil
        {
            return TextPointerHit(hit: hit, region: .content)
        }
        for embed in layout.embedRegions {
            for (textIndex, region) in embed.textRegions.enumerated() {
                if let hit = NativeTimelineTextHitTester.hit(
                    box: region.text,
                    frame: region.frame,
                    point: point
                ), hit.mention != nil
                    || hit.url != nil
                    || hit.spoilerRange != nil
                {
                    return TextPointerHit(
                        hit: hit,
                        region: .embed(
                           embedID: embed.embedID,
                           textIndex: textIndex
                       )
                    )
                }
            }
        }
        for (layoutIndex, component) in
            layout.componentLayouts.enumerated()
        {
            for (textIndex, region) in component.textRegions.enumerated() {
                if let hit = NativeTimelineTextHitTester.hit(
                    box: region.text,
                    frame: region.frame,
                    point: point
                ), hit.mention != nil
                    || hit.url != nil
                    || hit.spoilerRange != nil
                {
                    return TextPointerHit(
                        hit: hit,
                        region: .component(
                           layoutIndex: layoutIndex,
                           textIndex: textIndex
                       )
                    )
                }
            }
        }
        return nil
    }

    func activateTextHit(
        _ hit: NativeTimelineTextHit,
        message: Message,
        rowIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion
    ) -> Bool {
        if let spoilerRange = hit.spoilerRange {
            revealTextSpoiler(
                itemIdentifier: rowIdentifier,
                region: region,
                rangeLocation: spoilerRange.location
            )
            return true
        }
        if let mention = hit.mention {
            let anchor = StablePopoverAnchor(
                sourceView: self
            ) { [weak self] in
                self?.mentionAnchorFrame(
                    rowIdentifier: rowIdentifier,
                    region: region,
                    characterIndex: hit.characterIndex,
                    rawToken: mention.rawToken
                )
            }
            activateMention(
                mention,
                message: message,
                anchor: anchor
            )
            return true
        }
        guard let url = hit.url else { return false }
        return MessageLinkActivator.activate(url, model: model)
    }

    func revealTextSpoiler(
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        rangeLocation: Int
    ) {
        guard let key = textSpoilerRevealKey(
            itemIdentifier: itemIdentifier,
            region: region,
            rangeLocation: rangeLocation
        ),
              spoilerRevealStore.revealText(key)
        else { return }
    }

    func activateMention(
        _ mention: MentionPresentation,
        message: Message,
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        switch mention.target {
        case .unresolved:
            break
        case let .user(id):
            let resolver = MessageMentionResolver(
                model: model,
                message: message
            )
            if let user = resolver.user(id) {
                showMentionProfile(
                    for: user,
                    anchor: anchor
                )
            }
        case let .role(id):
            showMentionRole(id, anchor: anchor)
        case let .channel(id):
            model.navigate(to: id)
        case let .linkedChannel(guildID, channelID):
            model.navigate(to: guildID, linkedChannelID: channelID)
        case let .message(guildID, channelID, messageID):
            model.navigate(
                to: guildID,
                channelID: channelID,
                messageID: messageID
            )
        }
    }

    func mentionAnchorFrame(
        rowIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        characterIndex: Int,
        rawToken: String
    ) -> CGRect? {
        guard let index = items.firstIndex(where: {
            $0.identifier == rowIdentifier
        }),
           layouts.indices.contains(index)
        else { return nil }
        let layout = layouts[index]
        let localFrame: CGRect?
        switch region {
        case .beginningTitle, .beginningDescription:
            return nil
        case .content:
            guard let value = layout.attributedContent,
                  let framesetter = layout.contentFramesetter,
                  let frame = layout.contentFrame
            else { return nil }
            localFrame = NativeTimelineTextHitTester.mentionAnchorFrame(
                value: value,
                framesetter: framesetter,
                frame: NativeTimelineTextGeometry
                    .messageContentDrawingFrame(frame),
                characterIndex: characterIndex,
                rawToken: rawToken
            )
        case let .embed(embedID, textIndex):
            guard let embed = layout.embedRegions.first(where: {
                $0.embedID == embedID
            }),
               embed.textRegions.indices.contains(textIndex)
            else { return nil }
            let text = embed.textRegions[textIndex]
            localFrame = NativeTimelineTextHitTester.mentionAnchorFrame(
                box: text.text,
                frame: text.frame,
                characterIndex: characterIndex,
                rawToken: rawToken
            )
        case let .component(layoutIndex, textIndex):
            guard layout.componentLayouts.indices.contains(layoutIndex),
                  layout.componentLayouts[layoutIndex]
                      .textRegions.indices.contains(textIndex)
            else { return nil }
            let text = layout.componentLayouts[layoutIndex]
                .textRegions[textIndex]
            localFrame = NativeTimelineTextHitTester.mentionAnchorFrame(
                box: text.text,
                frame: text.frame,
                characterIndex: characterIndex,
                rawToken: rawToken
            )
        }
        return localFrame?.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
    }

    func reveal(
        _ key: NativeTimelineComponentRevealKey
    ) {
        guard let rowIndex = items.firstIndex(where: {
            $0.messageID == key.messageID
        }) else { return }
        reveal(key, rowIndex: rowIndex)
    }

    func reveal(
        _ key: NativeTimelineComponentRevealKey,
        rowIndex: Int
    ) {
        guard items.indices.contains(rowIndex),
              items[rowIndex].messageID == key.messageID
        else { return }
        guard spoilerRevealStore.revealMedia(key) else { return }
    }

    func installSpoilerRevealStore(
        _ store: NativeTimelineSpoilerRevealStore
    ) {
        guard spoilerRevealStore !== store else { return }
        if let spoilerRevealObserverID {
            spoilerRevealStore.removeObserver(spoilerRevealObserverID)
        }
        spoilerRevealStore = store
        spoilerRevealObserverID = store.observe { [weak self] messageID in
            self?.spoilerRevealStateDidChange(messageID: messageID)
        }
    }

    func spoilerRevealStateDidChange(messageID: MessageID) {
        guard let rowIndex = items.firstIndex(where: {
            $0.messageID == messageID
        }) else { return }
        let identifier = items[rowIndex].identifier
        visibleMediaProjection = nil
        mediaKeysByIdentifier[identifier] = nil
        invalidateBitmap(identifier)
        requestMedia(for: items[rowIndex], at: rowIndex)
        setNeedsDisplay(rowFrame(at: rowIndex))
        reconcileAnimatedMedia()
        reconcileSpoilerOverlays()
        rebuildAccessibilityProxy(for: identifier)
    }

    func showMenu(
        for region: NativeTimelineComponentLayout.SelectRegion,
        message: Message,
        rowIndex: Int
    ) {
        guard region.kind == .string else {
            showComponentChoicePicker(
                for: region,
                message: message,
                rowIndex: rowIndex
            )
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in region.options {
            let title = option.emoji.map {
                "\($0.name) \(option.label)"
            } ?? option.label
            let item = actionItem(
                title,
                systemImage: option.isDefault
                    ? "checkmark.circle.fill"
                    : "circle"
            ) { [weak self] in
                guard let self else { return }
                self.actions?.submitComponent(
                    message,
                    region.customID,
                    self.interactionKind(region.kind),
                    [option.value]
                )
            }
            item.state = option.isDefault ? .on : .off
            item.toolTip = option.description
            menu.addItem(item)
        }
        let point = CGPoint(
            x: region.frame.minX,
            y: displayedRowOrigin(at: rowIndex) + region.frame.maxY + 2
        )
        menu.popUp(positioning: nil, at: point, in: self)
    }

    func showComponentChoicePicker(
        for region: NativeTimelineComponentLayout.SelectRegion,
        message: Message,
        rowIndex: Int
    ) {
        guard let model else { return }
        closeComponentChoicePopover()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ComponentChoicePicker(
                placeholder: region.placeholder,
                loader: { [weak model] query in
                    guard let model else {
                        throw CancellationError()
                    }
                    return try await model.componentChoices(
                        kind: region.kind,
                        query: query,
                        guildID: message.guildID,
                        channelID: message.channelID
                    )
                },
                select: { [weak self] option in
                    guard let self else { return }
                    self.actions?.submitComponent(
                        message,
                        region.customID,
                        self.interactionKind(region.kind),
                        [option.value]
                    )
                    self.closeComponentChoicePopover()
                }
            )
        )
        componentChoicePopover = popover
        popover.show(
            relativeTo: CGRect(
                x: region.frame.minX,
                y: displayedRowOrigin(at: rowIndex)
                    + region.frame.minY,
                width: region.frame.width,
                height: region.frame.height
            ),
            of: self,
            preferredEdge: .maxY
        )
    }

    func closeComponentChoicePopover() {
        componentChoicePopover?.performClose(nil)
        componentChoicePopover = nil
    }

    func interactionKind(
        _ kind: ComponentSelectKind
    ) -> ComponentInteractionKind {
        switch kind {
        case .string: .stringSelect
        case .user: .userSelect
        case .role: .roleSelect
        case .mentionable: .mentionableSelect
        case .channel: .channelSelect
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !overlayBlocksInteractions else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point.y),
              layouts.indices.contains(index),
              case let .message(row, _, _) = items[index]
        else { return nil }
        let localPoint = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        if let imageItem = NativeTimelineImageContextMenuPlan.item(
            in: row.message,
            layout: layouts[index],
            at: localPoint,
            isRevealed: { [spoilerRevealStore] componentID in
                spoilerRevealStore.isMediaRevealed(
                    NativeTimelineComponentRevealKey(
                        messageID: row.message.id,
                        componentID: componentID
                    )
                )
            }
        ) {
            return MediaImageContextMenuBuilder.make(
                actions: imageContextMenuActions(for: imageItem)
            )
        }
        guard let actions else { return nil }
        return messageContextMenu(
            for: row,
            at: index,
            point: point,
            actions: actions
        )
    }

    func messageContextMenu(
        for row: MessageRowPresentation,
        at index: Int,
        point: CGPoint,
        actions: NativeTimelineRowActions
    ) -> NSMenu? {
        guard TimelineContextMenuHitTesting.contains(
            point,
            rowOrigin: displayedRowOrigin(at: index),
            highlightFrame: layouts[index].highlightFrame
        ) else { return nil }
        let canEdit =
            row.message.author.id == model?.snapshot?.currentUser.id
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in NativeTimelineMessageMenuPolicy.entries(
            canEdit: canEdit,
            canRetry: row.message.outboxState == .failed,
            canReply: actions.reply != nil,
            canForward: actions.forward != nil && model?.canForward(row.message) == true,
            context: messageInteractionContext
        ) {
            guard case let .action(
                action,
                title,
                systemImage,
                isDestructive
            ) = entry
            else {
                menu.addItem(.separator())
                continue
            }
            let handler = messageMenuHandler(
                action: action,
                row: row,
                index: index,
                actions: actions
            )
            menu.addItem(
                actionItem(
                    title,
                    systemImage: systemImage,
                    isDestructive: isDestructive,
                    action: handler
                )
            )
        }
        return menu
    }

    func messageMenuHandler(
        action: NativeTimelineMessageMenuAction,
        row: MessageRowPresentation,
        index: Int,
        actions: NativeTimelineRowActions
    ) -> () -> Void {
        switch action {
        case .jumpToMessage:
            { actions.openMessage?(row.message) }
        case .retrySending:
            { actions.retry(row.message) }
        case .addReaction:
            { actions.react("👍", row.message) }
        case .reply:
            {
                guard let reply = actions.reply else { return }
                reply(row.message)
            }
        case .forward:
            {
                guard let forward = actions.forward else { return }
                forward(row.message)
            }
        case .markUnread:
            { actions.markUnread(row.message) }
        case .editMessage:
            { [weak self] in self?.beginEditing(row: row, at: index) }
        case .copyText:
            { Self.copyText(row.message.content) }
        case .copyLink:
            { [weak self] in
                guard let self else { return }
                Self.copyText(self.messageLink(for: row.message))
            }
        case .copyMessageID:
            { Self.copyText(row.message.id.description) }
        case .copyAuthorID:
            { Self.copyText(row.message.author.id.description) }
        case .deleteMessage:
            { [weak self] in self?.confirmDelete(row.message) }
        }
    }

    func imageContextMenuActions(
        for item: RichMediaItem
    ) -> MediaImageContextMenuActions {
        MediaImageContextMenuActions(
            copyImage: { [weak self] in
                Task { @MainActor [weak self] in
                    do {
                        try await MediaViewerActionService.copyImage(
                            from: item.url
                        )
                    } catch {
                        self?.presentMediaActionError(error)
                    }
                }
            },
            saveImage: { [weak self] in
                Task { @MainActor [weak self] in
                    do {
                        _ = try await MediaViewerActionService.save(item)
                    } catch {
                        self?.presentMediaActionError(error)
                    }
                }
            },
            copyLink: {
                MediaViewerActionService.copyText(item.url.absoluteString)
            },
            openLink: {
                MediaViewerActionService.openInBrowser(item.url)
            }
        )
    }

    func presentMediaActionError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

}
