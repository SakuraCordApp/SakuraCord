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
        let presentation = presentation.withTimelinePreviewImages(
            timelinePreviewImages(
                for: presentation,
                rowIndex: rowIndex
            )
        )
        guard presentation.items.indices.contains(presentation.selection),
              case .image = presentation.items[presentation.selection].kind
        else { return presentation }

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

    private func timelinePreviewImages(
        for presentation: NativeTimelineMediaViewerPresentation,
        rowIndex: Int
    ) -> [String: NSImage] {
        guard layouts.indices.contains(rowIndex) else { return [:] }
        let layout = layouts[rowIndex]
        let imageItemIDs = Set(presentation.items.compactMap { item in
            if case .image = item.kind { item.id } else { nil }
        })
        var images: [String: NSImage] = [:]

        func insert(_ itemID: String, key: NativeTimelineMediaKey) {
            guard imageItemIDs.contains(itemID),
                  let image = NativeTimelineRowPainter.mediaImage(for: key)
            else { return }
            images[itemID] = image
        }

        for region in layout.attachmentRegions {
            guard let key = NativeTimelineMediaKey.attachment(
                region.attachment
            ) else { continue }
            insert(region.attachment.id, key: key)
        }
        for region in layout.linkedImageRegions {
            insert(
                region.reference.id,
                key: .media(
                    region.reference.displayURL,
                    maximumPixelDimension:
                        region.reference.isEmoji ? 96 : 720
                )
            )
        }
        for component in layout.componentLayouts {
            for region in component.images {
                insert(
                    region.componentID,
                    key: .media(
                        region.displayURL,
                        maximumPixelDimension: region.maximumPixelDimension
                    )
                )
            }
            for region in component.media where !region.isVideo {
                insert(
                    region.componentID,
                    key: .media(region.displayURL)
                )
            }
        }
        for region in layout.embedRegions {
            guard !region.mediaIsVideo, let url = region.mediaURL else {
                continue
            }
            let candidateIDs: [String] = presentation.items.compactMap { item in
                guard case .image = item.kind,
                      item.url == url || item.previewURL == url
                else { return nil }
                return item.id
            }
            for itemID in candidateIDs {
                insert(itemID, key: .media(url))
            }
        }

        return images
    }

    func mediaViewerPresentation(
        _ presentation: NativeTimelineMediaViewerPresentation,
        componentID: String,
        rowIndex: Int
    ) -> NativeTimelineMediaViewerPresentation {
        guard layouts.indices.contains(rowIndex) else { return presentation }
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
