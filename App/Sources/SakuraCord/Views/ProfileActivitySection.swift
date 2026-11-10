import AppKit
import DiscordProtocol
import SakuraCordModels
import SwiftUI

struct ProfileActivitySectionRightHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ActivityMarqueeText: View {
    let text: String
    var font: Font = .interfaceSystem(size: 13, weight: .semibold)
    var foregroundStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    var isCardHovered: Bool = false
    var height: CGFloat = InterfaceScale.metric(18)

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?
    @State private var isActivelyScrolling = false

    private let gap: CGFloat = InterfaceScale.metric(36)

    private var overflowDistance: CGFloat {
        max(0, textWidth - containerWidth)
    }

    private var isOverflowing: Bool {
        overflowDistance > 4
    }

    private var loopDistance: CGFloat {
        textWidth + gap
    }

    var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width
            ZStack(alignment: .leading) {
                if isOverflowing, isCardHovered, !systemReduceMotion {
                    HStack(spacing: gap) {
                        textView
                        textView
                    }
                    .offset(x: scrollOffset)
                } else {
                    textView
                        .offset(x: 0)
                }
            }
            .frame(width: availableWidth, alignment: .leading)
            .clipped()
            .mask {
                if isOverflowing, isCardHovered {
                    let hasLeftFade = isActivelyScrolling && scrollOffset < -3
                    LinearGradient(
                        stops: [
                            .init(color: hasLeftFade ? .clear : .black, location: 0),
                            .init(color: .black, location: hasLeftFade ? 0.04 : 0),
                            .init(color: .black, location: 0.96),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .onAppear {
                containerWidth = availableWidth
            }
            .onChange(of: availableWidth) { _, newWidth in
                containerWidth = newWidth
            }
        }
        .frame(height: height)
        .onChange(of: isCardHovered) { _, hovered in
            updateScroll(hovered: hovered)
        }
        .onChange(of: text) { _, _ in
            updateScroll(hovered: isCardHovered)
        }
        .onChange(of: systemReduceMotion) { _, _ in
            updateScroll(hovered: isCardHovered)
        }
        .onDisappear {
            scrollTask?.cancel()
            scrollTask = nil
            isActivelyScrolling = false
        }
    }

    private var textView: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { textGeo in
                    Color.clear
                        .onAppear {
                            let width = textGeo.size.width
                            if abs(textWidth - width) > 1 {
                                textWidth = width
                            }
                        }
                        .onChange(of: textGeo.size.width) { _, width in
                            if abs(textWidth - width) > 1 {
                                textWidth = width
                            }
                        }
                }
            }
    }

    private func updateScroll(hovered: Bool) {
        scrollTask?.cancel()
        scrollTask = nil
        guard hovered, isOverflowing, !systemReduceMotion else {
            isActivelyScrolling = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollOffset = 0
            }
            return
        }

        let distance = loopDistance
        let duration = max(3.0, Double(distance) / 28.0)

        scrollTask = Task { @MainActor in
            isActivelyScrolling = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                isActivelyScrolling = true
                withAnimation(.linear(duration: duration)) {
                    scrollOffset = -distance
                }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }

                var resetTransaction = Transaction()
                resetTransaction.disablesAnimations = true
                withTransaction(resetTransaction) {
                    scrollOffset = 0
                }
                isActivelyScrolling = false
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
            }
        }
    }
}

