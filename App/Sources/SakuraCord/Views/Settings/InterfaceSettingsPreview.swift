import SwiftUI

struct InterfaceSettingsPreview: View {
    let value: InterfaceSettingsSnapshot

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider()
            HStack(spacing: 0) {
                previewSidebar
                Divider()
                previewMessages
                if value.showsMemberList {
                    Divider()
                    previewMembers
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 300)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Interface settings preview")
        .accessibilityValue(accessibilitySummary)
    }

    private var previewHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "number")
            VStack(alignment: .leading, spacing: 0) {
                Text("design-lab", bundle: #bundle)
                    .font(.system(size: value.interfaceTextSize, weight: .semibold))
                if value.showsChannelHeader {
                    Text("Critique, prototypes, and experiments", bundle: #bundle)
                        .font(.system(size: max(10, value.interfaceTextSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: value.showsMemberList ? "person.2.fill" : "person.2")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: value.showsChannelHeader ? 48 : 38)
    }

    private var previewSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STUDIO", bundle: #bundle)
                .font(.system(size: max(10, value.interfaceTextSize - 2), weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 3)
            previewChannel("general", image: "number", selected: false)
            previewChannel("design-lab", image: "number", selected: true)
            previewChannel("Lounge", image: "speaker.wave.2", selected: false)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 150, alignment: .topLeading)
        .background(.quaternary.opacity(0.22))
    }

    private func previewChannel(
        _ title: LocalizedStringKey,
        image: String,
        selected: Bool
    ) -> some View {
        Label(title, systemImage: image)
            .font(.system(size: value.interfaceTextSize))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: value.sidebarDensity.minimumRowHeight)
            .background(
                selected
                    ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                    : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    private var previewMessages: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewMessage(
                name: "Hana",
                content: linkMessage,
                time: representativeTime,
                startsGroup: true,
                isLink: true,
                showsActionCapsule: false
            )
            previewMessage(
                name: "Hana",
                content: AttributedString(localized: "The spacing updates immediately."),
                time: laterTime,
                startsGroup: !groupsRepresentativeMessages,
                isLink: false,
                showsActionCapsule: value.messageActionVisibility == .always
            )
            .padding(
                .top,
                groupsRepresentativeMessages ? 0 : value.messageDensity.groupSeparation
            )
            Spacer(minLength: 0)
        }
        .padding(value.messageDensity.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func previewMessage(
        name: LocalizedStringKey,
        content: AttributedString,
        time: Date,
        startsGroup: Bool,
        isLink: Bool,
        showsActionCapsule: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: value.messageDensity.columnGap) {
            Group {
                if startsGroup {
                    Circle()
                        .fill(.tertiary)
                        .overlay {
                            Text("H", bundle: #bundle)
                                .font(.caption.weight(.semibold))
                        }
                } else {
                    Text(timestamp(time, includesSeconds: false))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(
                width: value.messageDensity.avatarDiameter,
                height: startsGroup ? value.messageDensity.avatarDiameter : 18
            )

            VStack(alignment: .leading, spacing: value.messageDensity.authorToContentSpacing) {
                if startsGroup {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(value.showsRoleColors ? .purple : .primary)
                        Text(timestamp(time, includesSeconds: true))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(content)
                    .font(.system(size: value.messageTextSize))
                    .foregroundStyle(
                        isLink
                            ? Color(nsColor: .linkColor)
                            : Color.primary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if showsActionCapsule {
                HStack(spacing: 5) {
                    Image(systemName: "face.smiling")
                    Image(systemName: "arrowshape.turn.up.left")
                    Image(systemName: "ellipsis")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(5)
                .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private var previewMembers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ONLINE — 2", bundle: #bundle)
                .font(.system(size: max(10, value.interfaceTextSize - 2), weight: .semibold))
                .foregroundStyle(.secondary)
            previewMember("Hana", activity: "Designing a prototype", color: .purple)
            previewMember("Ren", activity: "Reviewing feedback", color: .primary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 170, alignment: .topLeading)
        .background(.quaternary.opacity(0.12))
    }

    private func previewMember(
        _ name: LocalizedStringKey,
        activity: LocalizedStringKey,
        color: Color
    ) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.tertiary)
                .frame(width: 28, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    if value.showsActivityDetails {
                        Circle().fill(.green).frame(width: 8, height: 8)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: value.interfaceTextSize, weight: .semibold))
                    .foregroundStyle(value.showsRoleColors ? color : .primary)
                if value.showsActivityDetails {
                    Text(activity)
                        .font(.system(size: max(10, value.interfaceTextSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var linkMessage: AttributedString {
        var text = AttributedString(localized: "See the interface guide")
        if value.underlinesLinks {
            text.underlineStyle = .single
        }
        return text
    }

    private var representativeTime: Date {
        Date(timeIntervalSinceReferenceDate: 760_000_000)
    }

    private var laterTime: Date {
        representativeTime.addingTimeInterval(5 * 60)
    }

    private var groupsRepresentativeMessages: Bool {
        value.groupingIntervalMinutes > 5
    }

    private func timestamp(_ date: Date, includesSeconds: Bool) -> String {
        InterfaceTimestampFormatter.text(
            for: date,
            format: value.timestampFormat,
            includesSeconds: includesSeconds && value.includesTimestampSeconds
        )
    }

    private var accessibilitySummary: String {
        let textSizes =
            "message text \(Int(value.messageTextSize)) points, "
            + "interface text \(Int(value.interfaceTextSize)) points"
        let memberList = value.showsMemberList ? "shown" : "hidden"
        return "\(value.messageDensity.rawValue) messages, "
            + "\(value.sidebarDensity.rawValue) sidebar, \(textSizes), "
            + "\(value.timestampFormat.rawValue) timestamps, member list \(memberList)"
    }
}
