import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
final class NativeMemberListCanvasView: NSView, WindowModalInputParticipant {
    var cosmeticPolicy = ProfileCosmeticPolicy()

    nonisolated struct Header: Equatable, Sendable {
        let id: MemberSection.SectionIdentifier
        let title: String
        let colorHex: UInt32?
        let totalCount: Int
        let gatewayStartIndex: Int?
        let isLoadingSkeleton: Bool

        init(_ section: MemberSection) {
            id = section.id
            title = section.title
            colorHex = section.colorHex
            totalCount = section.totalCount
            gatewayStartIndex = section.gatewayStartIndex
            isLoadingSkeleton = section.isLoadingSkeleton
        }
    }

    nonisolated enum ItemID: Hashable, Sendable {
        case header(MemberSection.SectionIdentifier)
        case member(UserID)
        case placeholder(Int)
    }

    nonisolated enum Item: Equatable, Sendable {
        case header(Header)
        // A large guild has many unloaded rows. Keep their storage independent
        // of the full Member value while preserving the enum's value semantics.
        indirect case member(Member, gatewayIndex: Int?)
        case placeholder(gatewayIndex: Int)

        var id: ItemID {
            switch self {
            case .header(let section): .header(section.id)
            case .member(let member, _): .member(member.id)
            case .placeholder(let index): .placeholder(index)
            }
        }

        var gatewayIndex: Int? {
            switch self {
            case .header(let section): section.gatewayStartIndex
            case .member(_, let index): index
            case .placeholder(let index): index
            }
        }

        var height: CGFloat {
            switch self {
            case .header: NativeMemberListMetrics.sectionHeaderHeight
            case .member, .placeholder: NativeMemberListMetrics.memberRowHeight
            }
        }
    }

    nonisolated final class PreparedText: @unchecked Sendable {
        let nameFont: NSFont
        let name: CTLine
        let nameTruncationToken: CTLine
        let nameWidth: CGFloat
        let activity: CTLine?
        let activityTruncationToken: CTLine?
        let activityWidth: CGFloat

        init(
            nameFont: NSFont,
            name: CTLine,
            nameTruncationToken: CTLine,
            nameWidth: CGFloat,
            activity: CTLine?,
            activityTruncationToken: CTLine?,
            activityWidth: CGFloat
        ) {
            self.nameFont = nameFont
            self.name = name
            self.nameTruncationToken = nameTruncationToken
            self.nameWidth = nameWidth
            self.activity = activity
            self.activityTruncationToken = activityTruncationToken
            self.activityWidth = activityWidth
        }
    }

    nonisolated struct PreparationSnapshot: Sendable {
        let presentation: NativeMemberListPresentation
        let sections: [MemberSection]
        let items: [Item]
        let itemIndexesByID: [ItemID: Int]
        let origins: [CGFloat]
        let contentHeight: CGFloat
        let preparedText: [ItemID: PreparedText]
        let loadedItemIndexes: [Int]
    }

    nonisolated struct PreparedDocument: Sendable {
        let presentation: NativeMemberListPresentation
        let sections: [MemberSection]
        let items: [Item]
        let itemIndexesByID: [ItemID: Int]
        let origins: [CGFloat]
        let contentHeight: CGFloat
        let preparedText: [ItemID: PreparedText]
        let loadedItemIndexes: [Int]
        let hasLoadingPlaceholders: Bool
        let stableLayoutChangedIndexes: [Int]?
    }

    struct SkeletonDrawingStyle {
        let phase: Double?
        let fullOpacityGradient: CGGradient?
        let secondaryOpacityGradient: CGGradient?
    }

    nonisolated struct StableLayoutProjection {
        let headerIndexes: [Int]
        let desiredMembersByItemIndex: [Int: Member]
    }

    struct ActivityEmojiOverlayID: Hashable {
        let itemID: ItemID
        let ordinal: Int
    }

    struct ActivityEmojiOverlayConfiguration: Equatable {
        let url: URL
        let opacity: CGFloat
    }

    struct AvatarOverlayPresentation {
        let id: ItemID
        let member: Member
        let index: Int
    }

    struct AvatarOverlayConfiguration: Equatable {
        let member: Member
        let isHovered: Bool
    }

    struct ActivityEmojiOverlayPresentation {
        let id: ActivityEmojiOverlayID
        let configuration: ActivityEmojiOverlayConfiguration
        let frame: CGRect
    }

    nonisolated static func requiresAvatarOverlay(for member: Member) -> Bool {
        let avatarURL = member.guildAvatarURL ?? member.user.avatarURL
        return member.user.avatarDecorationURL != nil
            || avatarURL.map(
                NativeTimelineAvatarPresentation.shouldDecodeAnimation
            ) == true
    }

    struct GuildTagPresentation {
        let line: CTLine
        let width: CGFloat
        let iconWidth: CGFloat
        let image: CGImage?
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        layer?.setNeedsDisplay()
        rowOverlay?.needsDisplay = true
        rowForegroundOverlay?.needsDisplay = true
        for overlay in avatarOverlays.values {
            overlay.needsDisplay = true
        }
        for overlay in activityEmojiOverlays.values {
            overlay.needsDisplay = true
        }
    }

