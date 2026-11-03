import AppKit
import SwiftUI

struct GradientThemeEditor: View {
    enum Presentation {
        case settings(appearance: AppColorScheme, windowOpacity: Double)
        case onboarding
    }

    let themeStore: SakuraCordThemeStore
    let presentation: Presentation

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(18)) {
            GradientThemeEditorHeader(
                themeStore: themeStore,
                presentation: presentation
            )
            GradientThemeControls(themeStore: themeStore)
        }
        .padding(.vertical, InterfaceScale.metric(6))
    }
}

private struct GradientThemeEditorHeader: View {
    let themeStore: SakuraCordThemeStore
    let presentation: GradientThemeEditor.Presentation

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
                Text(title, bundle: #bundle)
                    .font(.interface(.title3).weight(.semibold))
                Text(subtitle, bundle: #bundle)
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: InterfaceScale.metric(16))
            HStack(spacing: InterfaceScale.metric(8)) {
                ThemeRandomizeButton(themeStore: themeStore)
                    .settingsControlAnchor(.themeRandomize)
                if case let .settings(appearance, windowOpacity) = presentation {
                    ThemeShareCopyButton(
                        themeStore: themeStore,
                        appearance: appearance,
                        windowOpacity: windowOpacity
                    )
                    .settingsControlAnchor(.themeCopy)
                }
                ThemeColorCountControls(themeStore: themeStore)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch presentation {
        case .settings: "Theme Designer"
        case .onboarding: "Make SakuraCord yours"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch presentation {
        case .settings: "Create your perfect theme."
        case .onboarding: "Pick colors you love. You can change them anytime in Settings."
        }
    }
}

private struct ThemeShareCopyButton: View {
    let themeStore: SakuraCordThemeStore
    let appearance: AppColorScheme
    let windowOpacity: Double

    @State private var isShowingConfirmation = false
    @State private var confirmationTask: Task<Void, Never>?

    var body: some View {
        Button(action: copyTheme) {
            HStack(spacing: InterfaceScale.metric(7)) {
                if isShowingConfirmation {
                    Image(systemName: "checkmark")
                    Text("Copied", bundle: #bundle)
                } else {
                    Image(systemName: "document.on.document")
                    Text("Copy Theme", bundle: #bundle)
                }
            }
            .font(.interface(.callout).weight(.semibold))
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, InterfaceScale.metric(14))
            .frame(height: ThemePickerGeometry.colorCountButtonDiameter)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(Capsule())
        .accessibilityLabel("Copy theme link")
        .onDisappear {
            confirmationTask?.cancel()
        }
    }

    private func copyTheme() {
        let sharedTheme = SakuraCordSharedTheme(
            appearance: appearance,
            theme: themeStore.activeTheme,
            windowOpacity: windowOpacity
        )
        guard let url = try? SakuraCordThemeShareCodec.shareURL(
            for: sharedTheme
        ) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(url.absoluteString, forType: .string) else {
            return
        }

        confirmationTask?.cancel()
        isShowingConfirmation = true
        confirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            isShowingConfirmation = false
        }
    }
}

private struct ThemeColorCountControls: View {
    let themeStore: SakuraCordThemeStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colorCount = themeStore.activeTheme.activeColorCount
        GlassEffectContainer(spacing: InterfaceScale.metric(8)) {
            HStack(spacing: InterfaceScale.metric(8)) {
                ThemeColorCountButton(
                    systemImage: "minus",
                    label: "Remove gradient color",
                    isDisabled: colorCount == SakuraCordGradientTheme.minimumColorCount
                ) {
                    withAnimation(reduceMotion ? nil : .themeControlResponse) {
                        themeStore.removeColor()
                    }
                }
                .settingsControlAnchor(.themeRemoveColor)
                ThemeColorCountButton(
                    systemImage: "plus",
                    label: "Add gradient color",
                    isDisabled: colorCount == SakuraCordGradientTheme.maximumColorCount
                ) {
                    withAnimation(reduceMotion ? nil : .themeControlResponse) {
                        themeStore.addColor()
                    }
                }
                .settingsControlAnchor(.themeAddColor)
                .modifier(ThemeColorMenu(themeStore: themeStore, colorIndex: nil))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gradient colors")
        .accessibilityValue("\(colorCount)")
    }
}

private struct ThemeColorCountButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.interface(.body).weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(
                    width: ThemePickerGeometry.colorCountButtonDiameter,
                    height: ThemePickerGeometry.colorCountButtonDiameter
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(Circle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .accessibilityLabel(label)
    }
}

private struct GradientThemeControls: View {
    let themeStore: SakuraCordThemeStore

    var body: some View {
        GlassEffectContainer(spacing: InterfaceScale.metric(20)) {
            HStack(alignment: .center, spacing: 0) {
                CircularThemeControl(
                    value: themeStore.activeTheme.brightness,
                    systemImage: "sun.max.fill",
                    label: "Theme brightness",
                    setter: themeStore.setBrightness,
                    finishInteraction: themeStore.finishInteraction
                )
                    .frame(maxWidth: .infinity)
                    .settingsControlAnchor(.themeBrightness)
                GradientHuePicker(themeStore: themeStore)
                    .settingsControlAnchor(.themeColors)
                    .frame(
                        width: ThemePickerGeometry.diameter,
                        height: ThemePickerGeometry.diameter
                    )
                CircularThemeControl(
                    value: themeStore.activeTheme.saturation,
                    systemImage: "drop.halffull",
                    label: "Theme saturation",
                    setter: themeStore.setSaturation,
                    finishInteraction: themeStore.finishInteraction
                )
                    .frame(maxWidth: .infinity)
                    .settingsControlAnchor(.themeSaturation)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, InterfaceScale.metric(6))
    }
}

private struct GradientHuePicker: View {
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

            ForEach(theme.activeColors.indices, id: \.self) { index in
                ThemeHueHandle(
                    hue: theme.colors[index].hue,
                    order: theme.activeColorCount == 1 ? nil : index + 1,
                    setter: { themeStore.setHue($0, at: index) },
                    finishInteraction: themeStore.finishInteraction,
                    themeStore: themeStore,
                    colorIndex: index
                )
            }

            // Keep the intensity control above every hue-handle hit target.
            // Its central interaction region must never lose a drag to the ring.
            ThemeIntensityControl(themeStore: themeStore)
                .settingsControlAnchor(.themeIntensity)
                .frame(
                    width: ThemePickerGeometry.intensityHitWidth,
                    height: ThemePickerGeometry.intensityTrackHeight
                )
        }
        .frame(width: ThemePickerGeometry.diameter, height: ThemePickerGeometry.diameter)
        .coordinateSpace(.named("gradient-hue-picker"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gradient color picker")
    }
}

private struct ThemeHueHandle: View {
    let hue: Double
    let order: Int?
    let setter: (Double) -> Void
    let finishInteraction: () -> Void
    let themeStore: SakuraCordThemeStore
    let colorIndex: Int

    @State private var lastHapticStep: Int?

    var body: some View {
        ZStack {
            if let order {
                Text(order, format: .number)
                    .font(.interface(.body).weight(.bold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .frame(
            width: ThemePickerGeometry.hueHandleSize,
            height: ThemePickerGeometry.hueHandleSize
        )
        .contentShape(Circle())
        .glassEffect(.clear.interactive(), in: Circle())
        .frame(
            width: ThemePickerGeometry.hueHandleHitSize,
            height: ThemePickerGeometry.hueHandleHitSize
        )
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .modifier(ThemeColorMenu(themeStore: themeStore, colorIndex: colorIndex))
        // `position`, unlike `offset`, moves layout and hit testing together.
        .position(ThemePickerGeometry.hueHandleCenter(for: hue))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("gradient-hue-picker"))
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
        .accessibilityLabel(order.map { "Gradient color \($0)" } ?? "Gradient color")
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
        let trackColors = colors + Array(colors.prefix(1))
        let handleY = ThemePickerGeometry.intensityHandleCenterY(for: theme.intensity)

        ZStack {
            IntensityTrackShape()
                .fill(
                    LinearGradient(
                        colors: trackColors,
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
                        .shadow(color: .black.opacity(0.22), radius: InterfaceScale.metric(2))
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

private struct CircularThemeControl: View {
    let value: Double
    let systemImage: String
    let label: LocalizedStringKey
    let setter: (Double) -> Void
    let finishInteraction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastHapticStep: Int?

    var body: some View {
        let brightness = value
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

            Image(systemName: systemImage)
                .font(.interface(.title2).weight(.medium))
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
                        preservingEndpointFor: self.value
                    )
                    updateHaptics(for: brightness)
                    setter(brightness)
                }
                .onEnded { _ in
                    lastHapticStep = nil
                    finishInteraction()
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    let brightness = ThemePickerGeometry.brightness(at: value.location)
                    withAnimation(reduceMotion ? nil : .themeRandomizationTransition) {
                        setter(brightness)
                    }
                    finishInteraction()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((brightness * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            setter(brightness + step)
            finishInteraction()
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
                .font(.interface(.body).weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .rotationEffect(.degrees(rotation))
                .frame(
                    width: ThemePickerGeometry.colorCountButtonDiameter,
                    height: ThemePickerGeometry.colorCountButtonDiameter
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(
            width: ThemePickerGeometry.colorCountButtonDiameter,
            height: ThemePickerGeometry.colorCountButtonDiameter
        )
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(Circle())
        .accessibilityLabel("Randomise theme")
        .help("Randomise theme")
        .onDisappear {
            randomizationTask?.cancel()
        }
    }
}

nonisolated enum ThemePickerGeometry {
    static var diameter: CGFloat { InterfaceScale.metric(270) }
    static let colorCountButtonDiameter: CGFloat = 42
    static var ringWidth: CGFloat { InterfaceScale.metric(25) }
    static let ringGlowLineWidth: CGFloat = 3
    static var ringGlowRadius: CGFloat { InterfaceScale.metric(4) }
    static let ringGlowOpacity = 0.32
    static var hueHandleSize: CGFloat { InterfaceScale.metric(40) }
    static var hueHandleHitSize: CGFloat { InterfaceScale.metric(52) }
    static var intensityTrackHeight: CGFloat { InterfaceScale.metric(132) }
    static var intensityTrackTopWidth: CGFloat { InterfaceScale.metric(34) }
    static var intensityTrackBottomWidth: CGFloat { InterfaceScale.metric(18) }
    static let intensityWaveLineWidth: CGFloat = 3.5
    static let intensityWaveMinimumStrength = 0.13
    static let intensityWaveMaximumStrength = 0.84
    static let intensityWaveCount = 3.0
    static let intensityWaveSampleCount = 60
    static var intensityHitWidth: CGFloat { InterfaceScale.metric(76) }
    static var intensityHandleWidth: CGFloat { InterfaceScale.metric(58) }
    static var intensityHandleHeight: CGFloat { InterfaceScale.metric(24) }
    static var sideControlDiameter: CGFloat { InterfaceScale.metric(112) }
    static var brightnessIndicatorWidth: CGFloat { InterfaceScale.metric(27) }
    static var brightnessIndicatorHeight: CGFloat { InterfaceScale.metric(12) }
    static let brightnessTickCount = 19
    static var brightnessTickRadius: CGFloat { InterfaceScale.metric(38) }
    static let sliderDragMinimumDistance: CGFloat = 3
    static let hueHapticDivisions = 36
    static let linearHapticDivisions = 20

    private static var hueRadius: CGFloat { (diameter - ringWidth) / 2 }
    private static var brightnessRadius: CGFloat { brightnessTickRadius }
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

extension Animation {
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
