import SwiftUI

struct AvatarView: View {
    let name: String
    let url: URL?
    let size: CGFloat
    let maximumPixelDimension: Int?
    let animates: Bool

    init(
        name: String,
        url: URL?,
        size: CGFloat,
        maximumPixelDimension: Int? = nil,
        animates: Bool = true
    ) {
        self.name = name
        self.url = url
        self.size = size
        self.maximumPixelDimension = maximumPixelDimension
        self.animates = animates
    }

    var body: some View {
        ZStack {
            if let cachedFrame {
                Image(decorative: cachedFrame, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Color.accentColor.gradient)
                fallback
            }
            if let url {
                AnimatedRemoteImage(
                    url: url,
                    animates: animates,
                    maximumPixelDimension: requestedPixelDimension,
                    contentMode: .fill
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(name) avatar")
    }

    private var fallback: some View {
        Text(name.prefix(1).uppercased()).font(.system(size: size * 0.42, weight: .semibold))
    }

    var requestedPixelDimension: Int {
        maximumPixelDimension ?? max(1, Int((size * 2).rounded(.up)))
    }

    var cachedFrame: CGImage? {
        guard let url else { return nil }
        return AnimatedRemoteImageDisplayCache.shared.image(
            for: url,
            maximumPixelDimension: requestedPixelDimension
        )?.frames.first
    }
}
