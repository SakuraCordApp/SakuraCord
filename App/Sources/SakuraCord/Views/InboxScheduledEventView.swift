import AppKit
import SakuraCordModels
import SwiftUI

struct InboxScheduledEventView: View {
    let event: InboxScheduledEvent
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: InterfaceScale.metric(12)) {
            Button { model.inbox.selectedEvent = event } label: {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(5)) {
                    Text(event.isActive ? "Happening Now" : event.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.interface(.caption)).foregroundStyle(.secondary)
                    Text(event.name).font(.interface(.headline)).lineLimit(2)
                    if let location = event.location {
                        Text(location).font(.interface(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(InterfaceScale.metric(6))
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            HoverActionButton(
                systemImage: event.isInterested ? "star.fill" : "star",
                help: event.isInterested ? "Remove Interest" : "Interested",
                isSelected: event.isInterested
            ) {
                model.setInboxEventInterest(!event.isInterested, event: event)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(16))
        .frame(height: InboxRowMetrics.scheduledEventHeight)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, InterfaceScale.metric(12)) }
    }
}

struct InboxEventDetailsView: View {
    let event: InboxScheduledEvent
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let event = model.inbox.selectedEvent ?? self.event
        VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
            HStack {
                Text(event.name).font(.interface(.title2).weight(.semibold))
                Spacer()
                HoverCloseButton(help: "Close", accessibilityIdentifier: "inbox-event-close", diameter: InterfaceScale.metric(28)) { dismiss() }
            }
            Text(event.startTime.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
            if let description = event.description, !description.isEmpty {
                Text(LocalizedStringKey(description)).textSelection(.enabled)
            }
            if let location = event.location { Label(location, systemImage: "mappin.and.ellipse") }
            HStack {
                if let channelID = event.channelID {
                    Button("Open Channel") {
                        dismiss()
                        model.dismissInbox()
                        model.navigate(to: event.guildID, linkedChannelID: channelID)
                    }
                }
                Spacer()
                Button(event.isInterested ? "Remove Interest" : "Interested") {
                    model.setInboxEventInterest(!event.isInterested, event: event)
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(InterfaceScale.metric(24))
        .frame(width: InterfaceScale.metric(440))
    }
}

extension NativeTimelineCanvasView {
    func reconcileInboxEventViews() {
        var desired: [ScheduledEventID: (InboxScheduledEvent, CGRect)] = [:]
        forEachDisplayedRow(in: visibleRect) { index in
            if case let .inboxEvent(event) = items[index] {
                desired[event.id] = (event, CGRect(x: 0, y: displayedRowOrigin(at: index), width: bounds.width, height: InboxRowMetrics.scheduledEventHeight))
            }
        }
        for id in Array(inboxEventHosts.keys) where desired[id] == nil {
            inboxEventHosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        guard let model else { return }
        for (id, value) in desired {
            let host: NSHostingView<InboxScheduledEventView>
            if let existing = inboxEventHosts[id] {
                host = existing
                if host.rootView.event != value.0 { host.rootView = InboxScheduledEventView(event: value.0, model: model) }
            } else {
                host = NSHostingView(rootView: InboxScheduledEventView(event: value.0, model: model))
                inboxEventHosts[id] = host
                addSubview(host)
            }
            host.frame = value.1
        }
    }
}
