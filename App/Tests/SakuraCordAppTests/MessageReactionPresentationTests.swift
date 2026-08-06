import AppKit
import CoreGraphics
import Foundation
import SakuraCordModels
import SwiftUI
@testable import SakuraCord
import Testing

@Test func `hover popovers prefer below and ignore pointer events`() {
    #expect(NativeHoverPopoverPolicy.preferredEdge == .minY)
    #expect(NativeHoverPopoverPolicy.ignoresMouseEvents)
    #expect(NativeHoverPopoverPolicy.usesIntrinsicContentSize)
}

@MainActor
@Test func `member profile popovers stabilize their size before animating`() {
    #expect(StablePopoverConfiguration.memberProfile.animates)
    #expect(StablePopoverConfiguration.memberProfile.stabilizesInitialContentSize)
    #expect(
        StablePopoverConfiguration.memberProfile.dismissalBehavior
            == .outsideSourceView
    )
}

@Test func `stable hover placement chooses an edge that fits before presentation`() {
    let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let content = CGSize(width: 240, height: 110)

    let centered = StablePopoverPlacementPolicy.placement(
        sourceFrame: CGRect(x: 440, y: 480, width: 40, height: 24),
        visibleFrame: screen,
        contentSize: content,
        preferredEdge: .minY
    )
    #expect(centered.edge == .minY)

    let nearBottom = StablePopoverPlacementPolicy.placement(
        sourceFrame: CGRect(x: 440, y: 12, width: 40, height: 24),
        visibleFrame: screen,
        contentSize: content,
        preferredEdge: .minY
    )
    #expect(nearBottom.edge == .maxY)
    #expect(
        StablePopoverPlacementPolicy.constrainedContentSize(
            content,
            placement: nearBottom
        ).height <= nearBottom.availableSpace - StablePopoverPlacementPolicy.sourceClearance
    )
}

@Test func `stable picker placement changes edges instead of offsetting the arrow`() {
    let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let picker = CGSize(width: 520, height: 420)

    let nearLeft = StablePopoverPlacementPolicy.placement(
        sourceFrame: CGRect(x: 140, y: 440, width: 36, height: 36),
        visibleFrame: screen,
        contentSize: picker,
        preferredEdge: .minY
    )
    #expect(nearLeft.edge == .maxX)

    let nearRight = StablePopoverPlacementPolicy.placement(
        sourceFrame: CGRect(x: 824, y: 440, width: 36, height: 36),
        visibleFrame: screen,
        contentSize: picker,
        preferredEdge: .minY
    )
    #expect(nearRight.edge == .minX)
}

@MainActor
@Test func `short hover labels keep their intrinsic width`() {
    let content = Text("TheUnFunnyClown")
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    let hostingController = NSHostingController(rootView: content)
    let popover = NSPopover()
    popover.contentViewController = hostingController

    let size = sizeIntrinsicPopover(
        popover,
        hostingController: hostingController
    )

    #expect(size.width < 200)
    #expect(size.height < 50)
}

@MainActor
@Test func `long hover labels remain one line and use their full intrinsic width`() {
    let content = Text(String(repeating: "Completed a very long quest ", count: 20))
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    let hostingController = NSHostingController(rootView: content)
    let popover = NSPopover()
    popover.contentViewController = hostingController

    let size = sizeIntrinsicPopover(
        popover,
        hostingController: hostingController
    )

    #expect(size.width > 400)
    #expect(size.height < 50)
}

@MainActor
@Test func `profile hover presenter fills only its badge or connection source`() throws {
    let window = NSWindow(
        contentRect: CGRect(x: 80, y: 80, width: 260, height: 140),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let hostingView = NSHostingView(rootView:
        Color.clear
            .frame(width: 23, height: 23)
            .nativeHoverPopover(isPresented: .constant(false)) {
                Text("Gifting Patron")
            }
    )
    hostingView.frame = CGRect(x: 90, y: 54, width: 23, height: 23)
    let contentView = NSView(frame: window.contentLayoutRect)
    contentView.addSubview(hostingView)
    window.contentView = contentView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    hostingView.layoutSubtreeIfNeeded()
    let source = try #require(firstDescendant(of: StablePopoverSourceView.self, in: hostingView))
    #expect(approximatelyEqual(source.bounds, CGRect(x: 0, y: 0, width: 23, height: 23)))
    #expect(approximatelyEqual(
        window.convertToScreen(source.convert(source.bounds, to: nil)),
        window.convertToScreen(hostingView.convert(hostingView.bounds, to: nil))
    ))
}

