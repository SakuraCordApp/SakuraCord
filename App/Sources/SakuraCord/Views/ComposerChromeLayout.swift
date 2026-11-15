import SwiftUI

struct ComposerChromeLayout<Header: View, Leading: View, Input: View, Accessories: View, Send: View, Overlay: View>: View {
    let appearance: ComposerBarAppearance
    let focus: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let leading: Leading
    @ViewBuilder let input: Input
    @ViewBuilder let accessories: Accessories
    @ViewBuilder let send: Send
    @ViewBuilder let overlay: Overlay

    var body: some View {
        GlassEffectContainer(spacing: ChatChromeMetrics.composerSegmentSpacing) {
            switch appearance {
            case .defaultStyle:
                defaultLayout
            case .legacy:
                legacyLayout
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var defaultLayout: some View {
        HStack(alignment: .bottom, spacing: ChatChromeMetrics.composerSegmentSpacing) {
            // Centred on the bar's first line, which grows with the font size.
            leading
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(height: ChatChromeMetrics.composerControlHeight)

            VStack(alignment: .leading, spacing: 0) {
                header
                HStack(alignment: .bottom, spacing: InterfaceScale.metric(9)) {
                    input
                    accessories
                }
                .padding(.leading, ChatChromeMetrics.composerTextLeadingInset)
                .padding(.trailing, ChatChromeMetrics.composerAccessoryEdgeInset)
                .frame(minHeight: ChatChromeMetrics.composerControlHeight)
            }
            .frame(maxWidth: .infinity)
            .background { ComposerFocusSurface(focus: focus) }
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: ChatChromeMetrics.composerCornerRadius, style: .continuous)
            )
            .composerOverlay(overlay)

            send
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(height: ChatChromeMetrics.composerControlHeight)
        }
    }

    private var legacyLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .bottom, spacing: InterfaceScale.metric(9)) {
                leading
                input
                HStack(spacing: 1) {
                    accessories
                    Capsule()
                        .fill(.primary.opacity(0.16))
                        .frame(width: 1, height: InterfaceScale.metric(16))
                        .frame(width: InterfaceScale.metric(9), height: ChatChromeMetrics.composerControlHeight)
                        .accessibilityHidden(true)
                    send
                }
            }
            .padding(.horizontal, InterfaceScale.metric(11))
            .padding(.vertical, InterfaceScale.metric(6))
            .frame(minHeight: ChatChromeMetrics.controlHeight)
        }
        .background { ComposerFocusSurface(focus: focus) }
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: ChatChromeMetrics.composerMinimumCornerRadius, style: .continuous)
        )
        .composerOverlay(overlay)
    }
}

private extension View {
    func composerOverlay(_ overlay: some View) -> some View {
        self.overlay(alignment: .top) {
            overlay
                .background { ComposerOverlayPointerRegion() }
                .alignmentGuide(.top) { dimensions in
                    dimensions[.bottom] + 7
                }
                .zIndex(10)
        }
    }
}
