#if !compiler(>=6.4)
import AppKit
import SwiftUI

extension ToolbarContent {
    func contentMarginsRemoved(_ removed: Bool = true) -> Self { self }
}

extension GeometryProxy {
    // nil makes the caller fall back to its fixed 16pt corners
    func concentricCornerRadii(in rect: CGRect) -> RectangleCornerRadii? { nil }
}

extension NSWindow {
    nonisolated struct DidChangeOcclusionStateMessage: NotificationCenter.MainActorMessage {
        typealias Subject = NSWindow
        static var name: Notification.Name { NSWindow.didChangeOcclusionStateNotification }
        static func makeMessage(_ notification: Notification) -> Self? { Self() }
    }
}
#endif
