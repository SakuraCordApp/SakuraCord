import AppKit
import Foundation
import SakuraCordModels
@testable import SakuraCord
import Testing

@MainActor
private func firstDescendant<View: NSView>(
    of type: View.Type,
    in root: NSView
) -> View? {
    if let match = root as? View { return match }
    for subview in root.subviews {
        if let match = firstDescendant(of: type, in: subview) {
            return match
        }
    }
    return nil
}

@MainActor
private func mouseEvent(
    _ type: NSEvent.EventType,
    at point: CGPoint,
    windowNumber: Int
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseDown ? 1 : 0
    ))
}

@Test func `GIF picker Escape returns to categories before dismissal`() {
    #expect(!GIFPickerPage.landing.returnsToLandingOnEscape)
    #expect(GIFPickerPage.favorites.returnsToLandingOnEscape)
    #expect(GIFPickerPage.trending.returnsToLandingOnEscape)
    #expect(GIFPickerPage.search("hello").returnsToLandingOnEscape)
}

@Test func `GIF picker keeps supported animation media on the native path`() throws {
    let tenorWebM = try #require(URL(
        string: "https://media.tenor.com/abcAAAPs/favorite.WEBM?size=2"
    ))
    let otherWebM = try #require(URL(
        string: "https://cdn.example/favorite.webm?size=2"
    ))
    let gif = try #require(URL(string: "https://cdn.example/search.gif"))
    let tenor = GIFSearchResult(
        id: "tenor",
        title: "Tenor",
        url: tenorWebM,
        previewURL: tenorWebM,
        mediaURL: tenorWebM,
        mediaKind: .video
    )
    let unsupported = GIFSearchResult(
        id: "other",
        title: "Other",
        url: otherWebM,
        previewURL: otherWebM,
        mediaURL: otherWebM,
        mediaKind: .video
    )
    let native = GIFSearchResult(
        id: "gif",
        title: "GIF",
        url: gif,
        previewURL: gif,
        mediaURL: gif,
        mediaKind: .image
    )

    #expect(
        GIFPickerMediaPolicy.nativeAnimationURL(for: tenor)?.absoluteString
            == "https://media.tenor.com/abcAAAAM/favorite.gif?size=2"
    )
    #expect(
        GIFPickerMediaPolicy.nativeVideoURL(for: tenor)?.absoluteString
            == "https://media.tenor.com/abcAAAPo/favorite.mp4?size=2"
    )
    #expect(
        GIFPickerMediaPolicy.nativeVideoURL(for: unsupported)?.absoluteString
            == "https://cdn.example/favorite.mp4?size=2"
    )
    #expect(
        GIFPickerMediaPolicy.nativeAnimationURL(for: unsupported)?.absoluteString
            == "https://cdn.example/favorite.gif?size=2"
    )
    #expect(GIFPickerMediaPolicy.nativeAnimationURL(for: native) == gif)
}

@Test func `GIF picker preserves Tenor video size when deriving native MP4`() throws {
    let tinyWebM = try #require(URL(
        string: "https://media1.tenor.co/m/abcAAAP3/favorite.webm"
    ))
    let nanoWebM = try #require(URL(
        string: "https://c.tenor.com/abcAAAP4/favorite.webm"
    ))
    let tiny = GIFSearchResult(
        id: "tiny",
        title: "Tiny",
        url: tinyWebM,
        mediaURL: tinyWebM,
        mediaKind: .video
    )
    let nano = GIFSearchResult(
        id: "nano",
        title: "Nano",
        url: nanoWebM,
        mediaURL: nanoWebM,
        mediaKind: .video
    )

    #expect(
        GIFPickerMediaPolicy.nativeVideoURL(for: tiny)?.absoluteString
            == "https://media1.tenor.co/m/abcAAAP1/favorite.mp4"
    )
    #expect(
        GIFPickerMediaPolicy.nativeVideoURL(for: nano)?.absoluteString
            == "https://c.tenor.com/abcAAAP2/favorite.mp4"
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

@Test func `native GIF grid produces stable nonoverlapping masonry frames`() {
    let results = (0 ..< 50).map { index in
        GIFSearchResult(
            id: "gif-\(index)",
            title: "GIF \(index)",
            url: URL(string: "https://example.com/gif/\(index)")!,
            previewURL: nil,
            width: 180 + index % 5 * 30,
            height: 120 + index % 7 * 24
        )
    }
    let geometry = GIFMasonryLayout.geometry(
        for: results,
        columnWidth: 200
    )

    #expect(geometry.itemFrames.count == results.count)
    #expect(geometry.itemFrames.allSatisfy { !$0.isEmpty })
    #expect(geometry.contentSize.width == 434)
    #expect(geometry.contentSize.height > 420)
    for first in geometry.itemFrames.indices {
        for second in geometry.itemFrames.indices where second > first {
            #expect(!geometry.itemFrames[first].intersects(
                geometry.itemFrames[second]
            ))
        }
    }
}

