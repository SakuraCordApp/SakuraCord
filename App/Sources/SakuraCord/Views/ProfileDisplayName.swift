import AppKit
import DiscordProtocol
import SakuraCordModels
import SwiftUI

struct ProfileDisplayName: View {
    let name: String
    let style: DisplayNameStyle?
    var size: CGFloat = 22
    var showsEffects = true
    var background: Color = Color(nsColor: .controlBackgroundColor)
    var plainColor: Color = .primary
    var wraps = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedFont: NSFont?
    @State private var fontError: String?
    @State private var animationStart = Date.now

    private var definition: ProfileNameFont? {
        ProfileNameFontCache.customDefinition(for: style?.fontID)
    }

    private var animatesEffect: Bool {
        guard showsEffects, !reduceMotion, let style,
              let effect = ProfileNameEffect(rawValue: style.effectID) else { return false }
        switch effect {
        case .solid, .gradient: return false
        case .neon, .toon, .pop, .gummy, .prism: return true
        }
    }

    /// The display size at the current interface size.
    private var pointSize: CGFloat { InterfaceScale.fontSize(size) }

    var body: some View {
        let size = pointSize
        return Group {
            if let style {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animatesEffect)) { timeline in
                    ProfileNameNativeText(
                        name: name, font: loadedFont ?? .systemFont(ofSize: size, weight: .bold),
                        tracking: CGFloat(definition?.letterSpacing ?? 0) * size,
                        style: style, showsEffects: showsEffects,
                        background: NSColor(background),
                        plainColor: NSColor(plainColor),
                        elapsed: animatesEffect ? max(0, timeline.date.timeIntervalSince(animationStart)) : 0,
                        wraps: wraps
                    )
                    .padding(-max(4 + size * 0.12, size * 0.2))
                }
            } else {
                Text(name).font(.system(size: size, weight: .bold)).lineLimit(wraps ? nil : 1)
                    .textSelection(.enabled)
            }
        }
        .help(fontError ?? name)
        .task(id: FontRequest(definition: definition, size: size)) {
            loadedFont = nil
            fontError = nil
            guard let definition else { return }
            do {
                loadedFont = try await ProfileNameFontLoader.shared.font(definition, size: size)
            } catch is CancellationError {
                return
            } catch {
                fontError = String(localized: "The display-name font could not be loaded.")
            }
        }
        .onChange(of: style, initial: true) {
            animationStart = .now
        }
        .onChange(of: animatesEffect) {
            animationStart = .now
        }
    }

    private struct FontRequest: Equatable {
        let definition: ProfileNameFont?
        let size: CGFloat
    }
}

private struct ProfileNameNativeText: NSViewRepresentable {
    let name: String
    let font: NSFont
    let tracking: CGFloat
    let style: DisplayNameStyle
    let showsEffects: Bool
    let background: NSColor
    let plainColor: NSColor
    let elapsed: Double
    let wraps: Bool

    func makeNSView(context: Context) -> ProfileNameTextView { ProfileNameTextView() }

    func updateNSView(_ view: ProfileNameTextView, context: Context) {
        view.configure(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProfileNameTextView, context: Context) -> CGSize? {
        nsView.size(for: proposal.width)
    }
}

private final class ProfileNameTextView: NSView {
    private var name = ""
    private var font = NSFont.interfaceSystemFont(ofSize: 22, weight: .bold)
    private var tracking: CGFloat = 0
    private var style = DisplayNameStyle()
    private var showsEffects = true
    private var background = NSColor.controlBackgroundColor
    private var plainColor = NSColor.labelColor
    private var elapsed: Double = 0
    private var wraps = false
    private var naturalLayout: ProfileNameTextLayout?
    private var fittedLayouts: [ProfileNameTextLayout] = []
    private var fittedWidth: CGFloat?

    private var padding: CGFloat { max(4 + font.pointSize * 0.12, font.pointSize * 0.2) }

    override var intrinsicContentSize: NSSize {
        guard let layout = naturalLayout else { return .zero }
        return CGSize(width: ceil(layout.width + padding * 2), height: ceil(layout.ascent + layout.descent + padding * 2))
    }

    func configure(_ configuration: ProfileNameNativeText) {
        let layoutChanged = name != configuration.name || font != configuration.font || tracking != configuration.tracking || wraps != configuration.wraps
            || (style.effectID == ProfileNameEffect.gummy.rawValue) != (configuration.style.effectID == ProfileNameEffect.gummy.rawValue)
        self.name = configuration.name
        self.font = configuration.font
        self.tracking = configuration.tracking
        self.style = configuration.style
        self.showsEffects = configuration.showsEffects
        self.background = configuration.background
        self.plainColor = configuration.plainColor
        self.elapsed = configuration.elapsed
        self.wraps = configuration.wraps
        if layoutChanged || naturalLayout == nil {
            naturalLayout = ProfileNameTextLayout(name: name, font: font, tracking: tracking, gummy: style.effectID == 8)
            fittedLayouts = []
            fittedWidth = nil
            invalidateIntrinsicContentSize()
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(name)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let naturalLayout else { return }
        let width = max(0, bounds.width - padding * 2)
        fit(to: width, natural: naturalLayout)
        let effect = showsEffects ? ProfileNameEffect(rawValue: style.effectID) ?? .solid : .solid
        let backdrop = ProfileNameEffectColor(effect == .toon ? NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1) : background)
        let colors = showsEffects ? style.colors.map {
            ProfileNameEffectColor(hex: $0).adjusted(against: backdrop, ratio: effect == .gradient || effect == .prism ? 2.5 : 3)
        } : [ProfileNameEffectColor(plainColor)]
        var top = bounds.height - padding
        for layout in fittedLayouts {
            context.saveGState()
            context.translateBy(x: padding, y: top - layout.ascent)
            ProfileNameEffectPainter.draw(layout, in: context, fontSize: font.pointSize, effect: effect,
                                          colors: colors, elapsed: elapsed)
            context.restoreGState()
            top -= ceil(layout.ascent + layout.descent) + 2
        }
    }

    func size(for proposedWidth: CGFloat?) -> CGSize {
        guard let naturalLayout else { return .zero }
        let width = min(proposedWidth ?? intrinsicContentSize.width, intrinsicContentSize.width)
        fit(to: max(0, width - padding * 2), natural: naturalLayout)
        let height = fittedLayouts.reduce(CGFloat(0)) { $0 + ceil($1.ascent + $1.descent) }
            + CGFloat(max(0, fittedLayouts.count - 1)) * 2 + padding * 2
        return CGSize(width: width, height: height)
    }

    private func fit(to width: CGFloat, natural: ProfileNameTextLayout) {
        guard fittedWidth != width else { return }
        if wraps, natural.width > width, width > 0 {
            fittedLayouts = ProfileNameTextLayout.wrappedLines(name: name, font: font, tracking: tracking, gummy: style.effectID == 8, width: width)
        } else {
            fittedLayouts = [natural.width <= width ? natural : ProfileNameTextLayout(
                name: name, font: font, tracking: tracking, gummy: style.effectID == 8, maximumWidth: width
            )]
        }
        fittedWidth = width
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "Copy Display Name"), action: #selector(copyName), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyName() {
        Pasteboard.copy(name)
    }
}
