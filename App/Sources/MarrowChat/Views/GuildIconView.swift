import SwiftUI

struct GuildIconView: View {
    let name: String
    let iconURL: URL?
    let size: CGFloat
    let cornerRadius: CGFloat
    var animates = true

    var body: some View {
        ZStack {
            ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
            if let iconURL {
                StaticRemoteImage(
                    url: iconURL,
                    maximumPixelDimension: requestedPixelDimension
                )
                if animates,
                   NativeTimelineAvatarPresentation
                    .shouldDecodeAnimation(for: iconURL)
                {
                    AnimatedRemoteImage(
                        url: iconURL,
                        maximumPixelDimension: requestedPixelDimension
                    )
                    .transition(.identity)
                }
            } else {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(name.isEmpty ? "Unnamed Server" : name)
    }

    private var requestedPixelDimension: Int {
        max(1, Int((size * 2).rounded(.up)))
    }
}
