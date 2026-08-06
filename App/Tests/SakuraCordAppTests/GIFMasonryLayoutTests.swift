import Foundation
import SakuraCordModels
@testable import SakuraCord
import Testing

@Test func `GIF picker Escape returns to categories before dismissal`() {
    #expect(!GIFPickerPage.landing.returnsToLandingOnEscape)
    #expect(GIFPickerPage.favorites.returnsToLandingOnEscape)
    #expect(GIFPickerPage.trending.returnsToLandingOnEscape)
    #expect(GIFPickerPage.search("hello").returnsToLandingOnEscape)
}

@Test func `GIF picker routes persisted video media through web playback`() throws {
    let webM = try #require(URL(string: "https://cdn.example/favorite.WEBM?size=2"))
    let mp4 = try #require(URL(string: "https://cdn.example/favorite.mp4?size=2"))
    let gif = try #require(URL(string: "https://cdn.example/search.gif"))
    let extensionless = try #require(URL(string: "https://cdn.example/media/123"))

    #expect(GIFPickerMediaPolicy.requiresWebVideoPlayback(webM))
    #expect(GIFPickerMediaPolicy.requiresWebVideoPlayback(mp4))
    #expect(GIFPickerMediaPolicy.requiresWebVideoPlayback(
        extensionless,
        declaredKind: .video
    ))
    #expect(!GIFPickerMediaPolicy.requiresWebVideoPlayback(gif))
    #expect(!GIFPickerMediaPolicy.requiresWebVideoPlayback(extensionless))
}

@Test func `remote video HTML receives the media source origin`() throws {
    let source = try #require(URL(
        string: "https://cdn.example:8443/media/favorite.webm?size=2"
    ))

    #expect(
        LoopingRemoteVideoPolicy.documentBaseURL(for: source)?.absoluteString
            == "https://cdn.example:8443/"
    )
}

@MainActor
@Test func `message action capsule remains mounted for inline delete confirmation`() {
    let state = NativeTimelineActionCapsuleState()
    var presentationChanges: [Bool] = []
    state.presentationDidChange = { presentationChanges.append($0) }

    state.isDeleteConfirmationPresented = true
    #expect(state.isPresentationActive)
    state.isReactionPickerPresented = true
    state.isDeleteConfirmationPresented = false
    #expect(state.isPresentationActive)
    state.isReactionPickerPresented = false

    #expect(!state.isPresentationActive)
    #expect(presentationChanges == [true, true, true, false])
}

@Test func `GIF masonry preserves Discord result order while balancing aspect ratios`() throws {
    let dimensions = [
        (640, 640), (498, 210), (374, 352),
        (498, 498), (200, 150), (640, 492),
    ]
    let results = dimensions.enumerated().map { index, size in
        GIFSearchResult(
            id: "gif-\(index)",
            title: "GIF \(index)",
            url: URL(string: "https://example.com/gif/\(index)")!,
            previewURL: nil,
            width: size.0,
            height: size.1
        )
    }

    let columns = GIFMasonryLayout.columns(for: results, columnWidth: 200)

    #expect(columns.leading.map(\.ordinal) == [0, 3, 5])
    #expect(columns.trailing.map(\.ordinal) == [1, 2, 4])
    #expect(columns.leading[0].height == 200)
    #expect(abs(columns.trailing[0].height - (CGFloat(200 * 210) / 498)) < 0.001)
}

@Test func `GIF masonry keeps ten thousand stable identities without eager row padding`() {
    let results = (0 ..< 10_000).map { index in
        GIFSearchResult(
            id: "gif-\(index)",
            title: "GIF \(index)",
            url: URL(string: "https://example.com/gif/\(index)")!,
            previewURL: nil,
            width: 200 + index % 7 * 31,
            height: 120 + index % 11 * 29
        )
    }

    let columns = GIFMasonryLayout.columns(for: results, columnWidth: 220)
    let allItems = columns.leading + columns.trailing

    #expect(allItems.count == 10_000)
    #expect(allItems.map(\.ordinal).sorted() == Array(0 ..< 10_000))
    #expect(Set(allItems.map(\.id)).count == 10_000)
    #expect(allItems.allSatisfy { $0.height > 0 })
    #expect(allItems.allSatisfy { item in
        guard let width = item.result.width, let height = item.result.height else {
            return false
        }
        return abs(item.height - (220 * CGFloat(height) / CGFloat(width))) < 0.001
    })
}
