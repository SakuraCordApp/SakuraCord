import AppKit

extension NativeTimelineCanvasView {
    func mediaViewerPresentation(
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

    private func timelineMedia(
        for presentation: NativeTimelineMediaViewerPresentation,
        rowIndex: Int
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
                  let image = NativeTimelineRowPainter.mediaImage(for: key)
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
                    fillsFrame: false
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
        let visibleFrame = frameInCanvas.intersection(visibleRect)
        guard !visibleFrame.isNull,
              visibleFrame.width > 0,
              visibleFrame.height > 0
        else { return nil }
        return MediaViewerTransitionSource(
            itemID: itemID,
            image: image,
            frameInWindow: convert(frameInCanvas, to: nil),
            visibleFrameInWindow: convert(visibleFrame, to: nil),
            cornerRadius: cornerRadius,
            fillsFrame: fillsFrame
        )
    }

    /// A file card's snapshot, which grows into the file's preview. A video
    /// file shows without one, as the viewer zooms only files it previews.
    private func fileCardTransitionSource(for item: RichMediaItem, rowIndex: Int) -> MediaViewerTransitionSource? {
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
        let visibleFrame = frameInCanvas.intersection(visibleRect)
        guard !visibleFrame.isNull, visibleFrame.width > 0, visibleFrame.height > 0,
              let bitmap = bitmapImageRepForCachingDisplay(in: frameInCanvas)
        else { return nil }
        cacheDisplay(in: frameInCanvas, to: bitmap)
        let image = NSImage(size: frameInCanvas.size)
        image.addRepresentation(bitmap)
        return MediaViewerTransitionSource(
            itemID: itemID,
            image: image,
            frameInWindow: convert(frameInCanvas, to: nil),
            visibleFrameInWindow: convert(visibleFrame, to: nil),
            cornerRadius: card.cornerRadius,
            fillsFrame: true
        )
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
            return fileCardTransitionSource(for: presentation.items[presentation.selection], rowIndex: rowIndex)
                .map(presentation.withTransitionSource) ?? presentation
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
                    fillsFrame: false
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