@Test func `reaction hover detail uses an independent native application defined popover`() {
    #expect(ReactionHoverDetailPolicy.usesNativePopover)
    #expect(ReactionHoverDetailPolicy.permitsIndependentPresentations)
    #expect(ReactionHoverDetailPolicy.ignoresMouseEvents)
    #expect(ReactionHoverDetailPolicy.behavior == .applicationDefined)
    #expect(ReactionHoverDetailPolicy.preferredEdge == .minY)
    #expect(ReactionHoverDetailPolicy.tracksExactPillBounds)
}

@MainActor
@Test func `reaction hover representable fills the exact pill overlay`() throws {
    let window = NSWindow(
        contentRect: CGRect(x: 80, y: 80, width: 360, height: 180),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let hostingView = NSHostingView(rootView:
        Color.clear
            .frame(width: 146, height: MessageReactionMetrics.pillHeight)
            .reactionHoverDetail(isPresented: .constant(false)) {
                Text("Reaction detail")
            }
    )
    hostingView.frame = CGRect(x: 70, y: 60, width: 146, height: MessageReactionMetrics.pillHeight)
    let contentView = NSView(frame: window.contentLayoutRect)
    contentView.addSubview(hostingView)
    window.contentView = contentView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    hostingView.layoutSubtreeIfNeeded()
    let source = try #require(firstDescendant(
        of: StablePopoverSourceView.self,
        in: hostingView
    ))
    #expect(approximatelyEqual(source.bounds.width, 146))
    #expect(approximatelyEqual(source.bounds.height, MessageReactionMetrics.pillHeight))
    #expect(approximatelyEqual(
        window.convertToScreen(source.convert(source.bounds, to: nil)),
        window.convertToScreen(hostingView.convert(hostingView.bounds, to: nil))
    ))
}

@MainActor
@Test func `reaction hover anchor follows long rows scrolling resize and source reuse`() throws {
    let window = NSWindow(
        contentRect: CGRect(x: 220, y: 240, width: 520, height: 360),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let contentView = TestFlippedView(frame: window.contentLayoutRect)
    let scrollView = NSScrollView(frame: CGRect(x: 20, y: 20, width: 480, height: 300))
    let documentView = TestFlippedView(frame: CGRect(x: 0, y: 0, width: 480, height: 1_100))
    let emojiHeavyRowAbove = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 680))
    let firstPill = StablePopoverSourceView(
        frame: CGRect(x: 130, y: 710, width: 146, height: MessageReactionMetrics.pillHeight)
    )
    let secondPill = StablePopoverSourceView(
        frame: CGRect(x: 300, y: 760, width: 124, height: MessageReactionMetrics.pillHeight)
    )
    documentView.addSubview(emojiHeavyRowAbove)
    documentView.addSubview(firstPill)
    documentView.addSubview(secondPill)
    scrollView.documentView = documentView
    contentView.addSubview(scrollView)
    window.contentView = contentView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    scrollView.contentView.scroll(to: CGPoint(x: 0, y: 620))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    contentView.layoutSubtreeIfNeeded()

    let tracker = StablePopoverAnchorTracker()
    _ = try #require(tracker.attach(to: firstPill, sourceRect: firstPill.bounds))
    let firstPillScreenRect = window.convertToScreen(firstPill.convert(firstPill.bounds, to: nil))
    #expect(approximatelyEqual(anchorScreenRect(tracker, in: window), firstPillScreenRect))
    #expect(tracker.anchorView.superview === contentView)

    // A long row above the reaction can relayout after emoji/media metrics resolve.
    firstPill.frame.origin.y += 90
    _ = try #require(tracker.attach(to: firstPill, sourceRect: firstPill.bounds))
    let relaidOutScreenRect = window.convertToScreen(firstPill.convert(firstPill.bounds, to: nil))
    #expect(approximatelyEqual(anchorScreenRect(tracker, in: window), relaidOutScreenRect))
    #expect(approximatelyEqual(relaidOutScreenRect.minY - firstPillScreenRect.minY, -90))

    scrollView.contentView.scroll(to: CGPoint(x: 0, y: 680))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    _ = try #require(tracker.attach(to: firstPill, sourceRect: firstPill.bounds))
    let scrolledScreenRect = window.convertToScreen(firstPill.convert(firstPill.bounds, to: nil))
    #expect(approximatelyEqual(anchorScreenRect(tracker, in: window), scrolledScreenRect))
    #expect(approximatelyEqual(scrolledScreenRect.minY - relaidOutScreenRect.minY, 60))

    _ = try #require(tracker.attach(to: secondPill, sourceRect: secondPill.bounds))
    let secondPillScreenRect = window.convertToScreen(secondPill.convert(secondPill.bounds, to: nil))
    #expect(tracker.sourceView === secondPill)
    #expect(approximatelyEqual(anchorScreenRect(tracker, in: window), secondPillScreenRect))
    #expect(!approximatelyEqual(anchorScreenRect(tracker, in: window), scrolledScreenRect))

    window.setContentSize(CGSize(width: 640, height: 440))
    scrollView.frame.size = CGSize(width: 600, height: 380)
    contentView.layoutSubtreeIfNeeded()
    _ = try #require(tracker.attach(to: secondPill, sourceRect: secondPill.bounds))
    let resizedScreenRect = window.convertToScreen(secondPill.convert(secondPill.bounds, to: nil))
    #expect(approximatelyEqual(anchorScreenRect(tracker, in: window), resizedScreenRect))

    let popover = testPopover(behavior: ReactionHoverDetailPolicy.behavior)
    defer { popover.close() }
    popover.show(
        relativeTo: tracker.anchorView.bounds,
        of: tracker.anchorView,
        preferredEdge: ReactionHoverDetailPolicy.preferredEdge
    )
    let popoverWindow = try #require(popover.contentViewController?.view.window)
    let arrowSeparation = abs(popoverWindow.frame.maxY - resizedScreenRect.minY)
    #expect(arrowSeparation <= 18)
}

