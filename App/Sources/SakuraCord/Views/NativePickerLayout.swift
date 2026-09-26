import Foundation

/// Exact document geometry, independent of mounted views or lazy size estimates.
/// Like the timeline's row origins, this permits direct jumps into any catalog.
nonisolated struct NativePickerLayout {
    private(set) var origins: [CGFloat] = []
    private(set) var heights: [CGFloat] = []
    private(set) var indicesByID: [String: Int] = [:]
    private(set) var contentHeight: CGFloat = 0

    init(ids: [String] = [], heights: [CGFloat] = []) {
        precondition(ids.count == heights.count)
        self.heights = heights.map { max(0, $0) }
        origins.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() {
            indicesByID[id] = index
            origins.append(contentHeight)
            contentHeight += self.heights[index]
        }
    }

    func rows(intersecting rect: CGRect) -> Range<Int> {
        guard !origins.isEmpty, rect.maxY > 0, rect.minY < contentHeight else { return 0 ..< 0 }
        var low = 0
        var high = origins.count
        while low < high {
            let middle = (low + high) / 2
            if origins[middle] + heights[middle] <= rect.minY { low = middle + 1 } else { high = middle }
        }
        let first = low
        high = origins.count
        while low < high {
            let middle = (low + high) / 2
            if origins[middle] < rect.maxY { low = middle + 1 } else { high = middle }
        }
        return first ..< low
    }
}
