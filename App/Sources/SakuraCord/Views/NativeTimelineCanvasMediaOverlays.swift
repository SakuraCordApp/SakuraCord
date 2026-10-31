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
    var permitsAnimatedMediaPlayback: Bool {
        AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: window != nil,
            isWindowVisible: window?.occlusionState.contains(.visible) == true,
            reduceMotion: false
        )
    }

    @objc
    func mediaPlaybackVisibilityDidChange(_ notification: Notification) {
        if let changedWindow = notification.object as? NSWindow,
           changedWindow !== window
        {
            return
        }
        reconcileHistorySkeletonShimmer()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            reconcileSendTransitions()
        }
        if !permitsAnimatedMediaPlayback {
            NativeTimelineMediaStore.shared.cancelAnimatedRequests(owner: visibleMediaPinOwner)
        }
        reconcileAnimatedMedia(allowsScrolling: true)
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || !permitsAnimatedMediaPlayback
        reconcileInlineVideoOverlays(
            plays: !reduceMotion
        )
    }

    func scheduleAnimatedMediaReconciliation() {
        animatedMediaReconcileTask?.cancel()
        guard mediaReadyConversationID == presentedConversationID else {
            animatedMediaReconcileTask = nil
            return
        }
        animatedMediaReconcileTask = Task { @MainActor [weak self] in
            let interval = AppPerformanceSignposts.signposter.beginInterval(
                "TimelinePostFirstFrameMediaDeferral"
            )
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    "TimelinePostFirstFrameMediaDeferral",
                    interval
                )
            }
            // Network/history preparation can make a cold first frame arrive
            // well after an update. This is gated by the actual completed
            // frame, not update time, so optional GIF/APNG expansion cannot
            // compete with cold row rasterization. Keep a further quiet
            // interval after that frame before starting utility work.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let self,
                  self.mediaReadyConversationID
                    == self.presentedConversationID
            else { return }
            self.animatedMediaReconcileTask = nil
            self.reconcileAnimatedMedia()
        }
    }

    func startVisibleInlineVideosImmediately() {
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || !permitsAnimatedMediaPlayback
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            inlineVideoRows.removeAll()
            removeInlineVideoOverlays()
            return
        }

        var rows:
            [NativeMessageTimelineItem.Identifier: Set<URL>] = [:]
        var videoCount = 0
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY,
              videoCount < Self.maximumInlineVideoOverlayCount
        {
            guard layouts.indices.contains(index),
                  !hidesRowForSendTransition(items[index].identifier)
            else {
                index += 1
                continue
            }
            let urls = Set(layouts[index].embedRegions.compactMap { region -> URL? in
                guard region.mediaIsVideo,
                      region.mediaAutoplaysInline
                else { return nil }
                return region.mediaURL
            })
            if !urls.isEmpty {
                let remaining =
                    Self.maximumInlineVideoOverlayCount - videoCount
                let boundedURLs = Set(urls.prefix(remaining))
                rows[items[index].identifier] = boundedURLs
                videoCount += boundedURLs.count
            }
            index += 1
        }
        inlineVideoRows = rows
        reconcileInlineVideoOverlays(
            // Created while scrolling so the embed is not blank, but paused
            // until scrolling settles.
            plays: !reduceMotion && !suppressesHoverPresentation
        )
    }

    struct DesiredAnimatedMediaOverlay {
        let key: AnimatedMediaOverlayKey
        let mediaFrame: CGRect
        let selectionFrame: CGRect?
        let cornerRadius: CGFloat
        let isLooping: Bool
        let opacity: CGFloat
        let fillsFrame: Bool
        let image: DecodedAnimatedImage
    }

    final class AnimatedMediaOverlayAccumulator {
        unowned let canvas: NativeTimelineCanvasView
        var desired: [DesiredAnimatedMediaOverlay] = []

        init(canvas: NativeTimelineCanvasView) {
            self.canvas = canvas
            desired.reserveCapacity(NativeTimelineCanvasView.maximumAnimatedMediaOverlayCount)
        }

        func append(
            row: NativeMessageTimelineItem.Identifier,
            role: AnimatedMediaOverlayRole,
            media: NativeTimelineMediaKey,
            frame: CGRect,
            selectionFrame: CGRect? = nil,
            cornerRadius: CGFloat,
            isLooping: Bool,
            opacity: CGFloat = 1,
            fillsFrame: Bool = false,
            allowsStaticImage: Bool = false
        ) {
            let image = allowsStaticImage
                ? NativeTimelineMediaStore.shared.decodedImage(for: media)
                : NativeTimelineMediaStore.shared.decodedAnimatedImage(for: media)
            guard desired.count < NativeTimelineCanvasView.maximumAnimatedMediaOverlayCount,
                  canvas.animatedMediaRows[row]?.contains(media) == true,
                  let image
            else { return }
            desired.append(DesiredAnimatedMediaOverlay(
                key: AnimatedMediaOverlayKey(row: row, role: role, media: media),
                mediaFrame: frame,
                selectionFrame: selectionFrame,
                cornerRadius: cornerRadius,
                isLooping: isLooping,
                opacity: opacity,
                fillsFrame: fillsFrame,
                image: image
            ))
        }

        func appendInlineEmoji(
            row: NativeMessageTimelineItem.Identifier,
            role: (Int, Int) -> AnimatedMediaOverlayRole,
            value: NSAttributedString,
            framesetter: CTFramesetter,
            frame: CGRect,
            selectionRange: NSRange?,
            revealedSpoilerLocations: Set<Int>
        ) {
            for (ordinal, region) in NativeTimelineInlineEmojiGeometry.regions(
                in: value,
                framesetter: framesetter,
                frame: frame,
                selectionRange: selectionRange,
                revealedSpoilerLocations: revealedSpoilerLocations
            ).enumerated() {
                let reference = EmojiReference(rawToken: region.rawToken)
                guard reference.isAnimated,
                      let url = reference.id.flatMap({
                          canvas.model?.customEmojiURLsByID[$0]
                      }) ?? reference.imageURL(size: 64)
                else { continue }
                append(
                    row: row,
                    role: role(ordinal, region.characterRange.location),
                    media: .media(url, maximumPixelDimension: 64),
                    frame: region.mediaFrame,
                    selectionFrame: region.selectionFrame,
                    cornerRadius: 0,
                    isLooping: true
                )
            }
        }
    }

    static let maximumAnimatedMediaOverlayCount = 48

    func reconcileAnimatedMediaOverlays(reduceMotion: Bool) {
        let desired = desiredAnimatedMediaOverlays(reduceMotion: reduceMotion)
        applyAnimatedMediaOverlays(desired)
    }

    private func desiredAnimatedMediaOverlays(
        reduceMotion: Bool
    ) -> [DesiredAnimatedMediaOverlay] {
        guard !reduceMotion,
              !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeAnimatedMediaOverlays()
            return []
        }

        let accumulator = AnimatedMediaOverlayAccumulator(canvas: self)

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY,
              accumulator.desired.count < Self.maximumAnimatedMediaOverlayCount
        {
            guard layouts.indices.contains(index),
                  case let .message(row, _, _) = items[index]
            else {
                index += 1
                continue
            }
            let identifier = items[index].identifier
            let layout = layouts[index]
            guard animatedMediaRows[identifier] != nil else {
                index += 1
                continue
            }

            appendAnimatedAvatarOverlays(
                row: row,
                identifier: identifier,
                layout: layout,
                accumulator: accumulator
            )

            appendAnimatedMessageContentOverlays(
                row: row,
                identifier: identifier,
                layout: layout,
                accumulator: accumulator
            )

            appendAnimatedEmbedOverlays(
                messageID: row.message.id,
                identifier: identifier,
                layout: layout,
                accumulator: accumulator
            )

            for (componentIndex, component) in
                layout.componentLayouts.enumerated()
            {
                appendAnimatedComponentMediaOverlays(
                    component,
                    componentIndex: componentIndex,
                    identifier: identifier,
                    accumulator: accumulator
                )
                appendAnimatedComponentContentOverlays(
                    component,
                    componentIndex: componentIndex,
                    messageID: row.message.id,
                    identifier: identifier,
                    layout: layout,
                    accumulator: accumulator
                )
            }

            appendAnimatedStickerAndReactionOverlays(
                row: row,
                identifier: identifier,
                layout: layout,
                accumulator: accumulator
            )
            index += 1
        }

        return accumulator.desired
    }

    private func appendAnimatedAvatarOverlays(
        row: MessageRowPresentation,
        identifier: NativeMessageTimelineItem.Identifier,
        layout: NativeTimelineRowLayout,
        accumulator: AnimatedMediaOverlayAccumulator
    ) {
        let author = model?.authorPresentation(for: row.message).user ?? row.message.author
        if let frame = layout.avatarFrame {
            if let url = author.avatarURL ?? row.message.author.avatarURL,
               NativeTimelineAvatarPresentation.shouldDecodeAnimation(for: url) {
                accumulator.append(
                    row: identifier, role: .authorAvatar, media: .avatar(url), frame: frame,
                    cornerRadius: frame.width / 2, isLooping: true, fillsFrame: true
                )
            }
            if let decorationURL = author.avatarDecorationURL {
                accumulator.append(
                    row: identifier,
                    role: .authorAvatarDecoration,
                    media: .avatarDecoration(decorationURL),
                    frame: NativeTimelineAvatarPresentation.decorationFrame(around: frame),
                    cornerRadius: 0,
                    isLooping: true,
                    allowsStaticImage: true
                )
            }
        }
        if let preview = row.replyPreview,
           let url = preview.author.avatarURL,
           let replyContentFrame = layout.replyContentFrame,
           NativeTimelineAvatarPresentation.shouldDecodeAnimation(for: url) {
            let frame = NativeTimelineAvatarPresentation.replyAvatarFrame(in: replyContentFrame)
            accumulator.append(
                row: identifier, role: .replyAvatar, media: .avatar(url), frame: frame,
                cornerRadius: frame.width / 2, isLooping: true, fillsFrame: true
            )
        }
        if let frame = layout.commandInvocationRegion?.avatarFrame,
           let url = row.message.interactionMetadata?.user?.avatarURL,
           NativeTimelineAvatarPresentation.shouldDecodeAnimation(for: url) {
            accumulator.append(
                row: identifier, role: .invocationAvatar, media: .avatar(url), frame: frame,
                cornerRadius: frame.width / 2, isLooping: true, fillsFrame: true
            )
        }
        for answer in row.message.poll?.answers ?? [] {
            guard answer.emoji?.isAnimated == true, let url = answer.emoji?.imageURL(size: 64),
                  let frame = layout.pollLayout?.answers.first(where: { $0.id == answer.id })?.emojiFrame else { continue }
            accumulator.append(row: identifier, role: .pollAnswer(answer.id),
                               media: .media(url, maximumPixelDimension: 64), frame: frame,
                               cornerRadius: 0, isLooping: true)
        }
        for reaction in layout.reactionRegions {
            for (avatarIndex, avatar) in reaction.avatarRegions.enumerated() {
                guard let url = avatar.reactor.avatarURL,
                      NativeTimelineAvatarPresentation.shouldDecodeAnimation(for: url)
                else { continue }
                accumulator.append(
                    row: identifier,
                    role: .reactionAvatar(reaction.reaction.id, avatarIndex),
                    media: .avatar(url),
                    frame: avatar.frame,
                    cornerRadius: avatar.frame.width / 2,
                    isLooping: true,
                    fillsFrame: true
                )
            }
        }
    }

    private func appendAnimatedMessageContentOverlays(
        row: MessageRowPresentation,
        identifier: NativeMessageTimelineItem.Identifier,
        layout: NativeTimelineRowLayout,
        accumulator: AnimatedMediaOverlayAccumulator
    ) {
        for (linkedIndex, region) in layout.linkedImageRegions.enumerated()
        where Self.isPotentiallyAnimated(region.reference.displayURL) {
            accumulator.append(
                row: identifier,
                role: .linkedImage(linkedIndex),
                media: .media(
                    region.reference.displayURL,
                    maximumPixelDimension: region.reference.isEmoji ? 96 : 720
                ),
                frame: region.frame,
                cornerRadius: region.reference.isEmoji ? 7 : 10,
                isLooping: true
            )
        }
        let fillsFrame = MediaGalleryImagePresentation.fillsFrame(
            itemCount: layout.mediaGalleryItemCount
        )
        for region in layout.attachmentRegions
        where region.attachment.mediaKind == .animatedImage {
            accumulator.append(
                row: identifier,
                role: .attachment(region.attachment.id),
                media: NativeTimelineMediaKey.attachment(region.attachment)
                    ?? .media(region.attachment.url),
                frame: region.frame,
                cornerRadius: InterfaceScale.metric(8),
                isLooping: true,
                opacity: CGFloat(MessageOutboxPresentation.mediaOpacity(
                    for: row.message.outboxState
                )),
                fillsFrame: fillsFrame
            )
        }
        if let contentFrame = layout.contentFrame,
           let attributedContent = layout.attributedContent,
           let framesetter = layout.contentFramesetter {
            accumulator.appendInlineEmoji(
                row: identifier,
                role: { _, location in .messageEmoji(location) },
                value: attributedContent,
                framesetter: framesetter,
                frame: NativeTimelineTextGeometry.messageContentDrawingFrame(contentFrame),
                selectionRange: textSelection?.itemIdentifier == identifier
                    && textSelection?.region == .content ? textSelection?.range : nil,
                revealedSpoilerLocations: revealedTextSpoilerLocations(
                    messageID: row.message.id,
                    region: .content,
                    value: attributedContent,
                    layout: layout
                )
            )
        }
    }

    private func appendAnimatedEmbedOverlays(
        messageID: MessageID,
        identifier: NativeMessageTimelineItem.Identifier,
        layout: NativeTimelineRowLayout,
        accumulator: AnimatedMediaOverlayAccumulator
    ) {
        for embed in layout.embedRegions {
            for (imageIndex, imageRegion) in embed.imageRegions.enumerated()
            where Self.isPotentiallyAnimated(imageRegion.url) {
                accumulator.append(
                    row: identifier,
                    role: .embedImage(embed.embedID, imageIndex),
                    media: .media(
                        imageRegion.url,
                        maximumPixelDimension: imageRegion.maximumPixelDimension
                    ),
                    frame: imageRegion.frame,
                    cornerRadius: imageRegion.cornerRadius,
                    isLooping: false
                )
            }
            if !embed.mediaIsVideo,
               let mediaURL = embed.mediaURL,
               let mediaFrame = embed.mediaFrame,
               Self.isPotentiallyAnimated(mediaURL) {
                accumulator.append(
                    row: identifier,
                    role: .embedMedia(embed.embedID),
                    media: .media(mediaURL),
                    frame: mediaFrame,
                    cornerRadius: InterfaceScale.metric(8),
                    isLooping: true
                )
            }
            for (textIndex, textRegion) in embed.textRegions.enumerated() {
                var drawingFrame = textRegion.frame
                drawingFrame.size.height += textRegion.text.layoutHeightAdjustment
                let textRegionID = NativeTimelineTextRegion.embed(
                    embedID: embed.embedID,
                    textIndex: textIndex
                )
                accumulator.appendInlineEmoji(
                    row: identifier,
                    role: { _, location in
                        .embedEmoji(embed.embedID, textIndex, location)
                    },
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter,
                    frame: drawingFrame,
                    selectionRange: textSelection?.itemIdentifier == identifier
                        && textSelection?.region == textRegionID ? textSelection?.range : nil,
                    revealedSpoilerLocations: revealedTextSpoilerLocations(
                        messageID: messageID,
                        region: textRegionID,
                        value: textRegion.text.value,
                        layout: layout
                    )
                )
            }
        }
    }

    private func appendAnimatedComponentMediaOverlays(
        _ component: NativeTimelineComponentLayout,
        componentIndex: Int,
        identifier: NativeMessageTimelineItem.Identifier,
        accumulator: AnimatedMediaOverlayAccumulator
    ) {
        for image in component.images
        where Self.isPotentiallyAnimated(image.displayURL) {
            accumulator.append(
                row: identifier,
                role: .componentImage(componentIndex, image.componentID),
                media: .media(
                    image.displayURL,
                    maximumPixelDimension: image.maximumPixelDimension
                ),
                frame: image.frame,
                cornerRadius: image.cornerRadius,
                isLooping: false,
                fillsFrame: true
            )
        }
        for media in component.media
        where !media.isVideo && Self.isPotentiallyAnimated(media.displayURL) {
            accumulator.append(
                row: identifier,
                role: .componentMedia(componentIndex, media.componentID),
                media: .media(media.displayURL),
                frame: media.frame,
                cornerRadius: DiscordRichMessageMetrics.px(8),
                isLooping: true,
                fillsFrame: true
            )
        }
    }

    private func appendAnimatedComponentContentOverlays(
        _ component: NativeTimelineComponentLayout,
        componentIndex: Int,
        messageID: MessageID,
        identifier: NativeMessageTimelineItem.Identifier,
        layout: NativeTimelineRowLayout,
        accumulator: AnimatedMediaOverlayAccumulator
    ) {
        for (textIndex, textRegion) in component.textRegions.enumerated() {
            var drawingFrame = textRegion.frame
            drawingFrame.size.height += textRegion.text.layoutHeightAdjustment
            let textRegionID = NativeTimelineTextRegion.component(
                layoutIndex: componentIndex,
                textIndex: textIndex
            )
            accumulator.appendInlineEmoji(
                row: identifier,
                role: { _, location in
                    .componentEmoji(componentIndex, textIndex, location)
                },
                value: textRegion.text.value,
                framesetter: textRegion.text.framesetter,
                frame: drawingFrame,
                selectionRange: textSelection?.itemIdentifier == identifier
                    && textSelection?.region == textRegionID ? textSelection?.range : nil,
                revealedSpoilerLocations: revealedTextSpoilerLocations(
                    messageID: messageID,
                    region: textRegionID,
                    value: textRegion.text.value,
                    layout: layout
                )
            )
        }
        for button in component.buttons {
            guard let emoji = button.emoji,
                  emoji.isAnimated,
                  let url = emoji.imageURL(size: 32)
            else { continue }
            let size = DiscordComponentEmojiMetrics.buttonSize
            let box = CGRect(
                x: button.contentMinX,
                y: button.frame.midY - size / 2,
                width: size,
                height: size
            )
            let opticalInset = (size - DiscordComponentEmojiMetrics.opticalSize(for: size)) / 2
            accumulator.append(
                row: identifier,
                role: .componentButton(componentIndex, button.componentID),
                media: .media(url, maximumPixelDimension: 64),
                frame: box.insetBy(dx: opticalInset, dy: opticalInset),
                cornerRadius: InterfaceScale.metric(3),
                isLooping: true,
                opacity: button.opacity
            )
        }
    }

    private func appendAnimatedStickerAndReactionOverlays(
        row: MessageRowPresentation,
        identifier: NativeMessageTimelineItem.Identifier,
        layout: NativeTimelineRowLayout,
        accumulator: AnimatedMediaOverlayAccumulator
    ) {
        for (stickerIndex, sticker) in row.message.stickers.enumerated()
        where sticker.format?.isAnimated == true {
            guard layout.stickerFrames.indices.contains(stickerIndex),
                  let url = sticker.mediaURL
            else { continue }
            accumulator.append(
                row: identifier,
                role: .sticker(sticker.id),
                media: .media(url, maximumPixelDimension: 384),
                frame: layout.stickerFrames[stickerIndex],
                cornerRadius: InterfaceScale.metric(8),
                isLooping: true,
                opacity: CGFloat(MessageOutboxPresentation.mediaOpacity(
                    for: row.message.outboxState
                ))
            )
        }
        for reaction in layout.reactionRegions {
            let reference = reaction.reaction.emojiReference
            guard reference.isAnimated,
                  let url = reference.id.flatMap({ model?.customEmojiURLsByID[$0] })
                    ?? reference.imageURL(size: 64)
            else { continue }
            accumulator.append(
                row: identifier,
                role: .reaction(reaction.reaction.id),
                media: .media(url, maximumPixelDimension: 64),
                frame: reaction.emojiFrame,
                cornerRadius: 0,
                isLooping: true
            )
        }
    }

    private func applyAnimatedMediaOverlays(
        _ desired: [DesiredAnimatedMediaOverlay]
    ) {
        let desiredKeys = Set(desired.map(\.key))
        let changedKeys = Set(animatedMediaOverlays.keys).symmetricDifference(desiredKeys)
        defer { invalidateOverlaidPosters(for: changedKeys) }
        for key in Array(animatedMediaOverlays.keys)
        where !desiredKeys.contains(key) {
            animatedMediaOverlays.removeValue(forKey: key)?
                .removeFromSuperview()
        }

        var didCreateOverlay = false
        for item in desired {
            let rowOrigin: CGFloat
            guard let rowIndex = items.firstIndex(where: {
                $0.identifier == item.key.row
            }) else { continue }
            rowOrigin = displayedRowOrigin(at: rowIndex)
            let mediaFrame = item.mediaFrame.offsetBy(
                dx: 0,
                dy: rowOrigin
            )
            let selectionFrame = item.selectionFrame?.offsetBy(
                dx: 0,
                dy: rowOrigin
            )
            let hostFrame = selectionFrame.map {
                mediaFrame.union($0)
            } ?? mediaFrame
            let localMediaFrame = mediaFrame.offsetBy(
                dx: -hostFrame.minX,
                dy: -hostFrame.minY
            )
            let localSelectionFrame = selectionFrame?.offsetBy(
                dx: -hostFrame.minX,
                dy: -hostFrame.minY
            )
            let overlay: NativeTimelineAnimatedMediaOverlay
            if let existing = animatedMediaOverlays[item.key] {
                overlay = existing
            } else {
                overlay = NativeTimelineAnimatedMediaOverlay(
                    frame: hostFrame
                )
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                animatedMediaOverlays[item.key] = overlay
                didCreateOverlay = true
            }
            overlay.frame = hostFrame
            overlay.setHoverPlaybackEnabled(
                !item.key.role.playsOnHover || hoveredRow == rowIndex
            )
            overlay.setPlaybackSuppressed(suppressesHoverPresentation)
            overlay.display(
                item.image,
                mediaFrame: localMediaFrame,
                selectionFrame: localSelectionFrame,
                cornerRadius: item.cornerRadius,
                isLooping: item.isLooping,
                opacity: item.opacity,
                fillsFrame: item.fillsFrame
            )
        }
        if didCreateOverlay {
            // A decoration can decode before its avatar (or vice versa).
            // Restore the desired order whenever a late result creates a new
            // overlay so decorations always remain above avatar frames while
            // the media viewer remains the topmost interaction surface.
            for item in desired {
                guard let overlay = animatedMediaOverlays[item.key] else {
                    continue
                }
                overlay.removeFromSuperview()
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
            }
        }
        // Animated frames are native subviews while spoiler materials are
        // separate native overlays. Loading may complete after the spoiler
        // was installed, so restore the required preview < animation <
        // spoiler stacking order deterministically.
        for spoiler in spoilerOverlays.values {
            addSubview(
                spoiler,
                positioned: .below,
                relativeTo: mediaViewerHost
            )
        }

    }

    func updateAvatarPlayback() {
        let hoveredIdentifier = hoveredRow.flatMap {
            items.indices.contains($0) ? items[$0].identifier : nil
        }
        for (key, overlay) in animatedMediaOverlays where key.role.playsOnHover {
            overlay.setHoverPlaybackEnabled(key.row == hoveredIdentifier && !suppressesHoverPresentation)
        }
    }

    func positionAnimatedMediaOverlays() {
        guard !animatedMediaOverlays.isEmpty else { return }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reconcileAnimatedMediaOverlays(reduceMotion: reduceMotion)
    }

    /// The row's live reactions, stickers and button emoji, whose still
    /// copies the row leaves out: their transparent frames would show the
    /// still through.
    func animatedOverlayRoles(for row: NativeMessageTimelineItem.Identifier) -> Set<AnimatedMediaOverlayRole> {
        Set(animatedMediaOverlays.keys.compactMap { key in
            guard key.row == row, key.role.replacesPoster else { return nil }
            return key.role
        })
    }

    private func invalidateOverlaidPosters(for keys: Set<AnimatedMediaOverlayKey>) {
        let rows = Set(keys.compactMap { key -> NativeMessageTimelineItem.Identifier? in
            key.role.replacesPoster ? key.row : nil
        })
        for row in rows {
            invalidateBitmap(row)
            if let index = items.firstIndex(where: { $0.identifier == row }) {
                setNeedsDisplay(rowFrame(at: index))
            }
        }
    }

    func removeAnimatedMediaOverlays() {
        let removedKeys = Set(animatedMediaOverlays.keys)
        for overlay in animatedMediaOverlays.values {
            overlay.removeFromSuperview()
        }
        animatedMediaOverlays.removeAll()
        invalidateOverlaidPosters(for: removedKeys)
    }

    static let maximumActivityIndicatorCount = 32

    func reconcileActivityIndicators() {
        reconcileInboxHeaders()
        reconcileUploadRings()
        positionUnreadDividerFades()
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeActivityIndicators()
            return
        }

        var desired: [ActivityIndicatorKey: NativeTimelineRowLayout.ActivityIndicator] = [:]
        desired.reserveCapacity(Self.maximumActivityIndicatorCount)
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY,
              desired.count < Self.maximumActivityIndicatorCount
        {
            if layouts.indices.contains(index),
               !hidesRowForSendTransition(items[index].identifier)
            {
                let origin = displayedRowOrigin(at: index)
                for (position, indicator) in layouts[index].activityIndicators.enumerated() {
                    desired[ActivityIndicatorKey(row: items[index].identifier, index: position)] = .init(
                        frame: indicator.frame.offsetBy(dx: 0, dy: origin),
                        style: indicator.style
                    )
                }
            }
            index += 1
        }

        for (key, view) in activityIndicators
        where desired[key].map({ !Self.view(view, matches: $0.style) }) ?? true {
            view.removeFromSuperview()
            activityIndicators.removeValue(forKey: key)
        }
        for (key, indicator) in desired {
            let view = activityIndicators[key] ?? {
                let view = Self.makeActivityIndicator(indicator.style)
                addSubview(view, positioned: .below, relativeTo: mediaViewerHost)
                activityIndicators[key] = view
                return view
            }()
            view.frame = indicator.frame
        }
    }

    private static func makeActivityIndicator(_ style: NativeTimelineRowLayout.ActivityIndicator.Style) -> NSView {
        switch style {
        case .spinner:
            let spinner = NativeTimelineLoadingIndicator(frame: .zero)
            spinner.controlSize = .small
            return spinner
        case let .dots(tone):
            let dots = InteractionLoadingDots(frame: .zero)
            dots.tone = tone
            return dots
        }
    }

    private static func view(_ view: NSView, matches style: NativeTimelineRowLayout.ActivityIndicator.Style) -> Bool {
        switch style {
        case .spinner: view is NativeTimelineLoadingIndicator
        case let .dots(tone): (view as? InteractionLoadingDots)?.tone == tone
        }
    }

    func removeActivityIndicators() {
        for view in activityIndicators.values {
            view.removeFromSuperview()
        }
        activityIndicators.removeAll()
        removeUploadRings()
    }

    static let maximumInlineVideoOverlayCount = 4

    struct DesiredInlineVideoOverlay {
        let key: InlineVideoOverlayKey
        let frame: CGRect
        let placeholder: NativeTimelineMediaPlaceholder?
    }

    func reconcileInlineVideoOverlays(plays: Bool) {
        var desired: [DesiredInlineVideoOverlay] = []
        desired.reserveCapacity(Self.maximumInlineVideoOverlayCount)

        guard var index = rowIndex(at: max(0, visibleRect.minY)) else {
            removeInlineVideoOverlays()
            return
        }
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            let identifier = items[index].identifier
            if let urls = inlineVideoRows[identifier],
               layouts.indices.contains(index)
            {
                for region in layouts[index].embedRegions {
                    guard region.mediaIsVideo,
                          region.mediaAutoplaysInline,
                          let url = region.mediaURL,
                          urls.contains(url),
                          let frame = region.mediaFrame
                    else { continue }
                    desired.append(DesiredInlineVideoOverlay(
                        key: InlineVideoOverlayKey(
                            row: identifier,
                            embedID: region.embedID,
                            url: url
                        ),
                        frame: frame.offsetBy(
                            dx: 0,
                            dy: displayedRowOrigin(at: index)
                        ),
                        placeholder: region.mediaPlaceholder
                    ))
                    if desired.count == Self.maximumInlineVideoOverlayCount {
                        break
                    }
                }
            }
            if desired.count == Self.maximumInlineVideoOverlayCount {
                break
            }
            index += 1
        }

        let desiredKeys = Set(desired.map(\.key))
        for key in Array(inlineVideoOverlays.keys)
        where !desiredKeys.contains(key) {
            guard let overlay = inlineVideoOverlays.removeValue(forKey: key)
            else { continue }
            overlay.stop()
            overlay.removeFromSuperview()
        }
        for item in desired {
            let key = item.key
            let frame = item.frame
            let overlay: NativeTimelineInlineVideoOverlay
            if let existing = inlineVideoOverlays[key] {
                overlay = existing
            } else {
                overlay = NativeTimelineInlineVideoOverlay(frame: frame)
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                inlineVideoOverlays[key] = overlay
            }
            overlay.frame = frame
            overlay.placeholder = item.placeholder?.image
            overlay.display(key.url, plays: plays)
        }
    }

    func positionInlineVideoOverlays() {
        var removed: [InlineVideoOverlayKey] = []
        for (key, overlay) in inlineVideoOverlays {
            guard let index = items.firstIndex(where: {
                $0.identifier == key.row
            }),
               layouts.indices.contains(index),
               let frame = layouts[index].embedRegions.first(where: {
                   $0.embedID == key.embedID
                       && $0.mediaURL == key.url
               })?.mediaFrame
            else {
                overlay.stop()
                overlay.removeFromSuperview()
                removed.append(key)
                continue
            }
            overlay.frame = frame.offsetBy(
                dx: 0,
                dy: displayedRowOrigin(at: index)
            )
        }
        for key in removed {
            inlineVideoOverlays[key] = nil
        }
        reconcileInlinePlayers()
    }

    func removeInlineVideoOverlays() {
        for overlay in inlineVideoOverlays.values {
            overlay.stop()
            overlay.removeFromSuperview()
        }
        inlineVideoOverlays.removeAll()
        removeInlinePlayers()
    }

    /// Plays a video in place over its tile, as Discord does. When the
    /// player's menu asks for the viewer, `openInViewer` receives the row as it
    /// is then: an edit may have changed the message's other media.
    func playInline(
        _ url: URL, mediaID: String, frame: CGRect, rowIndex: Int,
        openInViewer: @escaping (_ rowIndex: Int, _ layout: NativeTimelineRowLayout, _ message: Message) -> Void
    ) {
        let key = NativeTimelineInlinePlayer.Key(row: items[rowIndex].identifier, mediaID: mediaID)
        guard inlinePlayers[key] == nil else { return }
        let player = NativeTimelineInlinePlayer(
            url: url,
            frame: frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: rowIndex))
        ) { [weak self] in
            guard let self, let index = self.rowIndex(forIdentifier: key.row), layouts.indices.contains(index),
                  let message = items[index].messageRow?.message
            else { return }
            openInViewer(index, layouts[index], message)
        }
        addSubview(player, positioned: .below, relativeTo: mediaViewerHost)
        inlinePlayers[key] = player
    }

    /// Players follow their tiles and pause once out of view. One ends when
    /// its row leaves the timeline, its tile no longer shows that video, or
    /// its message is being edited, whose editor shows no media.
    func reconcileInlinePlayers() {
        guard !inlinePlayers.isEmpty else { return }
        let viewport = enclosingScrollView?.documentVisibleRect ?? visibleRect
        for (key, player) in inlinePlayers {
            guard let index = rowIndex(forIdentifier: key.row),
                  layouts.indices.contains(index),
                  editingMessageID == nil || items[index].messageID != editingMessageID,
                  let frame = inlinePlayerFrame(key.mediaID, url: player.url, in: layouts[index])
            else {
                player.stop()
                player.removeFromSuperview()
                inlinePlayers[key] = nil
                continue
            }
            player.frame = frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
            if !player.frame.intersects(viewport) { player.pause() }
        }
    }

    /// The tile still showing the player's video. Signed URLs refresh their
    /// query, so the host and path identify the media.
    private func inlinePlayerFrame(_ mediaID: String, url: URL, in layout: NativeTimelineRowLayout) -> CGRect? {
        func isSameMedia(_ other: URL) -> Bool { other.host == url.host && other.path == url.path }
        if let region = layout.attachmentRegions.first(where: { $0.attachment.id == mediaID }) {
            let attachment = region.attachment
            return attachment.mediaKind == .video && isSameMedia(attachment.proxyURL ?? attachment.url) ? region.frame : nil
        }
        return layout.componentLayouts.lazy.flatMap(\.media)
            .first { $0.componentID == mediaID && $0.isVideo && isSameMedia($0.displayURL) }?.frame
    }

    func removeInlinePlayers() {
        for player in inlinePlayers.values {
            player.stop()
            player.removeFromSuperview()
        }
        inlinePlayers.removeAll()
    }

    struct DesiredSpoilerOverlay {
        let key: NativeTimelineComponentRevealKey
        let frame: CGRect
        let presentation: NativeTimelineSpoilerOverlayPresentation
    }

    func reconcileSpoilerOverlays() {
        let desired = desiredSpoilerOverlays()
        applySpoilerOverlays(desired)
        // Revealing a file card uncovers its upload ring.
        reconcileUploadRings()
    }

    private func desiredSpoilerOverlays() -> [DesiredSpoilerOverlay] {
        var desired: [DesiredSpoilerOverlay] = []
        desired.reserveCapacity(16)
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeSpoilerOverlays()
            return []
        }

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            guard layouts.indices.contains(index),
                  case let .message(row, _, _) = items[index],
                  !hidesRowForSendTransition(items[index].identifier)
            else {
                index += 1
                continue
            }
            let message = row.message
            let rowOrigin = displayedRowOrigin(at: index)
            appendAttachmentSpoilerOverlays(
                for: message,
                layout: layouts[index],
                rowOrigin: rowOrigin,
                into: &desired
            )
            for component in layouts[index].componentLayouts {
                appendComponentSpoilerOverlays(
                    for: component,
                    messageID: message.id,
                    rowOrigin: rowOrigin,
                    into: &desired
                )
            }
            index += 1
        }
        return desired
    }

    private func appendAttachmentSpoilerOverlays(
        for message: Message,
        layout: NativeTimelineRowLayout,
        rowOrigin: CGFloat,
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        for region in layout.attachmentRegions where region.attachment.isSpoiler {
            appendDesiredSpoilerOverlay(
                .attachment(messageID: message.id, attachmentID: region.attachment.id),
                frame: region.frame,
                cornerRadius: InterfaceScale.metric(8),
                rowOrigin: rowOrigin,
                into: &desired
            )
        }
    }

    private func appendComponentSpoilerOverlays(
        for component: NativeTimelineComponentLayout,
        messageID: MessageID,
        rowOrigin: CGFloat,
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        let hiddenContainerFrames =
            NativeTimelineSpoilerConcealmentPolicy.hiddenContainerFrames(
                in: component,
                messageID: messageID,
                store: spoilerRevealStore
            )
        appendContainerSpoilerOverlays(
            component,
            messageID: messageID,
            rowOrigin: rowOrigin,
            hiddenContainerFrames: hiddenContainerFrames,
            into: &desired
        )
        appendComponentMediaSpoilerOverlays(
            component,
            messageID: messageID,
            rowOrigin: rowOrigin,
            hiddenContainerFrames: hiddenContainerFrames,
            into: &desired
        )
    }

    private func appendContainerSpoilerOverlays(
        _ component: NativeTimelineComponentLayout,
        messageID: MessageID,
        rowOrigin: CGFloat,
        hiddenContainerFrames: [CGRect],
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        for container in component.containers
        where hiddenContainerFrames.contains(container.frame) {
            appendDesiredSpoilerOverlay(
                NativeTimelineComponentRevealKey(
                    messageID: messageID,
                    componentID: container.componentID
                ),
                frame: container.frame,
                cornerRadius: container.cornerRadius,
                rowOrigin: rowOrigin,
                into: &desired
            )
        }
    }

    private func appendComponentMediaSpoilerOverlays(
        _ component: NativeTimelineComponentLayout,
        messageID: MessageID,
        rowOrigin: CGFloat,
        hiddenContainerFrames: [CGRect],
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        for region in component.images where shouldOverlaySpoiler(
            region.isSpoiler,
            frame: region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            appendDesiredSpoilerOverlay(
                NativeTimelineComponentRevealKey(
                    messageID: messageID,
                    componentID: region.componentID
                ),
                frame: region.frame,
                cornerRadius: region.cornerRadius,
                rowOrigin: rowOrigin,
                into: &desired
            )
        }
        for region in component.media where shouldOverlaySpoiler(
            region.isSpoiler,
            frame: region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            appendDesiredSpoilerOverlay(
                NativeTimelineComponentRevealKey(
                    messageID: messageID,
                    componentID: region.componentID
                ),
                frame: region.frame,
                cornerRadius: InterfaceScale.metric(8),
                rowOrigin: rowOrigin,
                into: &desired
            )
        }
        for region in component.files where shouldOverlaySpoiler(
            region.isSpoiler,
            frame: region.frame,
            hiddenContainerFrames: hiddenContainerFrames
        ) {
            appendDesiredSpoilerOverlay(
                NativeTimelineComponentRevealKey(
                    messageID: messageID,
                    componentID: region.componentID
                ),
                frame: region.frame,
                cornerRadius: DiscordRichMessageMetrics.cardCornerRadius,
                rowOrigin: rowOrigin,
                into: &desired
            )
        }
    }

    private func shouldOverlaySpoiler(
        _ isSpoiler: Bool,
        frame: CGRect,
        hiddenContainerFrames: [CGRect]
    ) -> Bool {
        isSpoiler && !isInsideSpoilerContainer(
            frame,
            hiddenContainerFrames: hiddenContainerFrames
        )
    }

    private func isInsideSpoilerContainer(
        _ frame: CGRect,
        hiddenContainerFrames: [CGRect]
    ) -> Bool {
        hiddenContainerFrames.contains {
            $0.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private func appendDesiredSpoilerOverlay(
        _ key: NativeTimelineComponentRevealKey,
        frame: CGRect,
        cornerRadius: CGFloat,
        rowOrigin: CGFloat,
        into desired: inout [DesiredSpoilerOverlay]
    ) {
        guard !spoilerRevealStore.isMediaRevealed(key) else { return }
        desired.append(DesiredSpoilerOverlay(
            key: key,
            frame: frame.offsetBy(dx: 0, dy: rowOrigin),
            presentation: NativeTimelineSpoilerOverlayPresentation(cornerRadius: cornerRadius)
        ))
    }

    private func applySpoilerOverlays(_ desired: [DesiredSpoilerOverlay]) {
        let desiredKeys = Set(desired.map(\.key))
        for key in Array(spoilerOverlays.keys)
        where !desiredKeys.contains(key) {
            spoilerOverlays.removeValue(forKey: key)?.removeFromSuperview()
            spoilerOverlayPresentations[key] = nil
        }
        for item in desired {
            let overlay: NativeTimelineSpoilerOverlayHost
            if let existing = spoilerOverlays[item.key],
               spoilerOverlayPresentations[item.key] == item.presentation
            {
                overlay = existing
            } else {
                spoilerOverlays.removeValue(forKey: item.key)?
                    .removeFromSuperview()
                overlay = NativeTimelineSpoilerOverlayHost(
                    frame: item.frame,
                    cornerRadius: item.presentation.cornerRadius
                ) { [weak self] in
                    self?.reveal(item.key)
                }
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                spoilerOverlays[item.key] = overlay
                spoilerOverlayPresentations[item.key] = item.presentation
            }
            overlay.frame = item.frame
        }
    }

    func positionSpoilerOverlays() {
        guard !spoilerOverlays.isEmpty else { return }
        reconcileSpoilerOverlays()
    }

    func removeSpoilerOverlays() {
        for overlay in spoilerOverlays.values {
            overlay.removeFromSuperview()
        }
        spoilerOverlays.removeAll()
        spoilerOverlayPresentations.removeAll()
    }

}
