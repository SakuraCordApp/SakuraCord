import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
extension NativeMemberListCanvasView {
    func itemRange(intersecting rect: CGRect) -> Range<Int> {
        guard !items.isEmpty else { return 0 ..< 0 }
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if origins[mid] + items[mid].height > rect.minY {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let first = low
        var last = first
        while last < items.count, origins[last] < rect.maxY { last += 1 }
        return min(first, items.count) ..< min(last, items.count)
    }

    func index(at point: CGPoint) -> Int? {
        guard point.y >= NativeMemberListMetrics.verticalInset else { return nil }
        var low = 0
        var high = origins.count
        while low < high {
            let mid = (low + high) / 2
            if origins[mid] <= point.y { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard items.indices.contains(index), itemRect(at: index).contains(point) else { return nil }
        return index
    }

    func itemRect(at index: Int) -> CGRect {
        CGRect(x: 0, y: origins[index], width: bounds.width, height: items[index].height)
    }

    func paintedRowRect(at index: Int) -> CGRect {
        CGRect(
            x: NativeMemberListMetrics.horizontalInset,
            y: origins[index] + 1,
            width: max(0, bounds.width - NativeMemberListMetrics.horizontalInset * 2),
            height: NativeMemberListMetrics.paintedRowHeight
        )
    }

    /// The avatar's square container, centred vertically in the painted row.
    func avatarContainerRect(at index: Int, leadingInset: CGFloat) -> CGRect {
        let row = paintedRowRect(at: index)
        return CGRect(
            x: row.minX + leadingInset,
            y: row.minY + (row.height - NativeMemberListMetrics.avatarContainerSize) / 2,
            width: NativeMemberListMetrics.avatarContainerSize,
            height: NativeMemberListMetrics.avatarContainerSize
        )
    }

    /// Where a member row's name and activity text start.
    func textOriginX(at index: Int) -> CGFloat {
        paintedRowRect(at: index).minX + 4 + NativeMemberListMetrics.avatarContainerSize + 8
    }

    func gatewayRange(intersecting visibleRect: CGRect) -> ClosedRange<Int>? {
        let indexes = itemRange(intersecting: visibleRect)
        let values = indexes.compactMap { items[$0].gatewayIndex }
        guard let first = values.min(), let last = values.max() else { return nil }
        return first ... last
    }

}
