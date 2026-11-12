import AppKit
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
    private let days: [Date]
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
                            // Up or right is later, as with scrolling.
                            let steps = Int(((value.translation.width - value.translation.height) / 16).rounded(.towardZero))
                            while draggedSteps != steps {
                                let direction = steps > draggedSteps ? 1 : -1
                                guard scrub(by: direction) else {
                                    draggedSteps = steps
                                    break
                                }
                                draggedSteps += direction
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
        let steps = direction > 0 ? minute / 15 + 1 : (minute + 14) / 15 - 1
        minute = min(max(steps, 0), 95) * 15
        return .handled
    }

    /// Scrolling and dragging run through the allowed days in 15-minute steps
    /// and stop at either end, each step ticking like the theme editor's controls.
    private func scrub(by direction: Int) -> Bool {
        let steps = direction > 0 ? minute / 15 + 1 : (minute + 14) / 15 - 1
        guard let candidate = Calendar.current.date(byAdding: .minute, value: steps * 15, to: day) else { return false }
        if direction > 0, candidate > ScheduledMessagePolicy.latestSendDate(for: scheduledMessageID) { return false }
        if direction < 0, candidate < ScheduledMessagePolicy.earliestSendDate() { return false }
        day = Calendar.current.startOfDay(for: candidate)
        minute = Self.minutes(of: candidate)
        ColorPickerHaptics.performStep()
        return true
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

/// Turns scrolling over a view into whole steps, up or right being later: a
/// trackpad every few points, momentum included, and a mouse wheel per notch.
private struct ScrollStepInput: NSViewRepresentable {
    /// Returns whether the step was taken; a refused step drops the remainder.
    let step: (Int) -> Bool

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) { view.step = step }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stopMonitoring() }

    final class InputView: NSView {
        var step: (Int) -> Bool = { _ in false }
        private var monitor: Any?
        private var pending: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      WindowModalCoordinator.allowsInput(for: self)
                else { return event }
                self.handle(event)
                return nil
            }
        }

        private func handle(_ event: NSEvent) {
            let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let delta = direction * (event.scrollingDeltaX - event.scrollingDeltaY)
            guard event.hasPreciseScrollingDeltas else {
                if delta != 0 { _ = step(delta > 0 ? 1 : -1) }
                return
            }
            if event.phase.contains(.began) { pending = 0 }
            pending += delta
            while abs(pending) >= 18 {
                guard step(pending > 0 ? 1 : -1) else {
                    pending = 0
                    return
                }
                pending -= pending > 0 ? 18 : -18
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