@MainActor
@Test func `reaction hover uses the live pill hover geometry when its AppKit source is stale`() throws {
    let window = NSWindow(
        contentRect: CGRect(x: 180, y: 140, width: 680, height: 520),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let contentView = NSView(frame: window.contentLayoutRect)
    let staleSource = StablePopoverSourceView(
        frame: CGRect(x: 240, y: 390, width: 126, height: MessageReactionMetrics.pillHeight)
    )
    contentView.addSubview(staleSource)
    window.contentView = contentView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    let actualPillInWindow = CGRect(
        x: 240,
        y: 32,
        width: staleSource.bounds.width,
        height: staleSource.bounds.height
    )
    let actualPillInScreen = window.convertToScreen(actualPillInWindow)
    let localHoverPoint = CGPoint(x: 38, y: 9)
    let snapshot = ReactionHoverAnchorSnapshot(
        mouseLocationInScreen: CGPoint(
            x: actualPillInScreen.minX + localHoverPoint.x,
            y: actualPillInScreen.minY + actualPillInScreen.height - localHoverPoint.y
        ),
        mouseLocationInPill: localHoverPoint
    )
    let tracker = StablePopoverAnchorTracker()
    _ = try #require(tracker.attach(
        to: staleSource,
        sourceRect: staleSource.bounds,
        sourceFrameInScreen: snapshot.pillFrameInScreen(pillSize: staleSource.bounds.size)
    ))

    let staleSourceInScreen = window.convertToScreen(staleSource.convert(staleSource.bounds, to: nil))
    #expect(!approximatelyEqual(staleSourceInScreen, actualPillInScreen))
    #expect(approximatelyEqual(anchorScreenRect(tracker, in: window), actualPillInScreen))

    let nextPillInScreen = actualPillInScreen.offsetBy(dx: 170, dy: 74)
    let nextSnapshot = ReactionHoverAnchorSnapshot(
        mouseLocationInScreen: CGPoint(
            x: nextPillInScreen.minX + localHoverPoint.x,
            y: nextPillInScreen.minY + nextPillInScreen.height - localHoverPoint.y
        ),
        mouseLocationInPill: localHoverPoint
    )
    _ = try #require(tracker.attach(
        to: staleSource,
        sourceRect: staleSource.bounds,
        sourceFrameInScreen: nextSnapshot.pillFrameInScreen(pillSize: staleSource.bounds.size)
    ))
    #expect(approximatelyEqual(anchorScreenRect(tracker, in: window), nextPillInScreen))
}

