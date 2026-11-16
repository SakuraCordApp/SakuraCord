import AppKit
import QuartzCore
import SakuraCordModels

nonisolated enum UserAvatarPresentation {
    static let decorationScale: CGFloat = 1.16

    /// Discord's subtle background (#97979F at 12% in dark, 16% in light),
    /// shown under an avatar until its picture loads, or if it fails.
    static let placeholderColor = NSColor(name: nil) { appearance in
        NSColor(srgbRed: 0x97 / 255, green: 0x97 / 255, blue: 0x9F / 255, alpha: appearance.isDark ? 0.12 : 0.16)
    }

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
