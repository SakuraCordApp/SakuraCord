import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    func requestMedia(
        for item: NativeMessageTimelineItem,
        at index: Int,
        preparedMediaKeys: Set<NativeTimelineMediaKey>? = nil,
        priority: MediaLoadPriority = .visible
    ) {
        let identifier = item.identifier
        let requestOwner = visibleMediaPinOwner
        let keys = preparedMediaKeys ?? mediaKeys(for: item, at: index)
        for key in keys {
            // Another row may have loaded this image since the draw queued
            // its request. The store skips cache hits without a callback.
            if NativeTimelineRowPainter.mediaImage(for: key) != nil {
                scheduleMediaInvalidation(identifier)
                continue
            }
            NativeTimelineMediaStore.shared.request(
                key,
                owner: requestOwner,
                subscriber: identifier,
                priority: priority
            ) { [weak self] _ in
                self?.scheduleMediaInvalidation(identifier)
            }
        }
    }

    func enqueueVisibleMediaRequests(
        identifier: NativeMessageTimelineItem.Identifier,
        keys: Set<NativeTimelineMediaKey>
    ) {
        // Record what the painter actually lacked, so cache-hit completion
        // repairs placeholders without repeatedly invalidating complete rows.
        let missingKeys = keys.filter {
            NativeTimelineRowPainter.mediaImage(for: $0) == nil
        }
        guard !missingKeys.isEmpty else { return }
        pendingVisibleMediaRequests[identifier, default: []]
            .formUnion(missingKeys)
        guard visibleMediaRequestTask == nil else { return }
        visibleMediaRequestTask = Task { @MainActor [weak self] in
            let interval = AppPerformanceSignposts.signposter.beginInterval(
                "TimelineVisibleMediaRequestDeferral"
            )
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    "TimelineVisibleMediaRequestDeferral",
                    interval
                )
            }
            do {
                // Missing media cannot affect the draw currently in progress.
                // Dispatching ImageIO from inside draw(_:) made decoder work
                // compete with the same cold frame on another core.
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return
            }
            guard let self else { return }
            self.visibleMediaRequestTask = nil
            let requests = self.pendingVisibleMediaRequests
            self.pendingVisibleMediaRequests.removeAll(keepingCapacity: true)
            let viewport = self.enclosingScrollView?.documentVisibleRect
                ?? self.visibleRect
            let priority: MediaLoadPriority =
                suppressesHoverPresentation || AppScrollActivity.isActive
                    ? .prefetch
                    : .visible
            for (identifier, keys) in requests {
                guard let index = self.items.firstIndex(where: {
                    $0.identifier == identifier
                }),
                self.rowFrame(at: index).intersects(viewport)
                else { continue }
                self.requestMedia(
                    for: self.items[index],
                    at: index,
                    preparedMediaKeys: keys,
                    priority: priority
                )
            }
        }
    }

    func reconcileVisibleReactionPreviewLoads() {
        let viewport =
            enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard window != nil,
              viewport.width > 0,
              viewport.height > 0,
              !items.isEmpty,
              !layouts.isEmpty,
              var index = rowIndex(at: max(0, viewport.minY))
        else {
            cancelReactionPreviewLoads()
            return
        }

        var desired:
            [ReactionPreviewLoadKey: (reaction: Reaction, message: Message)] = [:]
        while items.indices.contains(index),
              layouts.indices.contains(index),
              displayedRowOrigin(at: index) < viewport.maxY
        {
            if rowFrame(at: index).intersects(viewport),
               case let .message(row, _, _) = items[index]
            {
                let reactions = layouts[index].reactionRegions.map(\.reaction)
                for reaction in MessageReactionPresentation
                    .previewLoadCandidates(fromPresented: reactions)
                {
                    let key = ReactionPreviewLoadKey(
                        messageID: row.message.id,
                        reactionID: reaction.id
                    )
                    desired[key] = (reaction, row.message)
                }
            }
            index += 1
        }

        let obsolete = visibleReactionPreviewLoadKeys.subtracting(desired.keys)
        for key in obsolete {
            reactionPreviewLoadTasks.removeValue(forKey: key)?.cancel()
            visibleReactionPreviewLoadKeys.remove(key)
        }

        for (key, input) in desired
        where visibleReactionPreviewLoadKeys.insert(key).inserted
        {
            reactionPreviewLoadTasks[key] = Task { @MainActor [weak self] in
                guard let self,
                      self.visibleReactionPreviewLoadKeys.contains(key),
                      let model = self.model
                else { return }
                await model.loadReactionReactors(
                    input.reaction,
                    on: input.message
                )
            }
        }
    }

    func cancelReactionPreviewLoads() {
        for task in reactionPreviewLoadTasks.values {
            task.cancel()
        }
        reactionPreviewLoadTasks.removeAll(keepingCapacity: true)
        visibleReactionPreviewLoadKeys.removeAll(keepingCapacity: true)
    }

    func scheduleMediaInvalidation(
        _ identifier: NativeMessageTimelineItem.Identifier
    ) {
        pendingMediaInvalidations.insert(identifier)
        mediaInvalidationTask?.cancel()
        mediaInvalidationTask = Task { @MainActor [weak self] in
            do {
                // Gallery tiles frequently finish in the same display frame.
                // Collapse their row-wide bitmap rebuilds into one transaction.
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard let self else { return }
            self.mediaInvalidationTask = nil
            let identifiers = self.pendingMediaInvalidations
            self.pendingMediaInvalidations.removeAll(keepingCapacity: true)
            self.onMediaDimensionsChange?(identifiers)
            self.refreshVisibleMediaPins()
            var dirtyRect = CGRect.null
            for identifier in identifiers {
                self.invalidateBitmap(identifier)
                if let index = self.items.firstIndex(where: {
                    $0.identifier == identifier
                }) {
                    dirtyRect = dirtyRect.union(self.rowFrame(at: index))
                }
            }
            if !dirtyRect.isNull {
                self.setNeedsDisplay(dirtyRect)
            }
        }
    }

    @discardableResult
    func refreshVisibleMediaPins()
        -> [NativeMessageTimelineItem.Identifier: Set<NativeTimelineMediaKey>]
    {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "TimelineVisibleMediaProjection"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "TimelineVisibleMediaProjection",
                interval
            )
        }
        let viewport =
            enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard viewport.height > 0,
              !items.isEmpty,
              !layouts.isEmpty,
              var index = rowIndex(at: max(0, viewport.minY))
        else {
            visibleMediaProjection = nil
            NativeTimelineMediaStore.shared.retainVisibleImages(
                for: [],
                owner: visibleMediaPinOwner
            )
            NativeTimelineMediaStore.shared
                .cancelStaticRequestsOutsideVisibleSet(
                    owner: visibleMediaPinOwner
                )
            return [:]
        }

        var lowerBound: Int?
        var upperBound: Int?
        while items.indices.contains(index),
              layouts.indices.contains(index),
              displayedRowOrigin(at: index) < viewport.maxY
        {
            if rowFrame(at: index).intersects(viewport) {
                lowerBound = lowerBound ?? index
                upperBound = index + 1
            }
            index += 1
        }
        guard let lowerBound, let upperBound else {
            visibleMediaProjection = nil
            NativeTimelineMediaStore.shared.retainVisibleImages(
                for: [],
                owner: visibleMediaPinOwner
            )
            NativeTimelineMediaStore.shared
                .cancelStaticRequestsOutsideVisibleSet(
                    owner: visibleMediaPinOwner
                )
            return [:]
        }
        let rowRange = lowerBound ..< upperBound
        if let visibleMediaProjection,
           visibleMediaProjection.rowRange == rowRange
        {
            return visibleMediaProjection.keysByIdentifier
        }

        var keys: Set<NativeTimelineMediaKey> = []
        var keysByIdentifier:
            [NativeMessageTimelineItem.Identifier:
                Set<NativeTimelineMediaKey>] = [:]
        for index in rowRange
        where rowFrame(at: index).intersects(viewport) {
            if let row = items[index].messageRow, !row.serverInvites.isEmpty, let model {
                let references = row.serverInvites
                let session = model.accountSession()
                Task { @MainActor in
                    guard model.isCurrentAccountSession(session) else { return }
                    for reference in references { model.loadServerInvite(reference) }
                }
            }
            let rowKeys = mediaKeys(for: items[index], at: index)
            keys.formUnion(rowKeys)
            keysByIdentifier[items[index].identifier] = rowKeys
        }
        visibleMediaProjection = VisibleMediaProjection(
            rowRange: rowRange,
            keysByIdentifier: keysByIdentifier
        )
        NativeTimelineMediaStore.shared.retainVisibleImages(
            for: keys,
            owner: visibleMediaPinOwner
        )
        NativeTimelineMediaStore.shared
            .cancelStaticRequestsOutsideVisibleSet(
                owner: visibleMediaPinOwner
            )
        return keysByIdentifier
    }

    func uncachedMediaKeys(
        for item: NativeMessageTimelineItem,
        at index: Int?
    ) -> Set<NativeTimelineMediaKey> {
        guard let index,
              layouts.indices.contains(index),
              case let .message(row, _, _) = item
        else { return [] }
        let message = row.message
        let visibleEmbedCount = MessageEmbedPresentation.visibleEmbeds(for: message).count
        var keys: [NativeTimelineMediaKey] = []
        keys.reserveCapacity(
            1 + message.attachments.count + visibleEmbedCount
                + message.stickers.count
        )
        appendAuthorMediaKeys(for: row, layout: layouts[index], into: &keys)
        appendMessageTextMediaKeys(for: row, layout: layouts[index], into: &keys)
        appendAttachmentMediaKeys(for: message, layout: layouts[index], into: &keys)
        appendEmbedMediaKeys(layouts[index].embedRegions, into: &keys)
        for card in layouts[index].inviteRegions {
            if let invite = card.invite {
                if let url = invite.iconURL { keys.append(.media(url, maximumPixelDimension: 128)) }
                if let url = invite.inviter?.avatarURL { keys.append(.media(url, maximumPixelDimension: 32)) }
                for trait in invite.traits {
                    if let url = trait.emojiURL { keys.append(.media(url, maximumPixelDimension: 32)) }
                }
            }
        }
        appendComponentMediaKeys(for: message, layouts: layouts[index].componentLayouts, into: &keys)
        appendStickerAndReactionMediaKeys(for: message, layout: layouts[index], into: &keys)
        for answer in message.poll?.answers ?? [] {
            if let url = answer.emoji?.imageURL(size: 64) {
                keys.append(.media(url, maximumPixelDimension: 64))
            }
        }
        return Set(keys)
    }

    private func appendAuthorMediaKeys(
        for row: MessageRowPresentation,
        layout: NativeTimelineRowLayout,
        into keys: inout [NativeTimelineMediaKey]
    ) {
        let message = row.message
        let author = model?.authorPresentation(for: message)
        if let url = author?.user.avatarURL ?? message.author.avatarURL {
            keys.append(.avatar(url))
        }
        if let url =
            (author?.user ?? message.author).avatarDecorationURL
        {
            keys.append(.avatarDecoration(url))
        }
        if let url = message.interactionMetadata?.user?.avatarURL {
            keys.append(.avatar(url))
        }
        if let url = layout.forwardedSourceRegion?.iconURL {
            keys.append(.avatar(url))
        }
        if let preview = row.replyPreview,
           let url = model?.authorPresentation(for: preview, in: message).user.avatarURL {
            keys.append(.avatar(url))
        } else if let key = NativeTimelineReplyMediaPolicy.avatarKey(
            for: row.replyPreview
        ) {
            keys.append(key)
        }
        for region in layout.linkedImageRegions {
            keys.append(.media(
                region.reference.displayURL,
                maximumPixelDimension: region.reference.isEmoji ? 96 : 720
            ))
        }
    }

    private func appendMessageTextMediaKeys(
        for row: MessageRowPresentation,
        layout: NativeTimelineRowLayout,
        into keys: inout [NativeTimelineMediaKey]
    ) {
        let message = row.message
        if let model {
            let mentionResolver = MessageMentionResolver(
                model: model,
                message: message
            )
            for token in row.textPlan.preparedText?.tokens ?? [] {
                switch token {
                case let .customEmoji(emoji):
                    let reference = EmojiReference(rawToken: emoji.rawToken)
                    guard let url =
                        reference.id.flatMap({ model.customEmojiURLsByID[$0] })
                        ?? reference.imageURL(size: 64)
                    else { continue }
                    keys.append(.media(url, maximumPixelDimension: 64))
                case let .mention(mention):
                    if let url = mentionResolver.avatarURL(mention) {
                        keys.append(.avatar(url))
                    }
                }
            }
        }
    }

    private func appendAttachmentMediaKeys(
        for message: Message,
        layout: NativeTimelineRowLayout,
        into keys: inout [NativeTimelineMediaKey]
    ) {
        for region in layout.attachmentRegions {
            let attachment = region.attachment
            guard NativeTimelineSpoilerConcealmentPolicy
                .shouldLoadOrAnimate(
                    messageID: message.id,
                    contentID:
                        NativeTimelineComponentRevealKey
                            .attachmentComponentID(attachment.id),
                    isSpoiler: attachment.isSpoiler,
                    store: spoilerRevealStore
                )
            else { continue }
            switch attachment.mediaKind {
            case .image, .animatedImage:
                if let key = NativeTimelineMediaKey.attachment(attachment) {
                    keys.append(key)
                }
            case .video, .audio, .file:
                break
            }
        }
    }

    private func appendEmbedMediaKeys(
        _ regions: [NativeTimelineRowLayout.EmbedRegion],
        into keys: inout [NativeTimelineMediaKey]
    ) {
        for region in regions {
            for image in region.imageRegions {
                keys.append(
                    .media(
                        image.url,
                        maximumPixelDimension: image.maximumPixelDimension
                    )
                )
            }
            for textRegion in region.textRegions {
                let value = textRegion.text.value
                let range = NSRange(location: 0, length: value.length)
                value.enumerateAttribute(
                    .discordEmojiToken,
                    in: range
                ) { rawValue, _, _ in
                    guard let rawToken = rawValue as? String else { return }
                    let reference = EmojiReference(rawToken: rawToken)
                    let customURL = reference.id.flatMap { id in
                        model?.customEmojiURLsByID[id]
                    }
                    guard let url = customURL
                        ?? reference.imageURL(size: 64)
                    else { return }
                    keys.append(.media(url, maximumPixelDimension: 64))
                }
                value.enumerateAttribute(
                    .nativeTimelineMention,
                    in: range
                ) { rawValue, _, _ in
                    guard let mention =
                        (rawValue as? NativeTimelineMentionBox)?
                        .presentation,
                        let url = mention.avatarURL
                    else { return }
                    keys.append(.avatar(url))
                }
            }
            if !region.mediaIsVideo,
               let url = region.mediaURL
            {
                keys.append(.media(url))
            }
        }
    }

    private func appendComponentMediaKeys(
        for message: Message,
        layouts: [NativeTimelineComponentLayout],
        into keys: inout [NativeTimelineMediaKey]
    ) {
        for componentLayout in layouts {
            let hiddenContainerFrames =
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: componentLayout,
                        messageID: message.id,
                        store: spoilerRevealStore
                    )
            for image in componentLayout.images {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        image.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    ),
                      !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                          messageID: message.id,
                          contentID: image.componentID,
                          isSpoiler: image.isSpoiler,
                          store: spoilerRevealStore
                      )
                else { continue }
                keys.append(
                    .media(
                        image.displayURL,
                        maximumPixelDimension: image.maximumPixelDimension
                    )
                )
            }
            for media in componentLayout.media {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        media.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    ),
                      !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                          messageID: message.id,
                          contentID: media.componentID,
                          isSpoiler: media.isSpoiler,
                          store: spoilerRevealStore
                      )
                else { continue }
                keys.append(.media(media.displayURL))
            }
            for button in componentLayout.buttons {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        button.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    )
                else { continue }
                guard let emoji = button.emoji,
                      emoji.id != nil,
                      let url = emoji.imageURL(size: 32)
                else { continue }
                keys.append(.media(url, maximumPixelDimension: 64))
            }
            keys += componentLayout.selectMediaKeys(hiddenContainerFrames)
            for textRegion in componentLayout.textRegions {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        textRegion.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    )
                else { continue }
                appendInlineMediaKeys(
                    from: textRegion.text.value,
                    model: model,
                    into: &keys
                )
            }
        }
    }

    private func appendStickerAndReactionMediaKeys(
        for message: Message,
        layout: NativeTimelineRowLayout,
        into keys: inout [NativeTimelineMediaKey]
    ) {
        for sticker in message.stickers where sticker.format != .lottie {
            if let url = sticker.mediaURL {
                keys.append(.media(url, maximumPixelDimension: 384))
            }
        }
        for region in layout.reactionRegions {
            let reference = region.reaction.emojiReference
            if let id = reference.id,
               let url = model?.customEmojiURLsByID[id]
                    ?? reference.imageURL(size: 64)
            {
                keys.append(.media(url, maximumPixelDimension: 64))
            }
            for avatar in region.avatarRegions {
                if let url = avatar.reactor.avatarURL {
                    keys.append(.avatar(url))
                }
            }
        }
    }

    func mediaKeys(
        for item: NativeMessageTimelineItem,
        at index: Int?
    ) -> Set<NativeTimelineMediaKey> {
        let identifier = item.identifier
        if let cached = mediaKeysByIdentifier[identifier] {
            return cached
        }
        let keys = uncachedMediaKeys(for: item, at: index)
        mediaKeysByIdentifier[identifier] = keys
        return keys
    }

    func invalidateVisibleMediaProjection(keepingCapacity: Bool) {
        visibleMediaProjection = nil
        mediaKeysByIdentifier.removeAll(keepingCapacity: keepingCapacity)
    }

    func appendInlineMediaKeys(
        from value: NSAttributedString,
        model: AppModel?,
        into keys: inout [NativeTimelineMediaKey]
    ) {
        let range = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(
            .discordEmojiToken,
            in: range
        ) { rawValue, _, _ in
            guard let rawToken = rawValue as? String else { return }
            let reference = EmojiReference(rawToken: rawToken)
            let customURL = reference.id.flatMap { id in
                model?.customEmojiURLsByID[id]
            }
            guard let url = customURL
                ?? reference.imageURL(size: 64)
            else { return }
            keys.append(.media(url, maximumPixelDimension: 64))
        }
        value.enumerateAttribute(
            .nativeTimelineMention,
            in: range
        ) { rawValue, _, _ in
            guard let mention =
                (rawValue as? NativeTimelineMentionBox)?.presentation,
                let url = mention.avatarURL
            else { return }
            keys.append(.avatar(url))
        }
    }

    func invalidateBitmap(
        _ identifier: NativeMessageTimelineItem.Identifier
    ) {
        guard let removed = bitmapCache.removeValue(forKey: identifier) else {
            return
        }
        bitmapCost -= removed.cost
        bitmapInsertionOrder.removeAll { $0 == identifier }
        NativeTimelineMediaStore.shared.releasePinnedImages(
            owner: removed.mediaPinOwner
        )
    }
}
