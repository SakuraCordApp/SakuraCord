import AppKit
import Observation
import SakuraCordModels

extension ForumBoardView {
    // MARK: Presentation

    /// Resolves presentation for realized posts under observation, so any
    /// model change that affects a visible card (read state, reactions,
    /// selection, emoji URLs, members) repaints just that card.
    func schedulePresentationRefresh() {
        guard !presentationRefreshScheduled else { return }
        presentationRefreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshPresentations()
        }
    }

    /// Re-resolves every realized card under one observation scope, on purpose:
    /// any change a card reads re-runs the whole pass. That is coarse, but
    /// bounded to the realized cards, and it avoids per-card tracking.
    private func refreshPresentations() {
        presentationRefreshScheduled = false
        guard let model, let channel else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        var changed: [ChannelID] = []
        var hydratedPostIDs = Set<ChannelID>()
        withObservationTracking {
            for id in cards.keys {
                guard case let .post(postID) = id, let post = postsByID[postID] else { continue }
                let presentation = model.forumCardPresentation(for: post, in: channel, tagsByID: tagsByID)
                let presentationChanged = presentations[postID] != presentation
                if presentations[postID]?.isAwaitingContent(isGallery: isGallery) == true,
                   !presentation.isAwaitingContent(isGallery: isGallery)
                {
                    hydratedPostIDs.insert(postID)
                }
                presentations[postID] = presentation
                // Excerpts also depend on mention resolution, which the
                // presentation omits; configuring here observes it too.
                let excerptChanged = configureExcerpt(for: postID)
                if presentationChanged || excerptChanged { changed.append(postID) }
            }
            _ = model.openThread?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, observationGeneration == generation else { return }
                schedulePresentationRefresh()
            }
        }
        for postID in changed {
            let id = ForumBoardItem.Identifier.post(postID)
            regions[id] = nil
            guard let card = cards[id] else { continue }
            applyChrome(card, id: id, animated: true)
            // Content replaces its skeleton bars in one frame; other updates
            // cross-fade. The shimmer follows when the bitmap lands.
            card.render(scale: backingScale, fading: card.hasContent && !hydratedPostIDs.contains(postID))
        }
        if !changed.isEmpty {
            refreshMedia()
            rebuildToolTips()
            updateAccessibilityChildren()
        }
    }

    /// Resolves a realized post's presentation and excerpt renderer before its
    /// first paint, so a card scrolled into view is never blank for a turn. A
    /// card entering the realized range always re-resolves, since its post may
    /// have changed while it was unobserved off screen; an existing card
    /// resolves only what is missing. Returns whether anything was resolved.
    func resolveContent(for postID: ChannelID, isNewCard: Bool) -> Bool {
        if !isNewCard, presentations[postID] != nil, excerptRenderers[postID] != nil || !needsExcerptRenderer(postID) {
            return false
        }
        if isNewCard || presentations[postID] == nil {
            guard let model, let channel, let post = postsByID[postID] else { return isNewCard }
            presentations[postID] = model.forumCardPresentation(for: post, in: channel, tagsByID: tagsByID)
        }
        configureExcerpt(for: postID)
        return true
    }

    private func needsExcerptRenderer(_ postID: ChannelID) -> Bool {
        guard let presentation = presentations[postID] else { return false }
        if isGallery {
            switch presentation.hero {
            case .text, .deleted: return true
            default: return false
            }
        }
        switch presentation.excerpt {
        case .message, .deleted, .placeholder: return true
        default: return false
        }
    }

    /// Excerpt fonts, emoji sizes and the list/gallery source all feed the
    /// renderers, so a font load, mode change or scale change rebuilds them.
    func reconfigureRealizedExcerpts() {
        for case let .post(postID) in cards.keys { configureExcerpt(for: postID) }
    }

    /// Configures a post's excerpt renderer for the current mode, metrics and
    /// mentions; returns whether its displayed text changed.
    @discardableResult
    private func configureExcerpt(for postID: ChannelID) -> Bool {
        guard let model, let presentation = presentations[postID] else { return false }
        // Without a message, Discord shows a placeholder in its place.
        let message: Message?
        var placeholder = "Original message was deleted"
        let lines: Int
        var prefix: ForumPostPreviewTextView.Prefix?
        if isGallery {
            switch presentation.hero {
            case let .text(value): message = value
            case .deleted: message = nil
            default: return excerptRenderers.removeValue(forKey: postID) != nil
            }
            let tagReserve = presentation.tags.isEmpty ? 0 : InterfaceScale.metric(34)
            lines = max(1, Int((metrics.galleryHeroHeight - InterfaceScale.metric(28) - tagReserve) / metrics.excerptLineHeight))
        } else {
            switch presentation.excerpt {
            case let .message(value, author):
                message = value
                prefix = authorPrefix(author)
            case let .deleted(author):
                message = nil
                prefix = author.map { authorPrefix($0) }
            case let .placeholder(text, author):
                message = nil
                placeholder = text ?? ""
                prefix = authorPrefix(author, separated: text != nil)
            default: return excerptRenderers.removeValue(forKey: postID) != nil
            }
            lines = metrics.excerptLines
        }
        let fontSize = metrics.excerptFont.pointSize
        let renderer = excerptRenderers[postID] ?? {
            let renderer = ForumPostPreviewTextRenderer()
            renderer.onDisplayChange = { [weak self] in
                guard let self, let card = cards[.post(postID)] else { return }
                card.render(scale: backingScale, fading: false)
                updateAccessibilityChildren()
            }
            excerptRenderers[postID] = renderer
            return renderer
        }()
        let previous = renderer.configuration
        renderer.configure(
            message.map {
                ForumPostPreviewTextView.Configuration(
                    resolving: $0,
                    model: model,
                    fontSize: fontSize,
                    maximumNumberOfLines: lines,
                    isEmphasized: presentation.isEmphasized,
                    underlinesLinks: presentation.underlinesLinks,
                    prefix: prefix
                )
            } ?? ForumPostPreviewTextView.Configuration(
                messageID: MessageID(rawValue: postID.rawValue),
                source: placeholder,
                mentionPresentations: [:],
                fontSize: fontSize,
                emojiSize: (fontSize * 1.375).rounded(),
                maximumNumberOfLines: lines,
                // Discord keeps a placeholder muted on an unread post too.
                isEmphasized: false,
                underlinesLinks: presentation.underlinesLinks,
                prefix: prefix
            ),
            revealStore: model.timelineSpoilerRevealStore
        )
        return renderer.configuration != previous
    }

    struct AuthorPrefixKey: Hashable {
        let author: ForumCardPresentation.Author
        let fontName: String
        let fontSize: CGFloat
        let isSeparated: Bool
    }

    /// Prefixes are cached so an unchanged author keeps an identical value,
    /// letting excerpt configuration compare equal and skip a rebuild.
    /// `separated` follows the name with a colon, as before text; a name
    /// standing alone has none.
    private func authorPrefix(
        _ author: ForumCardPresentation.Author,
        separated: Bool = true
    ) -> ForumPostPreviewTextView.Prefix {
        let bodySize = metrics.excerptFont.pointSize
        let fallback = NSFont.interfaceSystemFont(ofSize: bodySize, weight: .semibold)
        ProfileNameFontLoader.shared.request(id: author.fontID)
        let font = ProfileNameFontCache.font(id: author.fontID, fallback: fallback)
        let key = AuthorPrefixKey(author: author, fontName: font.fontName, fontSize: font.pointSize, isSeparated: separated)
        if let cached = authorPrefixes[key] { return cached }
        let prefix = makeAuthorPrefix(author, font: font, bodySize: bodySize, separated: separated)
        if authorPrefixes.count > 512 { authorPrefixes.removeAll(keepingCapacity: true) }
        authorPrefixes[key] = prefix
        return prefix
    }

    private func makeAuthorPrefix(
        _ author: ForumCardPresentation.Author,
        font: NSFont,
        bodySize: CGFloat,
        separated: Bool
    ) -> ForumPostPreviewTextView.Prefix {
        let value = NSMutableAttributedString()
        if let dotColor = author.roleDotColor,
           let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
           .withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: InterfaceScale.fontSize(8), weight: .regular)
                   .applying(.init(paletteColors: [dotColor]))
           )
        {
            let attachment = NSTextAttachment()
            attachment.image = dot
            attachment.bounds = CGRect(origin: CGPoint(x: 0, y: 1), size: dot.size)
            value.append(NSAttributedString(attachment: attachment))
            value.append(NSAttributedString(string: " "))
        }
        value.append(NSAttributedString(
            string: author.name,
            attributes: [
                .font: font,
                .foregroundColor: author.color ?? NSColor.labelColor,
            ]
        ))
        guard separated else {
            return ForumPostPreviewTextView.Prefix(value: value, accessibilityText: author.name)
        }
        value.append(NSAttributedString(
            string: ": ",
            attributes: [.font: NSFont.interfaceSystemFont(ofSize: bodySize), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        return ForumPostPreviewTextView.Prefix(value: value, accessibilityText: "\(author.name): ")
    }

    // MARK: Drawing

    func cardRegions(for id: ForumBoardItem.Identifier) -> ForumCardRegions? {
        if let cached = regions[id] { return cached }
        guard let entry = layoutState?.entry(for: id) else { return nil }
        let presentation: ForumCardPresentation?
        let titleLines: Int
        switch entry.item {
        case let .post(input):
            presentation = presentations[input.id]
            titleLines = entry.titleLines
        case .placeholder:
            presentation = nil
            titleLines = 1
        case .olderPostsHeader, .paginationStatus:
            regions[id] = ForumCardRegions()
            return regions[id]
        }
        var value = ForumCardPainter.regions(
            for: presentation,
            mode: isGallery ? .gallery : .list,
            size: entry.frame.size,
            titleLines: titleLines,
            metrics: metrics
        )
        // A post whose presentation has not resolved paints nothing, so it
        // shows no shimmer either.
        if presentation == nil, entry.item.postID != nil { value.skeletonFrames = [] }
        regions[id] = value
        return value
    }

    /// Records an item's drawing for the rasterizer.
    func scene(id: ForumBoardItem.Identifier, size: CGSize, scale: CGFloat) -> ForumCardScene {
        let colorSpace = window?.colorSpace?.cgColorSpace ?? ForumCardRasterizer.defaultColorSpace
        var scene = ForumCardScene.empty(size: size, scale: scale, colorSpace: colorSpace)
        guard let entry = layoutState?.entry(for: id) else { return scene }
        let bounds = CGRect(origin: .zero, size: size)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let canvas = ForumCardCanvas(size: size, scale: scale, colorSpace: colorSpace, cache: rasterCache)
            canvas.laysOutExcerptsOffMain = laysOutExcerptsOffMain
            switch entry.item {
            case let .post(input):
                paintPost(id: id, postID: input.id, titleLines: entry.titleLines, on: canvas)
            case .placeholder:
                if let regions = cardRegions(for: id) {
                    ForumCardPainter.drawSkeleton(regions.skeletonFrames, on: canvas)
                }
            case .olderPostsHeader:
                ForumCardPainter.drawSectionHeader("Older Posts", in: bounds, on: canvas)
            case .paginationStatus:
                ForumCardPainter.drawPaginationError(
                    snapshot?.paginationError ?? "",
                    in: bounds,
                    isRetryHovered: interactions[id]?.isRetryHovered == true,
                    on: canvas
                )
            }
            scene = canvas.scene
        }
        return scene
    }

    private func paintPost(id: ForumBoardItem.Identifier, postID: ChannelID, titleLines: Int, on canvas: ForumCardCanvas) {
        guard let presentation = presentations[postID], let regions = cardRegions(for: id) else { return }
        if !regions.skeletonFrames.isEmpty {
            ForumCardPainter.drawSkeleton(regions.skeletonFrames, on: canvas)
        }
        let excerpt = excerptRenderers[postID]
        if let excerpt, let frame = isGallery ? regions.heroFrame : regions.excerptFrame {
            excerpt.size = CGSize(width: frame.width - (isGallery ? InterfaceScale.metric(32) : 0), height: frame.height)
        }
        paintedRelativeTimes[id] = presentation.relativeTimeText(isGallery: isGallery)
        ForumCardPainter.draw(ForumCardPainter.DrawInput(
            presentation: presentation,
            mode: isGallery ? .gallery : .list,
            regions: regions,
            titleLines: titleLines,
            excerpt: excerpt,
            interaction: interactions[id] ?? ForumCardInteraction(),
            model: model,
            metrics: metrics,
            failedMedia: failedMediaKeys
        ), on: canvas)
    }

    /// The 30-second tick: repaints only cards whose relative time reads
    /// differently from when they last painted.
    func refreshRelativeTimes() {
        var repainted = false
        for (id, card) in cards {
            guard case let .post(postID) = id, let presentation = presentations[postID],
                  paintedRelativeTimes[id] != presentation.relativeTimeText(isGallery: isGallery)
            else { continue }
            regions[id] = nil
            card.render(scale: backingScale, fading: false)
            repainted = true
        }
        if repainted { rebuildToolTips() }
    }
}
