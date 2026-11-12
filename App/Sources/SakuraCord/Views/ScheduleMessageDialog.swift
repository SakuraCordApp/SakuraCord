import SakuraCordModels
import SwiftUI

/// SakuraCord's schedule dialog: a day from today to Discord's last allowed
/// day and a time in the official dialog's 15-minute steps. Arrow keys move
/// the day (left and right) and the time (up and down).
struct ScheduleMessageDialog: View {
    /// Bounds a reschedule to 30 days after its message was first scheduled.
    var scheduledMessageID: ScheduledMessageID?
    let commit: (Date) -> Void
    @Environment(\.windowModalContext) private var modal
    /// Today through the last day Discord accepts; an old message's 30-day
    /// bound may leave only today, which then reads as too far away.
    private let days: [Date]
    /// The time as given, kept while its day and time stay unchanged, so a
    /// reschedule never shifts it, as within a repeated daylight-saving hour.
    private let initialDate: Date
    @State private var day: Date
    /// Minutes after midnight; a time set elsewhere may fall between steps.
    @State private var minute: Int
    @FocusState private var isFocused: Bool

    init(initialDate: Date?, scheduledMessageID: ScheduledMessageID? = nil, commit: @escaping (Date) -> Void) {
        let calendar = Calendar.current
        let date = initialDate ?? Self.nextWholeHour()
        self.scheduledMessageID = scheduledMessageID
        self.commit = commit
        let last = calendar.startOfDay(for: ScheduledMessagePolicy.latestSendDate(for: scheduledMessageID))
        var days = [calendar.startOfDay(for: .now)]
        while let next = calendar.date(byAdding: .day, value: 1, to: days[days.count - 1]), next <= last {
            days.append(next)
        }
        self.days = days
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
                            Label("Sends \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))) at \(date.formatted(date: .omitted, time: .shortened))", systemImage: "paperplane")
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
            ForEach(days, id: \.self) { candidate in
                let isSelected = candidate == day
                Button { day = candidate } label: {
                    VStack(spacing: 2) {
                        Text(candidate.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        Text(candidate.formatted(.dateTime.day()))
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(isSelected ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular.interactive(), in: Capsule())
                .help(candidate.formatted(date: .complete, time: .omitted))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var timePicker: some View {
        HStack(spacing: 12) {
            stepButton(systemImage: "chevron.left", help: "15 Minutes Earlier") { _ = step(by: -1) }
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: minute)
                .frame(maxWidth: .infinity)
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
        let steps = direction > 0 ? minute / 15 + 1 : (minute + 14) / 15 - 1
        minute = min(max(steps, 0), 95) * 15
        return .handled
    }

    private func moveDay(by offset: Int) -> KeyPress.Result {
        guard let index = days.firstIndex(of: day) else { return .ignored }
        day = days[min(max(index + offset, 0), days.count - 1)]
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
}
