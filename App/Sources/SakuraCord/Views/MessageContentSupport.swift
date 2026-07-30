import MessageRendering
import SakuraCordModels
import SwiftUI

struct MessageMentionResolver {
    let model: AppModel
    let message: Message?

    init(model: AppModel, message: Message? = nil) {
        self.model = model
        self.message = message
    }

    func user(_ userID: UserID) -> User? {
        model.membersByID[userID]?.user
            ?? model.knownMentionMembers[userID]?.user
            ?? message?.mentionedUsers.first { $0.id == userID }
            ?? model.messages.first { $0.author.id == userID }?.author
            ?? model.threadMessages.first { $0.author.id == userID }?.author
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
            let role = model.guildRoles.first { $0.id == roleID }
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
            let post = model.forumCataloguePosts.first { $0.id == channelID }
                ?? model.forumPosts.first { $0.id == channelID }
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
        model.snapshot?.channels.first { $0.id == channelID }
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
            model: model,
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
                ?? model.messages.first { $0.author.id == id }?.author
                ?? model.threadMessages.first { $0.author.id == id }?.author
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

nonisolated struct LinkedImagePresentation: Sendable {
    private static let expression = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\((https://[^\s)]+)\)"#
    )

    let visibleText: String
    let images: [LinkedImageReference]
    let matchedEmojiURLs: Set<URL>

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
        if isEmoji { return CGSize(width: 48, height: 48) }
        if isSticker { return CGSize(width: 160, height: 160) }
        return CGSize(width: 360, height: 220)
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
