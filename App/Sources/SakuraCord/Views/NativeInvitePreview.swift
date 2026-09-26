import AppKit
import SwiftUI

struct NativeInvitePreview: NSViewRepresentable {
    let card: NativeTimelineInviteLayout
    var isModalPreview = true

    func makeNSView(context: Context) -> Preview { Preview() }
    func updateNSView(_ view: Preview, context: Context) {
        view.isModalPreview = isModalPreview
        view.card = card
        view.needsDisplay = true
        view.loadImages()
    }

    final class Preview: NSView {
        var card: NativeTimelineInviteLayout? {
            didSet { setAccessibilityLabel(card?.accessibilityLabel) }
        }
        var isModalPreview = true
        let mediaOwner = UUID()
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let card else { return }
            NativeTimelineRowPainter.inviteCard(card, isHovered: false, pressProgress: 0, isModalPreview: isModalPreview)
        }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
        }
        required init?(coder: NSCoder) { nil }
        func loadImages() {
            guard let invite = card?.content else { return }
            let keys = [invite.iconURL.map { NativeTimelineMediaKey.media($0, maximumPixelDimension: 128) },
                        invite.inviter?.avatarURL.map { NativeTimelineMediaKey.media($0, maximumPixelDimension: 32) }].compactMap { $0 }
                + invite.traits.compactMap { $0.emojiURL.map { NativeTimelineMediaKey.media($0, maximumPixelDimension: 32) } }
            for key in keys {
                NativeTimelineMediaStore.shared.request(key, owner: mediaOwner, subscriber: .loader) { [weak self] _ in self?.needsDisplay = true }
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { NativeTimelineMediaStore.shared.removeStaticRequests(owner: mediaOwner) }
        }
    }
}
