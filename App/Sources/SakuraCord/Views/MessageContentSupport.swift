import MessageRendering
import SakuraCordModels
import SwiftUI

/// Resolves mention metadata for a message through the app model.
struct MessageMentionResolver {
    let model: AppModel
    let message: Message?

    init(model: AppModel, message: Message? = nil) {
        self.model = model
        self.message = message
    }

    func user(_ userID: UserID) -> User? {
        model.mentionUser(userID, in: message)
    }

    func presentation(_ mention: RenderedMention) -> MentionPresentation {
        model.mentionPresentation(mention, in: message)
    }

    func avatarURL(_ mention: RenderedMention) -> URL? {
        model.mentionAvatarURL(mention, in: message)
    }

    func label(_ mention: RenderedMention) -> String {
        presentation(mention).label
    }
}

struct CustomEmojiRichText: View {
    var model: AppModel?
    /// Resolves clicked user mentions the source message knows about.
    var message: Message?
    let content: String
    let emojiSize: CGFloat
    var baseFontSize: CGFloat?
    var maximumNumberOfLines: Int?
    var isSelectable = true
    var foregroundColor: NSColor?
    let mentionPresentation: (RenderedMention) -> MentionPresentation
    let onMentionClick: (MentionPresentation, StablePopoverAnchor) -> Void
    let onURLClick: (URL) -> Bool
    @State private var presentedMention: AnchoredMentionPresentation?

    init(
        model: AppModel? = nil,
        message: Message? = nil,
        content: String,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        maximumNumberOfLines: Int? = nil,
        isSelectable: Bool = true,
        foregroundColor: NSColor? = nil,
        mentionPresentation: @escaping (RenderedMention) -> MentionPresentation = {
            MentionPresentation.fallback(for: $0)
        },
        onMentionClick: @escaping (MentionPresentation, StablePopoverAnchor) -> Void = { _, _ in },
        onURLClick: @escaping (URL) -> Bool = { _ in false }
    ) {
        self.model = model
        self.message = message
        self.content = content
        self.emojiSize = emojiSize
        self.baseFontSize = baseFontSize
        self.maximumNumberOfLines = maximumNumberOfLines
        self.isSelectable = isSelectable
        self.foregroundColor = foregroundColor
        self.mentionPresentation = mentionPresentation
        self.onMentionClick = onMentionClick
        self.onURLClick = onURLClick
    }

    var body: some View {
        SelectableMessageTextView(
            model: model,
            source: content,
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,
            maximumNumberOfLines: maximumNumberOfLines,
            isSelectable: isSelectable,
            foregroundColor: foregroundColor,
            mentionPresentations: mentionPresentations,
            onMentionClick: handleMentionClick,
            onURLClick: onURLClick
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            if let model {
                AnchoredMentionPopoverLayer(
                    request: presentedMention,
                    model: model,
                    onDismiss: { presentedMention = nil }
                )
            }
        }
    }

    private var document: MessageDocument {
        MessageDocumentCache.shared.document(for: content)
    }

    private var mentionPresentations: [String: MentionPresentation] {
        document.segments.reduce(into: [:]) { values, segment in
            if case let .mention(mention) = segment {
                values[mention.rawToken] = mentionPresentation(mention)
            }
        }
    }

    private func handleMentionClick(
        _ mention: MentionPresentation,
        anchor: StablePopoverAnchor
    ) {
        onMentionClick(mention, anchor)
        guard let model else { return }
        switch mention.target {
        case .unresolved:
            return
        case let .user(id):
            let user = model.mentionUser(id, in: message)
                ?? model.membersByID[id]?.user
                ?? model.knownMentionMembers[id]?.user
            guard let user else { return }
            let requestID = model.showProfile(for: user)
            presentedMention = AnchoredMentionPresentation(
                mention: mention,
                anchor: anchor,
                profileRequestID: requestID
            )
        case let .role(id):
            model.showMembers(withRole: id, in: model.selectedGuildID)
            presentedMention = AnchoredMentionPresentation(
                mention: mention,
                anchor: anchor,
                profileRequestID: nil
            )
        case let .guildNavigation(guildID, destination):
            model.openGuildNavigationDestination(destination, in: guildID)
        case let .channel(id):
            model.navigate(to: id)
        case let .linkedChannel(guildID, channelID):
            model.navigate(to: guildID, linkedChannelID: channelID)
        case let .message(guildID, channelID, messageID):
            model.navigate(to: guildID, channelID: channelID, messageID: messageID)
        }
    }
}

