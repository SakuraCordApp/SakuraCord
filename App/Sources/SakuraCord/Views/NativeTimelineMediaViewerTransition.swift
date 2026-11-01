import AppKit

/// A viewer this canvas opened with a zoom: the canvas keeps the zoom's
/// sources on its cards' live frames and leaves out the card the viewer
/// stands in for.
struct NativeTimelineMediaViewerTransition {
    let presentation: NativeTimelineMediaViewerPresentation
    let row: NativeMessageTimelineItem.Identifier
    var coveredItemID: String?
}

extension NativeTimelineCanvasView {
    func mediaViewerPresentation(
        _ presentation: NativeTimelineMediaViewerPresentation,
        sourceFrame: CGRect,
        rowIndex: Int,
        mediaKey: NativeTimelineMediaKey?,
        cornerRadius: CGFloat,
        fillsFrame: Bool
    ) -> NativeTimelineMediaViewerPresentation {
        linking(
            sourcedPresentation(
                presentation, sourceFrame: sourceFrame, rowIndex: rowIndex,
                mediaKey: mediaKey, cornerRadius: cornerRadius, fillsFrame: fillsFrame
            ),
            rowIndex: rowIndex
        )
    }

    private func sourcedPresentation(
        _ presentation: NativeTimelineMediaViewerPresentation,
        sourceFrame: CGRect,
        rowIndex: Int,
        mediaKey: NativeTimelineMediaKey?,
        cornerRadius: CGFloat,
        fillsFrame: Bool
    ) -> NativeTimelineMediaViewerPresentation {
        let media = timelineMedia(for: presentation, rowIndex: rowIndex)
        let presentation = presentation.withTimelineMedia(
            previewImages: media.previewImages,
            transitionSources: media.transitionSources
        )
        guard presentation.items.indices.contains(presentation.selection) else { return presentation }
        guard case .image = presentation.items[presentation.selection].kind else {
            return fileCardTransitionSource(for: presentation.items[presentation.selection], rowIndex: rowIndex)
                .map(presentation.withTransitionSource) ?? presentation
        }

        let item = presentation.items[presentation.selection]
        let performanceProbe =
            MediaViewerPresentationPerformanceProbe.shared
        performanceProbe.begin(
            mediaWidth: item.width,
            mediaHeight: item.height
        )

        guard let mediaKey,
              let image = NativeTimelineRowPainter.mediaImage(for: mediaKey),
              window != nil
        else {
            performanceProbe.reportSourcePrepared(
                imageSize: nil,
                visibleSourceRatio: 0,
                hasTransitionSource: false
            )
            return presentation
        }

        let frameInCanvas = sourceFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: rowIndex)
        )
        let visibleFrameInCanvas = frameInCanvas.intersection(visibleRect)
        guard !visibleFrameInCanvas.isNull,
              visibleFrameInCanvas.width > 0,
              visibleFrameInCanvas.height > 0
        else {
            performanceProbe.reportSourcePrepared(
                imageSize: image.size,
                visibleSourceRatio: 0,
                hasTransitionSource: false
            )
            return presentation
        }

        performanceProbe.reportSourcePrepared(
            imageSize: image.size,
            visibleSourceRatio:
                visibleFrameInCanvas.width * visibleFrameInCanvas.height
                / (frameInCanvas.width * frameInCanvas.height),
            hasTransitionSource: true
        )
        return presentation.withTransitionSource(
            MediaViewerTransitionSource(
                itemID: item.id,
                image: image,
                frameInWindow: convert(frameInCanvas, to: nil),
                visibleFrameInWindow: convert(
                    visibleFrameInCanvas,
                    to: nil
                ),
                cornerRadius: cornerRadius,
                fillsFrame: fillsFrame
            )
        )
    }

    /// Given the sources a viewer opened with, only those come back, at
    /// their cards' current frames and with their images if the cache let
    /// them go.
    private func timelineMedia(
        for presentation: NativeTimelineMediaViewerPresentation,
        rowIndex: Int,
        refreshing previousSources: [String: MediaViewerTransitionSource]? = nil
    ) -> (
        previewImages: [String: NSImage],
        transitionSources: [String: MediaViewerTransitionSource]
    ) {
        guard layouts.indices.contains(rowIndex) else { return ([:], [:]) }
        let layout = layouts[rowIndex]
        let imageItemIDs = Set(presentation.items.compactMap { item in
            if case .image = item.kind { item.id } else { nil }
        })
        let rowOrigin = displayedRowOrigin(at: rowIndex)
        var images: [String: NSImage] = [:]
        var sources: [String: MediaViewerTransitionSource] = [:]

        func insert(
            _ itemID: String,
            key: NativeTimelineMediaKey,
            frame: CGRect?,
            cornerRadius: CGFloat,
            fillsFrame: Bool
        ) {
            guard imageItemIDs.contains(itemID),
                  previousSources.map({ $0[itemID] != nil }) ?? true,
                  let image = NativeTimelineRowPainter.mediaImage(for: key) ?? previousSources?[itemID]?.image
            else { return }
            images[itemID] = image
            guard sources[itemID] == nil else { return }
            sources[itemID] = timelineTransitionSource(
                itemID: itemID,
                image: image,
                frame: frame,
                rowOrigin: rowOrigin,
                cornerRadius: cornerRadius,
                fillsFrame: fillsFrame
            )
        }

        for region in layout.attachmentRegions {
            guard let key = NativeTimelineMediaKey.attachment(
                region.attachment
            ) else { continue }
            insert(
                region.attachment.id,
                key: key,
                frame: region.frame,
                cornerRadius: 8,
                fillsFrame: MediaGalleryImagePresentation.fillsFrame(
                    itemCount: layout.mediaGalleryItemCount
                )
            )
        }
        for region in layout.linkedImageRegions {
            insert(
                region.reference.id,
                key: .media(
                    region.reference.displayURL,
                    maximumPixelDimension:
                        region.reference.isEmoji ? 96 : 720
                ),
                frame: region.frame,
                cornerRadius: region.reference.isEmoji ? 7 : 10,
                fillsFrame: !region.reference.isEmoji
                    && !region.reference.isSticker
            )
        }
        for component in layout.componentLayouts {
            for region in component.images {
                insert(
                    region.componentID,
                    key: .media(
                        region.displayURL,
                        maximumPixelDimension: region.maximumPixelDimension
                    ),
                    frame: region.frame,
                    cornerRadius: region.cornerRadius,
                    // The row crops a thumbnail to fill its square.
                    fillsFrame: true
                )
            }
            for region in component.media where !region.isVideo {
                insert(
                    region.componentID,
                    key: .media(region.displayURL),
                    frame: region.frame,
                    cornerRadius: 8,
                    fillsFrame: true
                )
            }
        }
        for region in layout.embedRegions {
            guard !region.mediaIsVideo,
                  let url = region.mediaURL
            else { continue }
            for item in presentation.items where imageItemIDs.contains(item.id)
                && (item.url == url || item.previewURL == url) {
                insert(
                    item.id,
                    key: .media(url),
                    frame: region.mediaFrame,
                    cornerRadius: 8,
                    fillsFrame: false
                )
            }
        }

        return (images, sources)
    }

    private func timelineTransitionSource(
        itemID: String,
        image: NSImage,
        frame: CGRect?,
        rowOrigin: CGFloat,
        cornerRadius: CGFloat,
        fillsFrame: Bool
    ) -> MediaViewerTransitionSource? {
        guard window != nil, let frame else { return nil }
        let frameInCanvas = frame.offsetBy(dx: 0, dy: rowOrigin)
        return MediaViewerTransitionSource(
            itemID: itemID,
            image: image,
            frameInWindow: convert(frameInCanvas, to: nil),
            visibleFrameInWindow: convert(visiblePart(of: frameInCanvas), to: nil),
            cornerRadius: cornerRadius,
            fillsFrame: fillsFrame
        )
    }

    /// The part of a card the viewport shows. A card scrolled out keeps an
    /// empty part on the viewport's nearest edge, where a zoom heading to it
    /// collapses rather than jumping.
    private func visiblePart(of frame: CGRect) -> CGRect {
        let viewport = visibleRect
        let minX = min(max(frame.minX, viewport.minX), viewport.maxX)
        let maxX = max(min(frame.maxX, viewport.maxX), viewport.minX)
        let minY = min(max(frame.minY, viewport.minY), viewport.maxY)
        let maxY = max(min(frame.maxY, viewport.maxY), viewport.minY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A file card's snapshot, which grows into the file's preview. A video
    /// file shows without one, as the viewer zooms only files it previews.
    /// Given an earlier snapshot, it is kept unless `retakesSnapshot` and
    /// the card shows.
    private func fileCardTransitionSource(
        for item: RichMediaItem, rowIndex: Int, reusing previousImage: NSImage? = nil, retakesSnapshot: Bool = false
    ) -> MediaViewerTransitionSource? {
        switch item.kind {
        case .audio, .text, .file: break
        default: return nil
        }
        let itemID = item.id
        guard window != nil, layouts.indices.contains(rowIndex) else { return nil }
        let layout = layouts[rowIndex]
        guard let card = layout.fileCards.first(where: { $0.attachment.id == itemID })
            ?? layout.componentLayouts.lazy.flatMap(\.files).first(where: { $0.componentID == itemID })?.card
        else { return nil }
        let frameInCanvas = card.frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: rowIndex))
        let visibleFrame = visiblePart(of: frameInCanvas)
        let image: NSImage
        if let previousImage, !retakesSnapshot || visibleFrame.isEmpty {
            image = previousImage
        } else {
            guard !visibleFrame.isEmpty, let snapshot = cardSnapshot(of: frameInCanvas) else { return nil }
            image = snapshot
        }
        return MediaViewerTransitionSource(
            itemID: itemID,
            image: image,
            frameInWindow: convert(frameInCanvas, to: nil),
            visibleFrameInWindow: convert(visibleFrame, to: nil),
            cornerRadius: card.cornerRadius,
            fillsFrame: true
        )
    }

    /// What the canvas shows in `rect`, rendered from its layer as it is on
    /// screen, once pending drawing such as a cleared highlight is done.
    /// Drawing the card again, as `cacheDisplay` does, misses it while the
    /// viewer covers it. The cover mask is lifted for the render, which
    /// commits no frame.
    private func cardSnapshot(of rect: CGRect) -> NSImage? {
        guard let layer, let window else { return nil }
        displayIfNeeded()
        let scale = window.backingScaleFactor
        let width = Int((rect.width * scale).rounded(.up)), height = Int((rect.height * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let layerRect = convertToLayer(rect)
        // The context's origin is at its bottom; the canvas's at its top.
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -layerRect.minX, y: -layerRect.maxY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = layer.mask
        layer.mask = nil
        layer.render(in: context)
        layer.mask = mask
        CATransaction.commit()
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: rect.size)
    }

    func mediaViewerPresentation(
        _ presentation: NativeTimelineMediaViewerPresentation,
        componentID: String,
        rowIndex: Int
    ) -> NativeTimelineMediaViewerPresentation {
        guard layouts.indices.contains(rowIndex) else { return presentation }
        if presentation.items.indices.contains(presentation.selection),
           presentation.items[presentation.selection].id == componentID,
           layouts[rowIndex].componentLayouts.contains(where: { $0.files.contains { $0.componentID == componentID } }) {
            return linking(
                fileCardTransitionSource(for: presentation.items[presentation.selection], rowIndex: rowIndex)
                    .map(presentation.withTransitionSource) ?? presentation,
                rowIndex: rowIndex
            )
        }
        for layout in layouts[rowIndex].componentLayouts {
            if let region = layout.images.first(where: {
                $0.componentID == componentID
            }) {
                return mediaViewerPresentation(
                    presentation,
                    sourceFrame: region.frame,
                    rowIndex: rowIndex,
                    mediaKey: .media(
                        region.displayURL,
                        maximumPixelDimension: region.maximumPixelDimension
                    ),
                    cornerRadius: region.cornerRadius,
                    fillsFrame: true
                )
            }
            if let region = layout.media.first(where: {
                $0.componentID == componentID
            }) {
                return mediaViewerPresentation(
                    presentation,
                    sourceFrame: region.frame,
                    rowIndex: rowIndex,
                    mediaKey: .media(region.displayURL),
                    cornerRadius: 8,
                    fillsFrame: true
                )
            }
        }
        return presentation
    }
}

