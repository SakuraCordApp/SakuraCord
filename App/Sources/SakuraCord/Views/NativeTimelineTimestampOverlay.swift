import AppKit
import MessageRendering
import SwiftUI

struct NativeTimelineTimestampPillView: View {
    let date: Date
    let style: String?
    let isOutgoingBubble: Bool
    var fontSize: CGFloat = 15
    @State private var clock = RelativeTimestampDisplayClock()

    var body: some View {
        Text(currentLabel)
            .font(.interfaceSystem(size: fontSize).monospacedDigit())
            .foregroundStyle(isOutgoingBubble ? Color.white : Color.primary)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: currentLabel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onAppear { clock.start() }
            .onDisappear { clock.stop() }
    }

    private var currentLabel: String {
        DiscordTimestampFormatter.formatted(date: date, style: style, now: clock.date)
    }
}

final class NativeTimelinePassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
