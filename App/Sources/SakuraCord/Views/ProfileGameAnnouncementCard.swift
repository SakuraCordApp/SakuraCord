import MessageRendering
import SakuraCordModels
import SwiftUI

struct ProfileGameAnnouncementCard: View {
    let message: ProfileGameAnnouncement
    var isInteractive = true
    @Environment(\.displayScale) private var displayScale

    private static var width: CGFloat { InterfaceScale.metric(300) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.poll == nil, let url = imageURL {
                ProfileWidgetImageView(url: url, contentMode: .fill)
                    .frame(width: Self.width, height: InterfaceScale.metric(140))
                    .clipped()
            }
            VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                if let poll = message.poll { pollContent(poll) } else { textContent }
                Spacer(minLength: InterfaceScale.metric(8))
                footer
            }
            .padding(InterfaceScale.metric(14))
        }
        .frame(width: Self.width, height: InterfaceScale.metric(260), alignment: .topLeading)
        .modifier(CompactProfileWidgetHover(backgroundOpacity: 0.04, cornerRadius: ProfileGameMetrics.cardRadius))
        .environment(\.isEnabled, isInteractive)
        .clipShape(.rect(cornerRadius: ProfileGameMetrics.cardRadius))
        .contentShape(.rect(cornerRadius: ProfileGameMetrics.cardRadius))
    }

    @ViewBuilder private var textContent: some View {
        if let author = message.embedSource?.author {
            HStack(spacing: InterfaceScale.metric(6)) {
                if let icon = author.proxyIconURL ?? author.iconURL {
                    ProfileWidgetImageView(url: icon).frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(16)).clipShape(.circle)
                }
                Text(author.name).font(.interfaceSystem(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        if let title = message.title {
            Text(DiscordMarkdown.attributed(title)).font(.interfaceSystem(size: 14, weight: .semibold)).lineLimit(2)
        }
        if !previewBody.isEmpty {
            Text(DiscordMarkdown.attributed(previewBody))
                .font(.interfaceSystem(size: 13)).foregroundStyle(message.title == nil ? .primary : .secondary)
                .lineLimit(imageURL == nil ? 7 : 2)
        }
    }

    @ViewBuilder private func pollContent(_ poll: ProfileGameAnnouncementPoll) -> some View {
        Label("Poll", systemImage: "chart.bar.fill").font(.interfaceSystem(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        Text(poll.question).font(.interfaceSystem(size: 14, weight: .semibold)).lineLimit(2)
        ForEach(poll.answers.prefix(3)) { answer in
            Text(answer.text).font(.interfaceSystem(size: 13)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, InterfaceScale.metric(10)).padding(.vertical, InterfaceScale.metric(6))
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: ProfileGameMetrics.thumbnailRadius))
        }
        if poll.answers.count > 3 {
            Text("\(poll.answers.count - 3) more options").font(.interfaceSystem(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            if let source = message.embedSource {
                if let icon = source.footer?.proxyIconURL ?? source.footer?.iconURL {
                    ProfileWidgetImageView(url: icon).frame(width: InterfaceScale.metric(14), height: InterfaceScale.metric(14))
                }
                if let name = source.footer?.text ?? source.provider?.name { Text("\(name) ·").lineLimit(1) }
            }
            if let expiry = message.poll?.expiry {
                Text(expiry > .now ? "Ends \(expiry.formatted(date: .abbreviated, time: .shortened))" : "Poll ended")
            } else {
                Text(message.timestamp.formatted(date: .abbreviated, time: .omitted))
            }
            Spacer(minLength: 0)
            if message.reactionCount > 0, message.poll == nil {
                HStack(spacing: InterfaceScale.metric(4)) {
                    Image(systemName: "face.smiling")
                    Text(message.reactionCount.formatted(.number.notation(.compactName)))
                }
            }
        }
        .font(.interfaceSystem(size: 12)).foregroundStyle(.secondary)
    }

    /// The body without lines that only ping, such as `@here` or a role the
    /// viewer can't resolve outside the game's server.
    private var previewBody: String {
        message.body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let isPingOnly = line.replacing(/<@&\d+>|@here|@everyone/, with: "").allSatisfy(\.isWhitespace)
                return !isPingOnly || line.allSatisfy(\.isWhitespace)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var imageURL: URL? {
        guard let media = message.media, let url = media.proxyURL ?? media.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let ratio = media.width.flatMap { width in media.height.flatMap { $0 > 0 && width > 0 ? Double(width) / Double($0) : nil } } ?? 16 / 9
        let width = ProfileGameGallery.supportedSize(Self.width * displayScale)
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "format", value: "webp"),
            URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "height", value: String(Int((Double(width) / ratio).rounded())))]
        return components.url
    }
}

struct ProfileGameDescription: View {
    let text: String
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    private static let collapsedLines = 5

    private var description: some View {
        Text(text).font(.interfaceSystem(size: 14)).lineSpacing(InterfaceScale.metric(3)).foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            description.lineLimit(expanded ? nil : Self.collapsedLines).textSelection(.enabled)
                .background {
                    description.fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
                .background {
                    description.lineLimit(Self.collapsedLines).fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedHeight = $0 }
                }
            if expanded || fullHeight > collapsedHeight + 1 {
                Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
                    .buttonStyle(.plain).pointerStyle(.link)
                    .font(.interfaceSystem(size: 13, weight: .semibold)).foregroundStyle(SakuraCordAccentColor.color)
            }
        }
    }
}