extension NativeTimelineCanvasView {
    /// Keeps a viewer that zooms from this canvas's cards on their live frames.
    private func linking(
        _ presentation: NativeTimelineMediaViewerPresentation,
        rowIndex: Int
    ) -> NativeTimelineMediaViewerPresentation {
        let link = presentation.transitionLink
        guard !link.sources.isEmpty, items.indices.contains(rowIndex) else { return presentation }
        mediaViewerTransition = NativeTimelineMediaViewerTransition(
            presentation: presentation,
            row: items[rowIndex].identifier
        )
        updateMediaViewerCoverMask()
        link.cover = { [weak self, weak link] itemID in
            guard let self, mediaViewerTransition?.presentation.transitionLink === link else { return }
            mediaViewerTransition?.coveredItemID = itemID
            updateMediaViewerCoverMask()
        }
        link.release = { [weak self, weak link] in
            guard let self, mediaViewerTransition?.presentation.transitionLink === link else { return }
            endMediaViewerTransition()
            // Hover follows the pointer, which the viewer covered.
            synchronizeHoverWithCurrentPointer()
        }
        return presentation
    }

    /// Moves the zoom's sources to their cards' current frames, as the
    /// timeline scrolls under a closing viewer or its rows change. File
    /// cards are drawn again once, as the viewer starts closing, so the
    /// zoom lands on their hover and playback state as they are then.
    func refreshMediaViewerTransition(retakingSnapshots: Bool = false) {
        guard let transition = mediaViewerTransition else { return }
        let link = transition.presentation.transitionLink
        let rowIndex = items.firstIndex { $0.identifier == transition.row }
        var sources = rowIndex.map {
            timelineMedia(for: transition.presentation, rowIndex: $0, refreshing: link.sources).transitionSources
        } ?? [:]
        for item in transition.presentation.items where sources[item.id] == nil {
            guard var previous = link.sources[item.id] else { continue }
            if let rowIndex, let source = fileCardTransitionSource(
                for: item, rowIndex: rowIndex, reusing: previous.image, retakesSnapshot: retakingSnapshots
            ) {
                sources[item.id] = source
            } else {
                // The card left, as after an edit or a deletion: the zoom
                // collapses where it was, and nothing is left out for it.
                let visible = previous.visibleFrameInWindow
                previous.visibleFrameInWindow = CGRect(x: visible.midX, y: visible.midY, width: 0, height: 0)
                sources[item.id] = previous
            }
        }
        link.sources = sources
        updateMediaViewerCoverMask()
    }

