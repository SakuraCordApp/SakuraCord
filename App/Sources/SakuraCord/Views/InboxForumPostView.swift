import AppKit
import SakuraCordModels
import SwiftUI

struct InboxForumPostView: View {
    let post: ForumPost
    let model: AppModel

    var body: some View {
        // The entry opens the post from a background button so the preview
        // can take clicks on hidden spoilers, which reveal them in place.
        VStack(alignment: .leading, spacing: InterfaceScale.metric(5)) {
            Text(post.thread.name).font(.interface(.headline)).lineLimit(1)
                .allowsHitTesting(false)
            if let message = post.firstMessage {
                ForumPostPreviewText(model: model, message: message)
            } else {
                Text("\(post.thread.messageCount) messages")
                    .font(.interface(.caption)).foregroundStyle(.secondary)
                    .accessibilityLabel("\(post.thread.messageCount) replies")
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, InterfaceScale.metric(16))
        .frame(height: InboxRowMetrics.forumPostHeight)
        .background {
            Button { model.openInboxForumPost(post) } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .accessibilityLabel(post.thread.name)
            .accessibilityHint("Opens this post")
        }
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, InterfaceScale.metric(12)) }
        .help("Open post")
    }
}

/// A forum post's message preview in the Inbox. It renders
/// the message's rich text, conceals hidden text spoilers like the timeline,
/// and reveals a spoiler in place when it is clicked. Every other click passes
/// through to the entry, which opens the post.
struct ForumPostPreviewText: NSViewRepresentable {
    let model: AppModel
    let message: Message

    func makeNSView(context _: Context) -> ForumPostPreviewTextView {
        ForumPostPreviewTextView()
    }

    func updateNSView(_ view: ForumPostPreviewTextView, context _: Context) {
        view.configure(
            ForumPostPreviewTextRenderer.Configuration(
                resolving: message,
                model: model,
                fontSize: NSFont.interfacePreferredFont(forTextStyle: .callout).pointSize,
                maximumNumberOfLines: 1,
                isEmphasized: false,
                underlinesLinks: model.accessibilitySettings.underlinesLinks,
                prefix: nil
            ),
            revealStore: model.timelineSpoilerRevealStore
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView view: ForumPostPreviewTextView,
        context _: Context
    ) -> CGSize? {
        view.measuredSize(proposedWidth: proposal.width)
    }

    static func dismantleNSView(_ view: ForumPostPreviewTextView, coordinator _: Void) {
        view.stopObservingReveals()
    }
}

final class ForumPostPreviewTextView: NSView {
    private let renderer = ForumPostPreviewTextRenderer()
    private var hoverTrackingArea: NSTrackingArea?

    #if DEBUG
        var contentForTesting: NSAttributedString { renderer.content }
    #endif

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        renderer.onDisplayChange = { [weak self] in
            guard let self else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func configure(
        _ configuration: ForumPostPreviewTextRenderer.Configuration,
        revealStore: NativeTimelineSpoilerRevealStore
    ) {
        let previous = renderer.configuration
        renderer.configure(configuration, revealStore: revealStore)
        guard previous != configuration else { return }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func stopObservingReveals() {
        renderer.stopObservingReveals()
    }

    func measuredSize(proposedWidth: CGFloat?) -> CGSize {
        renderer.measuredSize(proposedWidth: proposedWidth)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer.size = newSize
    }

    func hiddenSpoilerFrames(for range: NSRange) -> [CGRect] {
        renderer.hiddenSpoilerFrames(for: range)
    }

    func hiddenSpoilerLocation(at point: CGPoint) -> Int? {
        renderer.hiddenSpoilerLocation(at: point)
    }

    override func draw(_: NSRect) {
        renderer.draw(at: .zero)
    }

    // MARK: Pointer

    /// Only hidden spoilers take clicks; the rest of the preview belongs to
    /// the card, which opens the post.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return hiddenSpoilerLocation(at: local) == nil ? nil : self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let location = hiddenSpoilerLocation(
            at: convert(event.locationInWindow, from: nil)
        ) else {
            super.mouseDown(with: event)
            return
        }
        renderer.revealSpoiler(at: location)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredSpoiler(hiddenSpoilerLocation(at: convert(event.locationInWindow, from: nil)))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredSpoiler(nil)
        super.mouseExited(with: event)
    }

    override func resetCursorRects() {
        guard !renderer.hiddenSpoilerRanges.isEmpty, WindowModalCoordinator.allowsInput(for: self) else { return }
        for range in renderer.hiddenSpoilerRanges {
            for frame in hiddenSpoilerFrames(for: range) {
                addCursorRect(frame, cursor: .pointingHand)
            }
        }
    }

    private func setHoveredSpoiler(_ location: Int?) {
        if renderer.setHoveredSpoiler(location) { needsDisplay = true }
    }

    func revealSpoiler(at location: Int) {
        renderer.revealSpoiler(at: location)
    }

    // MARK: Accessibility

    override func accessibilityValue() -> Any? {
        renderer.accessibilityText
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let location = renderer.hiddenSpoilerRanges.first?.location else { return nil }
        return [
            NSAccessibilityCustomAction(name: "Reveal spoiler") { [weak self] in
                self?.revealSpoiler(at: location)
                return true
            },
        ]
    }
}

extension NativeTimelineCanvasView {
    func reconcileInboxForumPosts() {
        var desired: [ChannelID: (ForumPost, CGRect)] = [:]
        forEachDisplayedRow(in: visibleRect) { index in
            if case let .inboxForumPost(post) = items[index] {
                desired[post.id] = (post, CGRect(x: 0, y: displayedRowOrigin(at: index), width: bounds.width, height: InboxRowMetrics.forumPostHeight))
            }
        }
        for id in Array(inboxForumPostHosts.keys) where desired[id] == nil {
            inboxForumPostHosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        guard let model else { return }
        for (id, value) in desired {
            let host: NSHostingView<InboxForumPostView>
            if let existing = inboxForumPostHosts[id] {
                host = existing
                if host.rootView.post != value.0 { host.rootView = InboxForumPostView(post: value.0, model: model) }
            } else {
                host = NSHostingView(rootView: InboxForumPostView(post: value.0, model: model))
                inboxForumPostHosts[id] = host
                addSubview(host)
            }
            host.frame = value.1
        }
    }
}
