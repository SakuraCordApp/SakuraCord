import CoreGraphics

/// The message count of each history read, derived from the viewport as the
/// official desktop client does (build 650389, module 326337, captured
/// 27 October 2026) so SakuraCord's reads match its counts.
nonisolated enum DiscordHistoryFetchLimit {
    /// A jump to a message or to the first unread message always reads 30.
    static let aroundLimit = 30
    /// Used before any timeline has reported its window, such as the
    /// bootstrap prefetch.
    static let fallbackWindowHeight: CGFloat = 800

    private static let chromeHeight: Double = 145
    private static let minimumViewportHeight: Double = 400
    private static let cozyMessageHeight: Double = 91
    private static let compactMessageHeight: Double = 65
    private static let defaultFontSize: Double = 16
    private static let maximumLimit = 30

    /// A cold open, a stale refetch and Jump to Present.
    ///
    /// - Parameters:
    ///   - windowHeight: The hosting window's content height in points.
    ///   - zoom: The whole-UI scale; Discord's window height is in CSS pixels,
    ///     which are points divided by the zoom.
    static func initial(
        windowHeight: CGFloat,
        zoom: CGFloat = 1,
        isCompact: Bool = false,
        fontSize: CGFloat = 16
    ) -> Int {
        let height = max(Double(windowHeight / zoom) - chromeHeight, minimumViewportHeight)
        let messageHeight = (isCompact ? compactMessageHeight : cozyMessageHeight)
            * (Double(fontSize) / defaultFontSize)
        return max(10, min(maximumLimit, Int((1.05 * (height / messageHeight).rounded(.up)).rounded(.up))))
    }

    /// An older or newer page while scrolling.
    static func page(
        windowHeight: CGFloat,
        zoom: CGFloat = 1,
        isCompact: Bool = false,
        fontSize: CGFloat = 16
    ) -> Int {
        min(maximumLimit, 2 * initial(
            windowHeight: windowHeight,
            zoom: zoom,
            isCompact: isCompact,
            fontSize: fontSize
        ))
    }
}

extension AppModel {
    /// SakuraCord has no compact message display, and its message text size is
    /// fixed, so only the whole-UI Interface Size changes the inputs: it plays
    /// the part of Discord's zoom.
    var initialHistoryFetchLimit: Int {
        DiscordHistoryFetchLimit.initial(
            windowHeight: timelineWindowHeight ?? DiscordHistoryFetchLimit.fallbackWindowHeight,
            zoom: InterfaceScale.factor
        )
    }

    var historyPageFetchLimit: Int {
        DiscordHistoryFetchLimit.page(
            windowHeight: timelineWindowHeight ?? DiscordHistoryFetchLimit.fallbackWindowHeight,
            zoom: InterfaceScale.factor
        )
    }
}
