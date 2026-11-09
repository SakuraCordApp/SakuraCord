import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
final class NativeMemberForegroundOverlayView: NSView {
    weak var canvas: NativeMemberListCanvasView?
    var itemIndex = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas,
              canvas.items.indices.contains(itemIndex),
              case .member(let member, _) = canvas.items[itemIndex],
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        context.saveGState()
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSmoothing(true)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        canvas.drawMemberForeground(member, at: itemIndex, context: context)
        context.restoreGState()
    }
}
