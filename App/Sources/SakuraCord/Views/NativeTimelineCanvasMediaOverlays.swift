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
            isApplicationActive: NSApp.isActive,
            isWindowVisible: window?.occlusionState.contains(.visible) == true,
            reduceMotion: false,
            reduceAnimatedMedia: false
        )
    }

    @objc
    func mediaPlaybackVisibilityDidChange(_ notification: Notification) {
        if let changedWindow = notification.object as? NSWindow,
           changedWindow !== window
        {
            return
        }
        reconcileAnimatedMedia(allowsScrolling: true)
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceAnimatedMedia")
            || !permitsAnimatedMediaPlayback
        reconcileInlineVideoOverlays(plays: !reduceMotion)
        reconcileLottieStickerOverlays(reduceMotion: reduceMotion)
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
        guard !suppressesHoverPresentation else { return }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceAnimatedMedia")
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
            guard layouts.indices.contains(index) else {
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
        reconcileInlineVideoOverlays(plays: !reduceMotion)
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

    static let maximumAnimatedMediaOverlayCount = 48

    var mediaOverlayReconciliationOperation: @MainActor (Bool) -> Void {
        { [self] reduceMotion in
        guard !reduceMotion,
              !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeAnimatedMediaOverlays()
            return
        }

        var desired: [DesiredAnimatedMediaOverlay] = []
        desired.reserveCapacity(Self.maximumAnimatedMediaOverlayCount)

        @MainActor
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
                : NativeTimelineMediaStore.shared
                    .decodedAnimatedImage(for: media)
            guard desired.count < Self.maximumAnimatedMediaOverlayCount,
                  animatedMediaRows[row]?.contains(media) == true,
                  let image
            else { return }
            desired.append(DesiredAnimatedMediaOverlay(
                key: AnimatedMediaOverlayKey(
                    row: row,
                    role: role,
                    media: media
                ),
                mediaFrame: frame,
                selectionFrame: selectionFrame,
                cornerRadius: cornerRadius,
                isLooping: isLooping,
                opacity: opacity,
                fillsFrame: fillsFrame,
                image: image
            ))
        }

        @MainActor
        func appendInlineEmoji(
            row: NativeMessageTimelineItem.Identifier,
            role: (Int, Int) -> AnimatedMediaOverlayRole,
            value: NSAttributedString,
            framesetter: CTFramesetter,
            frame: CGRect,
            selectionRange: NSRange?
        ) {
            for (ordinal, region) in NativeTimelineInlineEmojiGeometry.regions(
                in: value,
                framesetter: framesetter,
                frame: frame,
                selectionRange: selectionRange
            ).enumerated() {
                let reference = EmojiReference(rawToken: region.rawToken)
                guard reference.isAnimated,
                      let url = reference.id.flatMap({
                          model?.customEmojiURLsByID[$0]
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

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY,
              desired.count < Self.maximumAnimatedMediaOverlayCount
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

            let author =
                model?.authorPresentation(for: row.message).user
                ?? row.message.author
            if let frame = layout.avatarFrame {
                if let url =
                    author.avatarURL
                        ?? row.message.author.avatarURL,
                   NativeTimelineAvatarPresentation
                    .shouldDecodeAnimation(for: url)
                {
                    append(
                        row: identifier,
                        role: .authorAvatar,
                        media: .avatar(url),
                        frame: frame,
                        cornerRadius: frame.width / 2,
                        isLooping: true,
                        fillsFrame: true
                    )
                }
                if let decorationURL =
                    author.avatarDecorationURL
                        ?? row.message.author.avatarDecorationURL
                {
                    append(
                        row: identifier,
                        role: .authorAvatarDecoration,
                        media: .avatarDecoration(decorationURL),
                        frame:
                            NativeTimelineAvatarPresentation
                                .decorationFrame(around: frame),
                        cornerRadius: 0,
                        isLooping: true,
                        allowsStaticImage: true
                    )
                }
            }
            if let preview = row.replyPreview,
               let url = preview.author.avatarURL,
               let replyContentFrame = layout.replyContentFrame,
               NativeTimelineAvatarPresentation
                .shouldDecodeAnimation(for: url)
            {
                let frame =
                    NativeTimelineAvatarPresentation
                        .replyAvatarFrame(in: replyContentFrame)
                append(
                    row: identifier,
                    role: .replyAvatar,
                    media: .avatar(url),
                    frame: frame,
                    cornerRadius: frame.width / 2,
                    isLooping: true,
                    fillsFrame: true
                )
            }
            if let frame = layout.commandInvocationRegion?.avatarFrame,
               let url = row.message.interactionMetadata?.user?.avatarURL,
               NativeTimelineAvatarPresentation
                .shouldDecodeAnimation(for: url)
            {
                append(
                    row: identifier,
                    role: .invocationAvatar,
                    media: .avatar(url),
                    frame: frame,
                    cornerRadius: frame.width / 2,
                    isLooping: true,
                    fillsFrame: true
                )
            }
            for reaction in layout.reactionRegions {
                for (avatarIndex, avatar) in
                    reaction.avatarRegions.enumerated()
                {
                    guard let url = avatar.reactor.avatarURL,
                          NativeTimelineAvatarPresentation
                            .shouldDecodeAnimation(for: url)
                    else { continue }
                    append(
                        row: identifier,
                        role: .reactionAvatar(
                            reaction.reaction.id,
                            avatarIndex
                        ),
                        media: .avatar(url),
                        frame: avatar.frame,
                        cornerRadius: avatar.frame.width / 2,
                        isLooping: true,
                        fillsFrame: true
                    )
                }
            }

            for (linkedIndex, region) in
                layout.linkedImageRegions.enumerated()
            where Self.isPotentiallyAnimated(region.reference.displayURL) {
                append(
                    row: identifier,
                    role: .linkedImage(linkedIndex),
                    media: .media(
                        region.reference.displayURL,
                        maximumPixelDimension:
                            region.reference.isEmoji ? 96 : 720
                    ),
                    frame: region.frame,
                    cornerRadius: region.reference.isEmoji ? 7 : 10,
                    isLooping: true
                )
            }

            let attachmentFillsFrame =
                MediaGalleryImagePresentation.fillsFrame(
                    itemCount: layout.attachmentRegions.count
                )
            for region in layout.attachmentRegions
            where region.attachment.mediaKind == .animatedImage {
                append(
                    row: identifier,
                    role: .attachment(region.attachment.id),
                    media: NativeTimelineMediaKey.attachment(
                        region.attachment
                    ) ?? .media(region.attachment.url),
                    frame: region.frame,
                    cornerRadius: 8,
                    isLooping: true,
                    opacity: CGFloat(
                        MessageOutboxPresentation.mediaOpacity(
                            for: row.message.outboxState
                        )
                    ),
                    fillsFrame: attachmentFillsFrame
                )
            }

            if let contentFrame = layout.contentFrame,
               let attributedContent = layout.attributedContent,
               let framesetter = layout.contentFramesetter
            {
                let drawingFrame = NativeTimelineTextGeometry
                    .messageContentDrawingFrame(contentFrame)
                appendInlineEmoji(
                    row: identifier,
                    role: { _, location in .messageEmoji(location) },
                    value: attributedContent,
                    framesetter: framesetter,
                    frame: drawingFrame,
                    selectionRange:
                        textSelection?.itemIdentifier
                            == .message(row.message.id)
                            && textSelection?.region == .content
                            ? textSelection?.range
                            : nil
                )
            }

            for embed in layout.embedRegions {
                for (imageIndex, imageRegion) in
                    embed.imageRegions.enumerated()
                where Self.isPotentiallyAnimated(imageRegion.url) {
                    append(
                        row: identifier,
                        role: .embedImage(embed.embedID, imageIndex),
                        media: .media(
                            imageRegion.url,
                            maximumPixelDimension:
                                imageRegion.maximumPixelDimension
                        ),
                        frame: imageRegion.frame,
                        cornerRadius: imageRegion.cornerRadius,
                        isLooping: false
                    )
                }
                if !embed.mediaIsVideo,
                   let mediaURL = embed.mediaURL,
                   let mediaFrame = embed.mediaFrame,
                   Self.isPotentiallyAnimated(mediaURL)
                {
                    append(
                        row: identifier,
                        role: .embedMedia(embed.embedID),
                        media: .media(mediaURL),
                        frame: mediaFrame,
                        cornerRadius: 8,
                        isLooping: true
                    )
                }
                for (textIndex, textRegion) in
                    embed.textRegions.enumerated()
                {
                    var drawingFrame = textRegion.frame
                    drawingFrame.size.height +=
                        textRegion.text.layoutHeightAdjustment
                    appendInlineEmoji(
                        row: identifier,
                        role: { _, location in
                            .embedEmoji(
                                embed.embedID,
                                textIndex,
                                location
                            )
                        },
                        value: textRegion.text.value,
                        framesetter: textRegion.text.framesetter,
                        frame: drawingFrame,
                        selectionRange:
                            textSelection?.itemIdentifier
                                == .message(row.message.id)
                                && textSelection?.region == .embed(
                                    embedID: embed.embedID,
                                    textIndex: textIndex
                                )
                            ? textSelection?.range
                            : nil
                    )
                }
            }

            for (componentIndex, component) in
                layout.componentLayouts.enumerated()
            {
                for imageRegion in component.images
                where Self.isPotentiallyAnimated(
                    imageRegion.displayURL
                ) {
                    append(
                        row: identifier,
                        role: .componentImage(
                            componentIndex,
                            imageRegion.componentID
                        ),
                        media: .media(
                            imageRegion.displayURL,
                            maximumPixelDimension:
                                imageRegion.maximumPixelDimension
                        ),
                        frame: imageRegion.frame,
                        cornerRadius: imageRegion.cornerRadius,
                        isLooping: false
                    )
                }
                for mediaRegion in component.media
                where !mediaRegion.isVideo
                    && Self.isPotentiallyAnimated(
                        mediaRegion.displayURL
                    )
                {
                    append(
                        row: identifier,
                        role: .componentMedia(
                            componentIndex,
                            mediaRegion.componentID
                        ),
                        media: .media(mediaRegion.displayURL),
                        frame: mediaRegion.frame,
                        cornerRadius: 8,
                        isLooping: true
                    )
                }
                for (textIndex, textRegion) in
                    component.textRegions.enumerated()
                {
                    var drawingFrame = textRegion.frame
                    drawingFrame.size.height +=
                        textRegion.text.layoutHeightAdjustment
                    appendInlineEmoji(
                        row: identifier,
                        role: { _, location in
                            .componentEmoji(
                                componentIndex,
                                textIndex,
                                location
                            )
                        },
                        value: textRegion.text.value,
                        framesetter: textRegion.text.framesetter,
                        frame: drawingFrame,
                        selectionRange:
                            textSelection?.itemIdentifier
                                == .message(row.message.id)
                                && textSelection?.region == .component(
                                    layoutIndex: componentIndex,
                                    textIndex: textIndex
                                )
                            ? textSelection?.range
                            : nil
                    )
                }
                for button in component.buttons {
                    guard let emoji = button.emoji,
                          emoji.isAnimated,
                          let url = emoji.imageURL(size: 32)
                    else { continue }
                    let box = CGRect(
                        x: button.frame.minX + 12,
                        y: button.frame.midY
                            - DiscordComponentEmojiMetrics.buttonSize / 2,
                        width: DiscordComponentEmojiMetrics.buttonSize,
                        height: DiscordComponentEmojiMetrics.buttonSize
                    )
                    let opticalInset = (
                        DiscordComponentEmojiMetrics.buttonSize
                            - DiscordComponentEmojiMetrics.opticalSize(
                                for: DiscordComponentEmojiMetrics.buttonSize
                            )
                    ) / 2
                    append(
                        row: identifier,
                        role: .componentButton(
                            componentIndex,
                            button.componentID
                        ),
                        media: .media(
                            url,
                            maximumPixelDimension: 64
                        ),
                        frame: box.insetBy(
                            dx: opticalInset,
                            dy: opticalInset
                        ),
                        cornerRadius: 3,
                        isLooping: true
                    )
                }
            }

            for (stickerIndex, sticker) in
                row.message.stickers.enumerated()
            where sticker.format == .apng || sticker.format == .gif {
                guard layout.stickerFrames.indices.contains(stickerIndex),
                      let url = sticker.mediaURL
                else { continue }
                append(
                    row: identifier,
                    role: .sticker(sticker.id),
                    media: .media(
                        url,
                        maximumPixelDimension: 384
                    ),
                    frame: layout.stickerFrames[stickerIndex],
                    cornerRadius: 8,
                    isLooping: true
                )
            }

            for reaction in layout.reactionRegions {
                let reference = reaction.reaction.emojiReference
                guard reference.isAnimated,
                      let url = reference.id.flatMap({
                          model?.customEmojiURLsByID[$0]
                      }) ?? reference.imageURL(size: 64)
                else { continue }
                append(
                    row: identifier,
                    role: .reaction(reaction.reaction.id),
                    media: .media(
                        url,
                        maximumPixelDimension: 64
                    ),
                    frame: reaction.emojiFrame,
                    cornerRadius: 0,
                    isLooping: true
                )
            }
            index += 1
        }

        let desiredKeys = Set(desired.map(\.key))
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
    }

    func reconcileAnimatedMediaOverlays(reduceMotion: Bool) {
        mediaOverlayReconciliationOperation(reduceMotion)
    }

    func positionAnimatedMediaOverlays() {
        guard !animatedMediaOverlays.isEmpty else { return }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceAnimatedMedia")
        reconcileAnimatedMediaOverlays(reduceMotion: reduceMotion)
    }

    func removeAnimatedMediaOverlays() {
        for overlay in animatedMediaOverlays.values {
            overlay.removeFromSuperview()
        }
        animatedMediaOverlays.removeAll()
    }

    static let maximumLoadingIndicatorCount = 32

    func reconcileLoadingIndicators() {
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeLoadingIndicators()
            return
        }

        var desired:
            [NativeMessageTimelineItem.Identifier: CGRect] = [:]
        desired.reserveCapacity(Self.maximumLoadingIndicatorCount)
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY,
              desired.count < Self.maximumLoadingIndicatorCount
        {
            if layouts.indices.contains(index),
               let frame = layouts[index].loadingIndicatorFrame
            {
                desired[items[index].identifier] = frame.offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
            }
            index += 1
        }

        let desiredKeys = Set(desired.keys)
        for key in Array(loadingIndicators.keys)
        where !desiredKeys.contains(key) {
            loadingIndicators.removeValue(forKey: key)?
                .removeFromSuperview()
        }
        for (key, frame) in desired {
            let indicator: NativeTimelineLoadingIndicator
            if let existing = loadingIndicators[key] {
                indicator = existing
            } else {
                indicator = NativeTimelineLoadingIndicator(frame: frame)
                addSubview(
                    indicator,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                loadingIndicators[key] = indicator
            }
            if case .loader = key {
                indicator.controlSize = .small
            } else {
                indicator.controlSize = .mini
            }
            indicator.frame = frame
        }
    }

    func removeLoadingIndicators() {
        for indicator in loadingIndicators.values {
            indicator.removeFromSuperview()
        }
        loadingIndicators.removeAll()
    }

    static let maximumInlineVideoOverlayCount = 4

    func reconcileInlineVideoOverlays(plays: Bool) {
        var desired: [(InlineVideoOverlayKey, CGRect)] = []
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
                    desired.append((
                        InlineVideoOverlayKey(
                            row: identifier,
                            embedID: region.embedID,
                            url: url
                        ),
                        frame.offsetBy(
                            dx: 0,
                            dy: displayedRowOrigin(at: index)
                        )
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

        let desiredKeys = Set(desired.map(\.0))
        for key in Array(inlineVideoOverlays.keys)
        where !desiredKeys.contains(key) {
            guard let overlay = inlineVideoOverlays.removeValue(forKey: key)
            else { continue }
            overlay.stop()
            overlay.removeFromSuperview()
        }
        for (key, frame) in desired {
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
    }

    func removeInlineVideoOverlays() {
        for overlay in inlineVideoOverlays.values {
            overlay.stop()
            overlay.removeFromSuperview()
        }
        inlineVideoOverlays.removeAll()
    }

    static let maximumLottieStickerOverlayCount = 4

    func reconcileLottieStickerOverlays(reduceMotion: Bool) {
        var desired: [(LottieStickerOverlayKey, CGRect)] = []
        desired.reserveCapacity(Self.maximumLottieStickerOverlayCount)

        guard var index = rowIndex(at: max(0, visibleRect.minY)) else {
            removeLottieStickerOverlays()
            return
        }
        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            let identifier = items[index].identifier
            if let urls = lottieStickerRows[identifier],
               layouts.indices.contains(index),
               case let .message(row, _, _) = items[index]
            {
                for (sticker, frame) in zip(
                    row.message.stickers,
                    layouts[index].stickerFrames
                ) {
                    guard sticker.format == .lottie,
                          let url = sticker.mediaURL,
                          urls.contains(url)
                    else { continue }
                    desired.append((
                        LottieStickerOverlayKey(
                            row: identifier,
                            stickerID: sticker.id,
                            url: url
                        ),
                        frame.offsetBy(
                            dx: 0,
                            dy: displayedRowOrigin(at: index)
                        )
                    ))
                    if desired.count == Self.maximumLottieStickerOverlayCount {
                        break
                    }
                }
            }
            if desired.count == Self.maximumLottieStickerOverlayCount {
                break
            }
            index += 1
        }

        let desiredKeys = Set(desired.map(\.0))
        for key in Array(lottieStickerOverlays.keys)
        where !desiredKeys.contains(key) {
            guard let overlay = lottieStickerOverlays.removeValue(forKey: key)
            else { continue }
            overlay.stop()
            overlay.removeFromSuperview()
        }
        for (key, frame) in desired {
            let overlay: NativeTimelineLottieStickerOverlay
            if let existing = lottieStickerOverlays[key] {
                overlay = existing
            } else {
                overlay = NativeTimelineLottieStickerOverlay(frame: frame)
                addSubview(
                    overlay,
                    positioned: .below,
                    relativeTo: mediaViewerHost
                )
                lottieStickerOverlays[key] = overlay
            }
            overlay.frame = frame
            overlay.display(key.url, reduceMotion: reduceMotion)
        }
    }

    func positionLottieStickerOverlays() {
        var removed: [LottieStickerOverlayKey] = []
        for (key, overlay) in lottieStickerOverlays {
            guard let index = items.firstIndex(where: {
                $0.identifier == key.row
            }),
               layouts.indices.contains(index),
               case let .message(row, _, _) = items[index],
               let stickerIndex = row.message.stickers.firstIndex(where: {
                   $0.id == key.stickerID && $0.mediaURL == key.url
               }),
               layouts[index].stickerFrames.indices.contains(stickerIndex)
            else {
                overlay.stop()
                overlay.removeFromSuperview()
                removed.append(key)
                continue
            }
            overlay.frame = layouts[index].stickerFrames[stickerIndex]
                .offsetBy(
                    dx: 0,
                    dy: displayedRowOrigin(at: index)
                )
        }
        for key in removed {
            lottieStickerOverlays[key] = nil
        }
    }

    func removeLottieStickerOverlays() {
        for overlay in lottieStickerOverlays.values {
            overlay.stop()
            overlay.removeFromSuperview()
        }
        lottieStickerOverlays.removeAll()
    }

    struct DesiredSpoilerOverlay {
        let key: NativeTimelineComponentRevealKey
        let frame: CGRect
        let presentation: NativeTimelineSpoilerOverlayPresentation
    }

    var spoilerOverlayReconciliationOperation: @MainActor () -> Void {
        { [self] in
        var desired: [DesiredSpoilerOverlay] = []
        desired.reserveCapacity(16)
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, visibleRect.minY))
        else {
            removeSpoilerOverlays()
            return
        }

        @MainActor
        func append(
            _ key: NativeTimelineComponentRevealKey,
            frame: CGRect,
            cornerRadius: CGFloat,
            rowOrigin: CGFloat
        ) {
            guard !spoilerRevealStore.isMediaRevealed(key)
            else { return }
            desired.append(DesiredSpoilerOverlay(
                key: key,
                frame: frame.offsetBy(dx: 0, dy: rowOrigin),
                presentation: NativeTimelineSpoilerOverlayPresentation(
                    cornerRadius: cornerRadius
                )
            ))
        }

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < visibleRect.maxY
        {
            guard layouts.indices.contains(index),
                  case let .message(row, _, _) = items[index]
            else {
                index += 1
                continue
            }
            let message = row.message
            let rowOrigin = displayedRowOrigin(at: index)
            for region in layouts[index].attachmentRegions
            where region.attachment.isSpoiler {
                append(
                    .attachment(
                        messageID: message.id,
                        attachmentID: region.attachment.id
                    ),
                    frame: region.frame,
                    cornerRadius: 8,
                    rowOrigin: rowOrigin
                )
            }
            for component in layouts[index].componentLayouts {
                let hiddenContainerFrames =
                    NativeTimelineSpoilerConcealmentPolicy
                        .hiddenContainerFrames(
                            in: component,
                            messageID: message.id,
                            store: spoilerRevealStore
                        )
                for container in component.containers
                where hiddenContainerFrames.contains(container.frame) {
                    let key = NativeTimelineComponentRevealKey(
                        messageID: message.id,
                        componentID: container.componentID
                    )
                    append(
                        key,
                        frame: container.frame,
                        cornerRadius:
                            DiscordRichMessageMetrics.cardCornerRadius,
                        rowOrigin: rowOrigin
                    )
                }
                for region in component.images
                where region.isSpoiler
                    && !hiddenContainerFrames.contains(where: {
                        $0.contains(
                            CGPoint(
                                x: region.frame.midX,
                                y: region.frame.midY
                            )
                        )
                    }) {
                    append(
                        NativeTimelineComponentRevealKey(
                            messageID: message.id,
                            componentID: region.componentID
                        ),
                        frame: region.frame,
                        cornerRadius: region.cornerRadius,
                        rowOrigin: rowOrigin
                    )
                }
                for region in component.media
                where region.isSpoiler
                    && !hiddenContainerFrames.contains(where: {
                        $0.contains(
                            CGPoint(
                                x: region.frame.midX,
                                y: region.frame.midY
                            )
                        )
                    }) {
                    append(
                        NativeTimelineComponentRevealKey(
                            messageID: message.id,
                            componentID: region.componentID
                        ),
                        frame: region.frame,
                        cornerRadius: 8,
                        rowOrigin: rowOrigin
                    )
                }
                for region in component.files
                where region.isSpoiler
                    && !hiddenContainerFrames.contains(where: {
                        $0.contains(
                            CGPoint(
                                x: region.frame.midX,
                                y: region.frame.midY
                            )
                        )
                    }) {
                    append(
                        NativeTimelineComponentRevealKey(
                            messageID: message.id,
                            componentID: region.componentID
                        ),
                        frame: region.frame,
                        cornerRadius:
                            DiscordRichMessageMetrics.cardCornerRadius,
                        rowOrigin: rowOrigin
                    )
                }
            }
            index += 1
        }

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
    }

    func reconcileSpoilerOverlays() {
        spoilerOverlayReconciliationOperation()
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
