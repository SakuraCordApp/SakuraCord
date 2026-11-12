import SakuraCordModels
import SwiftUI

/// SakuraCord's schedule dialog: a day from today to Discord's last allowed
/// day and a time in the official dialog's 15-minute steps. Arrow keys move
/// the day (left and right) and the time (up and down); scrolling or dragging
/// the time runs through the allowed days.
struct ScheduleMessageDialog: View {
    let timeFormat: InterfaceTimestampFormat
    /// Bounds a reschedule to 30 days after its message was first scheduled.
    var scheduledMessageID: ScheduledMessageID?
    let commit: (Date) -> Void
    @Environment(\.windowModalContext) private var modal
    /// Today through the last day Discord accepts; an old message's 30-day
    /// bound may leave only today, which then reads as too far away.
    private let days: [Day]
    /// The time as given, kept while its day and time stay unchanged, so a
    /// reschedule never shifts it, as within a repeated daylight-saving hour.
    private let initialDate: Date
    @State private var day: Date
    /// Minutes after midnight; a time set elsewhere may fall between steps.
    @State private var minute: Int
    /// Steps already taken by the drag under way.
    @State private var draggedSteps = 0
    @FocusState private var isFocused: Bool

    init(
        initialDate: Date?,
        timeFormat: InterfaceTimestampFormat,
        scheduledMessageID: ScheduledMessageID? = nil,
        commit: @escaping (Date) -> Void
    ) {
        let calendar = Calendar.current
        let date = initialDate ?? Self.nextWholeHour()
        self.timeFormat = timeFormat
        self.scheduledMessageID = scheduledMessageID
        self.commit = commit
        let last = calendar.startOfDay(for: ScheduledMessagePolicy.latestSendDate(for: scheduledMessageID))
        var dates = [calendar.startOfDay(for: .now)]
        while let next = calendar.date(byAdding: .day, value: 1, to: dates[dates.count - 1]), next <= last {
            dates.append(next)
        }
        days = dates.map(Day.init)
        self.initialDate = date
        _day = State(initialValue: calendar.startOfDay(for: date))
        _minute = State(initialValue: Self.minutes(of: date))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(scheduledMessageID == nil ? "Schedule Message" : "Update Scheduled Message")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 12)
            dayPicker
            timePicker
            // The allowed range moves with the clock while the dialog stays open.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let issue = issue(now: context.date)
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if let issue {
                            Label(issue, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                        } else {
                            Label("Sends \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))) at \(ScheduleTimeText.time(date, format: timeFormat))", systemImage: "paperplane")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    // Keep the 12-point footer inset that makes the capsules concentric with the panel.
                    HStack {
                        ModalGlassButton(symbol: "xmark", label: "Cancel") { modal?.dismiss() }
                        Spacer(minLength: 16)
                        ModalGlassButton(
                            symbol: "calendar.badge.clock",
                            label: scheduledMessageID == nil ? "Schedule" : "Update",
                            primary: true
                        ) {
                            commit(date)
                            modal?.dismiss()
                        }
                        .disabled(issue != nil)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.top, 12)
        .padding(12)
        .frame(width: 400)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveDay(by: -1) }
        .onKeyPress(.rightArrow) { moveDay(by: 1) }
        .onKeyPress(.upArrow) { step(by: 1) }
        .onKeyPress(.downArrow) { step(by: -1) }
        .task {
            await Task.yield()
            isFocused = true
        }
    }

    private var dayPicker: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.date) { candidate in
                let isSelected = candidate.date == day
                Button { day = candidate.date } label: {
                    VStack(spacing: 2) {
                        Text(candidate.weekday)
                            .font(.caption)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        Text(candidate.number)
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(isSelected ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular.interactive(), in: Capsule())
                .help(candidate.help)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var timePicker: some View {
        HStack(spacing: 12) {
            stepButton(systemImage: "chevron.left", help: "15 Minutes Earlier") { _ = step(by: -1) }
            Text(ScheduleTimeText.time(date, format: timeFormat))
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: date)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(ScrollStepInput { scrub(by: $0) })
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            // Up or right is later, as with scrolling; a refused step drops the rest.
                            let steps = Int(((value.translation.width - value.translation.height) / 16).rounded(.towardZero))
                            let delta = steps - draggedSteps
                            draggedSteps = steps
                            for _ in 0 ..< abs(delta) {
                                guard scrub(by: delta.signum()) else { break }
                            }
                        }
                        .onEnded { _ in draggedSteps = 0 }
                )
            stepButton(systemImage: "chevron.right", help: "15 Minutes Later") { _ = step(by: 1) }
        }
        .padding(6)
        .background(.primary.opacity(0.05), in: Capsule())
    }

    private func stepButton(systemImage: String, help: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(String(localized: help))
        .accessibilityLabel(Text(help))
    }

    private var date: Date {
        if day == Calendar.current.startOfDay(for: initialDate), minute == Self.minutes(of: initialDate) { return initialDate }
        return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
    }

    private func issue(now: Date) -> LocalizedStringResource? {
        if date < ScheduledMessagePolicy.earliestSendDate(now: now) { return "Scheduled time is too soon" }
        if date > ScheduledMessagePolicy.latestSendDate(for: scheduledMessageID, now: now) { return "Scheduled time is too far away" }
        return nil
    }

    /// Moves to the neighbouring 15-minute mark within the day.
    private func step(by direction: Int) -> KeyPress.Result {
        minute = min(max(neighbouringMark(direction), 0), 95) * 15
        return .handled
    }

    /// The next 15-minute mark from the time, counted from midnight.
    private func neighbouringMark(_ direction: Int) -> Int {
        direction > 0 ? minute / 15 + 1 : (minute + 14) / 15 - 1
    }

    /// Scrolling and dragging run through the allowed days in 15-minute steps
    /// and stop at either end, each step ticking.
    private func scrub(by direction: Int) -> Bool {
        guard let candidate = Calendar.current.date(byAdding: .minute, value: neighbouringMark(direction) * 15, to: day)
        else { return false }
        if direction > 0, candidate > ScheduledMessagePolicy.latestSendDate(for: scheduledMessageID) { return false }
        if direction < 0, candidate < ScheduledMessagePolicy.earliestSendDate() { return false }
        day = Calendar.current.startOfDay(for: candidate)
        minute = Self.minutes(of: candidate)
        StepHaptics.performStep()
        return true
    }

    private func moveDay(by offset: Int) -> KeyPress.Result {
        guard let index = days.firstIndex(where: { $0.date == day }) else { return .ignored }
        day = days[min(max(index + offset, 0), days.count - 1)].date
        return .handled
    }

    private static func minutes(of date: Date) -> Int {
        Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
    }

    /// The next whole hour, or the one after when that is under ten minutes away.
    static func nextWholeHour(now: Date = .now, calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        return hour < ScheduledMessagePolicy.earliestSendDate(now: now) ? hour.addingTimeInterval(3600) : hour
    }

    /// A selectable day, its labels formatted once rather than on every step.
    private struct Day {
        let date: Date
        let weekday: String
        let number: String
        let help: String

        init(_ date: Date) {
            self.date = date
            weekday = date.formatted(.dateTime.weekday(.abbreviated))
            number = date.formatted(.dateTime.day())
            help = date.formatted(date: .complete, time: .omitted)
        }
    }
}
