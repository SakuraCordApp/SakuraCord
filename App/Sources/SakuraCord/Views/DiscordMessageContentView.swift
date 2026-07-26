import MessageRendering
import SakuraCordModels
import SwiftUI

struct DiscordMessageContentView: View {
    private static let jumboEmojiSize: CGFloat = 48

    let model: AppModel
    let message: Message
    let content: String

    private let presentation: LinkedImagePresentation
    @State private var presentedMention: AnchoredMentionPresentation?

    init(model: AppModel, message: Message, content: String) {
        self.model = model
        self.message = message
        self.content = content
        presentation = LinkedImagePresentation(content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !presentation.visibleText.isEmpty {
                CustomEmojiRichText(
                    content: presentation.visibleText,
                    emojiSize: document.isEmojiOnly ? Self.jumboEmojiSize : 22,
                    mentionPresentation: resolver.presentation,
                    onMentionClick: openMention,
                    onURLClick: openURL
                )
            }
            if !presentation.images.isEmpty {
                EmojiWrappingLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(presentation.images) { image in
                        LinkedMessageImage(image: image)
                    }
                }
            }
        }
        .overlay {
            AnchoredMentionPopoverLayer(
                request: presentedMention,
                model: model,
                onDismiss: { presentedMention = nil }
            )
        }
    }

    private var document: MessageDocument {
        MessageDocumentCache.shared.document(for: presentation.visibleText)
    }

    private var resolver: MessageMentionResolver {
        MessageMentionResolver(model: model, message: message)
    }

    private func openMention(
        _ mention: MentionPresentation,
        anchor: StablePopoverAnchor
    ) {
        switch mention.target {
        case .unresolved:
            return
        case let .user(id):
            guard let user = resolver.user(id) else { return }
            model.showProfile(for: user)
            presentedMention = AnchoredMentionPresentation(
                mention: mention,
                anchor: anchor
            )
        case let .role(id):
            model.showMembers(withRole: id)
            presentedMention = AnchoredMentionPresentation(
                mention: mention,
                anchor: anchor
            )
        case let .channel(id):
            model.navigate(to: id)
        case let .linkedChannel(guildID, channelID):
            model.navigate(to: guildID, linkedChannelID: channelID)
        case let .message(guildID, channelID, messageID):
            model.navigate(to: guildID, channelID: channelID, messageID: messageID)
        }
    }

    private func openURL(_ url: URL) -> Bool {
        guard let link = DiscordChannelLink(url) else { return false }
        model.navigate(to: link.guildID, linkedChannelID: link.channelID)
        return true
    }
}

struct MessageMentionResolver {
    let model: AppModel
    let message: Message?

    init(model: AppModel, message: Message? = nil) {
        self.model = model
        self.message = message
    }

    /// Resolves entirely from indexed stores.
    ///
    /// This previously scanned `model.messages` and `model.threadMessages`,
    /// which was an O(messages) walk per mention per render and an observation
    /// dependency on the timeline, so every new message re-rendered every
    /// mention-bearing row. `messageAuthorsByID` preserves that fallback.
    func user(_ userID: UserID) -> User? {
        model.membersByID[userID]?.user
            ?? model.knownMentionMembers[userID]?.user
            ?? message?.mentionedUsers.first { $0.id == userID }
            ?? model.messageAuthorsByID[userID]
            ?? (model.snapshot?.currentUser.id == userID ? model.snapshot?.currentUser : nil)
    }

