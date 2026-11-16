import CoreGraphics

nonisolated enum NativeTimelineTransientRowGeometry {
    static func contentOriginY(
        base: CGFloat,
        heightDelta: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        guard base > minimum + 0.5 else { return base }
        return max(minimum, base - heightDelta)
    }

    static func contentHeight(
        base: CGFloat,
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        base + heightDelta(
            replacementHeight: replacementHeight,
            baseRowHeight: baseRowHeight
        )
    }

    static func rowOrigin(
        base: CGFloat,
        rowIndex: Int,
        replacementIndex: Int?,
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementIndex, rowIndex > replacementIndex else {
            return base
        }
        return base + heightDelta(
            replacementHeight: replacementHeight,
            baseRowHeight: baseRowHeight
        )
    }

    static func rowHeight(
        base: CGFloat,
        rowIndex: Int,
        replacementIndex: Int?,
        replacementHeight: CGFloat?
    ) -> CGFloat {
        guard rowIndex == replacementIndex, let replacementHeight else {
            return base
        }
        return replacementHeight
    }

    static func heightDelta(
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementHeight, let baseRowHeight else { return 0 }
        return replacementHeight - baseRowHeight
    }
}
