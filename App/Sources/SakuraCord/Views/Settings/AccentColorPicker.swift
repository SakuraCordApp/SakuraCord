import AppKit
import SwiftUI

struct AccentColorPicker: View {
    @Binding var selection: AccentColorChoice
    let isEnabled: Bool
    let paletteRefresh: UInt64

    @State private var hoveredChoice: AccentColorChoice?

    private var visibleSubtitleChoice: AccentColorChoice? {
        guard isEnabled else { return nil }
        return hoveredChoice ?? selection
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Accent color", bundle: #bundle)
                .frame(width: 116, alignment: .leading)

            Spacer(minLength: 12)

            HStack(alignment: .top, spacing: 12) {
                ForEach(AccentColorChoice.allCases) { choice in
                    swatchButton(for: choice)
                }
            }
        }
        .disabled(!isEnabled)
    }

    private func swatchButton(for choice: AccentColorChoice) -> some View {
        let ringDiameter: CGFloat = 32
        let swatchDiameter: CGFloat = 24

        return VStack(spacing: 4) {
            Button {
                selection = choice
            } label: {
                swatch(for: choice)
                    .frame(width: swatchDiameter, height: swatchDiameter)
            }
            .buttonStyle(.plain)
            .background {
                if isEnabled, selection == choice {
                    ZStack {
                        Circle()
                            .fill(SakuraCordAccentColor.color)
                            .frame(width: ringDiameter, height: ringDiameter)

                        Circle()
                            .fill(.background)
                            .frame(width: ringDiameter - 6, height: ringDiameter - 6)
                    }
                }
            }
            .contentShape(Circle())
            .accessibilityLabel(choice.title)
            .accessibilityValue(
                !isEnabled
                    ? "Unavailable"
                    : selection == choice ? "Selected" : "Not selected"
            )
            .onHover { isHovering in
                if isHovering {
                    hoveredChoice = choice
                } else if hoveredChoice == choice {
                    hoveredChoice = nil
                }
            }

            if visibleSubtitleChoice == choice {
                Text(choice.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(
                        width: swatchDiameter,
                        alignment: choice == .gray ? .trailing : .center
                    )
            }
        }
        .frame(width: swatchDiameter, alignment: .top)
    }

    @ViewBuilder
    private func swatch(for choice: AccentColorChoice) -> some View {
        if let systemImage = SystemAccentPalette.image(
            for: choice,
            refresh: paletteRefresh
        ) {
            Image(nsImage: systemImage)
                .resizable()
                .interpolation(.high)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(choice.color)
        }
    }
}

struct SystemAccentPaletteRefreshBridge: NSViewRepresentable {
    @Binding var refresh: UInt64

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        let refresh = $refresh
        view.refresh = {
            refresh.wrappedValue &+= 1
        }
    }

    @MainActor
    final class ObserverView: NSView {
        var refresh: (() -> Void)?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refresh?()
        }
    }
}
