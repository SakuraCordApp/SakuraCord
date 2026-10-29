import AppKit
@testable import SakuraCord
import SwiftUI
import Testing

/// The composer lives in a view graph of its own (`ConversationFooterHost`),
/// but the conversation still lays its timeline out around the composer's
/// height: a draft growing a line must reach the enclosing layout.
@MainActor
@Test
func `the conversation footer reports its height as its content grows`() async throws {
    let lines = FooterLines()
    let heights = HeightBox()
    let host = NSHostingView(rootView: FooterHarness(lines: lines, heights: heights))
    host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }

    try await settle(host)
    let oneLine = try #require(heights.last)
    #expect(oneLine > 0)

    lines.count = 4
    try await settle(host)
    let fourLines = try #require(heights.last)
    #expect(fourLines > oneLine + 30, "footer height \(oneLine) → \(fourLines)")

    lines.count = 1
    try await settle(host)
    #expect(abs((heights.last ?? 0) - oneLine) < 0.5)
}

@MainActor
private func settle(_ view: NSView) async throws {
    for _ in 0 ..< 6 {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Observable
@MainActor
private final class FooterLines {
    var count = 1
}

@MainActor
private final class HeightBox {
    var last: CGFloat?
}

private struct FooterHarness: View {
    let lines: FooterLines
    let heights: HeightBox

    var body: some View {
        Color.clear
            .overlay(alignment: .bottom) {
                ConversationFooterHost {
                    FooterContent(lines: lines)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.last = $0 }
            }
    }
}

private struct FooterContent: View {
    let lines: FooterLines

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< lines.count, id: \.self) { index in
                Text("Line \(index)").frame(height: 20)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
