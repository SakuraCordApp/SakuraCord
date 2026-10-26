import AppKit
@testable import SakuraCord
import SwiftUI
import Testing

/// A side chat pane's measured widths are shared with the next pane. A
/// full-width side chat has none of its own: when it measured first, the
/// next pane took the whole window, drawing its content in a narrow column
/// at the leading edge over nothing.
@MainActor
@Test(arguments: [false, true])
func `a side chat pane keeps its own width after a full-width side chat`(flipsInPlace: Bool) {
    // Heights no other test uses: measured widths are shared per height.
    let height: CGFloat = flipsInPlace ? 731 : 733
    let host = WorkspaceColumnsView(frame: NSRect(x: 0, y: 0, width: 1440, height: height))
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = host
    defer { window.contentView = nil }
    let environment = EnvironmentValues()

    if flipsInPlace {
        // The same side chat moves to full width, the window's height
        // changes, and it comes back to the pane.
        host.apply(spec([column(fullWidth: false)]), environment: environment, animates: false)
        host.apply(spec([column(fullWidth: true)]), environment: environment, animates: false)
        window.setContentSize(NSSize(width: 1440, height: height + 40))
        host.layoutSubtreeIfNeeded()
        host.apply(spec([column(fullWidth: false)]), environment: environment, animates: false)
    } else {
        // Full width first, then the parent channel, then a pane.
        host.apply(spec([column(fullWidth: true)]), environment: environment, animates: false)
        host.apply(spec([]), environment: environment, animates: false)
        host.apply(spec([column(fullWidth: false)]), environment: environment, animates: false)
    }
    host.layoutSubtreeIfNeeded()

    let conversation = try? #require(host.subviews.first)
    let pane = try? #require(host.subviews.last)
    #expect(conversation?.alphaValue == 1)
    #expect(pane?.frame.width == paneWidth, "pane \(String(describing: pane?.frame))")
    #expect(pane?.frame.maxX == host.bounds.maxX)
    #expect(conversation?.frame.width == host.bounds.width - paneWidth)
}

/// A side chat pane reused from the pool reports the same frame in its
/// column's space as before, which is no change to report. Without its last
/// report, the reopened pane had no frame: a file dropped over it went to
/// the parent channel.
@MainActor
@Test
func `a reopened side chat pane reports its frame again`() async throws {
    // A height no other test uses: measured widths are shared per height.
    let host = WorkspaceColumnsView(frame: NSRect(x: 0, y: 0, width: 1440, height: 737))
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = host
    defer { window.contentView = nil }
    let reported = ReportedFrame()
    func show(_ columns: [WorkspaceColumnsHost.Column]) {
        host.apply(
            spec(columns) { reported.frame = $0 }, environment: EnvironmentValues(), animates: false
        )
        host.layoutSubtreeIfNeeded()
    }

    show([column(fullWidth: false, reportsFrame: true)])
    #expect(await reported.becomes { $0.width == paneWidth })
    show([])
    #expect(await reported.becomes { $0 == .zero })
    show([column(fullWidth: false, reportsFrame: true)])
    #expect(await reported.becomes { $0.width == paneWidth && $0.maxX == host.bounds.maxX }, "\(reported.frame)")
}

@MainActor
private final class ReportedFrame {
    var frame = CGRect.zero

    /// Whether the reported frame comes to satisfy `condition`: reports
    /// arrive on a later turn of the main queue.
    func becomes(_ condition: (CGRect) -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition(frame) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(frame)
    }
}

private let paneWidth: CGFloat = 440

@MainActor
private func spec(
    _ columns: [WorkspaceColumnsHost.Column],
    paneFrameChanged: @escaping (CGRect) -> Void = { _ in }
) -> WorkspaceColumnsHost {
    WorkspaceColumnsHost(
        conversation: AnyView(Color.clear.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)),
        columns: columns,
        widening: nil,
        supplementaryPaneFrameChanged: paneFrameChanged
    )
}

@MainActor
private func column(fullWidth: Bool, reportsFrame: Bool = false) -> WorkspaceColumnsHost.Column {
    let pane = Color.clear.frame(minWidth: 340, idealWidth: paneWidth, maxWidth: paneWidth, maxHeight: .infinity)
    return WorkspaceColumnsHost.Column(
        id: "side-thread-regression",
        isSideConversation: true,
        isFullWidth: fullWidth,
        content: fullWidth
            ? AnyView(Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity))
            : reportsFrame ? AnyView(pane.reportsSupplementaryPaneFrame()) : AnyView(pane)
    )
}