@MainActor
@Test func `reaction hover sizes long reactor names before showing and centers the native popover`() throws {
    let window = NSWindow(
        contentRect: CGRect(x: 120, y: 120, width: 900, height: 420),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let contentView = NSView(frame: window.contentLayoutRect)
    let anchor = NSView(frame: CGRect(x: 430, y: 210, width: 90, height: 28))
    contentView.addSubview(anchor)
    window.contentView = contentView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    let reaction = Reaction(
        emoji: "🤔",
        count: 7,
        reactors: [
            reactor(1, "Alexandria Very Long Display Name"),
            reactor(2, "Bartholomew Another Long Display Name"),
            reactor(3, "Cassandra Extremely Long Display Name"),
            reactor(4, "Demetrius Unusually Long Display Name"),
            reactor(5, "Evangeline Remarkably Long Display Name")
        ]
    )
    let hostingController = NSHostingController(
        rootView: MessageReactionTooltip(reaction: reaction, emojiURL: nil)
    )
    let popover = NSPopover()
    popover.animates = false
    popover.behavior = ReactionHoverDetailPolicy.behavior
    popover.contentViewController = hostingController
    let contentSize = sizeReactionHoverPopover(
        popover,
        hostingController: hostingController
    )
    #expect(contentSize.height > 70)
    #expect(contentSize.height < ReactionHoverDetailPolicy.maximumContentSize.height)

    popover.show(
        relativeTo: anchor.bounds,
        of: anchor,
        preferredEdge: ReactionHoverDetailPolicy.preferredEdge
    )
    defer { popover.close() }
    let popoverWindow = try #require(popover.contentViewController?.view.window)
    let anchorInScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    #expect(abs(popoverWindow.frame.midX - anchorInScreen.midX) <= 2)
}

@MainActor
@Test func `application defined reaction popover coexists with another native popover`() {
    let window = NSWindow(
        contentRect: CGRect(x: 40, y: 40, width: 320, height: 160),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let contentView = NSView(frame: window.contentLayoutRect)
    let profileAnchor = NSView(frame: CGRect(x: 30, y: 80, width: 30, height: 30))
    let reactionAnchor = NSView(frame: CGRect(x: 180, y: 80, width: 60, height: 28))
    contentView.addSubview(profileAnchor)
    contentView.addSubview(reactionAnchor)
    window.contentView = contentView
    window.orderFrontRegardless()

    let profilePopover = testPopover(behavior: .transient)
    let reactionPopover = testPopover(behavior: ReactionHoverDetailPolicy.behavior)
    defer {
        reactionPopover.close()
        profilePopover.close()
        window.orderOut(nil)
    }

    profilePopover.show(relativeTo: profileAnchor.bounds, of: profileAnchor, preferredEdge: .maxX)
    reactionPopover.show(
        relativeTo: reactionAnchor.bounds,
        of: reactionAnchor,
        preferredEdge: ReactionHoverDetailPolicy.preferredEdge
    )
    reactionPopover.contentViewController?.view.window?.ignoresMouseEvents =
        ReactionHoverDetailPolicy.ignoresMouseEvents

    #expect(profilePopover.isShown)
    #expect(reactionPopover.isShown)
    #expect(reactionPopover.contentViewController?.view.window?.ignoresMouseEvents == true)
}

@MainActor
@Test func `reaction picker snapshots the initiating control and uses control specific edges`() {
    #expect(StableReactionPickerAnchorPolicy.freezesAnchorWhilePresented)
    #expect(ReactionActionMenuPresentation.inline.popoverEdge == .maxX)
    #expect(ReactionActionMenuPresentation.toolbar.popoverEdge == .minY)
    #expect(ReactionActionMenuPresentation.inline.pickerAccessibilityIdentifier
        == "reaction-picker-inline")
    #expect(ReactionActionMenuPresentation.toolbar.pickerAccessibilityIdentifier
        == "reaction-picker-toolbar")
}

