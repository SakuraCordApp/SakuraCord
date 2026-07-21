import SwiftUI

struct AvatarView: View {
    let name: String
    let url: URL?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.gradient)
            if let url {
                AnimatedRemoteImage(url: url)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(name) avatar")
    }

    private var fallback: some View {
        Text(name.prefix(1).uppercased()).font(.system(size: size * 0.42, weight: .semibold))
    }
}