    func presentation(_ mention: RenderedMention) -> MentionPresentation {
        switch mention.kind {
        case .user:
            guard let userID = UserID(mention.id) else {
                return MentionPresentation.fallback(for: mention)
            }
            let member = model.membersByID[userID]
                ?? model.knownMentionMembers[userID]
            let value = user(userID)
            let topColor = member.flatMap {
                MessageAuthorPresentation.topRoleColor(in: $0.roles)
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "@\(member?.user.displayName ?? value?.displayName ?? "unknown-user")",
                target: .user(userID),
                avatarURL: member?.guildAvatarURL ?? value?.avatarURL,
                colorHex: topColor
            )
        case .role:
            guard let roleID = RoleID(mention.id) else {
                return MentionPresentation.fallback(for: mention)
            }
            let role = model.guildRolesByID[roleID]
                ?? model.members.lazy.flatMap(\.roles).first { $0.id == roleID }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: "@\(role?.name ?? "unknown-role")",
                target: .role(roleID),
                colorHex: role?.colorHex
            )
        case .channel:
            guard let channelID = ChannelID(mention.id) else {
                return MentionPresentation.fallback(for: mention)
            }
            let channel = channel(channelID)
            let crossesGuild = crossesGuild(targetGuildID: channel?.guildID)
            let guildName = channel?.guildID.flatMap { model.serverRailGuildsByID[$0]?.name }
            let label = if crossesGuild, let guildName, let channel {
                "\(guildName) / \(channel.name)"
            } else {
                channel?.name ?? "unknown-channel"
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: label,
                target: .channel(channelID),
                systemImage: ChannelIconPresentation.systemImage(
                    for: channel?.kind ?? .unknown,
                    isHidden: false
                )
            )
        case .channelLink:
            guard let channelID = ChannelID(mention.id) else {
                return MentionPresentation.fallback(for: mention)
            }
            let guildID = mention.messageGuildID.flatMap(GuildID.init)
            if let channel = channel(channelID) {
                let guildName = channel.guildID.flatMap { model.serverRailGuildsByID[$0]?.name }
                let label = if crossesGuild(targetGuildID: channel.guildID), let guildName {
                    "\(guildName) / \(channel.name)"
                } else {
                    channel.name
                }
                return MentionPresentation(
                    rawToken: mention.rawToken,
                    label: label,
                    target: .channel(channelID),
                    systemImage: ChannelIconPresentation.systemImage(
                        for: channel.kind,
                        isHidden: false
                    )
                )
            }
            let post = model.forumPost(withID: channelID)
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: post?.thread.name ?? "unknown-post",
                target: .linkedChannel(guildID: guildID, channelID: channelID),
                systemImage: ChannelIconPresentation.forumPostSystemImage
            )
        case .message:
            guard let rawChannelID = mention.messageChannelID,
                  let channelID = ChannelID(rawChannelID),
                  let messageID = MessageID(mention.id)
            else {
                return MentionPresentation.fallback(for: mention)
            }
            let guildID = mention.messageGuildID.flatMap(GuildID.init)
            let channel = channel(channelID)
            let guildName = guildID.flatMap { model.serverRailGuildsByID[$0]?.name }
            let channelLabel = if crossesGuild(targetGuildID: guildID),
                                  let guildName,
                                  let channel
            {
                "\(guildName) / \(channel.name) ›"
            } else {
                "\(channel?.name ?? "unknown-channel") ›"
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: channelLabel,
                target: .message(
                    guildID: guildID,
                    channelID: channelID,
                    messageID: messageID
                ),
                systemImage: "bubble.left.fill"
            )
        }
    }

    private func channel(_ channelID: ChannelID) -> Channel? {
        model.channelsByID[channelID]
            ?? model.visibleChannels.first { $0.id == channelID }
    }

    private var sourceGuildID: GuildID? {
        if let guildID = message?.guildID { return guildID }
        if let channelID = message?.channelID { return channel(channelID)?.guildID }
        return model.selectedGuildID
    }

    private func crossesGuild(targetGuildID: GuildID?) -> Bool {
        guard let targetGuildID, let sourceGuildID else { return false }
        return targetGuildID != sourceGuildID
    }

    func label(_ mention: RenderedMention) -> String {
        presentation(mention).label
    }
}

struct CustomEmojiRichText: View {
    var model: AppModel?
    let content: String
    let emojiSize: CGFloat
    let mentionPresentation: (RenderedMention) -> MentionPresentation
    let onMentionClick: (MentionPresentation, StablePopoverAnchor) -> Void
    let onURLClick: (URL) -> Bool
    @State private var presentedMention: AnchoredMentionPresentation?

    init(
        model: AppModel? = nil,
        content: String,
        emojiSize: CGFloat,
        mentionPresentation: @escaping (RenderedMention) -> MentionPresentation = {
            MentionPresentation.fallback(for: $0)
        },
        onMentionClick: @escaping (MentionPresentation, StablePopoverAnchor) -> Void = { _, _ in },
        onURLClick: @escaping (URL) -> Bool = { _ in false }
    ) {
        self.model = model
        self.content = content
        self.emojiSize = emojiSize
        self.mentionPresentation = mentionPresentation
        self.onMentionClick = onMentionClick
        self.onURLClick = onURLClick
    }