@MainActor
@Test func `reaction picker snapshot never becomes a child of the window content root`() throws {
    let window = NSWindow(
        contentRect: CGRect(x: 40, y: 40, width: 320, height: 160),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let contentView = NSView(frame: window.contentLayoutRect)
    let sourceView = StableReactionPickerSourceView(
        frame: CGRect(x: 180, y: 80, width: 36, height: 36)
    )
    contentView.addSubview(sourceView)
    window.contentView = contentView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    let snapshot = sourceView.installSnapshotAnchor(in: window)
    let contentContainer = try #require(contentView.superview)

    #expect(snapshot.superview === contentContainer)
    #expect(snapshot.superview !== contentView)
}

@Test func `visible reaction preview loading is stable and skips known reactors`() {
    let missing = Reaction(emoji: "🔥", count: 8)
    let known = Reaction(emoji: "✅", count: 2, reactors: [reactor(1, "One")])
    let invalid = Reaction(emoji: "", count: 4)

    #expect(
        MessageReactionPresentation.previewLoadCandidates(from: [missing, known, invalid])
            .map(\.id) == [missing.id]
    )
    let initialKey = MessageReactionPresentation.previewLoadKey(for: [missing, known])
    let enrichedKey = MessageReactionPresentation.previewLoadKey(for: [
        Reaction(emoji: "🔥", count: 8, reactors: [reactor(2, "Two")]),
        known
    ])
    let countChangedKey = MessageReactionPresentation.previewLoadKey(for: [
        Reaction(emoji: "🔥", count: 9),
        known
    ])
    #expect(initialKey == enrichedKey)
    #expect(initialKey == countChangedKey)
    #expect(
        MessageReactionAutomaticLoadKey(reactionID: missing.id, needsLoad: true)
            == MessageReactionAutomaticLoadKey(
                reactionID: Reaction(emoji: "🔥", count: 9).id,
                needsLoad: true
            )
    )
    #expect(
        MessageReactionAutomaticLoadKey(reactionID: missing.id, needsLoad: true)
            != MessageReactionAutomaticLoadKey(reactionID: missing.id, needsLoad: false)
    )
}

@Test func `reaction presentation removes empty artifacts and coalesces duplicate identities`() {
    let first = Reaction(
        emoji: "<:old_name:123>", count: 2,
        reactors: [reactor(1, "One")]
    )
    let renamed = Reaction(
        emoji: "<a:new_name:123>", count: 4, didCurrentUserReact: true,
        reactors: [reactor(1, "One"), reactor(2, "Two")]
    )

    let items = MessageReactionPresentation.items(from: [
        Reaction(emoji: "", count: 3),
        Reaction(emoji: "   ", count: 1),
        Reaction(emoji: "✅", count: 0),
        first,
        renamed,
        Reaction(emoji: "🎉", count: 1)
    ])

    #expect(items.map(\.id) == ["custom:123", "unicode:🎉"])
    #expect(items[0].count == 4)
    #expect(items[0].didCurrentUserReact)
    #expect(items[0].reactors.map(\.id) == [UserID(rawValue: 1), UserID(rawValue: 2)])
}

@Test func `forum summary shows the highest count and preserves source order for ties`() {
    let reactions = [
        Reaction(emoji: "🐛", count: 2),
        Reaction(emoji: "❤️", count: 3),
        Reaction(emoji: "🎉", count: 3),
    ]
    let displayed = ForumPostReactionPresentation.displayedReaction(
        reactions: reactions,
        defaultReaction: ForumDefaultReaction(emojiName: "🐛")
    )

    #expect(displayed?.emoji == "❤️")
    #expect(displayed?.count == 3)
}

@Test func `forum summary uses the default emoji without a count only when empty`() throws {
    let unicodeDefault = ForumPostReactionPresentation.displayedReaction(
        reactions: [],
        defaultReaction: ForumDefaultReaction(emojiName: "🐛")
    )
    #expect(unicodeDefault == Reaction(emoji: "🐛", count: 0))
    #expect(
        MessageReactionPresentation.tooltipDescription(for: try #require(unicodeDefault))
            == "No reactions yet"
    )

    let customDefault = ForumPostReactionPresentation.displayedReaction(
        reactions: [],
        defaultReaction: ForumDefaultReaction(emojiID: "123", emojiName: "bug_hunt")
    )
    #expect(customDefault?.id == "custom:123")
    #expect(customDefault?.count == 0)
    #expect(
        ForumPostReactionPresentation.displayedReaction(
            reactions: [],
            defaultReaction: nil
        ) == nil
    )
}

