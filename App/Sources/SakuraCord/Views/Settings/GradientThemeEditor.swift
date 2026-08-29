import AppKit
import SwiftUI

struct GradientThemeEditor: View {
    let themeStore: SakuraCordThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GradientThemeEditorHeader(themeStore: themeStore)
            GradientThemeControls(themeStore: themeStore)
        }
        .padding(.vertical, 6)
    }
}

private struct GradientThemeEditorHeader: View {
    let themeStore: SakuraCordThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = themeStore.activeTheme.colors(for: colorScheme)
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Theme Designer", bundle: #bundle)
                    .font(.title3.weight(.semibold))
                Text("Create your perfect theme.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [colors.first, colors.second],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 130, height: 42)
                .overlay {
                    Capsule().stroke(.primary.opacity(0.15), lineWidth: 1)
                }
        }
    }
}

private struct GradientThemeControls: View {
    let themeStore: SakuraCordThemeStore

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(alignment: .center, spacing: 0) {
                CircularBrightnessControl(themeStore: themeStore)
                    .frame(maxWidth: .infinity)
                DualHuePicker(themeStore: themeStore)
                    .frame(
                        width: ThemePickerGeometry.diameter,
                        height: ThemePickerGeometry.diameter
                    )
                ThemeRandomizeButton(themeStore: themeStore)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

private struct DualHuePicker: View {
    let themeStore: SakuraCordThemeStore

    var body: some View {
        let theme = themeStore.activeTheme
        let wheelColors = stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map {
            Color(hue: $0, saturation: 1, brightness: 1)
        }
        let wheelGradient = AngularGradient(
            colors: wheelColors,
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
        ZStack {
            Circle()
                .stroke(
                    wheelGradient,
                    lineWidth: ThemePickerGeometry.ringGlowLineWidth
                )
                .blur(radius: ThemePickerGeometry.ringGlowRadius)
                .opacity(ThemePickerGeometry.ringGlowOpacity)

            Circle()
                .inset(by: ThemePickerGeometry.ringWidth)
                .stroke(
                    wheelGradient,
                    lineWidth: ThemePickerGeometry.ringGlowLineWidth
                )
                .blur(radius: ThemePickerGeometry.ringGlowRadius)
                .opacity(ThemePickerGeometry.ringGlowOpacity)

            Circle()
                .strokeBorder(
                    wheelGradient,
                    lineWidth: ThemePickerGeometry.ringWidth
                )

            ThemeHueHandle(
                hue: theme.first.hue,
                setter: themeStore.setFirstHue,
                finishInteraction: themeStore.finishInteraction
            )
            ThemeHueHandle(
                hue: theme.second.hue,
                setter: themeStore.setSecondHue,
                finishInteraction: themeStore.finishInteraction
            )

            // Keep the intensity control above every hue-handle hit target.
            // Its central interaction region must never lose a drag to the ring.
            ThemeIntensityControl(themeStore: themeStore)
                .frame(
                    width: ThemePickerGeometry.intensityHitWidth,
                    height: ThemePickerGeometry.intensityTrackHeight
                )
        }
        .frame(width: ThemePickerGeometry.diameter, height: ThemePickerGeometry.diameter)
        .coordinateSpace(.named("dual-hue-picker"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gradient color picker")
    }
}

private struct ThemeHueHandle: View {
    let hue: Double
    let setter: (Double) -> Void
    let finishInteraction: () -> Void

    @State private var lastHapticStep: Int?

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .frame(
                    width: ThemePickerGeometry.hueHandleSize,
                    height: ThemePickerGeometry.hueHandleSize
                )
                .glassEffect(.clear.interactive(), in: Circle())
                .overlay {
                    Circle().stroke(.primary.opacity(0.52), lineWidth: 1)
                }
            }
            .frame(
                width: ThemePickerGeometry.hueHandleHitSize,
                height: ThemePickerGeometry.hueHandleHitSize
            )
            .contentShape(Circle())
            // `position`, unlike `offset`, moves layout and hit testing together.
            .position(ThemePickerGeometry.hueHandleCenter(for: hue))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("dual-hue-picker"))
                    .onChanged { value in
                        let newHue = ThemePickerGeometry.hue(at: value.location)
                        updateHaptics(for: newHue)
                        setter(newHue)
                    }
                    .onEnded { _ in
                        lastHapticStep = nil
                        finishInteraction()
                    }
            )
            .accessibilityLabel("Gradient color")
            .accessibilityValue("Hue \(Int((hue * 360).rounded())) degrees")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1.0 / 72 : -1.0 / 72
                setter(hue + step)
                finishInteraction()
            }
    }