    var body: some View {
        SelectableMessageTextView(
            source: content,
            emojiSize: emojiSize,
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
            let user = model.membersByID[id]?.user
                ?? model.knownMentionMembers[id]?.user
                ?? model.messageAuthorsByID[id]
                ?? (model.snapshot?.currentUser.id == id ? model.snapshot?.currentUser : nil)
            guard let user else { return }
            model.showProfile(for: user)
            presentedMention = AnchoredMentionPresentation(
                mention: mention,
                anchor: anchor
            )
        case let .role(id):
            model.showMembers(withRole: id)
            presentedMention = AnchoredMentionPresentation(
                mention: mention,
                anchor: anchor
            )
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
                configuration: .interactive,
                onDismiss: onDismiss
            ) {
                switch request.mention.target {
                case let .user(id):
                    MessageProfilePopoverContent(model: model, userID: id)
                case let .role(id):
                    RoleMembersPopover(model: model, roleID: id)
                case .unresolved, .channel, .linkedChannel, .message:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CustomEmojiGlyph: View {
    let emoji: RenderedEmoji
    let size: CGFloat

    init(emoji: RenderedEmoji, size: CGFloat) {
        self.emoji = emoji
        self.size = size
    }

    init?(token: String, size: CGFloat) {
        guard let emoji = RenderedEmoji(rawToken: token) else { return nil }
        self.init(emoji: emoji, size: size)
    }

    var body: some View {
        if let url = emoji.imageURL {
            AnimatedRemoteImage(url: url, fallbackSystemImage: "face.smiling")
                .frame(width: size, height: size)
                .help(":\(emoji.name):")
                .accessibilityLabel(emoji.name)
        } else {
            Text(emoji.rawToken)
        }
    }
}

struct ParsedCustomEmoji {
    let value: RenderedEmoji
    init?(token: String) {
        guard let value = RenderedEmoji(rawToken: token) else { return nil }
        self.value = value
    }

    var name: String {
        value.name
    }

    var id: String {
        value.id
    }

    var isAnimated: Bool {
        value.isAnimated
    }

    var imageURL: URL? {
        value.imageURL
    }
}

private struct LinkedMessageImage: View {
    let image: LinkedImageReference

    var body: some View {
        Link(destination: image.url) {
            AnimatedRemoteImage(
                url: image.url,
                isLooping: true,
                fallbackSystemImage: image.isEmoji ? "face.smiling" : "photo"
            )
            .frame(width: image.displaySize.width, height: image.displaySize.height)
            .background(image.isEmoji ? Color.clear : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: image.isEmoji ? 7 : 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(image.label)
        .accessibilityLabel(image.label)
    }
}

struct LinkedImagePresentation {
    private static let expression = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\((https://[^\s)]+)\)"#
    )

    let visibleText: String
    let images: [LinkedImageReference]

    init(content: String) {
        let sourceRange = NSRange(content.startIndex ..< content.endIndex, in: content)
        let references = Self.expression.matches(in: content, range: sourceRange).compactMap {
            match -> (NSRange, LinkedImageReference)? in
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
        images = references.map(\.1)
        let textWithoutMedia = NSMutableString(string: content)
        for reference in references.reversed() {
            textWithoutMedia.replaceCharacters(in: reference.0, with: "")
        }
        visibleText = String(textWithoutMedia).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LinkedImageReference: Identifiable {
    let id: String
    let label: String
    let url: URL

    var isEmoji: Bool {
        url.host == "cdn.discordapp.com" && url.path.hasPrefix("/emojis/")
    }

    var isSticker: Bool {
        (url.host == "cdn.discordapp.com" || url.host == "media.discordapp.net")
            && url.path.hasPrefix("/stickers/")
    }

    var displaySize: CGSize {
        if isEmoji { return CGSize(width: 48, height: 48) }
        if isSticker { return CGSize(width: 160, height: 160) }
        return CGSize(width: 360, height: 220)
    }

    static func isSupported(_ url: URL) -> Bool {
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "avif"])
        return imageExtensions.contains(url.pathExtension.lowercased())
            || (url.host == "cdn.discordapp.com" && url.path.hasPrefix("/emojis/"))
    }
}

struct EmojiWrappingLayout: Layout {
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

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (
        size: CGSize, positions: [CGPoint], sizes: [CGSize]
    ) {
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
        return (
            CGSize(width: proposal.width ?? plan.size.width, height: plan.size.height),
            plan.frames.map(\.origin),
            plan.frames.map(\.size)
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
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for proposedSize in sizes {
            let size = CGSize(
                width: min(widthLimit, max(0, proposedSize.width)),
                height: max(0, proposedSize.height)
            )
            if x > 0, x + size.width > widthLimit {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        return (CGSize(width: usedWidth, height: y + lineHeight), frames)
    }
}
