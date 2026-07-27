import Foundation
import OSLog

/// Opt-in scroll instrumentation for diagnosing timeline stutter.
///
/// Enabled only by `--scroll-diagnostics`, so ordinary and packaged runs pay
/// nothing. Records counts rather than content: no message text, author, or
/// channel value is ever logged.
nonisolated struct ScrollDiagnosticsSample: Equatable {
    let contentHeight: CGFloat
    let contentOffset: CGFloat
}

@MainActor
enum ScrollDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--scroll-diagnostics")

    private static let logger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "ScrollDiagnostics"
    )

    private static var textViewsCreated = 0
    private static var textViewsDismantled = 0
    private static var attributedStringsBuilt = 0
    private static var heightCacheHits = 0
    private static var heightCacheMisses = 0
    private static var contentHeightChanges = 0
    private static var lastContentHeight: CGFloat?
    private static var lastContentOffset: CGFloat?
    private static var largestContentHeightJump: CGFloat = 0
    private static var uncompensatedJumps = 0
    private static var largestUncompensatedJump: CGFloat = 0
    private static var windowStartedAt: Date?
    /// The timeline realizes every loaded row, so this is the number that says
    /// whether history growth has started to cost anything.
    private static var rowCount = 0

    static func recordTextViewCreated() {
        guard isEnabled else { return }
        textViewsCreated += 1
    }

    static func recordTextViewDismantled() {
        guard isEnabled else { return }
        textViewsDismantled += 1
    }

    static func recordAttributedStringBuilt() {
        guard isEnabled else { return }
        attributedStringsBuilt += 1
    }

    static func recordHeightCacheHit() {
        guard isEnabled else { return }
        heightCacheHits += 1
    }

    static func recordHeightCacheMiss() {
        guard isEnabled else { return }
        heightCacheMisses += 1
    }

    /// Content height changing mid-scroll only moves the visible content when
    /// the scroll view fails to absorb it into the offset. Growth above the
    /// viewport should shift `contentOffset` by the same amount; when it does
    /// not, that difference is the visible jump.
    static func recordGeometry(height: CGFloat, offset: CGFloat) {
        guard isEnabled else { return }
        defer {
            lastContentHeight = height
            lastContentOffset = offset
        }
        guard let previousHeight = lastContentHeight,
              let previousOffset = lastContentOffset
        else { return }
        let heightDelta = height - previousHeight
        guard abs(heightDelta) > 0.5 else { return }
        contentHeightChanges += 1
        largestContentHeightJump = max(largestContentHeightJump, abs(heightDelta))

        let offsetDelta = offset - previousOffset
        let uncompensated = abs(heightDelta - offsetDelta)
        guard uncompensated > 1 else { return }
        uncompensatedJumps += 1
        largestUncompensatedJump = max(largestUncompensatedJump, uncompensated)
    }

    static func beginScroll(rowCount: Int) {
        guard isEnabled, windowStartedAt == nil else { return }
        windowStartedAt = Date()
        self.rowCount = rowCount
        textViewsCreated = 0
        textViewsDismantled = 0
        attributedStringsBuilt = 0
        heightCacheHits = 0
        heightCacheMisses = 0
        contentHeightChanges = 0
        largestContentHeightJump = 0
        uncompensatedJumps = 0
        largestUncompensatedJump = 0
    }

    static func endScroll() {
        guard isEnabled, let startedAt = windowStartedAt else { return }
        windowStartedAt = nil
        // The main-actor derivations are the other half of the picture, and a
        // scroll that ends in silence would otherwise never report them.
        MainActorWorkDiagnostics.flush()
        let duration = Date().timeIntervalSince(startedAt)
        logger.info(
            """
            scroll finished in \(duration, format: .fixed(precision: 2))s — \
            rows=\(rowCount), \
            textViews created=\(textViewsCreated) dismantled=\(textViewsDismantled), \
            attributedStrings=\(attributedStringsBuilt), \
            heightCache hits=\(heightCacheHits) misses=\(heightCacheMisses), \
            contentHeightChanges=\(contentHeightChanges) \
            largestJump=\(largestContentHeightJump, format: .fixed(precision: 1))pt, \
            uncompensated=\(uncompensatedJumps) \
            largestUncompensated=\(largestUncompensatedJump, format: .fixed(precision: 1))pt
            """
        )
    }
}
