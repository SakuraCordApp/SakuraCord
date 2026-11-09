import SakuraCordModels
import SwiftUI

enum ProfileGameMetrics {
    static var inset: CGFloat { InterfaceScale.metric(28) }
    static var sectionSpacing: CGFloat { InterfaceScale.metric(32) }
    static var columnSpacing: CGFloat { InterfaceScale.metric(28) }
    static var sidebarWidth: CGFloat { InterfaceScale.metric(320) }
    static var heroHeight: CGFloat { InterfaceScale.metric(240) }
    static var coverOverlap: CGFloat { InterfaceScale.metric(84) }
    static var cardRadius: CGFloat { InterfaceScale.metric(14) }
    static var thumbnailRadius: CGFloat { InterfaceScale.metric(8) }
    static var groupInset: CGFloat { InterfaceScale.metric(4) }
    static var controlHeight: CGFloat { InterfaceScale.metric(32) }
}

/// The page's artwork, fading into the modal surface behind the header.
struct ProfileGameHero: View {
    let game: ProfileGame

    var body: some View {
        Color.clear
            .frame(height: ProfileGameMetrics.heroHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                if let banner = game.metadata?.artwork.first ?? game.metadata?.screenshots.first {
                    ProfileWidgetImageView(url: banner, contentMode: .fill)
                } else if let cover = game.coverURL {
                    // Covers are portrait, so blur one into a wash rather than crop it.
                    ProfileWidgetImageView(url: cover, animates: false, contentMode: .fill).blur(radius: 40).opacity(0.7)
                }
            }
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.85), location: 0.45), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .accessibilityHidden(true)
    }
}

/// A floating control that stays legible over the hero artwork.
struct ProfileGameHeroButton: View {
    let systemImage: String
    let help: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.interfaceSystem(size: 13, weight: .semibold))
                .frame(width: ProfileGameMetrics.controlHeight, height: ProfileGameMetrics.controlHeight)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension View {
    /// Styles a control as a SakuraCord pill, or a circle when `isIcon`. The
    /// size sits on the label so the whole pill is clickable, and the fill sits
    /// on the control because macOS menus drop backgrounds from their labels.
    func profileGameAction(_ style: ProfileGameActionStyle) -> some View {
        modifier(ProfileGameActionFill(style: style))
    }

    func profileGameActionLabel(isIcon: Bool = false) -> some View {
        font(.interfaceSystem(size: 13, weight: .semibold))
            .padding(.horizontal, isIcon ? 0 : InterfaceScale.metric(14))
            .frame(minWidth: ProfileGameMetrics.controlHeight)
            .frame(height: ProfileGameMetrics.controlHeight)
            .contentShape(.capsule)
    }
}

enum ProfileGameActionStyle { case prominent, secondary }

private struct ProfileGameActionFill: ViewModifier {
    let style: ProfileGameActionStyle
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(style == .prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background { Capsule().fill(fill) }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .pointerStyle(isEnabled ? .link : nil)
            .onModalHover { isHovered = $0 }
    }

    private var fill: AnyShapeStyle {
        let hovered = isHovered && isEnabled
        switch style {
        case .prominent: return AnyShapeStyle(SakuraCordAccentColor.color.opacity(hovered ? 0.85 : 1))
        case .secondary: return AnyShapeStyle(.primary.opacity(hovered ? 0.14 : 0.08))
        }
    }
}

struct ProfileGameTextButton: View {
    let title: LocalizedStringResource
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(3)) {
                Text(title)
                Image(systemName: "chevron.right").font(.interfaceSystem(size: 10, weight: .bold))
            }
            .font(.interfaceSystem(size: 13, weight: .medium))
            .foregroundStyle(isHovered ? .primary : .secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onModalHover { isHovered = $0 }
    }
}

struct ProfileGameSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    init(_ title: LocalizedStringResource, @ViewBuilder content: @escaping () -> Content, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(12)) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.interfaceSystem(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: InterfaceScale.metric(8))
                accessory()
            }
            content()
        }
    }
}

/// A horizontal row that scrolls under the page's side insets instead of
/// clipping its items at the content edge.
struct ProfileGameCarousel<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: spacing) { content() }
                .padding(.vertical, InterfaceScale.metric(8))
        }
        .scrollIndicators(.never)
        .contentMargins(.horizontal, ProfileGameMetrics.inset, for: .scrollContent)
        .padding(.horizontal, -ProfileGameMetrics.inset)
        .padding(.vertical, -InterfaceScale.metric(8))
    }
}

struct ProfileGameNotice<Accessory: View>: View {
    let message: String
    let isError: Bool
    @ViewBuilder var accessory: () -> Accessory

    init(message: String, isError: Bool, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.message = message
        self.isError = isError
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(isError ? .red : .orange)
            Text(message).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: InterfaceScale.metric(8))
            accessory()
        }
        .font(.interfaceSystem(size: 13))
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(8))
        .frame(minHeight: InterfaceScale.metric(48))
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: ProfileGameMetrics.cardRadius))
    }
}

struct ProfileGameSimilarTile: View {
    let game: ProfileGame

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            ProfileWidgetGameCover(game: game, animates: true)
                .frame(width: InterfaceScale.metric(120), height: InterfaceScale.metric(160))
                .modifier(ProfileWidgetHover(tilts: true))
            Text(game.name)
                .font(.interfaceSystem(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .frame(width: InterfaceScale.metric(120), alignment: .leading)
    }
}
