import SwiftUI

struct GuildIconView: View {
    let name: String
    let iconURL: URL?
    let size: CGFloat
    let cornerRadius: CGFloat
    var animates = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
            if let iconURL {
                AnimatedRemoteImage(url: iconURL, animates: animates)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(name.isEmpty ? "Unnamed Server" : name)
    }
}