struct AnchoredMentionPresentation: Identifiable {
    let id = UUID()
    let mention: MentionPresentation
    let anchor: StablePopoverAnchor
    let profileRequestID: UUID?
}

private struct AnchoredMentionPopoverLayer: View {
    let request: AnchoredMentionPresentation?
    let model: AppModel
    let onDismiss: () -> Void

    var body: some View {
        if let request {
            StableAnchoredPopoverPresenter(
                isPresented: true,
                anchor: request.anchor,
                configuration: configuration(for: request),
                onDismiss: onDismiss
            ) {
                switch request.mention.target {
                case let .user(id):
                    if let requestID = request.profileRequestID {
                        MessageProfilePopoverContent(
                            model: model,
                            userID: id,
                            requestID: requestID
                        )
                    }
                case let .role(id):
                    RoleMembersPopover(model: model, roleID: id, guildID: model.selectedGuildID)
                case .unresolved, .guildNavigation, .channel, .linkedChannel, .message:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func configuration(
        for request: AnchoredMentionPresentation
    ) -> StablePopoverConfiguration {
        switch request.mention.target {
        case .user:
            .memberProfile
        case .unresolved, .guildNavigation, .role, .channel, .linkedChannel, .message:
            .interactive
        }
    }
}

nonisolated struct LinkedImagePresentation: Sendable {
    private static let expression = RegularExpressionFactory.make(
        #"\[([^\]]+)\]\((https://[^\s)]+)\)"#
    )

    let visibleText: String
    let images: [LinkedImageReference]
    let matchedEmojiURLs: Set<URL>

    init(content: String) {
        let sourceRange = NSRange(content.startIndex ..< content.endIndex, in: content)
        let matches = Self.expression.matches(in: content, range: sourceRange)
        var references = matches.compactMap { match -> (NSRange, LinkedImageReference)? in
            guard let labelRange = Range(match.range(at: 1), in: content),
                  let urlRange = Range(match.range(at: 2), in: content),
                  let url = URL(string: String(content[urlRange])),
                  LinkedImageReference.isSupported(url)
            else { return nil }
            return (
                match.range(at: 0),
                LinkedImageReference(
                    id: "\(match.range(at: 0).location):\(url.absoluteString)",
                    label: String(content[labelRange]),
                    url: url
                )
            )
        }
        // Discord leaves an emoji link inside a spoiler as a spoilered link.
        if references.contains(where: { $0.1.linkedEmoji != nil }) {
            let spoilered = Self.spoileredMatchLocations(matches, in: content)
            references.removeAll {
                $0.1.linkedEmoji != nil && spoilered.contains($0.0.location)
            }
        }
        matchedEmojiURLs = Set(
            references.compactMap { reference in
                reference.1.linkedEmoji == nil ? nil : reference.1.url
            }
        )

        let rendersAsEmojiOnly = !references.isEmpty
            && references.allSatisfy { $0.1.linkedEmoji != nil }
            && Self.remainingText(
                in: content,
                removing: references.map(\.0)
            ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let presentedText = NSMutableString(string: content)
        if rendersAsEmojiOnly {
            images = []
            for reference in references.reversed() {
                guard let token = reference.1.linkedEmoji?.rawToken else {
                    continue
                }
                presentedText.replaceCharacters(in: reference.0, with: token)
            }
        } else {
            images = references.map(\.1)
            for reference in references.reversed()
            where reference.1.linkedEmoji == nil {
                presentedText.replaceCharacters(in: reference.0, with: "")
            }
        }
        visibleText = String(presentedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Give each masked-link target a distinct, parse-only identity. Matching
    /// by destination loses source identity when bare, angle-bracket, adjacent,
    /// or code-contained links share the same URL. Keep all surrounding syntax
    /// intact so the Markdown parser remains the authority on spoiler state.
    private static func spoileredMatchLocations(
        _ matches: [NSTextCheckingResult],
        in content: String
    ) -> Set<Int> {
        var prefix = "https://sakuracord.invalid/spoiler-match/"
        while content.contains(prefix) { prefix += "x/" }
        let marked = NSMutableString(string: content)
        var locations: [URL: Int] = [:]
        for (index, match) in matches.enumerated().reversed() {
            let marker = prefix + String(index)
            guard let url = URL(string: marker) else { continue }
            locations[url] = match.range.location
            marked.replaceCharacters(in: match.range(at: 2), with: marker)
        }
        return Set(DiscordMarkdown.linkOccurrences(String(marked)).compactMap {
            $0.isSpoiler ? locations[$0.url] : nil
        })
    }

    private static func remainingText(
        in content: String,
        removing ranges: [NSRange]
    ) -> String {
        let remaining = NSMutableString(string: content)
        for range in ranges.reversed() {
            remaining.replaceCharacters(in: range, with: "")
        }
        return remaining as String
    }
}

nonisolated struct LinkedImageReference: Identifiable, Hashable, Sendable {
    private static let trustedMediaHosts: Set<String> = [
        "cdn.discordapp.com",
        "media.discordapp.net"
    ]

    let id: String
    let label: String
    let url: URL

    var isEmoji: Bool {
        url.host?.lowercased() == "cdn.discordapp.com"
            && url.path.hasPrefix("/emojis/")
    }

    var linkedEmoji: EmojiReference? {
        guard isEmoji else { return nil }
        let filename = url.lastPathComponent
        let emojiID = (filename as NSString).deletingPathExtension
        guard !emojiID.isEmpty,
              emojiID.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value)
              })
        else { return nil }

        let queryName = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "name" })?.value
        let rawName = (queryName ?? label)
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: ":")
                )
            )
        guard !rawName.isEmpty,
              rawName.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value)
                      || (65 ... 90).contains($0.value)
                      || (97 ... 122).contains($0.value)
                      || $0.value == 95
              })
        else { return nil }

        let queryItems = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        let isAnimated =
            url.pathExtension.lowercased() == "gif"
            || queryItems.contains {
                $0.name == "animated" && $0.value?.lowercased() == "true"
            }
        return EmojiReference(
            id: emojiID,
            name: rawName,
            isAnimated: isAnimated
        )
    }

    var displayURL: URL {
        linkedEmoji?.imageURL(size: 96) ?? url
    }

    var isSticker: Bool {
        Self.trustedMediaHosts.contains(url.host?.lowercased() ?? "")
            && url.path.hasPrefix("/stickers/")
    }

    var displaySize: CGSize {
        if isEmoji { return CGSize(width: InterfaceScale.metric(48), height: InterfaceScale.metric(48)) }
        if isSticker { return CGSize(width: InterfaceScale.metric(160), height: InterfaceScale.metric(160)) }
        return CGSize(width: InterfaceScale.metric(360), height: InterfaceScale.metric(220))
    }

    static func isSupported(_ url: URL) -> Bool {
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "avif"])
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              trustedMediaHosts.contains(url.host?.lowercased() ?? "")
        else { return false }
        return imageExtensions.contains(url.pathExtension.lowercased())
            || (isCanonicalEmojiURL(url))
    }

    private static func isCanonicalEmojiURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "cdn.discordapp.com"
            && url.path.hasPrefix("/emojis/")
    }
}

