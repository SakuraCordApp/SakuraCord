import AppKit
import DiscordProtocol
import SakuraCordModels
import SwiftUI

struct ProfileActivitySection: View {
    let member: Member
    var richActivity: MemberRichActivity? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var dynamicArtwork: NSImage? = nil

    private var effectiveActivity: MemberRichActivity? {
        richActivity ?? member.richActivity
    }

    private var activityType: Int {
        effectiveActivity?.type ?? (member.isListeningToMusic ? 2 : 0)
    }

    private var isMusic: Bool {
        activityType == 2 || member.isListeningToMusic
    }

    private var headerText: String {
        if let activity = effectiveActivity {
            switch activity.type {
            case 2:
                let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return "LISTENING TO \(name.isEmpty ? "MUSIC" : name.uppercased())"
            case 1:
                return "STREAMING"
            case 3:
                return "WATCHING"
            case 5:
                let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return "COMPETING IN \(name.isEmpty ? "GAME" : name.uppercased())"
            default:
                let name = activity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "PLAYING A GAME" : "PLAYING \(name.uppercased())"
            }
        }
        if member.isListeningToMusic {
            return "LISTENING TO MUSIC"
        }
        return "ACTIVITY"
    }

    private var primaryText: String {
        effectiveActivity?.details
            ?? effectiveActivity?.name
            ?? member.activityText
            ?? "Music"
    }

    private var secondaryText: String? {
        if let state = effectiveActivity?.state, !state.isEmpty {
            return isMusic ? "by \(state)" : state
        }
        if isMusic, let text = member.activityText, text != primaryText {
            return "by \(text)"
        }
        return nil
    }

    private var tertiaryText: String? {
        if let text = effectiveActivity?.largeText, !text.isEmpty, text != primaryText {
            return isMusic ? "on \(text)" : text
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
            if imageRef.hasPrefix("file://"), let url = URL(string: imageRef) {
                if let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
                    return img
                }
            }
            if imageRef.hasPrefix("/"), FileManager.default.fileExists(atPath: imageRef) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: imageRef)), let img = NSImage(data: data) {
                    return img
                }
            }
        }
        if isMusic {
            if let data = AppleMusicPresenceMonitor.currentArtworkData, let img = NSImage(data: data) {
                return img
            }
            if FileManager.default.fileExists(atPath: AppleMusicPresenceMonitor.artworkPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: AppleMusicPresenceMonitor.artworkPath)),
               let img = NSImage(data: data) {
                return img
            }
            if FileManager.default.fileExists(atPath: AppleMusicPresenceMonitor.fallbackArtworkPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: AppleMusicPresenceMonitor.fallbackArtworkPath)),
               let img = NSImage(data: data) {
                return img
            }
        }
        return nil
    }

    private var resolvedRemoteArtworkURL: URL? {
        guard let largeImage = effectiveActivity?.largeImage else { return nil }
        if largeImage.hasPrefix("spotify:") {
            let hash = String(largeImage.dropFirst("spotify:".count))
            return URL(string: "https://i.scdn.co/image/\(hash)")
        }
        if largeImage.hasPrefix("http://") || largeImage.hasPrefix("https://") {
            return URL(string: largeImage)
        }
        if let appID = effectiveActivity?.applicationID, !appID.isEmpty {
            return URL(string: "https://cdn.discordapp.com/app-assets/\(appID)/\(largeImage).png")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text(headerText)
                .font(.interfaceSystem(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .center, spacing: InterfaceScale.metric(12)) {
                artworkView
                    .frame(width: InterfaceScale.metric(58), height: InterfaceScale.metric(58))

                VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
                    Text(primaryText)
                        .font(.interfaceSystem(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let secondaryText {
                        Text(secondaryText)
                            .font(.interfaceSystem(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let tertiaryText {
                        Text(tertiaryText)
                            .font(.interfaceSystem(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if let start = startTimestamp, let end = endTimestamp, end > start {
                playbackProgressBar(start: start, end: end)
            }
        }
        .padding(InterfaceScale.metric(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .onAppear {
            refreshArtwork()
        }
        .task(id: effectiveActivity) {
            refreshArtwork()
        }
    }

    private func refreshArtwork() {
        dynamicArtwork = resolvedArtworkImage
    }

    @ViewBuilder
    private var artworkView: some View {
        let cornerRadius = InterfaceScale.metric(8)
        let size = InterfaceScale.metric(58)
        if let image = dynamicArtwork ?? resolvedArtworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if let remoteURL = resolvedRemoteArtworkURL {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    fallbackArtIcon
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallbackArtIcon
        }
    }

    @ViewBuilder
    private var fallbackArtIcon: some View {
        let cornerRadius = InterfaceScale.metric(8)
        let size = InterfaceScale.metric(58)
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
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
        } else {
            genericGameIcon
                .frame(width: size, height: size)
        }
    }

    private var genericGameIcon: some View {
        RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
    }

    private func playbackProgressBar(start: Int64, end: Int64) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            let nowMs = Int64(timeline.date.timeIntervalSince1970 * 1000)
            let totalDurationMs = max(1, end - start)
            let elapsedMs = max(0, min(totalDurationMs, nowMs - start))
            let progress = Double(elapsedMs) / Double(totalDurationMs)
            let elapsedSec = Int(elapsedMs / 1000)
            let remainingSec = Int(max(0, end - nowMs) / 1000)

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
