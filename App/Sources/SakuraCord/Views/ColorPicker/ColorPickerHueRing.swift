import SwiftUI

struct ColorPickerHueRing: View {
    let palette: ColorPickerPalette
    let setter: (Double, Int) -> Void
    let input: (Int) -> Void
    let remove: (Int) -> Void
    let canRemove: Bool

    var body: some View {
        let wheelColors = stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map {
            Color(hue: $0, saturation: 1, brightness: 1)
        }
        let wheelGradient = AngularGradient(
            colors: wheelColors, center: .center,
            startAngle: .degrees(-90), endAngle: .degrees(270)
        )
        ZStack {
            Capsule()
                .stroke(wheelGradient, lineWidth: ThemePickerGeometry.ringGlowLineWidth)
                .blur(radius: ThemePickerGeometry.ringGlowRadius)
                .opacity(ThemePickerGeometry.ringGlowOpacity)
            Capsule()
                .inset(by: ThemePickerGeometry.ringWidth)
                .stroke(wheelGradient, lineWidth: ThemePickerGeometry.ringGlowLineWidth)
                .blur(radius: ThemePickerGeometry.ringGlowRadius)
                .opacity(ThemePickerGeometry.ringGlowOpacity)
            Capsule()
                .strokeBorder(wheelGradient, lineWidth: ThemePickerGeometry.ringWidth)
            ForEach(palette.stops.indices, id: \.self) { index in
                ColorPickerHueHandle(
                    hue: palette.stops[index].hue, index: index, showsNumber: palette.stops.count > 1,
                    setter: { setter($0, index) },
                    input: { input(index) }, remove: { remove(index) }, canRemove: canRemove
                )
            }
        }
        .frame(width: ColorPickerGeometry.width, height: ColorPickerGeometry.height)
        .coordinateSpace(.named("sakuracord-color-picker"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color picker")
    }
}

private struct ColorPickerHueHandle: View {
    let hue: Double
    let index: Int
    let showsNumber: Bool
    let setter: (Double) -> Void
    let input: () -> Void
    let remove: () -> Void
    let canRemove: Bool
    @State private var lastHapticStep: Int?

    var body: some View {
        ZStack {
            if showsNumber {
                Text(index + 1, format: .number)
                    .font(.interface(.body).weight(.bold).monospacedDigit())
            }
        }
            .foregroundStyle(.white)
            .frame(width: ThemePickerGeometry.hueHandleSize, height: ThemePickerGeometry.hueHandleSize)
            .contentShape(Circle())
            .glassEffect(.clear.interactive(), in: Circle())
            .frame(width: ThemePickerGeometry.hueHandleHitSize, height: ThemePickerGeometry.hueHandleHitSize)
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
            .overlay {
                ColorPickerContextMenuBridge(canInputColor: true, canRemoveColor: canRemove, input: input, remove: remove)
            }
            .position(ColorPickerGeometry.hueHandleCenter(for: hue))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("sakuracord-color-picker"))
                    .onChanged { value in
                        let hue = ColorPickerGeometry.hue(at: value.location)
                        updateHaptics(for: hue)
                        setter(hue)
                    }
                    .onEnded { _ in lastHapticStep = nil }
            )
            .accessibilityLabel("Color \(index + 1)")
            .accessibilityValue("Hue \(Int((hue * 360).rounded())) degrees")
            .accessibilityAdjustableAction { direction in
                setter(hue + (direction == .increment ? 1.0 / 72 : -1.0 / 72))
            }
            .accessibilityActions {
                Button("Input Hex Code…", systemImage: "number", action: input)
                if canRemove {
                    Button("Remove Color", systemImage: "trash", role: .destructive, action: remove)
                }
            }
    }

    private func updateHaptics(for value: Double) {
        let step = ThemePickerGeometry.hapticStep(for: value, divisions: ThemePickerGeometry.hueHapticDivisions)
        guard step != lastHapticStep else { return }
        defer { lastHapticStep = step }
        guard lastHapticStep != nil else { return }
        StepHaptics.performStep()
    }
}

nonisolated enum ColorPickerGeometry {
    static var width: CGFloat { InterfaceScale.metric(330) }
    static var height: CGFloat { InterfaceScale.metric(226) }

    // Intersect the hue's angular-gradient ray with a capsule's centerline.
    // The straight edges remain straight and both ends are true semicircles.
    static func hueHandleCenter(for hue: Double) -> CGPoint {
        let angle = hue * 2 * Double.pi - Double.pi / 2
        let dx = cos(angle)
        let dy = sin(angle)
        let radius = (height - ThemePickerGeometry.ringWidth) / 2
        let halfStraight = (width - height) / 2
        let straightDistance = abs(dy) > 0.000001 ? radius / abs(dy) : .infinity
        let distance: Double
        if abs(dx * straightDistance) <= halfStraight {
            distance = straightDistance
        } else {
            distance = abs(dx) * halfStraight + sqrt(radius * radius - halfStraight * halfStraight * dy * dy)
        }
        return CGPoint(x: width / 2 + dx * distance, y: height / 2 + dy * distance)
    }

    static func hue(at location: CGPoint) -> Double {
        let angle = atan2(location.y - height / 2, location.x - width / 2) + .pi / 2
        let hue = angle / (2 * .pi)
        return hue < 0 ? hue + 1 : hue
    }
}
