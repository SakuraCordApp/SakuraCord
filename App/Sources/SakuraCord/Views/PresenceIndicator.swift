import SakuraCordModels
import SwiftUI

extension Color {
    /// The green of an online presence, for anything that should read as it.
    static let presenceOnline = Color(hex: PresenceIndicatorPresentation.colorHex(for: .online))
}

nonisolated enum PresenceIndicatorPresentation {
    static func colorHex(for status: PresenceStatus) -> UInt32 {
        switch status {
        case .online: 0x23A55A
        case .idle: 0xF0B232
        case .dnd: 0xF23F43
        case .invisible, .offline: 0x80848E
        }
    }

    static func showsMobileIndicator(for status: PresenceStatus, isMobile: Bool) -> Bool {
        isMobile && status.isVisibleOnline
    }

    static func accessibilityLabel(for status: PresenceStatus, isMobile: Bool) -> String {
        let label: String = switch status {
        case .online: "Online"
        case .idle: "Idle"
        case .dnd: "Do Not Disturb"
        case .invisible, .offline: "Offline"
        }
        return showsMobileIndicator(for: status, isMobile: isMobile) ? "\(label) on mobile" : label
    }

    /// The mobile indicator is a phone taller than the status dot.
    static let mobileHeightRatio: CGFloat = 1.5

    static func path(for status: PresenceStatus, isMobile: Bool = false, in rect: CGRect) -> Path {
        if showsMobileIndicator(for: status, isMobile: isMobile) { return mobilePath(in: rect) }
        var path = Path()
        path.addEllipse(in: rect)

        switch status {
        case .online:
            break
        case .idle:
            let size = rect.width * 0.62
            path.addEllipse(in: CGRect(
                x: rect.midX - size / 2 - rect.width * 0.18,
                y: rect.midY - size / 2 - rect.height * 0.18,
                width: size,
                height: size
            ))
        case .dnd:
            let height = rect.height * 0.18
            path.addRoundedRect(
                in: CGRect(
                    x: rect.midX - rect.width * 0.275,
                    y: rect.midY - height / 2,
                    width: rect.width * 0.55,
                    height: height
                ),
                cornerSize: CGSize(width: height / 2, height: height / 2)
            )
        case .invisible, .offline:
            let size = rect.width * 0.46
            path.addEllipse(in: CGRect(
                x: rect.midX - size / 2,
                y: rect.midY - size / 2,
                width: size,
                height: size
            ))
        }

        return path
    }

    static func outline(isMobile: Bool, in rect: CGRect) -> Path {
        isMobile
            ? Path(roundedRect: rect, cornerRadius: mobileCornerRadius(for: rect))
            : Path(ellipseIn: rect)
    }

    /// A phone body with the screen and home button cut out, filled even-odd.
    private static func mobilePath(in rect: CGRect) -> Path {
        var path = outline(isMobile: true, in: rect)
        let bezel = rect.width * 0.18
        let screen = CGRect(
            x: rect.minX + bezel,
            y: rect.minY + bezel,
            width: rect.width - bezel * 2,
            height: rect.height * 0.58
        )
        path.addRoundedRect(
            in: screen,
            cornerSize: CGSize(width: bezel * 0.4, height: bezel * 0.4)
        )
        let button = rect.width * 0.2
        path.addEllipse(in: CGRect(
            x: rect.midX - button / 2,
            y: (screen.maxY + rect.maxY) / 2 - button / 2,
            width: button,
            height: button
        ))
        return path
    }

    private static func mobileCornerRadius(for rect: CGRect) -> CGFloat {
        rect.width * 0.28
    }
}

