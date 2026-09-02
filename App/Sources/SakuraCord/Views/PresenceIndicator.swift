import SakuraCordModels
import SwiftUI

nonisolated enum PresenceIndicatorPresentation {
    static func colorHex(for status: PresenceStatus) -> UInt32 {
        switch status {
        case .online: 0x23A55A
        case .idle: 0xF0B232
        case .dnd: 0xF23F43
        case .invisible, .offline: 0x80848E
        }
    }

    static func path(for status: PresenceStatus, in rect: CGRect) -> Path {
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
}

nonisolated enum AvatarPresencePresentation {
    private static let indicatorCenterFraction: CGFloat = 0.86

    static func indicatorRect(
        avatarRect: CGRect,
        indicatorSize: CGFloat
    ) -> CGRect {
        let center = CGPoint(
            x: avatarRect.minX + avatarRect.width * indicatorCenterFraction,
            y: avatarRect.minY + avatarRect.height * indicatorCenterFraction
        )
        return CGRect(
            x: center.x - indicatorSize / 2,
            y: center.y - indicatorSize / 2,
            width: indicatorSize,
            height: indicatorSize
        )
    }

    static func cutoutRect(
        avatarRect: CGRect,
        indicatorSize: CGFloat
    ) -> CGRect {
        let clearance = max(1.5, indicatorSize * 0.16)
        return indicatorRect(
            avatarRect: avatarRect,
            indicatorSize: indicatorSize
        ).insetBy(dx: -clearance, dy: -clearance)
    }
}

private nonisolated struct PresenceIndicatorShape: Shape {
    let status: PresenceStatus

    func path(in rect: CGRect) -> Path {
        PresenceIndicatorPresentation.path(for: status, in: rect)
    }
}

struct PresenceIndicator: View {
    let status: PresenceStatus
    let size: CGFloat

    var body: some View {
        PresenceIndicatorShape(status: status)
            .fill(
                Color(hex: PresenceIndicatorPresentation.colorHex(for: status)),
                style: FillStyle(eoFill: true)
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

struct AvatarPresenceView<Avatar: View>: View {
    let status: PresenceStatus
    let avatarSize: CGFloat
    let indicatorSize: CGFloat
    let avatar: Avatar

    init(
        status: PresenceStatus,
        avatarSize: CGFloat,
        indicatorSize: CGFloat,
        @ViewBuilder avatar: () -> Avatar
    ) {
        self.status = status
        self.avatarSize = avatarSize
        self.indicatorSize = indicatorSize
        self.avatar = avatar()
    }

    var body: some View {
        avatar
            .overlay { avatarCutout }
            .compositingGroup()
            .overlay { indicator }
    }

    private var avatarCutout: some View {
        GeometryReader { proxy in
            let cutoutRect = AvatarPresencePresentation.cutoutRect(
                avatarRect: avatarRect(in: proxy.size),
                indicatorSize: indicatorSize
            )
            Circle()
                .fill(.black)
                .frame(width: cutoutRect.width, height: cutoutRect.height)
                .position(x: cutoutRect.midX, y: cutoutRect.midY)
                .blendMode(.destinationOut)
        }
    }

    private var indicator: some View {
        GeometryReader { proxy in
            let indicatorRect = AvatarPresencePresentation.indicatorRect(
                avatarRect: avatarRect(in: proxy.size),
                indicatorSize: indicatorSize
            )
            PresenceIndicator(status: status, size: indicatorSize)
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
