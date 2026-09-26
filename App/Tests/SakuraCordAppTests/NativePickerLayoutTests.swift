import Foundation
import AppKit
import SwiftUI
import Testing
@testable import SakuraCord

@Test func pickerViewportLookupMatchesExactRowsAcrossLargeJumps() {
    let heights: [CGFloat] = (0 ..< 20_000).map { $0.isMultiple(of: 37) ? 32 : 43 }
    let ids = heights.indices.map { "row-\($0)" }
    let layout = NativePickerLayout(ids: ids, heights: heights)
    var origin: CGFloat = 0
    let frames = heights.map { height -> CGRect in
        defer { origin += height }
        return CGRect(x: 0, y: origin, width: 473, height: height)
    }
    for fraction in [0.0, 0.75, 0.1, 0.99, 0.4, 1.0] {
        let viewport = CGRect(x: 0, y: (origin - 332) * fraction, width: 473, height: 332)
        let expected = frames.indices.filter { frames[$0].maxY > viewport.minY && frames[$0].minY < viewport.maxY }
        #expect(Array(layout.rows(intersecting: viewport)) == expected)
        #expect(layout.rows(intersecting: viewport).count <= 12)
    }
    #expect(layout.contentHeight == origin)
    #expect(layout.indicesByID["row-15000"] == 15000)
}

@Test func pickerViewportLookupHandlesExactEdgesAndEmptyDocuments() {
    let empty = NativePickerLayout()
    #expect(empty.rows(intersecting: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    let layout = NativePickerLayout(ids: ["header", "first", "last"], heights: [32, 43, 43])
    #expect(layout.rows(intersecting: CGRect(x: 0, y: 32, width: 100, height: 43)) == 1 ..< 2)
    #expect(layout.rows(intersecting: CGRect(x: 0, y: 118, width: 100, height: 10)).isEmpty)
    #expect(layout.rows(intersecting: CGRect(x: 0, y: -10, width: 100, height: 10)).isEmpty)
    #expect(layout.rows(intersecting: CGRect(x: 0, y: -10, width: 100, height: 20)) == 0 ..< 1)
}

@MainActor @Test func pickerJumpBoundsMountedContentAndPreservesAnchorAcrossCatalogUpdates() {
    struct Row: Identifiable { let id: String }
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 473, height: 332))
    let canvas = NativePickerCanvas<Row>()
    scroll.documentView = canvas
    var rows = (0 ..< 20_000).map { Row(id: "row-\($0)") }
    func update(_ revision: Int) {
        canvas.update(rows: rows, revision: revision, width: 473, height: { _, _ in 43 }, visible: { _ in }, content: { AnyView(Text($0.id)) })
    }
    update(0)
    let position = NativePickerScrollPosition()
    position.scrollTo("row-15000", anchor: .top)
    canvas.apply(position.request)
    #expect(abs(scroll.contentView.bounds.minY - CGFloat(15_000 * 43)) < 0.01)
    #expect(canvas.subviews.count <= 11)
    #expect(canvas.subviews.reduce(CGFloat.zero) { $0 + $1.frame.height } <= 332 + 3 * 43)
    rows.insert(Row(id: "new-section"), at: 0)
    update(1)
    #expect(abs(scroll.contentView.bounds.minY - CGFloat(15_001 * 43)) < 0.01)
    rows = [Row(id: "search-result")]
    update(2)
    #expect(scroll.contentView.bounds.minY == 0)
    #expect(canvas.geometry.contentHeight == 43)
    canvas.stop()
    #expect(canvas.subviews.isEmpty)
}

@MainActor @Test func recycledEmojiControlsActivateTheCurrentCellAndReleaseActions() throws {
    let interaction = EmojiPickerInteractionModel()
    var activated: [String] = []
    func row(_ id: String, value: String) -> EmojiDocumentRowView {
        let item = EmojiPickerItem.native(NativeEmoji(value: value, name: id, aliases: "", category: .smileys))
        let cell = EmojiPickerCell(id: id, rowID: id, item: item)
        return EmojiDocumentRowView(
            row: EmojiDocumentRow(id: id, section: .native(.smileys), content: .emojis([cell])),
            skinTone: .standard, interaction: interaction, isFavorite: { _ in false },
            choose: { cell, _ in activated.append(cell.id) }, toggleFavorite: { _ in }, retry: { _ in }
        )
    }
    let view = try #require(row("first", value: "😀").makeNativeView(reusing: nil, environment: EnvironmentValues()))
    let control = try #require(view.subviews.first)
    #expect(control.accessibilityPerformPress())
    let recycled = row("second", value: "😃").makeNativeView(reusing: view, environment: EnvironmentValues())
    #expect(recycled === view)
    #expect(view.subviews.first === control)
    #expect(control.accessibilityPerformPress())
    #expect(activated == ["first", "second"])
    (view as? any NativePickerReusableRow)?.clear()
    #expect(!control.accessibilityPerformPress())
    #expect(activated == ["first", "second"])
}
