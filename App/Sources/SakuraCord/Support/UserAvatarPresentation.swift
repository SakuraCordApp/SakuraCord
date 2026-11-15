import AppKit
import QuartzCore
import SakuraCordModels

nonisolated enum UserAvatarPresentation {
    static let decorationScale: CGFloat = 1.16

    static func decorationFrame(around avatarFrame: CGRect) -> CGRect {
        let width = avatarFrame.width * decorationScale
        let height = avatarFrame.height * decorationScale
        return CGRect(
            x: avatarFrame.midX - width / 2,
            y: avatarFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func shouldDecodeAnimation(for url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "gif", "apng":
            return true
        default:
            return URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.contains {
                $0.name == "animated"
                    && $0.value?.lowercased() == "true"
            } == true
        }
    }
}