struct ProfileActivitySection: View {
    let member: Member
    var richActivity: MemberRichActivity?
    var isCurrentUser: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.serverTagCardModel) private var model
    @State private var dynamicArtwork: NSImage?
    @State private var remoteArtworkOverride: URL?
    @State private var resolvedTrackURL: URL?
    @State private var rightColumnHeight: CGFloat = InterfaceScale.metric(64)
    @State private var isCardHovered = false

    private var effectiveActivity: MemberRichActivity? {
        richActivity ?? member.richActivity
    }

    private var activityType: Int {
        effectiveActivity?.type ?? (member.isListeningToMusic ? 2 : 0)
    }

    private var isMusic: Bool {
        activityType == 2 || member.isListeningToMusic
    }

    private var cardCornerRadius: CGFloat {
        InterfaceScale.metric(18)
    }

    private var headerText: String {
        if let activity = effectiveActivity {
            switch activity.type {
            case 2:
                let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Listening to \(name.isEmpty ? "Music" : name)"
            case 1:
                let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Streaming" : "Streaming \(name)"
            case 3:
                let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Watching" : "Watching \(name)"
            case 5:
                let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Competing in \(name.isEmpty ? "Game" : name)"
            default:
                let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Playing a game" : "Playing \(name)"
            }
        }
        if member.isListeningToMusic {
            return "Listening to Music"
        }
        return "Activity"
    }

    private var primaryText: String {
        if isMusic {
            return effectiveActivity?.details
                ?? effectiveActivity?.name
                ?? member.activityText
                ?? "Music"
        }
        return effectiveActivity?.name
            ?? member.activityText
            ?? "Game"
    }

    private var secondaryText: String? {
        if isMusic {
            if let state = effectiveActivity?.state, !state.isEmpty {
                return "by \(state)"
            }
            if let text = member.activityText, text != primaryText {
                return "by \(text)"
            }
            return nil
        }
        if let details = effectiveActivity?.details, !details.isEmpty, details != primaryText {
            return details
        }
        if let state = effectiveActivity?.state, !state.isEmpty, state != primaryText {
            return state
        }
        return nil
    }

    private var tertiaryText: String? {
        if isMusic {
            if let text = effectiveActivity?.largeText, !text.isEmpty, text != primaryText {
                return "on \(text)"
            }
            return nil
        }
        if let state = effectiveActivity?.state, !state.isEmpty,
           state != primaryText, state != secondaryText {
            return state
        }
        return nil
    }

    private var startTimestamp: Int64? {
        effectiveActivity?.startTimestamp
    }

    private var endTimestamp: Int64? {
        effectiveActivity?.endTimestamp
    }

    private var resolvedArtworkImage: NSImage? {
        if let imageRef = effectiveActivity?.largeImage {
            if let data = Data(base64Encoded: imageRef), let img = NSImage(data: data) {
                return img
            }
            if let local = NSImage(named: imageRef) {
                return local
            }
            if imageRef.hasPrefix("data:image"), let comma = imageRef.firstIndex(of: ",") {
                let base64 = String(imageRef[imageRef.index(after: comma)...])
                if let data = Data(base64Encoded: base64), let img = NSImage(data: data) {
                    return img
                }
            }
            if imageRef.hasPrefix("/"), FileManager.default.fileExists(atPath: imageRef) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: imageRef)), let img = NSImage(data: data) {
                    return img
                }
            }
        }
        if isMusic, isCurrentUser {
            if let data = AppleMusicPresenceMonitor.currentArtworkData, let img = NSImage(data: data) {
                return img
            }
        }
        if let lowerName = effectiveActivity?.name.lowercased(), lowerName.contains("roblox") {
            if let data = GamePresenceMonitor.currentRobloxIconData, let img = NSImage(data: data) {
                return img
            }
        }
        return nil
    }

    private var resolvedRemoteArtworkURL: URL? {
        if let override = remoteArtworkOverride { return override }
        guard let largeImage = effectiveActivity?.largeImage else { return nil }
        if largeImage.hasPrefix("spotify:") {
            let hash = String(largeImage.dropFirst("spotify:".count))
            return URL(string: "https://i.scdn.co/image/\(hash)")
        }
        if largeImage.hasPrefix("mp:external/") {
            let path = String(largeImage.dropFirst("mp:external/".count))
            return URL(string: "https://media.discordapp.net/external/\(path)")
        }
        if largeImage.hasPrefix("external/") {
            return URL(string: "https://media.discordapp.net/\(largeImage)")
        }
        if largeImage.hasPrefix("mp:attachments/") {
            let path = String(largeImage.dropFirst("mp:attachments/".count))
            return URL(string: "https://media.discordapp.net/attachments/\(path)")
        }
        if largeImage.hasPrefix("attachments/") {
            return URL(string: "https://cdn.discordapp.com/\(largeImage)")
        }
        if largeImage.hasPrefix("http://") || largeImage.hasPrefix("https://") {
            return URL(string: largeImage)
        }
        if let appID = effectiveActivity?.applicationID, !appID.isEmpty {
            return URL(string: "https://cdn.discordapp.com/app-assets/\(appID)/\(largeImage).png")
        }
        return nil
    }

    private var activityDestinationURL: URL? {
        if isMusic {
            if let directURLString = effectiveActivity?.url, let directURL = URL(string: directURLString) {
                return directURL
            }
            if let resolved = resolvedTrackURL {
                return resolved
            }
            let appName = effectiveActivity?.name ?? ""
            let isSpotify = appName.caseInsensitiveCompare("Spotify") == .orderedSame
            let query = [primaryText, secondaryText].compactMap { $0 }.joined(separator: " ")
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if isSpotify {
                if let trackID = effectiveActivity?.largeText, trackID.contains("track:") {
                    let id = trackID.components(separatedBy: "track:").last ?? ""
                    if !id.isEmpty, let url = URL(string: "https://open.spotify.com/track/\(id)") {
                        return url
                    }
                }
                return URL(string: "https://open.spotify.com/search/\(encodedQuery)")
            } else {
                return URL(string: "https://music.apple.com/search?term=\(encodedQuery)") ?? URL(string: "https://music.apple.com")
            }
        }
        let lowerName = (effectiveActivity?.name ?? "").lowercased()
        let lowerDetails = (effectiveActivity?.details ?? "").lowercased()
        if lowerName.contains("roblox") || lowerDetails.contains("roblox") {
            return URL(string: "https://www.roblox.com")
        }
        if lowerName.contains("essential") || lowerDetails.contains("essential") || lowerName.contains("minecraft") {
            return URL(string: "https://essential.gg")
        }
        if let appID = effectiveActivity?.applicationID, !appID.isEmpty {
            return URL(string: "https://discord.com/app")
        }
        return nil
    }

    private var destinationHelpText: String {
        if isMusic {
            let appName = effectiveActivity?.name ?? (member.isListeningToMusic ? "Spotify" : "Apple Music")
            return "Play in \(appName)"
        }
        let lowerName = (effectiveActivity?.name ?? "").lowercased()
        if lowerName.contains("roblox") {
            return "Open Roblox"
        }
        if lowerName.contains("essential") {
            return "Open Essential Mod"
        }
        return "Open in Browser"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text(headerText)
                .font(.interfaceSystem(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .center, spacing: InterfaceScale.metric(12)) {
                artworkView(size: rightColumnHeight)
                    .frame(width: rightColumnHeight, height: rightColumnHeight)

                rightDetailsColumn
            }
        }
        .padding(InterfaceScale.metric(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ConcentricRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(isCardHovered ? (colorScheme == .dark ? 0.09 : 0.06) : (colorScheme == .dark ? 0.06 : 0.04)))
        }
        .overlay {
            ConcentricRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(isCardHovered ? 0.14 : 0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .onHover { hovering in
            isCardHovered = hovering
            if hovering, activityDestinationURL != nil {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            if isMusic, isCurrentUser {
                let appName = effectiveActivity?.name ?? ""
                if appName.caseInsensitiveCompare("Apple Music") == .orderedSame || appName.isEmpty {
                    if let musicApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Music" }) {
                        musicApp.activate(options: .activateIgnoringOtherApps)
                    }
                }
            }
            if let destination = activityDestinationURL {
                _ = MessageLinkActivator.activate(destination, model: model, displayedText: destination.absoluteString)
            }
        }
        .help(activityDestinationURL != nil ? destinationHelpText : "")
        .onAppear {
            refreshArtwork()
        }
        .task(id: effectiveActivity) {
            remoteArtworkOverride = nil
            resolvedTrackURL = nil
            refreshArtwork()
            await resolveMissingMusicArtwork()
        }
    }

    @ViewBuilder
    private var rightDetailsColumn: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
            ActivityMarqueeText(
                text: primaryText,
                font: .interfaceSystem(size: 13, weight: .semibold),
                foregroundStyle: AnyShapeStyle(.primary),
                isCardHovered: isCardHovered,
                height: InterfaceScale.metric(18)
            )

            if let secondaryText {
                ActivityMarqueeText(
                    text: secondaryText,
                    font: .interfaceSystem(size: 12),
                    foregroundStyle: AnyShapeStyle(Color.primary.opacity(0.78)),
                    isCardHovered: isCardHovered,
                    height: InterfaceScale.metric(16)
                )
            }

            if let tertiaryText {
                ActivityMarqueeText(
                    text: tertiaryText,
                    font: .interfaceSystem(size: 12),
                    foregroundStyle: AnyShapeStyle(Color.primary.opacity(0.68)),
                    isCardHovered: isCardHovered,
                    height: InterfaceScale.metric(16)
                )
            }

            if let start = startTimestamp, let end = endTimestamp, end > start,
               !end.subtractingReportingOverflow(start).overflow,
               (end - start) < 86_400_000 * 7, (end - start) > 0 {
                playbackProgressBar(start: start, end: end)
                    .padding(.top, InterfaceScale.metric(2))
            } else if let start = startTimestamp, !isMusic {
                elapsedTimeLabel(start: start)
                    .padding(.top, InterfaceScale.metric(2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ProfileActivitySectionRightHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(ProfileActivitySectionRightHeightKey.self) { newHeight in
            if newHeight > 0 {
                let clamped = max(InterfaceScale.metric(56), newHeight)
                if abs(rightColumnHeight - clamped) > 1 {
                    rightColumnHeight = clamped
                }
            }
        }
    }

    private func refreshArtwork() {
        dynamicArtwork = resolvedArtworkImage
    }

    private func resolveMissingMusicArtwork() async {
        guard isMusic else { return }
        let appName = effectiveActivity?.name ?? ""
        let service = appName.caseInsensitiveCompare("Spotify") == .orderedSame ? "Spotify" : "Apple Music"
        let spotifyID = service == "Spotify" ? effectiveActivity?.largeText : nil
        let resolved = await MusicArtworkResolver.shared.resolveMusic(
            service: service,
            title: primaryText,
            artist: effectiveActivity?.state,
            album: effectiveActivity?.largeText,
            spotifyTrackID: spotifyID
        )
        guard !Task.isCancelled else { return }
        if resolvedRemoteArtworkURL == nil || effectiveActivity?.largeImage == "apple_music" {
            if let artwork = resolved.artworkURL, let url = URL(string: artwork) {
                remoteArtworkOverride = url
            }
        }
        if let track = resolved.trackURL, let url = URL(string: track) {
            resolvedTrackURL = url
        }
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        let cornerRadius = InterfaceScale.metric(14)
        if let remoteURL = resolvedRemoteArtworkURL {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    if let local = dynamicArtwork ?? resolvedArtworkImage {
                        Image(nsImage: local)
                            .resizable()
                            .scaledToFill()
                    } else {
                        fallbackArtIcon(size: size)
                    }
                default:
                    if let local = dynamicArtwork ?? resolvedArtworkImage {
                        Image(nsImage: local)
                            .resizable()
                            .scaledToFill()
                    } else {
                        fallbackArtIcon(size: size)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if let image = dynamicArtwork ?? resolvedArtworkImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallbackArtIcon(size: size)
        }
    }

    @ViewBuilder
    private func fallbackArtIcon(size: CGFloat) -> some View {
        let cornerRadius = InterfaceScale.metric(14)
        if isMusic {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xFC3C44), Color(hex: 0xFA233B)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: max(16, size * 0.38), weight: .semibold))
                        .foregroundStyle(.white)
                }
        } else {
            genericGameIcon(size: size)
                .frame(width: size, height: size)
        }
    }

    private func genericGameIcon(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: max(16, size * 0.35)))
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func elapsedTimeLabel(start: Int64) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            let nowMs = Int64(timeline.date.timeIntervalSince1970 * 1000)
            let (rawElapsed, elapsedOverflow) = nowMs.subtractingReportingOverflow(start)
            let elapsedMs = elapsedOverflow || rawElapsed < 0 ? 0 : rawElapsed
            let totalSeconds = Int(elapsedMs / 1000)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            let formattedTime: String = if hours > 0 {
                String(format: "%d:%02d:%02d elapsed", hours, minutes, seconds)
            } else {
                String(format: "%02d:%02d elapsed", minutes, seconds)
            }

            Text(formattedTime)
                .font(.interfaceSystem(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func playbackProgressBar(start: Int64, end: Int64) -> some View {
        let (durationMs, overflow) = end.subtractingReportingOverflow(start)
        if !overflow, durationMs > 0, durationMs < 86_400_000 * 7 {
            TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                let nowMs = Int64(timeline.date.timeIntervalSince1970 * 1000)
                let (rawElapsed, elapsedOverflow) = nowMs.subtractingReportingOverflow(start)
                let elapsedMs = elapsedOverflow ? (nowMs < start ? 0 : durationMs) : max(0, min(durationMs, rawElapsed))
                let progress = Double(elapsedMs) / Double(durationMs)
                let elapsedSec = Int(elapsedMs / 1000)
                let (rawRemaining, remainingOverflow) = end.subtractingReportingOverflow(nowMs)
                let remainingMs = remainingOverflow ? 0 : max(0, rawRemaining)
                let remainingSec = Int(remainingMs / 1000)

                VStack(spacing: InterfaceScale.metric(4)) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: InterfaceScale.metric(4))

                            Capsule()
                                .fill(Color.primary.opacity(0.8))
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progress))), height: InterfaceScale.metric(4))
                        }
                    }
                    .frame(height: InterfaceScale.metric(4))

                    HStack {
                        Text(String(format: "%d:%02d", elapsedSec / 60, elapsedSec % 60))
                            .font(.interfaceSystem(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "-%d:%02d", remainingSec / 60, remainingSec % 60))
                            .font(.interfaceSystem(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
