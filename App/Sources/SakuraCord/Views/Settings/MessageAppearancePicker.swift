import SwiftUI

struct MessageAppearancePicker: View {
    @Binding var selection: MessageAppearance
    let showsIncomingIdentity: Bool

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            ForEach(MessageAppearance.allCases) { appearance in
                Button {
                    selection = appearance
                } label: {
                    MessageAppearanceCard(appearance: appearance, showsIncomingIdentity: showsIncomingIdentity)
                        .background {
                            RoundedRectangle(cornerRadius: InterfaceScale.metric(10))
                                .fill(.primary.opacity(selection == appearance ? 0.06 : 0.025))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: InterfaceScale.metric(10))
                                .strokeBorder(
                                    selection == appearance ? SakuraCordAccentColor.color : Color(nsColor: .separatorColor),
                                    lineWidth: selection == appearance ? 2 : 1
                                )
                        }
                        .contentShape(.rect(cornerRadius: InterfaceScale.metric(10)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(appearance.title))
                .accessibilityAddTraits(selection == appearance ? .isSelected : [])
                .help(Text(appearance.title))
            }
        }
        .fixedSize()
    }
}

private struct MessageAppearanceCard: View {
    let appearance: MessageAppearance
    let showsIncomingIdentity: Bool

    var body: some View {
        VStack(spacing: InterfaceScale.metric(4)) {
            message(color: .orange, width: 58)
            message(color: .mint, width: 46, outgoing: true)
            message(color: .purple, width: 52)
        }
        .padding(.horizontal, InterfaceScale.metric(12))
        .padding(.vertical, InterfaceScale.metric(10))
        .frame(width: InterfaceScale.metric(136), height: InterfaceScale.metric(88))
        .accessibilityHidden(true)
    }

    private func message(color: Color, width: CGFloat, outgoing: Bool = false) -> some View {
        let usesBubbles = appearance == .bubbles
        let isTrailing = usesBubbles && outgoing
        let showsIdentity = !usesBubbles || (!outgoing && showsIncomingIdentity)

        return HStack(alignment: .bottom, spacing: InterfaceScale.metric(6)) {
            if isTrailing { Spacer(minLength: 0) }
            if showsIdentity {
                avatar(color, diameter: usesBubbles ? 13 : 16)
            }

            VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
                if showsIdentity {
                    RoundedRectangle(cornerRadius: InterfaceScale.metric(1))
                        .fill(color.opacity(0.8))
                        .frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(3))
                        .padding(.leading, InterfaceScale.metric(usesBubbles ? 6 : 0))
                }
                RoundedRectangle(cornerRadius: InterfaceScale.metric(1))
                    .fill(.primary.opacity(0.25))
                    .frame(width: InterfaceScale.metric(width), height: InterfaceScale.metric(usesBubbles ? 4 : 3))
                    .padding(.horizontal, InterfaceScale.metric(usesBubbles ? 6 : 0))
                    .padding(.vertical, InterfaceScale.metric(usesBubbles ? 5 : 0))
                    .background {
                        if usesBubbles {
                            bubbleBackground(outgoing: outgoing)
                        }
                    }
            }

            if !isTrailing { Spacer(minLength: 0) }
        }
        .frame(height: InterfaceScale.metric(20), alignment: .bottom)
    }

    private func bubbleBackground(outgoing: Bool) -> some View {
        GeometryReader { geometry in
            // Miniaturize the timeline's outline, including its tail.
            let scale: CGFloat = 0.4
            let region = NativeTimelineBubbleRegion(
                frame: CGRect(
                    x: 0, y: 0,
                    width: geometry.size.width / scale,
                    height: geometry.size.height / scale
                ),
                isOutgoing: outgoing,
                showsTail: true
            )
            Path(NativeTimelineBubbleDrawing.path(for: region).cgPath)
                .applying(CGAffineTransform(scaleX: scale, y: scale))
                .fill(outgoing ? SakuraCordAccentColor.color.opacity(0.18) : Color.primary.opacity(0.07))
        }
    }

    private func avatar(_ color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(color.gradient)
            .frame(width: InterfaceScale.metric(diameter), height: InterfaceScale.metric(diameter))
    }
}