    var items: [Item] = []
    var presentedSections: [MemberSection] = []
    var itemIndexesByID: [ItemID: Int] = [:]
    var customEmojiURLsByID: CustomEmojiImageURLs = [:]
    var origins: [CGFloat] = []
    var contentHeight: CGFloat = 1
    var preparedText: [ItemID: PreparedText] = [:]
    var presentation = NativeMemberListPresentation()
    var loadedItemIndexes: [Int] = []
    var selectedMemberID: UserID?
    var openProfile: ((ProfilePresentationState) -> Void)?
    var profilePresentation: ProfilePresentationState?
    var isProfilePresented = false
    var dismissProfile: () -> Void = {}
    var selectMember: (Member) -> Void = { _ in }
    var hoveredIndex: Int?
    var isScrolling = false
    var interactionsBlocked = false
    var trackingArea: NSTrackingArea?
    var rowOverlay: NSHostingView<AnyView>?
    var rowForegroundOverlay: NativeMemberForegroundOverlayView?
    var rowOverlayIndex: Int?
    var profileAnchorIndex: Int?
    let profilePopoverCoordinator =
        StableAnchoredPopoverPresenter<AnyView>.Coordinator()
    lazy var profilePopoverAnchor = StablePopoverAnchor(
        sourceView: self,
        sourceRect: { [weak self] in
            guard let self,
                  let index = self.profileAnchorIndex,
                  self.items.indices.contains(index)
            else { return nil }
            return self.paintedRowRect(at: index)
        }
    )
    var avatarOverlays: [ItemID: NSHostingView<AnyView>] = [:]
    var avatarOverlayConfigurations: [ItemID: AvatarOverlayConfiguration] = [:]
    var activityEmojiOverlays: [ActivityEmojiOverlayID: NSHostingView<AnyView>] = [:]
    var activityEmojiOverlayConfigurations: [
        ActivityEmojiOverlayID: ActivityEmojiOverlayConfiguration
    ] = [:]
    var accessibilityRows: [ItemID: NativeMemberAccessibilityProxyView] = [:]
    var imageTasks: [URL: Task<Void, Never>] = [:]
    var imageTaskPriorities: [URL: MediaLoadPriority] = [:]
    var imageTaskPixelDimensions: [URL: Int] = [:]
    var imageRequestItemIDs: [URL: Set<ItemID>] = [:]
    var images: [URL: CGImage] = [:]
    var imagePixelDimensions: [URL: Int] = [:]
    var hasLoadingPlaceholders = false
    var placeholderShimmerTask: Task<Void, Never>?
    var reconciledVisibleRange: Range<Int>?
    var reconciledViewportWidth: CGFloat?
    var imageLoadPromotion: @Sendable (URL, Int) async -> Void = { url, dimension in
        await SharedDecodedImageLoader.shared.promoteImageLoad(
            for: url,
            maximumPixelDimension: dimension
        )
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard !interactionsBlocked else {
            trackingArea = nil
            super.updateTrackingAreas()
            return
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        AppPerformanceSignposts.measureSync("MemberListCanvasDraw") {
            guard let context = NSGraphicsContext.current?.cgContext else {
                return
            }
            let range = itemRange(intersecting: dirtyRect)
            let drawsPlaceholders = range.contains {
                switch items[$0] {
                case .header(let header): header.isLoadingSkeleton
                case .placeholder: true
                case .member: false
                }
            }
            let style = drawsPlaceholders ? skeletonDrawingStyle() : nil
            if drawsPlaceholders {
                AppPerformanceSignposts.measureSync(
                    "MemberListPlaceholderCanvasDraw"
                ) {
                    drawItems(in: range, context: context, skeletonStyle: style)
                }
            } else {
                drawItems(in: range, context: context, skeletonStyle: nil)
            }
        }
    }
    override func mouseMoved(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        guard !isScrolling, !interactionsBlocked else { return }
        let newIndex = index(at: convert(event.locationInWindow, from: nil))
        guard newIndex != hoveredIndex else { return }
        let old = hoveredIndex
        hoveredIndex = newIndex
        if let old { setNeedsDisplay(itemRect(at: old)) }
        if let newIndex { setNeedsDisplay(itemRect(at: newIndex)) }
        updateVisibleOverlaysAndPrewarming()
    }

    override func mouseExited(with event: NSEvent) {
        guard let old = hoveredIndex else { return }
        hoveredIndex = nil
        setNeedsDisplay(itemRect(at: old))
        updateVisibleOverlaysAndPrewarming()
    }

    override func mouseDown(with event: NSEvent) {
        guard !interactionsBlocked,
              let index = index(at: convert(event.locationInWindow, from: nil)),
              case .member(let member, _) = items[index]
        else { return }
        selectMember(member)
    }

}