    /// A viewer can also leave without its closing transition, as when
    /// another replaces it or the conversation changes.
    func mediaViewerPresentationDidChange(to id: UUID?) {
        guard let transition = mediaViewerTransition, transition.presentation.id != id else { return }
        endMediaViewerTransition()
    }

    private func endMediaViewerTransition() {
        mediaViewerTransition = nil
        updateMediaViewerCoverMask()
    }

    /// Leaves out the card the viewer stands in for, along with any media
    /// view over it, by masking the canvas's layer. Dropping the mask in the
    /// transaction that removes the viewer swaps the zoom's last frame for
    /// the card it matches.
    private func updateMediaViewerCoverMask() {
        guard let layer else { return }
        guard let transition = mediaViewerTransition,
              let itemID = transition.coveredItemID,
              let source = transition.presentation.transitionLink.sources[itemID],
              !source.visibleFrameInWindow.isEmpty
        else {
            layer.mask = nil
            return
        }
        // The card's shape as the zoom draws it: its image clipped to the
        // card's rounded frame.
        let frame = convert(source.frameInWindow, from: nil)
        let imageFrame = MediaViewerLayoutPolicy.imageFrame(
            imageSize: source.image.size, in: frame, fillsFrame: source.fillsFrame
        )
        let card = NSBezierPath(concentricRoundedRect: convertToLayer(frame), cornerRadius: source.cornerRadius)
            .cgPath
            .intersection(CGPath(rect: convertToLayer(imageFrame), transform: nil))
        let path = CGMutablePath()
        path.addRect(layer.bounds)
        path.addPath(card)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        // In the layer's own coordinates, which the path uses.
        mask.bounds = layer.bounds
        mask.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        mask.path = path
        layer.mask = mask
        CATransaction.commit()
    }
}
