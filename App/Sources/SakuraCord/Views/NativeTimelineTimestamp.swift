import Foundation

enum NativeTimelineTimestamp {
    /// Header texts by everything they depend on, including the day they
    /// are read on: a row laid out again at another width, as on every
    /// frame of a resize, reuses its timestamp's text.
    private static var headerTexts: [HeaderKey: String] = [:]
    /// The day, locale and time zone texts are read in, looked up at most
    /// once a second of wall-clock time, which a sleeping Mac also passes.
    private static var headerContext: HeaderContextLookup?

    private struct HeaderContextLookup {
        let context: HeaderContext
        /// When it was looked up, and when it is looked up again.
        let created: Date
        let expires: Date
    }

    private struct HeaderContext: Hashable {
        let today: Date
        /// The current locale with the user's overrides, such as the hour cycle.
        let locale: Locale
        let timeZone: TimeZone
    }

    private struct HeaderKey: Hashable {
        let date: Date
        let format: InterfaceTimestampFormat
        let includesSeconds: Bool
        let context: HeaderContext
    }

    private static var currentHeaderContext: HeaderContext {
        let now = Date.now
        // A clock set back leaves the window too.
        if let cached = headerContext, cached.created <= now, now < cached.expires { return cached.context }
        let timeZone = TimeZone.current
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let context = HeaderContext(today: today, locale: .current, timeZone: timeZone)
        // Never past midnight, when today's texts become yesterday's.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        headerContext = HeaderContextLookup(context: context, created: now, expires: min(now.addingTimeInterval(1), tomorrow))
        return context
    }

    static func headerText(
        for date: Date,
        settings: InterfaceSettingsSnapshot = .defaults
    ) -> String {
        let key = HeaderKey(
            date: date,
            format: settings.timestampFormat,
            includesSeconds: settings.includesTimestampSeconds,
            context: currentHeaderContext
        )
        if let text = headerTexts[key] { return text }
        let text = InterfaceTimestampFormatter.messageText(
            for: date,
            format: settings.timestampFormat,
            includesSeconds: settings.includesTimestampSeconds
        )
        if headerTexts.count >= 4_096 { headerTexts.removeAll(keepingCapacity: true) }
        headerTexts[key] = text
        return text
    }
}
