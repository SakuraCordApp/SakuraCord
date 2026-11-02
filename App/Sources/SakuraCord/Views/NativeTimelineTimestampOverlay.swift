import AppKit
import MessageRendering
import SwiftUI

struct NativeTimelineTimestampPillView: View {
    let date: Date
    let style: String?
    let isOutgoingBubble: Bool
    var fontSize: CGFloat = 15
    @State private var now = Date.now

    var body: some View {
        Text(currentLabel)
            .font(.interfaceSystem(size: fontSize).monospacedDigit())
            .foregroundStyle(isOutgoingBubble ? Color.white : Color.primary)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: currentLabel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    now = .now
                }
            }
    }

    private var currentLabel: String {
        DiscordTimestampFormatter.formatted(date: date, style: style, now: now)
    }
}

final class NativeTimelinePassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
