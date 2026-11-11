import SakuraCordModels
import SwiftUI

/// Picks a send time: the official client's three shortcuts, or any time from
/// ten minutes to eight days ahead. Rescheduling an existing message, like the
/// official dialog, offers no shortcuts.
struct ScheduleMessagePicker: View {
    /// Bounds a reschedule to 30 days after its message was first scheduled.
    var scheduledMessageID: ScheduledMessageID?
    var clear: (() -> Void)?
    let commit: (Date) -> Void
    @State private var date: Date

    init(
        initialDate: Date?,
        scheduledMessageID: ScheduledMessageID? = nil,
        clear: (() -> Void)? = nil,
        commit: @escaping (Date) -> Void
    ) {
        self.scheduledMessageID = scheduledMessageID
        self.clear = clear
        self.commit = commit
        _date = State(initialValue: initialDate ?? Self.nextWholeHour())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text(scheduledMessageID == nil ? "Schedule Message" : "Update Scheduled Message")
                .font(.interface(.headline))
                .padding(.horizontal, InterfaceScale.metric(8))
                .padding(.top, InterfaceScale.metric(4))
            if scheduledMessageID == nil {
                VStack(spacing: InterfaceScale.metric(2)) {
                    // Late on a Sunday, tomorrow's 9:00 is also Monday's; the official menu lists both.
                    ForEach(Self.shortcuts(), id: \.label) { shortcut in
                        Button { commit(shortcut.date) } label: {
                            Label {
                                Text(shortcut.label)
                            } icon: {
                                Image(systemName: shortcut.systemImage)
                                    .frame(width: InterfaceScale.metric(20))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(InterfaceScale.metric(8))
                        }
                    }
                }
                .buttonStyle(PopoverRowButtonStyle())
                Divider().padding(.horizontal, InterfaceScale.metric(8))
            }
            DatePicker(
                "Send at",
                selection: $date,
                in: Self.allowedRange(for: scheduledMessageID),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .padding(.horizontal, InterfaceScale.metric(8))
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle.fill")
                    .font(.interface(.caption))
                    .foregroundStyle(.red)
                    .padding(.horizontal, InterfaceScale.metric(8))
            }
            HStack(spacing: InterfaceScale.metric(8)) {
                if let clear {
                    Button("Clear", role: .destructive, action: clear)
                        .buttonStyle(.glass)
                }
                Spacer(minLength: 0)
                Button(scheduledMessageID == nil ? "Set Schedule" : "Update") { commit(date) }
                    .buttonStyle(.glassProminent)
                    .tint(SakuraCordAccentColor.color)
                    .keyboardShortcut(.defaultAction)
                    .disabled(issue != nil)
            }
            .controlSize(.regular)
            .padding(InterfaceScale.metric(8))
        }
        .padding(InterfaceScale.metric(6))
        .frame(width: InterfaceScale.metric(260))
    }

    /// The range can lapse while the picker stays open.
    private var issue: LocalizedStringResource? {
        if date < ScheduledMessagePolicy.earliestSendDate() { return "Scheduled time is too soon" }
        if date > ScheduledMessagePolicy.latestSendDate(for: scheduledMessageID) { return "Scheduled time is too far away" }
        return nil
    }

    /// An old message's 30-day bound can precede the earliest time; the
    /// picker then shows that time and reports it as too far away.
    static func allowedRange(for id: ScheduledMessageID?) -> ClosedRange<Date> {
        let earliest = ScheduledMessagePolicy.earliestSendDate()
        return earliest ... max(earliest, ScheduledMessagePolicy.latestSendDate(for: id))
    }

    /// The next whole hour, or the one after when that is under ten minutes away.
    static func nextWholeHour(now: Date = .now, calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        return hour < ScheduledMessagePolicy.earliestSendDate(now: now) ? hour.addingTimeInterval(3600) : hour
    }

    struct Shortcut {
        let label: String
        let systemImage: String
        let date: Date
    }