    private func updateHaptics(for value: Double) {
        let step = ThemePickerGeometry.hapticStep(
            for: value,
            divisions: ThemePickerGeometry.hueHapticDivisions
        )
        guard step != lastHapticStep else { return }
        defer { lastHapticStep = step }
        guard lastHapticStep != nil else { return }
        ThemeSliderHaptics.performStep()
    }
}

private struct ThemeIntensityControl: View {
    let themeStore: SakuraCordThemeStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastHapticStep: Int?

    var body: some View {
        let theme = themeStore.activeTheme
        let colors = theme.colors(for: colorScheme)
        let handleY = ThemePickerGeometry.intensityHandleCenterY(for: theme.intensity)

        ZStack {
            IntensityTrackShape()
                .fill(
                    LinearGradient(
                        colors: [colors.first, colors.second, colors.first],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    IntensityTrackShape()
                        .stroke(.primary.opacity(0.18), lineWidth: 1)
                }
                .overlay {
                    IntensityWaveShape(intensity: theme.intensity)
                        .stroke(
                            .white.opacity(0.72),
                            style: StrokeStyle(
                                lineWidth: ThemePickerGeometry.intensityWaveLineWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .shadow(color: .black.opacity(0.22), radius: 2)
                        .clipShape(IntensityTrackShape())
                }
                .frame(
                    width: ThemePickerGeometry.intensityTrackTopWidth,
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
                    themeStore.setIntensity(intensity)
                }
                .onEnded { _ in
                    lastHapticStep = nil
                    themeStore.finishInteraction()
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    let intensity = ThemePickerGeometry.intensity(atY: value.location.y)
                    withAnimation(reduceMotion ? nil : .themeRandomizationTransition) {
                        themeStore.setIntensity(intensity)
                    }
                    themeStore.finishInteraction()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gradient intensity")
        .accessibilityValue("\(Int((theme.intensity * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            themeStore.setIntensity(theme.intensity + step)
            themeStore.finishInteraction()
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
        ThemeSliderHaptics.performStep()
    }
}

private nonisolated struct IntensityTrackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let topRadius = min(ThemePickerGeometry.intensityTrackTopWidth / 2, rect.height / 2)
        let bottomRadius = min(
            ThemePickerGeometry.intensityTrackBottomWidth / 2,
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

private nonisolated struct IntensityWaveShape: Shape {
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
            let trackWidth = ThemePickerGeometry.intensityTrackWidth(at: progress)
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

private struct CircularBrightnessControl: View {
    let themeStore: SakuraCordThemeStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastHapticStep: Int?

    var body: some View {
        let brightness = themeStore.activeTheme.brightness
        let indicatorAngle = ThemePickerGeometry.brightnessAngle(for: brightness)

        ZStack {
            ForEach(0 ..< ThemePickerGeometry.brightnessTickCount, id: \.self) { index in
                let isLarge = index.isMultiple(of: 3)
                Capsule()
                    .fill(.primary.opacity(isLarge ? 0.42 : 0.24))
                    .frame(
                        width: isLarge ? 2.2 : 1.6,
                        height: isLarge ? 8 : 5
                    )
                    .offset(y: -ThemePickerGeometry.brightnessTickRadius)
                    .rotationEffect(
                        .degrees(ThemePickerGeometry.brightnessTickAngle(at: index))
                    )
            }

            Image(systemName: "sun.max.fill")
                .font(.title2.weight(.medium))
                .foregroundStyle(.primary.opacity(0.78))

            Capsule()
                .fill(Color(nsColor: .labelColor))
                .frame(
                    width: ThemePickerGeometry.brightnessIndicatorWidth,
                    height: ThemePickerGeometry.brightnessIndicatorHeight
                )
                .offset(x: ThemePickerGeometry.brightnessTickRadius)
                .rotationEffect(.degrees(indicatorAngle))
        }
        .frame(
            width: ThemePickerGeometry.sideControlDiameter,
            height: ThemePickerGeometry.sideControlDiameter
        )
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: ThemePickerGeometry.sliderDragMinimumDistance)
                .onChanged { value in
                    let brightness = ThemePickerGeometry.brightness(
                        at: value.location,
                        preservingEndpointFor: themeStore.activeTheme.brightness
                    )
                    updateHaptics(for: brightness)
                    themeStore.setBrightness(brightness)
                }
                .onEnded { _ in
                    lastHapticStep = nil
                    themeStore.finishInteraction()
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    let brightness = ThemePickerGeometry.brightness(at: value.location)
                    withAnimation(reduceMotion ? nil : .themeRandomizationTransition) {
                        themeStore.setBrightness(brightness)
                    }
                    themeStore.finishInteraction()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theme brightness")
        .accessibilityValue("\(Int((brightness * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            themeStore.setBrightness(brightness + step)
            themeStore.finishInteraction()
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
        ThemeSliderHaptics.performStep()
    }
}

@MainActor
private enum ThemeSliderHaptics {
    static func performStep() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
    }
}

private struct ThemeRandomizeButton: View {
    let themeStore: SakuraCordThemeStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0
    @State private var randomizationTask: Task<Void, Never>?

    var body: some View {
        Button {
            randomizationTask?.cancel()
            if reduceMotion {
                rotation += 360
            } else {
                withAnimation(.themeControlResponse) {
                    rotation += 360
                }
            }
            randomizationTask = Task {
                await themeStore.randomize(reduceMotion: reduceMotion)
            }
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .rotationEffect(.degrees(rotation))
                .frame(
                    width: ThemePickerGeometry.sideControlDiameter,
                    height: ThemePickerGeometry.sideControlDiameter
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(
            width: ThemePickerGeometry.sideControlDiameter,
            height: ThemePickerGeometry.sideControlDiameter
        )
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(Circle())
        .accessibilityLabel("Randomise theme")
        .onDisappear {
            randomizationTask?.cancel()
        }
    }
}

nonisolated enum ThemePickerGeometry {
    static let diameter: CGFloat = 270
    static let ringWidth: CGFloat = 25
    static let ringGlowLineWidth: CGFloat = 3
    static let ringGlowRadius: CGFloat = 4
    static let ringGlowOpacity = 0.32
    static let hueHandleSize: CGFloat = 40
    static let hueHandleHitSize: CGFloat = 52
    static let intensityTrackHeight: CGFloat = 132
    static let intensityTrackTopWidth: CGFloat = 34
    static let intensityTrackBottomWidth: CGFloat = 18
    static let intensityWaveLineWidth: CGFloat = 3.5
    static let intensityWaveMinimumStrength = 0.13
    static let intensityWaveMaximumStrength = 0.84
    static let intensityWaveCount = 3.0
    static let intensityWaveSampleCount = 60
    static let intensityHitWidth: CGFloat = 76
    static let intensityHandleWidth: CGFloat = 58
    static let intensityHandleHeight: CGFloat = 24
    static let sideControlDiameter: CGFloat = 112
    static let brightnessIndicatorWidth: CGFloat = 27
    static let brightnessIndicatorHeight: CGFloat = 12
    static let brightnessTickCount = 19
    static let brightnessTickRadius: CGFloat = 38
    static let sliderDragMinimumDistance: CGFloat = 3
    static let hueHapticDivisions = 36
    static let linearHapticDivisions = 20

    private static let hueRadius = (diameter - ringWidth) / 2
    private static let brightnessRadius = brightnessTickRadius
    private static let brightnessStartAngle = 135.0
    private static let brightnessSweep = 270.0
    private static let brightnessEndpointActivationAngle = 10.0

    static func intensityTrackWidth(at progress: Double) -> CGFloat {
        let clampedProgress = min(max(progress, 0), 1)
        return intensityTrackTopWidth
            + (intensityTrackBottomWidth - intensityTrackTopWidth) * CGFloat(clampedProgress)
    }

    static func intensityWaveStrength(for intensity: Double) -> CGFloat {
        let clampedIntensity = min(max(intensity, 0), 1)
        return CGFloat(
            intensityWaveMinimumStrength
                + (intensityWaveMaximumStrength - intensityWaveMinimumStrength)
                * clampedIntensity
        )
    }

    static func hueHandleCenter(for hue: Double) -> CGPoint {
        let angle = hue * 2 * Double.pi - Double.pi / 2
        return CGPoint(
            x: diameter / 2 + cos(angle) * hueRadius,
            y: diameter / 2 + sin(angle) * hueRadius
        )
    }

    static func hue(at location: CGPoint) -> Double {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let angle = atan2(location.y - center.y, location.x - center.x) + .pi / 2
        let hue = angle / (2 * .pi)
        return hue < 0 ? hue + 1 : hue
    }

    static func intensityHandleCenterY(for intensity: Double) -> CGFloat {
        let travel = intensityTrackHeight - intensityHandleHeight
        return intensityHandleHeight / 2 + (1 - min(max(intensity, 0), 1)) * travel
    }

    static func intensity(atY locationY: CGFloat) -> Double {
        let travel = intensityTrackHeight - intensityHandleHeight
        return 1 - min(max((locationY - intensityHandleHeight / 2) / travel, 0), 1)
    }

    static func brightnessAngle(for brightness: Double) -> Double {
        brightnessStartAngle + brightnessSweep * min(max(brightness, 0), 1)
    }

    static func brightnessHandleCenter(for brightness: Double) -> CGPoint {
        let angle = brightnessAngle(for: brightness) * .pi / 180
        return CGPoint(
            x: sideControlDiameter / 2 + cos(angle) * brightnessRadius,
            y: sideControlDiameter / 2 + sin(angle) * brightnessRadius
        )
    }

    static func brightnessTickAngle(at index: Int) -> Double {
        let progress = Double(index) / Double(brightnessTickCount - 1)
        return brightnessStartAngle + brightnessSweep * progress + 90
    }

    static func hapticStep(for value: Double, divisions: Int) -> Int {
        Int((min(max(value, 0), 1) * Double(divisions)).rounded())
    }

    static func brightness(
        at location: CGPoint,
        preservingEndpointFor currentBrightness: Double? = nil
    ) -> Double {
        let center = CGPoint(x: sideControlDiameter / 2, y: sideControlDiameter / 2)
        var degrees = atan2(location.y - center.y, location.x - center.x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        var relative = degrees - brightnessStartAngle
        if relative < 0 { relative += 360 }
        if relative > brightnessSweep {
            if let currentBrightness {
                if currentBrightness >= 0.5 {
                    return 360 - relative <= brightnessEndpointActivationAngle ? 0 : 1
                }
                return relative - brightnessSweep <= brightnessEndpointActivationAngle ? 1 : 0
            }
            relative = relative - brightnessSweep < (360 - brightnessSweep) / 2
                ? brightnessSweep
                : 0
        }
        return relative / brightnessSweep
    }
}

private extension Animation {
    static let themeControlResponse = Animation.easeInOut(
        duration: SakuraCordThemeStore.randomizationDurationSeconds
    )
    static let themeRandomizationTransition = Animation.timingCurve(
        1.0 / 3.0,
        1,
        2.0 / 3.0,
        1,
        duration: SakuraCordThemeStore.randomizationDurationSeconds
    )
}
