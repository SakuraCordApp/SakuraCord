import SakuraCordModels
import SwiftUI

/// The official client's three send-time shortcuts, and Custom…, which opens
/// the schedule dialog.
struct ScheduleMessageShortcuts: View {
    let pick: (Date) -> Void
    let custom: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text("Schedule Message")
                .font(.interface(.headline))
                .padding(.horizontal, InterfaceScale.metric(8))
                .padding(.top, InterfaceScale.metric(4))
            VStack(spacing: InterfaceScale.metric(2)) {
                // Late on a Sunday, tomorrow's 9:00 is also Monday's; the official menu lists both.
                ForEach(Self.shortcuts(), id: \.label) { shortcut in
                    row(shortcut.label, systemImage: shortcut.systemImage) { pick(shortcut.date) }
                }
                row(String(localized: "Custom…"), systemImage: "calendar.badge.plus", action: custom)
            }
            .buttonStyle(PopoverRowButtonStyle())
        }
        .padding(InterfaceScale.metric(6))
        .frame(width: InterfaceScale.metric(260))
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(ComposerActionLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(InterfaceScale.metric(8))
        }
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
    /// Opens the composer's schedule dialog.
    let customize: () -> Void
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
                    .disabled(state.submissions[channelID] != nil)
                    .popover(isPresented: $isEditing, arrowEdge: .top) {
                        ScheduleMessageShortcuts { date in
                            isEditing = false
                            model.setScheduledSendDate(date, in: destination)
                        } custom: {
                            isEditing = false
                            customize()
                        }
                    }
                    Spacer(minLength: InterfaceScale.metric(8))
                    if state.submissions[channelID] != nil {
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