@Test func `forum summary never assigns the aggregate count to the default emoji`() {
    let nonDefault = Reaction(emoji: "❤️", count: 1)
    let first = ForumPostReactionPresentation.displayedReaction(
        reactions: [nonDefault],
        defaultReaction: ForumDefaultReaction(emojiName: "🐛")
    )
    #expect(first == nonDefault)

    let withDefault = ForumPostReactionPresentation.displayedReaction(
        reactions: [nonDefault, Reaction(emoji: "🐛", count: 1)],
        defaultReaction: ForumDefaultReaction(emojiName: "🐛")
    )
    #expect(withDefault == nonDefault)
    #expect(withDefault?.count == 1)
}

@Test func `custom reaction identity survives emoji rename and animation changes`() {
    #expect(Reaction(emoji: "<:old_name:123>", count: 1).id == "custom:123")
    #expect(Reaction(emoji: "<a:new_name:123>", count: 1).id == "custom:123")
    #expect(Reaction(emoji: "✅", count: 1).id == "unicode:✅")
}

@Test func `reactor previews show five people then four plus the remaining count`() {
    let reaction = Reaction(
        emoji: "✅", count: 5,
        reactors: [
            reactor(1, "One"), reactor(1, "Duplicate"), reactor(2, "Two"),
            reactor(3, "Three"), reactor(4, "Four"), reactor(5, "Five")
        ]
    )
    #expect(MessageReactionPresentation.previewPlan(for: reaction) == MessageReactionPreviewPlan(
        reactors: [
            reactor(1, "One"), reactor(2, "Two"), reactor(3, "Three"),
            reactor(4, "Four"), reactor(5, "Five")
        ],
        overflowCount: 0
    ))

    let overflowing = Reaction(
        emoji: "🔥", count: 9,
        reactors: (1 ... 5).map { reactor(UInt64($0), "User \($0)") }
    )
    #expect(MessageReactionPresentation.previewPlan(for: overflowing) == MessageReactionPreviewPlan(
        reactors: (1 ... 4).map { reactor(UInt64($0), "User \($0)") },
        overflowCount: 5
    ))

    let single = Reaction(
        emoji: "🎉", count: 1,
        reactors: [reactor(1, "One"), reactor(2, "Two")]
    )
    #expect(MessageReactionPresentation.previewPlan(for: single).reactors.map(\.displayName) == ["One"])
}

@Test func `reactor preview math safely handles malformed counts and duplicate people`() {
    #expect(MessageReactionPresentation.previewPlan(for: Reaction(
        emoji: "✅", count: -4, reactors: [reactor(1, "One")]
    )).isEmpty)
    let plan = MessageReactionPresentation.previewPlan(for: Reaction(
        emoji: "✅", count: 7,
        reactors: [reactor(1, "One"), reactor(1, "Duplicate"), reactor(2, "Two")]
    ))
    #expect(plan.reactors.map(\.displayName) == ["One", "Two"])
    #expect(plan.overflowCount == 5)
}

@Test func `tooltip summaries distinguish known reactors from an aggregate count`() {
    #expect(
        MessageReactionPresentation.tooltipSummary(for: Reaction(emoji: "🔥", count: 8))
            == .countOnly(8)
    )
    #expect(
        MessageReactionPresentation.tooltipSummary(
            for: Reaction(
                emoji: "🔥", count: 4,
                reactors: [reactor(1, "One"), reactor(2, "Two")]
            )
        ) == .knownReactors(names: ["One", "Two"], remainingCount: 2)
    )
}

@Test func `tooltip description does not repeat the displayed emoji`() {
    let reaction = Reaction(
        emoji: "✅", count: 3,
        reactors: [reactor(1, "Nova Chen"), reactor(2, "Two")]
    )

    let description = MessageReactionPresentation.tooltipDescription(for: reaction)
    #expect(description == "Reacted by Nova Chen and Two, and 1 others")
    #expect(!description.contains(reaction.emoji))
}

@MainActor
@Test func `tooltip supplies discord names for native and custom emoji`() {
    #expect(
        MessageReactionPresentation.emojiName(for: Reaction(emoji: "✅", count: 1))
            == ":white_check_mark:"
    )
    #expect(
        MessageReactionPresentation.emojiName(
            for: Reaction(emoji: "<:party_blob:123>", count: 1)
        ) == ":party_blob:"
    )
}