struct EmojiWrappingLayout: Layout {
    private struct LayoutResult {
        let size: CGSize
        let positions: [CGPoint]
        let sizes: [CGSize]
    }

    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews
        )
        for (index, point) in result.positions.enumerated() where subviews.indices.contains(index) {
            let size = result.sizes[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maximumWidth = proposal.width ?? 640
        let sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: maximumWidth, height: nil))
        }
        let plan = InlineWrappingLayoutPlan.frames(
            sizes: sizes,
            maximumWidth: maximumWidth,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
        return LayoutResult(
            size: CGSize(width: proposal.width ?? plan.size.width, height: plan.size.height),
            positions: plan.frames.map(\.origin),
            sizes: plan.frames.map(\.size)
        )
    }
}

nonisolated enum InlineWrappingLayoutPlan {
    static func frames(
        sizes: [CGSize], maximumWidth: CGFloat, horizontalSpacing: CGFloat, verticalSpacing: CGFloat
    ) -> (size: CGSize, frames: [CGRect]) {
        guard !sizes.isEmpty else { return (.zero, []) }

        let widthLimit = max(1, maximumWidth)
        var frames: [CGRect] = []
        var horizontalOffset: CGFloat = 0
        var verticalOffset: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for proposedSize in sizes {
            let size = CGSize(
                width: min(widthLimit, max(0, proposedSize.width)),
                height: max(0, proposedSize.height)
            )
            if horizontalOffset > 0, horizontalOffset + size.width > widthLimit {
                horizontalOffset = 0
                verticalOffset += lineHeight + verticalSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: horizontalOffset, y: verticalOffset), size: size))
            usedWidth = max(usedWidth, horizontalOffset + size.width)
            horizontalOffset += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        return (CGSize(width: usedWidth, height: verticalOffset + lineHeight), frames)
    }
}
