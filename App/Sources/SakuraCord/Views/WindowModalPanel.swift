import SwiftUI

extension EnvironmentValues {
    @Entry var windowModalContext: WindowModalContext?
    @Entry var windowModalAvailableSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    @Entry var profileAnimationsPaused = false
}

extension View {
    func windowModal<Item: Identifiable, Modal: View>(
        item: Binding<Item?>,
        title: LocalizedStringResource? = nil,
        cornerRadius: CGFloat = 16,
        cornerStyle: RoundedCornerStyle = .continuous,
        isConcealed: @escaping () -> Bool = { false },
        @ViewBuilder content: @escaping (Item) -> Modal
    ) -> some View {
        modifier(WindowModalPanelModifier(item: item, title: title, cornerRadius: cornerRadius, cornerStyle: cornerStyle, isConcealed: isConcealed, modal: content))
    }

    func windowModal<Modal: View>(
        isPresented: Binding<Bool>,
        title: LocalizedStringResource? = nil,
        cornerRadius: CGFloat = 16,
        cornerStyle: RoundedCornerStyle = .continuous,
        isConcealed: @escaping () -> Bool = { false },
        @ViewBuilder content: @escaping () -> Modal
    ) -> some View {
        windowModal(item: Binding(
            get: { isPresented.wrappedValue ? WindowModalBooleanPresentation() : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        ), title: title, cornerRadius: cornerRadius, cornerStyle: cornerStyle, isConcealed: isConcealed) { _ in content() }
    }

    func windowModalSize(width: CGFloat, height: CGFloat? = nil) -> some View {
        modifier(WindowModalSize(width: width, height: height))
    }

    func windowModalDismissDisabled(_ disabled: Bool) -> some View {
        modifier(WindowModalDismissGuard(disabled: disabled))
    }
}

private struct WindowModalBooleanPresentation: Identifiable { let id = "presented" }

private struct WindowModalPanelModifier<Item: Identifiable, Modal: View>: ViewModifier {
    @Binding var item: Item?
    let title: LocalizedStringResource?
    let cornerRadius: CGFloat
    let cornerStyle: RoundedCornerStyle
    let isConcealed: () -> Bool
    @ViewBuilder let modal: (Item) -> Modal
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.background {
            WindowModalOverlay(presentation: item, dismiss: { item = nil }, content: { item, animationState in
                WindowModalPanelSurface(animationState: animationState, title: title, cornerRadius: cornerRadius, cornerStyle: cornerStyle, isConcealed: isConcealed) { modal(item) }
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.locale, locale)
            })
        }
    }
}

private struct WindowModalPanelSurface<Content: View>: View {
    let animationState: WindowModalContext
    let title: LocalizedStringResource?
    let cornerRadius: CGFloat
    let cornerStyle: RoundedCornerStyle
    let isConcealed: () -> Bool
    @ViewBuilder let content: () -> Content
    private var context: WindowModalContext { animationState }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WindowModalBackdrop(dismiss: { context() })
                GlassEffectContainer(spacing: 0) {
                    VStack(spacing: 0) {
                        if let title {
                            HStack {
                                Text(title).font(.headline)
                                Spacer()
                                HoverCloseButton(help: "Close", accessibilityIdentifier: "window-modal-close") { context() }
                            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                        }
                        content()
                    }
                    .fixedSize()
                    .background(Color(nsColor: .windowBackgroundColor), in: ConcentricRectangle(cornerRadius: cornerRadius, style: cornerStyle))
                    .clipShape(ConcentricRectangle(cornerRadius: cornerRadius, style: cornerStyle))
                    .containerShape(.rect(cornerRadius: cornerRadius, style: cornerStyle))
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .overlay { ConcentricRectangle(cornerRadius: cornerRadius, style: cornerStyle).stroke(.separator, lineWidth: 1) }
                    .backgroundPreferenceValue(ProfileFrameAnchorKey.self) { anchor in
                        ProfileFrameDecoration(anchor: anchor, order: "back")
                    }
                    .overlayPreferenceValue(ProfileFrameAnchorKey.self) { anchor in
                        ProfileFrameDecoration(anchor: anchor, order: "front")
                    }
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
                    .scaleEffect(animationState.isVisible ? 1 : 0.965)
                    .padding(24)
                    .environment(\.windowModalContext, context)
                    .environment(\.windowModalAvailableSize, CGSize(width: max(0, geometry.size.width - 48), height: max(0, geometry.size.height - 48 - (title == nil ? 0 : 56))))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusable().focusEffectDisabled().accessibilityAddTraits(.isModal)
        .animation(.easeOut(duration: WindowModalAnimationTiming.openingSeconds), value: animationState.isVisible)
        .onExitCommand { context() }
        .opacity(isConcealed() ? 0 : 1)
    }
}

private struct WindowModalSize: ViewModifier {
    let width: CGFloat
    let height: CGFloat?
    @Environment(\.windowModalAvailableSize) private var available
    func body(content: Content) -> some View {
        content.frame(width: min(width, available.width), height: height.map { min($0, available.height) })
    }
}

private struct WindowModalDismissGuard: ViewModifier {
    let disabled: Bool
    @Environment(\.windowModalContext) private var context
    func body(content: Content) -> some View {
        content.onChange(of: disabled, initial: true) { _, disabled in context?.preventsDismissal = disabled }
    }
}

/// A full-window scrim. Omit dismissal for presentations that require an explicit action.
struct WindowModalBackdrop: View {
    var opacity = WindowModalVisualStyle.standardBackdropOpacity
    var dismiss: (() -> Void)?

    var body: some View {
        Color.black.opacity(opacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismiss?() }
            .accessibilityHidden(true)
    }
}