@Test func `legacy reaction payloads decode without reactor previews`() throws {
    let data = try #require(#"{"emoji":"✅","count":3,"didCurrentUserReact":true}"#.data(using: .utf8))
    let reaction = try JSONDecoder().decode(Reaction.self, from: data)
    #expect(reaction.emoji == "✅")
    #expect(reaction.count == 3)
    #expect(reaction.didCurrentUserReact)
    #expect(!reaction.didCurrentUserBurstReact)
    #expect(reaction.reactors.isEmpty)
}

@Test func `reaction sized items wrap cleanly at narrow widths`() {
    let plan = InlineWrappingLayoutPlan.frames(
        sizes: [
            CGSize(width: 112, height: MessageReactionMetrics.pillHeight),
            CGSize(width: 138, height: MessageReactionMetrics.pillHeight),
            CGSize(width: 96, height: MessageReactionMetrics.pillHeight),
            CGSize(width: 124, height: MessageReactionMetrics.pillHeight)
        ],
        maximumWidth: 250,
        horizontalSpacing: MessageReactionMetrics.horizontalSpacing,
        verticalSpacing: MessageReactionMetrics.verticalSpacing
    )

    #expect(plan.frames.count == 4)
    #expect(plan.frames.allSatisfy { $0.width > 0 && $0.height == MessageReactionMetrics.pillHeight })
    let rowStride = MessageReactionMetrics.pillHeight + MessageReactionMetrics.verticalSpacing
    #expect(plan.frames.map(\.minY) == [0, rowStride, rowStride, rowStride * 2])
    #expect(plan.size.height == MessageReactionMetrics.pillHeight * 3
        + MessageReactionMetrics.verticalSpacing * 2)
}

@Test func `reaction metrics use one compact optical slot for every emoji kind`() {
    #expect(MessageReactionMetrics.pillHeight <= 28)
    #expect(MessageReactionMetrics.nativeEmojiVisualScale < 1)
    #expect(MessageReactionMetrics.avatarSize < MessageReactionMetrics.emojiSize)
}

@Test func `reaction layout applies the same gap between every adjacent pill`() {
    let plan = InlineWrappingLayoutPlan.frames(
        sizes: [
            CGSize(width: 91, height: MessageReactionMetrics.pillHeight),
            CGSize(width: 104, height: MessageReactionMetrics.pillHeight),
            CGSize(width: 83, height: MessageReactionMetrics.pillHeight)
        ],
        maximumWidth: 400,
        horizontalSpacing: MessageReactionMetrics.horizontalSpacing,
        verticalSpacing: MessageReactionMetrics.verticalSpacing
    )

    #expect(plan.frames[1].minX - plan.frames[0].maxX
        == MessageReactionMetrics.horizontalSpacing)
    #expect(plan.frames[2].minX - plan.frames[1].maxX
        == MessageReactionMetrics.horizontalSpacing)
}

private func reactor(_ id: UInt64, _ displayName: String) -> ReactionReactor {
    ReactionReactor(id: UserID(rawValue: id), displayName: displayName)
}

@MainActor
private func testPopover(behavior: NSPopover.Behavior) -> NSPopover {
    let controller = NSViewController()
    controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 140, height: 56))
    let popover = NSPopover()
    popover.animates = false
    popover.behavior = behavior
    popover.contentViewController = controller
    return popover
}

@MainActor
private func anchorScreenRect(
    _ tracker: StablePopoverAnchorTracker,
    in window: NSWindow
) -> CGRect {
    window.convertToScreen(tracker.anchorView.convert(tracker.anchorView.bounds, to: nil))
}

private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
    approximatelyEqual(lhs.minX, rhs.minX, tolerance: tolerance)
        && approximatelyEqual(lhs.minY, rhs.minY, tolerance: tolerance)
        && approximatelyEqual(lhs.width, rhs.width, tolerance: tolerance)
        && approximatelyEqual(lhs.height, rhs.height, tolerance: tolerance)
}

@MainActor
private func firstDescendant<ViewType: NSView>(
    of type: ViewType.Type,
    in root: NSView
) -> ViewType? {
    if let match = root as? ViewType { return match }
    for subview in root.subviews {
        if let match = firstDescendant(of: type, in: subview) { return match }
    }
    return nil
}

private final class TestFlippedView: NSView {
    override var isFlipped: Bool { true }
}
