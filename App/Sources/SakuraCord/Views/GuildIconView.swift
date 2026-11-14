import SakuraCordModels
import SwiftUI

struct GuildIconView: View {
    let name: String
    let iconURL: URL?
    let size: CGFloat
    let cornerRadius: CGFloat
    var animates = true
    var isSelected = false
    var loadsImage = true
    let morphsInFolder: Bool
    let morphID: GuildID?
    let maximumPixelDimension: Int?
    @Environment(\.colorScheme) private var colorScheme

    init(
        name: String,
        iconURL: URL?,
        size: CGFloat,
        cornerRadius: CGFloat,
        animates: Bool = true,
        isSelected: Bool = false,
        loadsImage: Bool = true,
        morphsInFolder: Bool = false,
        morphID: GuildID? = nil,
        maximumPixelDimension: Int? = nil
    ) {
        self.name = name
        self.iconURL = iconURL
        self.size = size
        self.cornerRadius = cornerRadius
        self.animates = animates
        self.isSelected = isSelected
        self.loadsImage = loadsImage
        self.morphsInFolder = morphsInFolder
        self.morphID = morphID
        self.maximumPixelDimension = maximumPixelDimension
    }

    var body: some View {
        ZStack {
            if let iconURL {
                if loadsImage {
                    StaticRemoteImage(
                        url: iconURL,
                        maximumPixelDimension: requestedPixelDimension,
                        retriesFailedLoads: true
                    )
                    if animates,
                       UserAvatarPresentation
                        .shouldDecodeAnimation(for: iconURL)
                    {
                        AnimatedRemoteImage(
                            url: iconURL,
                            maximumPixelDimension: requestedPixelDimension
                        )
                        .transition(.identity)
                    }
                } else {
                    Color.clear
                }
            } else {
                ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fallbackBackground)
                Text(initials)
                    .font(.system(size: size * 0.43, weight: .medium))
                    .foregroundStyle(isSelected ? .white : fallbackForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .clipShape(ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous))
        .modifier(ServerFolderIconMorph(isEnabled: morphsInFolder, guildID: morphID))
        .frame(width: size, height: size)
        .accessibilityLabel(name.isEmpty ? "Unnamed Server" : name)
    }

    private var requestedPixelDimension: Int {
        max(1, maximumPixelDimension ?? Int((size * 2).rounded(.up)))
    }

    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        if words.count > 1 {
            return String(words.prefix(3).compactMap(\.first))
        }
        return words.first.map { String($0.prefix(2)) } ?? "?"
    }

    private var fallbackBackground: Color {
        if isSelected { return Color(hex: 0x6D7EEE) }
        return Color.secondary.opacity(0.16)
    }

    private var fallbackForeground: Color {
        Color(hex: colorScheme == .dark ? 0xF2F2F4 : 0x3C3D42)
    }
}
