import SwiftUI

/// A profile-independent RGB picker. Use `1...1` for a single color, `2...2`
/// for a fixed gradient, or a wider range to expose the designer's count controls.
/// Saturation and value are shared; existing colors stay untouched until edited.
struct SakuraCordColorPicker: View {
    @Binding private var colors: [UInt32]
    private let colorCount: ClosedRange<Int>
    @State private var palette: ColorPickerPalette
    @State private var lastPublished: [UInt32]?
    @State private var hexIndex: Int?
    @State private var isEnteringHexCode = false
    @State private var hexCode = ""
    @State private var transitionTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(colors: Binding<[UInt32]>, colorCount: ClosedRange<Int> = 1 ... 1) {
        precondition(colorCount.lowerBound >= 1)
        _colors = colors
        self.colorCount = colorCount
        _palette = State(initialValue: ColorPickerPalette(colors: colors.wrappedValue, count: colorCount))
    }

    init(color: Binding<UInt32>) {
        self.init(colors: Binding(get: { [color.wrappedValue] }, set: { if let first = $0.first { color.wrappedValue = first } }))
    }

    var body: some View {
        GlassEffectContainer(spacing: InterfaceScale.metric(20)) {
            VStack(spacing: InterfaceScale.metric(16)) {
                ZStack {
                    ColorPickerHueRing(
                        palette: palette,
                        setter: { hue, index in edit { $0.setHue(hue, at: index) } },
                        input: beginHexEntry, remove: removeColor,
                        canRemove: palette.stops.count > colorCount.lowerBound
                    )
                    // Match the designer: the central sliders own their hit regions.
                    HStack(spacing: InterfaceScale.metric(16)) {
                        componentSlider(value: palette.saturation, systemImage: "drop.halffull", label: "Saturation",
                                        colors: [.init(hue: palette.stops[0].hue, saturation: 1, brightness: palette.value), .init(white: palette.value)]) {
                            let saturation = $0
                            edit { $0.setSaturation(saturation) }
                        }
                        componentSlider(value: palette.value, systemImage: "sun.max.fill", label: "Value",
                                        colors: [.init(hue: palette.stops[0].hue, saturation: palette.saturation, brightness: 1), .black]) {
                            let value = $0
                            edit { $0.setValue(value) }
                        }
                    }
                }
                if colorCount.lowerBound != colorCount.upperBound {
                    HStack(spacing: InterfaceScale.metric(8)) {
                        ColorPickerCountButton(systemImage: "minus", label: "Remove color", isDisabled: palette.stops.count == colorCount.lowerBound) {
                            removeColor(palette.stops.count - 1)
                        }
                        ColorPickerCountButton(systemImage: "plus", label: "Add color", isDisabled: palette.stops.count == colorCount.upperBound) {
                            withAnimation(reduceMotion ? nil : .themeControlResponse) { edit { $0.add() } }
                        }
                        .overlay {
                            ColorPickerContextMenuBridge(canInputColor: palette.stops.count < colorCount.upperBound, canRemoveColor: false,
                                                         input: { beginHexEntry(nil) }, remove: nil)
                        }
                        .accessibilityActions {
                            Button("Input Hex Code…", systemImage: "number") { beginHexEntry(nil) }
                                .disabled(palette.stops.count == colorCount.upperBound)
                        }
                    }
                }
            }
            .padding(InterfaceScale.metric(24))
        }
        .fixedSize()
        .onChange(of: colors) { _, newColors in
            guard newColors != lastPublished else { return }
            transitionTask?.cancel()
            palette = ColorPickerPalette(colors: newColors, count: colorCount)
        }
        .onChange(of: colorCount) {
            transitionTask?.cancel()
            isEnteringHexCode = false
            palette = ColorPickerPalette(colors: colors, count: colorCount)
        }
        .onDisappear { transitionTask?.cancel() }
        .alert("Input Hex Code", isPresented: $isEnteringHexCode) {
            TextField("#RRGGBB", text: $hexCode)
            Button("Cancel", role: .cancel) { hexCode = "" }
            Button("Apply", action: applyHexColor).disabled(ColorPickerPalette.parseHex(hexCode) == nil)
        }
    }

    private func componentSlider(value: Double, systemImage: String, label: LocalizedStringKey, colors: [Color], setter: @escaping (Double) -> Void) -> some View {
        VStack(spacing: InterfaceScale.metric(8)) {
            Image(systemName: systemImage)
                .font(.interface(.body).weight(.medium))
                .foregroundStyle(.primary.opacity(0.78))
                .accessibilityHidden(true)
            SakuraCordColorSlider(value: value, colors: colors, label: label, setter: setter)
        }
    }

    private func edit(_ mutation: (inout ColorPickerPalette) -> Void) {
        transitionTask?.cancel()
        mutation(&palette)
        publish()
    }

    private func publish() {
        let output = palette.colors
        lastPublished = output
        if colors != output { colors = output }
    }

    private func beginHexEntry(_ index: Int?) {
        guard index != nil || palette.stops.count < colorCount.upperBound else { return }
        transitionTask?.cancel()
        hexIndex = index
        hexCode = ""
        isEnteringHexCode = true
    }

    private func removeColor(_ index: Int) {
        guard palette.stops.count > colorCount.lowerBound, palette.stops.indices.contains(index) else { return }
        // Preserve the designer's atomic renumbering of surviving handles.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { edit { $0.remove(at: index) } }
    }

    private func applyHexColor() {
        guard let color = ColorPickerPalette.parseHex(hexCode) else { return }
        var target = palette
        if let hexIndex {
            guard target.stops.indices.contains(hexIndex) else { return }
            target.apply(color, at: hexIndex)
        } else {
            guard target.stops.count < colorCount.upperBound else { return }
            target.add()
            target.apply(color, at: target.stops.count - 1)
        }
        transitionTask?.cancel()
        guard !reduceMotion, target.stops.count == palette.stops.count else {
            withAnimation(reduceMotion ? nil : .themeControlResponse) { palette = target; publish() }
            return
        }
        let source = palette
        // Commit the requested RGB once. Publishing every animation frame can
        // feed a delayed binding echo back through the AppKit popover host.
        // The preview animates to the target while handles follow the hue ring.
        withAnimation(.themeRandomizationTransition) {
            lastPublished = target.colors
            colors = target.colors
        }
        transitionTask = Task {
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                let elapsed = start.duration(to: clock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let progress = min(seconds / SakuraCordThemeStore.randomizationDurationSeconds, 1)
                palette = source.interpolated(to: target, progress: Double(MotionEasing.easeOut(CGFloat(progress))))
                if progress >= 1 { break }
                try? await clock.sleep(for: .milliseconds(8))
            }
        }
    }
}

private struct ColorPickerCountButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.interface(.body).weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(width: ThemePickerGeometry.colorCountButtonDiameter, height: ThemePickerGeometry.colorCountButtonDiameter)
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
