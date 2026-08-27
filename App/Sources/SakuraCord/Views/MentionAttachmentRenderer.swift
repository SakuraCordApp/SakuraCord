import AppKit
import SakuraCordModels

extension NSAttributedString.Key {
    nonisolated static let discordMentionToken = NSAttributedString.Key(
        "dev.sakuracord.discord-mention-token"
    )
}

nonisolated final class MentionTextAttachment: NSTextAttachment {
    let presentation: MentionPresentation
    let font: NSFont
    private(set) var normalImage: NSImage
    private(set) var hoverImage: NSImage

    @MainActor
    init(presentation: MentionPresentation, font: NSFont, avatar: NSImage? = nil) {
        self.presentation = presentation
        self.font = font
        normalImage = MentionAttachmentRenderer.image(
            presentation: presentation, font: font, avatar: avatar, hovered: false
        )
        hoverImage = MentionAttachmentRenderer.image(
            presentation: presentation, font: font, avatar: avatar, hovered: true
        )
        super.init(data: nil, ofType: nil)
        image = normalImage
        bounds = CGRect(
            x: 0,
            y: ComposerEmojiAttributedText.attachmentOriginY(
                font: font, size: normalImage.size.height
            ),
            width: normalImage.size.width,
            height: normalImage.size.height
        )
        image?.accessibilityDescription = presentation.label
    }

    required init?(coder: NSCoder) { nil }

    @MainActor
    func updateImages(avatar: NSImage?) {
        normalImage = MentionAttachmentRenderer.image(
            presentation: presentation, font: font, avatar: avatar, hovered: false
        )
        hoverImage = MentionAttachmentRenderer.image(
            presentation: presentation, font: font, avatar: avatar, hovered: true
        )
        image = normalImage
    }
}

@MainActor
enum MentionAttachmentRenderer {
    static func attributedString(
        presentation: MentionPresentation,
        font: NSFont = .systemFont(ofSize: 15)
    ) -> NSAttributedString {
        let attachment = MentionTextAttachment(
            presentation: presentation,
            font: font,
            avatar: presentation.avatarURL.flatMap(MentionAvatarImageStore.shared.cachedImage)
        )
        let value = NSMutableAttributedString(attachment: attachment)
        value.addAttributes(
            [
                .discordMentionToken: presentation.rawToken,
                .font: font
            ],
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }

    static func image(
        presentation: MentionPresentation,
        font: NSFont,
        avatar: NSImage?,
        hovered: Bool
    ) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let label = presentation.label as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let labelSize = label.size(withAttributes: attributes)
        let showsAvatar = if case .user = presentation.target { true } else { false }
        let showsLeadingIcon = presentation.systemImage != nil
        let height = max(21, ceil(font.pointSize + 6))
        let avatarSize = height - 6
        let iconSize = height - 7
        let horizontalPadding: CGFloat = 6
        let avatarGap: CGFloat = showsAvatar ? 4 : 0
        let iconGap: CGFloat = showsLeadingIcon ? 4 : 0
        let width = ceil(
            horizontalPadding * 2 + labelSize.width
                + (showsAvatar ? avatarSize + avatarGap : 0)
                + (showsLeadingIcon ? iconSize + iconGap : 0)
        )
        let size = NSSize(width: width, height: height)
        let color = mentionColor(hex: presentation.colorHex)
        let image = NSImage(size: size, flipped: false) { bounds in
            let background = color.withAlphaComponent(hovered ? 0.34 : 0.18)
            background.setFill()
            NSBezierPath(
                concentricRoundedRect: bounds,
                cornerRadius: 5.5
            ).fill()

            var textX = horizontalPadding
            if let systemImage = presentation.systemImage {
                let iconConfiguration = NSImage.SymbolConfiguration(
                    pointSize: iconSize,
                    weight: .semibold
                ).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                if let icon = NSImage(
                    systemSymbolName: systemImage,
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(iconConfiguration) {
                    let iconRect = NSRect(
                        x: horizontalPadding,
                        y: (height - iconSize) / 2,
                        width: iconSize,
                        height: iconSize
                    )
                    icon.draw(
                        in: iconRect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                    textX = iconRect.maxX + iconGap
                }
            } else if showsAvatar {
                let avatarRect = NSRect(
                    x: horizontalPadding,
                    y: (height - avatarSize) / 2,
                    width: avatarSize,
                    height: avatarSize
                )
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: avatarRect).addClip()
                if let avatar {
                    avatar.draw(
                        in: avatarRect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high]
                    )
                } else {
                    color.withAlphaComponent(0.38).setFill()
                    NSBezierPath(ovalIn: avatarRect).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                textX = avatarRect.maxX + avatarGap
            }

            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: color
            ]
            let textY = floor((height - labelSize.height) / 2)
            label.draw(at: NSPoint(x: textX, y: textY), withAttributes: textAttributes)
            return true
        }
        image.accessibilityDescription = presentation.label
        return image
    }

    private static func mentionColor(hex: UInt32?) -> NSColor {
        guard let hex, hex != 0 else { return .sakuraCordAccentColor }
        return NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

@MainActor
final class MentionAvatarImageStore {
    static let shared = MentionAvatarImageStore()
    private let images = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() { images.countLimit = 256 }

    func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let data = try? await SharedMediaDataLoader.shared.data(for: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }
}