    /// 9:00 and 13:00 today, or tomorrow once too close, then next week's Monday at 9:00.
    static func shortcuts(now: Date = .now, calendar: Calendar = .current) -> [Shortcut] {
        let earliest = ScheduledMessagePolicy.earliestSendDate(now: now)
        let today = calendar.startOfDay(for: now)
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        func daily(hour: Int, systemImage: String) -> Shortcut {
            let todayAt = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) ?? today
            if todayAt > earliest {
                return Shortcut(label: String(localized: "Today at \(time(todayAt))"), systemImage: systemImage, date: todayAt)
            }
            let tomorrowAt = calendar.date(byAdding: .day, value: 1, to: todayAt) ?? todayAt
            return Shortcut(label: String(localized: "Tomorrow at \(time(tomorrowAt))"), systemImage: systemImage, date: tomorrowAt)
        }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let thisWeek = iso.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let monday = calendar.date(
            bySettingHour: 9, minute: 0, second: 0, of: iso.date(byAdding: .weekOfYear, value: 1, to: thisWeek) ?? thisWeek
        ) ?? thisWeek
        return [
            daily(hour: 9, systemImage: "sunrise"),
            daily(hour: 13, systemImage: "sun.max"),
            Shortcut(label: String(localized: "Monday at \(time(monday))"), systemImage: "calendar", date: monday),
        ]
    }
}

/// The composer's note that its message will be scheduled, then that it was.
struct ComposerScheduleHeader: View {
    let model: AppModel
    let destination: MessageComposerDestination
    @State private var isEditing = false

    var body: some View {
        if let channelID = model.composerSendChannelID(in: destination) {
            let state = model.scheduledMessages
            if let confirmed = state.confirmations[channelID] {
                row(systemImage: "checkmark.circle.fill", tint: .green) {
                    Button { model.presentScheduledMessages() } label: {
                        Text("Message scheduled for \(confirmed.formatted(.scheduledSendTime))")
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(model.isInboxAvailable)
                    .help("Show Scheduled Messages")
                    Spacer(minLength: 0)
                }
            } else if let date = state.sendDates[channelID] {
                row(systemImage: "calendar.badge.clock", tint: SakuraCordAccentColor.color) {
                    Button { isEditing = true } label: {
                        Text("Scheduling for \(date.formatted(.scheduledSendTime))")
                    }
                    .buttonStyle(.plain)
                    .help("Edit Schedule Time")
                    .popover(isPresented: $isEditing, arrowEdge: .top) {
                        ScheduleMessagePicker(
                            initialDate: date,
                            clear: {
                                isEditing = false
                                model.setScheduledSendDate(nil, in: destination)
                            },
                            commit: {
                                isEditing = false
                                model.setScheduledSendDate($0, in: destination)
                            }
                        )
                    }
                    Spacer(minLength: InterfaceScale.metric(8))
                    if state.submittingChannelIDs.contains(channelID) {
                        ProgressView().controlSize(.small)
                    } else {
                        HoverCloseButton(
                            help: "Don't Schedule",
                            accessibilityIdentifier: "composer-schedule-close",
                            diameter: InterfaceScale.metric(30),
                            iconSize: 13
                        ) { model.setScheduledSendDate(nil, in: destination) }
                    }
                }
            }
        }
    }

    private func row(
        systemImage: String, tint: Color, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            Image(systemName: systemImage).foregroundStyle(tint)
            content()
        }
        .font(.interface(.callout))
        .frame(minHeight: InterfaceScale.metric(34))
        .padding(.leading, InterfaceScale.metric(12))
        .padding(.trailing, InterfaceScale.metric(8))
        .background(.primary.opacity(0.035))
    }
}

extension FormatStyle where Self == Date.FormatStyle {
    /// "Nov 12, 9:00 AM" in the person's locale.
    static var scheduledSendTime: Date.FormatStyle {
        .dateTime.month(.abbreviated).day().hour().minute()
    }
}