@Test func `GIF hover clears when scrolling moves the pointer outside the visible cell`() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 180)
    let pointer = CGPoint(x: 170, y: 18)

    #expect(GIFPickerHoverPolicy.isHovered(
        pointer: pointer,
        bounds: bounds,
        visibleRect: bounds
    ))
    #expect(!GIFPickerHoverPolicy.isHovered(
        pointer: pointer,
        bounds: bounds,
        visibleRect: CGRect(x: 0, y: 80, width: 200, height: 100)
    ))
    #expect(!GIFPickerHoverPolicy.isHovered(
        pointer: pointer,
        bounds: bounds,
        visibleRect: .zero
    ))
}

@Test func `GIF video failures remain on bounded native image fallback`() throws {
    let first = try #require(URL(string: "https://example.com/first.mp4"))
    let second = try #require(URL(string: "https://example.com/second.mp4"))
    let third = try #require(URL(string: "https://example.com/third.mp4"))
    var memory = GIFPickerVideoFallbackMemory(maximumCount: 2)

    memory.insert(first)
    memory.insert(second)
    memory.insert(second)
    #expect(memory.contains(first))
    #expect(memory.contains(second))

    memory.insert(third)
    #expect(!memory.contains(first))
    #expect(memory.contains(second))
    #expect(memory.contains(third))
}

@MainActor
@Test func `native GIF grid materializes only the visible reusable cells`() throws {
    var chosenIDs: [String] = []
    var toggledIDs: [String] = []
    let results = (0 ..< 50).map { index in
        GIFSearchResult(
            id: "gif-\(index)",
            title: "GIF \(index)",
            url: URL(string: "https://example.com/gif/\(index)")!,
            previewURL: nil,
            width: 200,
            height: 180
        )
    }
    let grid = GIFPickerNativeGrid(
        results: results,
        columnWidth: 200,
        favorites: [],
        mutatingURL: nil,
        choose: { chosenIDs.append($0.id) },
        toggleFavorite: { toggledIDs.append($0.id) }
    )
    let coordinator = grid.makeCoordinator()
    let scrollView = coordinator.makeScrollView()
    let hostWindow = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 434, height: 320),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    hostWindow.contentView = scrollView
    hostWindow.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
    hostWindow.orderFront(nil)
    defer { hostWindow.orderOut(nil) }
    scrollView.frame = hostWindow.contentView?.bounds ?? .zero
    coordinator.update(parent: grid, scrollView: scrollView)
    scrollView.layoutSubtreeIfNeeded()
    let collectionView = try #require(
        scrollView.documentView as? NSCollectionView
    )
    collectionView.layoutSubtreeIfNeeded()

    #expect(collectionView.numberOfItems(inSection: 0) == results.count)
    #expect(collectionView.frame.height > scrollView.contentSize.height)
    #expect(!collectionView.visibleItems().isEmpty)
    #expect(collectionView.visibleItems().count < results.count)
    #expect(collectionView.visibleItems().allSatisfy {
        $0.view.isAccessibilityElement()
    })
    let firstCell = try #require(collectionView.item(
        at: IndexPath(item: 0, section: 0)
    )?.view)
    let favoriteGlass = try #require(firstDescendant(
        of: NSGlassEffectView.self,
        in: firstCell
    ))
    #expect(favoriteGlass.style == .regular)
    #expect(favoriteGlass.effectIsInteractive)
    #expect(favoriteGlass.contentView is NSButton)
    firstCell.layoutSubtreeIfNeeded()
    let chooseDocumentPoint = CGPoint(
        x: firstCell.frame.minX + 20,
        y: firstCell.frame.midY
    )
    #expect(collectionView.hitTest(chooseDocumentPoint) === collectionView)
    let chooseWindowPoint = collectionView.convert(chooseDocumentPoint, to: nil)
    let chooseContentPoint = hostWindow.contentView?.convert(
        chooseWindowPoint,
        from: nil
    )
    #expect(chooseContentPoint.flatMap {
        hostWindow.contentView?.hitTest($0)
    } === collectionView)
    hostWindow.sendEvent(try mouseEvent(
        .leftMouseDown,
        at: chooseWindowPoint,
        windowNumber: hostWindow.windowNumber
    ))
    hostWindow.sendEvent(try mouseEvent(
        .leftMouseUp,
        at: chooseWindowPoint,
        windowNumber: hostWindow.windowNumber
    ))
    #expect(chosenIDs.count == 1)

    favoriteGlass.isHidden = true
    let glassCornerInCell = firstCell.convert(
        CGPoint(x: 2, y: 2),
        from: favoriteGlass
    )
    #expect(favoriteGlass.contentView?.frame.contains(favoriteGlass.bounds) == true)
    let favoriteDocumentPoint = firstCell.convert(
        glassCornerInCell,
        to: collectionView
    )
    #expect(collectionView.hitTest(favoriteDocumentPoint) === collectionView)
    let favoriteWindowPoint = collectionView.convert(
        favoriteDocumentPoint,
        to: nil
    )
    hostWindow.sendEvent(try mouseEvent(
        .leftMouseDown,
        at: favoriteWindowPoint,
        windowNumber: hostWindow.windowNumber
    ))
    hostWindow.sendEvent(try mouseEvent(
        .leftMouseUp,
        at: favoriteWindowPoint,
        windowNumber: hostWindow.windowNumber
    ))
    #expect(toggledIDs.count == 1)
}
