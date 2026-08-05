import Foundation
import Observation

@MainActor
@Observable
final class MediaViewerInteractionModel {
    nonisolated static let minimumScale: CGFloat = 1
    nonisolated static let maximumScale: CGFloat = 8

    let itemCount: Int
    private(set) var selection: Int
    private(set) var scale: CGFloat = minimumScale
    private(set) var offset = CGSize.zero
    var isSaving = false
    var feedback: MediaViewerFeedback?
    var errorMessage: String?

    init(itemCount: Int, selection: Int) {
        self.itemCount = max(1, itemCount)
        self.selection = min(max(0, selection), max(0, itemCount - 1))
    }

    var canMoveBackward: Bool { itemCount > 1 }
    var canMoveForward: Bool { itemCount > 1 }

    @discardableResult
    func move(_ delta: Int) -> Bool {
        guard itemCount > 1 else { return false }
        let destination = ((selection + delta) % itemCount + itemCount)
            % itemCount
        return select(destination)
    }

    @discardableResult
    func select(_ index: Int) -> Bool {
        let destination = min(max(0, index), itemCount - 1)
        guard destination != selection else { return false }
        selection = destination
        resetZoom()
        return true
    }

    func toggleZoom() {
        if scale > Self.minimumScale + 0.01 {
            resetZoom()
        } else {
            commitScale(2)
        }
    }

    func commitScale(_ value: CGFloat) {
        scale = min(Self.maximumScale, max(Self.minimumScale, value))
        if scale == Self.minimumScale {
            offset = .zero
        }
    }

    func commitOffset(_ value: CGSize) {
        offset = scale > Self.minimumScale ? value : .zero
    }

    func resetZoom() {
        scale = Self.minimumScale
        offset = .zero
    }
}

struct MediaViewerFeedback: Equatable {
    let message: String
}

nonisolated enum MediaViewerLayoutPolicy {
    static func restingFrame(
        availableSize: CGSize,
        horizontalInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGRect {
        let width = max(1, availableSize.width - horizontalInset * 2)
        let height = max(1, availableSize.height - topInset - bottomInset)
        return CGRect(
            x: horizontalInset,
            y: topInset,
            width: width,
            height: height
        )
    }

    static func fittedSize(
        mediaWidth: Int?,
        mediaHeight: Int?,
        availableSize: CGSize
    ) -> CGSize {
        let availableWidth = max(1, availableSize.width)
        let availableHeight = max(1, availableSize.height)
        guard let mediaWidth,
              let mediaHeight,
              mediaWidth > 0,
              mediaHeight > 0
        else {
            return CGSize(width: availableWidth, height: availableHeight)
        }

        let mediaAspect = CGFloat(mediaWidth) / CGFloat(mediaHeight)
        let availableAspect = availableWidth / availableHeight
        if mediaAspect > availableAspect {
            return CGSize(
                width: availableWidth,
                height: availableWidth / mediaAspect
            )
        }
        return CGSize(
            width: availableHeight * mediaAspect,
            height: availableHeight
        )
    }

    static func clampedOffset(
        _ offset: CGSize,
        scale: CGFloat,
        fittedSize: CGSize,
        availableSize: CGSize
    ) -> CGSize {
        guard scale > 1 else { return .zero }
        let horizontalLimit = max(
            0,
            (fittedSize.width * scale - availableSize.width) / 2
        )
        let verticalLimit = max(
            0,
            (fittedSize.height * scale - availableSize.height) / 2
        )
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(verticalLimit, max(-verticalLimit, offset.height))
        )
    }

    static func transformedImageFrame(
        restingFrame: CGRect,
        fittedSize: CGSize,
        scale: CGFloat,
        offset: CGSize
    ) -> CGRect {
        let transformedSize = CGSize(
            width: fittedSize.width * scale,
            height: fittedSize.height * scale
        )
        return CGRect(
            x: restingFrame.midX + offset.width - transformedSize.width / 2,
            y: restingFrame.midY + offset.height - transformedSize.height / 2,
            width: transformedSize.width,
            height: transformedSize.height
        )
    }

    static func offsetByScrolling(
        _ offset: CGSize,
        scrollingDelta: CGSize,
        scale: CGFloat,
        fittedSize: CGSize,
        availableSize: CGSize
    ) -> CGSize {
        clampedOffset(
            CGSize(
                width: offset.width + scrollingDelta.width,
                height: offset.height + scrollingDelta.height
            ),
            scale: scale,
            fittedSize: fittedSize,
            availableSize: availableSize
        )
    }
}
