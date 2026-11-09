import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

struct NativeMemberListView: NSViewRepresentable {
    @Environment(\.profileCosmeticPolicy) var cosmeticPolicy
    @Environment(\.serverTagCardModel) var serverTagCardModel
    var sections: [MemberSection]
    let customEmojiURLsByID: CustomEmojiImageURLs
    let profilePresentation: ProfilePresentationState?
    let isProfilePresented: Bool
    let selectMember: (Member) -> Void
    let dismissProfile: () -> Void
    let runsPerformanceAutoScroll: Bool
    let viewportIdentity: ChannelID?
    var presentation = NativeMemberListPresentation()
    var onViewportRange: (ClosedRange<Int>) -> Void = { _ in }

    var openProfile: ((ProfilePresentationState) -> Void)?
    var sendProfileMessage: ((UserID, String, String) async -> Bool)?
    var rowAccessory: ((Member) -> AnyView)?
    var rowMenu: ((Member) -> NSMenu?)?
    var rowAccessibilityActions: ((Member) -> [NSAccessibilityCustomAction])?
    var contentIdentity: String?
    var isInspector = false

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NativeMemberListHostView {
        NativeMemberListHostView(scrollView: context.coordinator.makeScrollView(), isInspector: isInspector)
    }

    func updateNSView(_ host: NativeMemberListHostView, context: Context) {
        context.coordinator.update(parent: self, scrollView: host.scrollView)
    }

    static func dismantleNSView(_ host: NativeMemberListHostView, coordinator: Coordinator) {
        host.scrollView.inputPerformanceProbe.invalidate()
        coordinator.stop()
        host.scrollView.documentView = nil
    }

    typealias Coordinator = NativeMemberListCoordinator
}

@MainActor
final class NativeMemberListHostView: NSView {
    let scrollView: NativeMemberListScrollView

    /// Every scroll pocket under the toolbar blurs one shared capture, taken
    /// where the first of them draws: the conversation, before an inspector
    /// column, so an inspector's rows would be missing from its toolbar band.
    /// Glass opts its content out of that capture, as it does for a native
    /// inspector item, so the list's pocket captures its own rows.
    init(scrollView: NativeMemberListScrollView, isInspector: Bool) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        scrollView.autoresizingMask = [.width, .height]
        guard isInspector, let glass = NSGlassEffectView.inspector() else {
            addSubview(scrollView)
            return
        }
        glass.autoresizingMask = [.width, .height]
        glass.contentView = scrollView
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension NSGlassEffectView {
    /// The glass of an inspector split item, or nil once its private variant
    /// is no longer settable: plain glass would not look like an inspector.
    static func inspector() -> NSGlassEffectView? {
        let glass = NSGlassEffectView()
        guard glass.responds(to: NSSelectorFromString("set_variant:")),
              glass.responds(to: NSSelectorFromString("set_adaptiveAppearance:"))
        else { return nil }
        glass.setValue(19, forKey: "_variant")
        glass.setValue(1, forKey: "_adaptiveAppearance")
        // An inspector item's glass is square; the view's default rounds it.
        glass.cornerRadius = 0
        return glass
    }
}

@MainActor
final class NativeMemberListScrollView: NSScrollView {
    let inputPerformanceProbe = ScrollInputPerformanceProbe(
        surface: .memberList
    )
    var appearanceDidChange: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        synchronizeCanvasFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackgroundForEffectiveAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundForEffectiveAppearance()
        appearanceDidChange?()
    }

    private func updateBackgroundForEffectiveAppearance() {
        backgroundColor = .clear
        needsDisplay = true
        contentView.needsDisplay = true
        documentView?.needsDisplay = true
    }

    func synchronizeCanvasFrame() {
        guard let canvas = documentView as? NativeMemberListCanvasView else { return }
        let targetSize = NSSize(
            width: max(0, contentSize.width),
            height: max(1, canvas.contentHeight)
        )
        guard canvas.frame.size != targetSize else { return }
        canvas.frame.size = targetSize
        canvas.needsDisplay = true
        canvas.updateVisibleOverlaysAndPrewarming(force: true)
    }
}
