import AppKit
import SwiftUI

struct DisplayCompleteFrameReporter: NSViewRepresentable {
    let presentationID: UInt64?
    let report: @MainActor () -> Void

    func makeNSView(context: Context) -> DisplayCompleteFrameReportingView {
        DisplayCompleteFrameReportingView(
            presentationID: presentationID,
            report: report
        )
    }

    func updateNSView(
        _ nsView: DisplayCompleteFrameReportingView,
        context: Context
    ) {
        nsView.update(
            presentationID: presentationID,
            report: report
        )
    }
}

final class DisplayCompleteFrameReportingView: NSView {
    private var presentationID: UInt64?
    private var report: @MainActor () -> Void
    private var didReport = false

    init(
        presentationID: UInt64?,
        report: @escaping @MainActor () -> Void
    ) {
        self.presentationID = presentationID
        self.report = report
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window != nil, !didReport else { return }
        didReport = true
        Task { @MainActor [report] in
            await Task.yield()
            report()
        }
    }

    func update(
        presentationID: UInt64?,
        report: @escaping @MainActor () -> Void
    ) {
        self.report = report
        guard self.presentationID != presentationID else { return }
        self.presentationID = presentationID
        didReport = false
        needsDisplay = true
    }
}
