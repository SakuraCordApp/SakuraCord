import AppKit
import SwiftUI

// Adapted from the theme designer without altering its controls.
struct SakuraCordColorSlider: View {
    let value: Double
    let colors: [Color]
    let label: LocalizedStringKey
    let setter: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastHapticStep: Int?

    var body: some View {
        let trackColors = colors
        let handleY = ThemePickerGeometry.intensityHandleCenterY(for: self.value)

        ZStack {
            ColorSliderTrackShape()
                .fill(
                    LinearGradient(
                        colors: trackColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    ColorSliderTrackShape()
                        .stroke(.primary.opacity(0.18), lineWidth: 1)
                }
                .overlay {
                    ColorSliderWaveShape(intensity: self.value)
                        .stroke(
                            .white.opacity(0.72),
                            style: StrokeStyle(
                                lineWidth: ThemePickerGeometry.intensityWaveLineWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .shadow(color: .black.opacity(0.22), radius: InterfaceScale.metric(2))
                        .clipShape(ColorSliderTrackShape())
                }
                .frame(
                    width: ThemePickerGeometry.ringWidth,
                    height: ThemePickerGeometry.intensityTrackHeight
                )

            Capsule()
                .fill(.clear)
                .frame(
                    width: ThemePickerGeometry.intensityHandleWidth,
                    height: ThemePickerGeometry.intensityHandleHeight
                )
                .glassEffect(.regular.interactive(), in: Capsule())
                .overlay {
                    Capsule().stroke(.primary.opacity(0.32), lineWidth: 1)
                }
                .position(x: ThemePickerGeometry.intensityHitWidth / 2, y: handleY)
        }
        .frame(
            width: ThemePickerGeometry.intensityHitWidth,
            height: ThemePickerGeometry.intensityTrackHeight
        )
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: ThemePickerGeometry.sliderDragMinimumDistance)
                .onChanged { value in
                    let intensity = ThemePickerGeometry.intensity(atY: value.location.y)
                    updateHaptics(for: intensity)
                    setter(intensity)
                }
                .onEnded { _ in
                    lastHapticStep = nil
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    let intensity = ThemePickerGeometry.intensity(atY: value.location.y)
                    withAnimation(reduceMotion ? nil : .themeRandomizationTransition) {
                        setter(intensity)
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((self.value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            setter(self.value + step)
        }
    }

    private func updateHaptics(for value: Double) {
        let step = ThemePickerGeometry.hapticStep(
            for: value,
            divisions: ThemePickerGeometry.linearHapticDivisions
        )
        guard step != lastHapticStep else { return }
        defer { lastHapticStep = step }
        guard lastHapticStep != nil else { return }
        StepHaptics.performStep()
    }
}

private nonisolated struct ColorSliderTrackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let topRadius = min(ThemePickerGeometry.ringWidth / 2, rect.height / 2)
        let bottomRadius = min(
            ThemePickerGeometry.ringWidth / 2,
            rect.height / 2
        )

        var path = Path()
        path.move(to: CGPoint(x: centerX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: centerX + topRadius, y: rect.minY + topRadius),
            control1: CGPoint(x: centerX + topRadius, y: rect.minY),
            control2: CGPoint(x: centerX + topRadius, y: rect.minY + topRadius)
        )
        path.addLine(to: CGPoint(x: centerX + bottomRadius, y: rect.maxY - bottomRadius))
        path.addCurve(
            to: CGPoint(x: centerX, y: rect.maxY),
            control1: CGPoint(x: centerX + bottomRadius, y: rect.maxY),
            control2: CGPoint(x: centerX, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: centerX - bottomRadius, y: rect.maxY - bottomRadius),
            control1: CGPoint(x: centerX, y: rect.maxY),
            control2: CGPoint(x: centerX - bottomRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: centerX - topRadius, y: rect.minY + topRadius))
        path.addCurve(
            to: CGPoint(x: centerX, y: rect.minY),
            control1: CGPoint(x: centerX - topRadius, y: rect.minY),
            control2: CGPoint(x: centerX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private nonisolated struct ColorSliderWaveShape: Shape {
    var intensity: Double

    var animatableData: Double {
        get { intensity }
        set { intensity = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let waveStrength = ThemePickerGeometry.intensityWaveStrength(for: intensity)
        let centerX = rect.midX
        let sampleCount = ThemePickerGeometry.intensityWaveSampleCount

        var path = Path()
        path.move(to: CGPoint(x: centerX, y: rect.minY))
        for sample in 1 ... sampleCount {
            let progress = Double(sample) / Double(sampleCount)
            let trackWidth = ThemePickerGeometry.ringWidth
            let availableAmplitude = max(
                0,
                trackWidth / 2 - ThemePickerGeometry.intensityWaveLineWidth
            )
            let amplitude = availableAmplitude * waveStrength
            let phase = progress * ThemePickerGeometry.intensityWaveCount * 2 * .pi
            path.addLine(
                to: CGPoint(
                    x: centerX + sin(phase) * amplitude,
                    y: rect.minY + rect.height * progress
                )
            )
        }
        return path
    }
}
