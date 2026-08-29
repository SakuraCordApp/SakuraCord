import SwiftUI

struct GradientThemeEditor: View {
    let themeStore: SakuraCordThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GradientThemePresetGrid(themeStore: themeStore)
            Divider()
            GradientThemeEditorHeader(themeStore: themeStore)
            GradientThemeControls(themeStore: themeStore)
        }
        .padding(.vertical, 6)
    }
}

private struct GradientThemePresetGrid: View {
    let themeStore: SakuraCordThemeStore
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 86), spacing: 10),
        count: 5
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(SakuraCordThemePreset.allCases) { preset in
                GradientThemePresetCard(preset: preset, themeStore: themeStore)
            }
        }
    }
}

private struct GradientThemePresetCard: View {
    let preset: SakuraCordThemePreset
    let themeStore: SakuraCordThemeStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let isSelected = themeStore.selectedPreset == preset
        let theme = preset == .custom
            ? themeStore.customTheme
            : (preset.presetTheme ?? .defaultCustom)

        Button {
            themeStore.select(preset)
        } label: {
            ZStack(alignment: .bottomLeading) {
                GradientThemePreview(
                    theme: theme,
                    usesSystemAppearance: preset.usesSystemAppearance,
                    colorScheme: colorScheme,
                    increasesContrast: colorSchemeContrast == .increased
                )

                if let systemImage = preset.systemImage {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.72))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, 13)
                }

                Text(preset.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(10)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: 25, height: 25)
                        .glassEffect(
                            .regular.tint(SakuraCordAccentColor.color.opacity(0.34)),
                            in: Circle()
                        )
                        .padding(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .aspectRatio(1.22, contentMode: .fit)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(
                        isSelected ? Color.primary.opacity(0.82) : Color.primary.opacity(0.14),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .shadow(
                color: isSelected ? SakuraCordAccentColor.color.opacity(0.42) : .clear,
                radius: 12
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct GradientThemePreview: View {
    let theme: SakuraCordGradientTheme
    let usesSystemAppearance: Bool
    let colorScheme: ColorScheme
    let increasesContrast: Bool

    var body: some View {
        if usesSystemAppearance {
            Color(nsColor: .windowBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        } else {
            GradientThemePreviewBackground(
                theme: theme,
                colorScheme: colorScheme,
                increasesContrast: increasesContrast
            )
        }
    }
}

private struct GradientThemePreviewBackground: View {
    let theme: SakuraCordGradientTheme
    let colorScheme: ColorScheme
    let increasesContrast: Bool

    var body: some View {
        let colors = theme.colors(for: colorScheme)
        let opacity = theme.tintOpacity * (increasesContrast ? 0.78 : 1)

        ZStack {
            theme.surfaceBaseColor(for: colorScheme)
            LinearGradient(
                colors: [
                    colors.first.opacity(opacity + 0.22),
                    colors.second.opacity(opacity + 0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct GradientThemeEditorHeader: View {
    let themeStore: SakuraCordThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = themeStore.activeTheme.colors(for: colorScheme)
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Color Splat", bundle: #bundle)
                    .font(.title3.weight(.semibold))
                Text("Shape a blend that feels like yours.", bundle: #bundle)
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
        HStack(alignment: .center, spacing: 20) {
            CircularBrightnessControl(themeStore: themeStore)
                .frame(
                    width: ThemePickerGeometry.sideControlDiameter,
                    height: ThemePickerGeometry.sideControlDiameter
                )
            Spacer(minLength: 0)
            DualHuePicker(themeStore: themeStore)
                .frame(width: 270, height: 270)
            Spacer(minLength: 0)
            ThemeRandomizeButton(themeStore: themeStore)
                .frame(
                    width: ThemePickerGeometry.sideControlDiameter,
                    height: ThemePickerGeometry.sideControlDiameter
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

private struct DualHuePicker: View {
    let themeStore: SakuraCordThemeStore

    var body: some View {
        let theme = themeStore.activeTheme
        let wheelBrightness = ThemePickerGeometry.wheelDisplayBrightness(
            for: theme.brightness
        )
        let wheelColors = stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map {
            Color(hue: $0, saturation: 1, brightness: wheelBrightness)
        }
        GlassEffectContainer(spacing: 20) {
            ZStack {
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: wheelColors,
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        lineWidth: ThemePickerGeometry.ringWidth
                    )
                    .shadow(color: .primary.opacity(0.10), radius: 8)

                hueHandle(
                    hue: theme.first.hue,
                    setter: themeStore.setFirstHue
                )
                hueHandle(
                    hue: theme.second.hue,
                    setter: themeStore.setSecondHue
                )

                // Keep the intensity control above every hue-handle hit target.
                // Its central interaction region must never lose a drag to the ring.
                ThemeIntensityControl(themeStore: themeStore)
                    .frame(
                        width: ThemePickerGeometry.intensityHitWidth,
                        height: ThemePickerGeometry.intensityTrackHeight
                    )
            }
        }
        .frame(width: ThemePickerGeometry.diameter, height: ThemePickerGeometry.diameter)
        .coordinateSpace(.named("dual-hue-picker"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gradient color picker")
    }

    private func hueHandle(
        hue: Double,
        setter: @escaping (Double) -> Void
    ) -> some View {
        ZStack {
            Circle()
                .fill(.clear)
                .frame(
                    width: ThemePickerGeometry.hueHandleSize,
                    height: ThemePickerGeometry.hueHandleSize
                )
                .glassEffect(.regular.interactive(), in: Circle())
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
                        setter(ThemePickerGeometry.hue(at: value.location))
                    }
                    .onEnded { _ in themeStore.finishInteraction() }
            )
            .accessibilityLabel("Gradient color")
            .accessibilityValue("Hue \(Int((hue * 360).rounded())) degrees")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1.0 / 72 : -1.0 / 72
                setter(hue + step)
                themeStore.finishInteraction()
            }
    }
}

private struct ThemeIntensityControl: View {
    let themeStore: SakuraCordThemeStore

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = themeStore.activeTheme
        let colors = theme.colors(for: colorScheme)
        let handleY = ThemePickerGeometry.intensityHandleCenterY(for: theme.intensity)

        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [colors.first, colors.second, colors.first],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 35, height: ThemePickerGeometry.intensityTrackHeight)
                .overlay {
                    Capsule().stroke(.primary.opacity(0.18), lineWidth: 1)
                }

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
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    themeStore.setIntensity(
                        ThemePickerGeometry.intensity(atY: value.location.y)
                    )
                }
                .onEnded { _ in themeStore.finishInteraction() }
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
}

private struct CircularBrightnessControl: View {
    let themeStore: SakuraCordThemeStore

    var body: some View {
        let brightness = themeStore.activeTheme.brightness
        let indicatorAngle = ThemePickerGeometry.brightnessAngle(for: brightness)
        let indicatorCenter = ThemePickerGeometry.brightnessHandleCenter(for: brightness)

        ZStack {
            Circle()
                .fill(.primary.opacity(0.045))
                .overlay {
                    Circle().stroke(.primary.opacity(0.14), lineWidth: 1)
                }

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
                .fill(.primary.opacity(0.86))
                .frame(
                    width: ThemePickerGeometry.brightnessIndicatorWidth,
                    height: ThemePickerGeometry.brightnessIndicatorHeight
                )
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .rotationEffect(.degrees(indicatorAngle))
                .position(indicatorCenter)
        }
        .frame(
            width: ThemePickerGeometry.sideControlDiameter,
            height: ThemePickerGeometry.sideControlDiameter
        )
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    themeStore.setBrightness(
                        ThemePickerGeometry.brightness(at: value.location)
                    )
                }
                .onEnded { _ in themeStore.finishInteraction() }
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
                withAnimation(.easeInOut(duration: 0.22)) {
                    rotation += 360
                }
            }
            randomizationTask = Task {
                await themeStore.randomize(reduceMotion: reduceMotion)
            }
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.primary)
                .rotationEffect(.degrees(rotation))
                .frame(
                    width: ThemePickerGeometry.sideControlDiameter,
                    height: ThemePickerGeometry.sideControlDiameter
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .frame(
            width: ThemePickerGeometry.sideControlDiameter,
            height: ThemePickerGeometry.sideControlDiameter
        )
        .contentShape(Circle())
        .accessibilityLabel("Randomise theme")
        .onDisappear {
            randomizationTask?.cancel()
        }
    }
}

enum ThemePickerGeometry {
    static let diameter: CGFloat = 270
    static let ringWidth: CGFloat = 25
    static let hueHandleSize: CGFloat = 40
    static let hueHandleHitSize: CGFloat = 52
    static let intensityTrackHeight: CGFloat = 132
    static let intensityHitWidth: CGFloat = 76
    static let intensityHandleWidth: CGFloat = 66
    static let intensityHandleHeight: CGFloat = 28
    static let sideControlDiameter: CGFloat = 112
    static let brightnessIndicatorWidth: CGFloat = 27
    static let brightnessIndicatorHeight: CGFloat = 12
    static let brightnessTickCount = 19
    static let brightnessTickRadius: CGFloat = 38

    private static let hueRadius = (diameter - ringWidth) / 2
    private static let brightnessRadius: CGFloat = 35
    private static let brightnessStartAngle = 135.0
    private static let brightnessSweep = 270.0

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

    static func wheelDisplayBrightness(for brightness: Double) -> Double {
        pow(min(max(brightness, 0), 1), 0.42)
    }

    static func brightness(at location: CGPoint) -> Double {
        let center = CGPoint(x: sideControlDiameter / 2, y: sideControlDiameter / 2)
        var degrees = atan2(location.y - center.y, location.x - center.x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        var relative = degrees - brightnessStartAngle
        if relative < 0 { relative += 360 }
        if relative > brightnessSweep {
            relative = relative - brightnessSweep < (360 - brightnessSweep) / 2
                ? brightnessSweep
                : 0
        }
        return relative / brightnessSweep
    }
}