nonisolated enum AvatarPresencePresentation {
    private static let indicatorCenterFraction: CGFloat = 0.86

    /// The mobile indicator keeps the dot's bottom edge and grows upward.
    static func indicatorRect(
        avatarRect: CGRect,
        indicatorSize: CGFloat,
        isMobile: Bool = false
    ) -> CGRect {
        let center = CGPoint(
            x: avatarRect.minX + avatarRect.width * indicatorCenterFraction,
            y: avatarRect.minY + avatarRect.height * indicatorCenterFraction
        )
        let height = isMobile
            ? indicatorSize * PresenceIndicatorPresentation.mobileHeightRatio
            : indicatorSize
        return CGRect(
            x: center.x - indicatorSize / 2,
            y: center.y + indicatorSize / 2 - height,
            width: indicatorSize,
            height: height
        )
    }

    static func cutoutPath(
        avatarRect: CGRect,
        indicatorSize: CGFloat,
        isMobile: Bool = false
    ) -> Path {
        let clearance = max(1.5, indicatorSize * 0.16)
        let rect = indicatorRect(
            avatarRect: avatarRect,
            indicatorSize: indicatorSize,
            isMobile: isMobile
        ).insetBy(dx: -clearance, dy: -clearance)
        return PresenceIndicatorPresentation.outline(isMobile: isMobile, in: rect)
    }
}

private nonisolated struct PresenceIndicatorShape: Shape {
    let status: PresenceStatus
    let isMobile: Bool

    func path(in rect: CGRect) -> Path {
        PresenceIndicatorPresentation.path(for: status, isMobile: isMobile, in: rect)
    }
}

private nonisolated struct PresenceIndicatorOutline: Shape {
    let isMobile: Bool

    func path(in rect: CGRect) -> Path {
        PresenceIndicatorPresentation.outline(isMobile: isMobile, in: rect)
    }
}

struct PresenceIndicator: View {
    let status: PresenceStatus
    let size: CGFloat
    var isMobile = false

    private var usesMobileShape: Bool {
        PresenceIndicatorPresentation.showsMobileIndicator(for: status, isMobile: isMobile)
    }

    var body: some View {
        PresenceIndicatorShape(status: status, isMobile: usesMobileShape)
            .fill(
                Color(hex: PresenceIndicatorPresentation.colorHex(for: status)),
                style: FillStyle(eoFill: true)
            )
            .frame(
                width: size,
                height: usesMobileShape ? size * PresenceIndicatorPresentation.mobileHeightRatio : size
            )
            .clipShape(PresenceIndicatorOutline(isMobile: usesMobileShape))
            .accessibilityHidden(true)
    }
}

struct AvatarPresenceView<Avatar: View>: View {
    let status: PresenceStatus?
    let avatarSize: CGFloat
    let indicatorSize: CGFloat
    let isMobile: Bool
    let avatar: Avatar

    init(
        status: PresenceStatus?,
        avatarSize: CGFloat,
        indicatorSize: CGFloat,
        isMobile: Bool = false,
        @ViewBuilder avatar: () -> Avatar
    ) {
        self.status = status
        self.avatarSize = avatarSize
        self.indicatorSize = indicatorSize
        self.isMobile = isMobile
        self.avatar = avatar()
    }

    private var usesMobileShape: Bool {
        status.map { PresenceIndicatorPresentation.showsMobileIndicator(for: $0, isMobile: isMobile) } ?? false
    }

    var body: some View {
        avatar
            .overlay {
                if status != nil { avatarCutout }
            }
            .compositingGroup()
            .overlay {
                if let status { indicator(status: status) }
            }
            .accessibilityValue(status.map {
                PresenceIndicatorPresentation.accessibilityLabel(for: $0, isMobile: usesMobileShape)
            } ?? "")
    }

    private var avatarCutout: some View {
        GeometryReader { proxy in
            AvatarPresencePresentation.cutoutPath(
                avatarRect: avatarRect(in: proxy.size),
                indicatorSize: indicatorSize,
                isMobile: usesMobileShape
            )
            .fill(.black)
            .blendMode(.destinationOut)
        }
    }

    private func indicator(status: PresenceStatus) -> some View {
        GeometryReader { proxy in
            let indicatorRect = AvatarPresencePresentation.indicatorRect(
                avatarRect: avatarRect(in: proxy.size),
                indicatorSize: indicatorSize,
                isMobile: usesMobileShape
            )
            PresenceIndicator(status: status, size: indicatorSize, isMobile: usesMobileShape)
                .position(x: indicatorRect.midX, y: indicatorRect.midY)
        }
    }

    private func avatarRect(in size: CGSize) -> CGRect {
        CGRect(
            x: (size.width - avatarSize) / 2,
            y: (size.height - avatarSize) / 2,
            width: avatarSize,
            height: avatarSize
        )
    }
}
