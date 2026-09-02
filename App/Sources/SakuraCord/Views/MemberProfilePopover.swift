import AppKit
import SakuraCordModels
import SwiftUI

enum ProfilePresentationLayout {
    case popover
    case inspector
}

struct ProfilePresentationContent<Footer: View>: View {
    let presentation: ProfilePresentationState
    var layout: ProfilePresentationLayout = .popover
    var maximumPopoverHeight: CGFloat = 560
    var showsRoles = true
    let footer: Footer

    init(
        presentation: ProfilePresentationState,
        layout: ProfilePresentationLayout = .popover,
        maximumPopoverHeight: CGFloat = 560,
        showsRoles: Bool = true,
        @ViewBuilder footer: () -> Footer
    ) {
        self.presentation = presentation
        self.layout = layout
        self.maximumPopoverHeight = maximumPopoverHeight
        self.showsRoles = showsRoles
        self.footer = footer()
    }

    var body: some View {
        MemberProfilePopover(
            member: presentation.member,
            profile: presentation.profile,
            isLoading: presentation.isLoading,
            errorMessage: presentation.errorMessage,
            layout: layout,
            maximumPopoverHeight: maximumPopoverHeight,
            showsRoles: showsRoles,
            footer: footer
        )
    }
}

extension ProfilePresentationContent where Footer == EmptyView {
    init(
        presentation: ProfilePresentationState,
        layout: ProfilePresentationLayout = .popover,
        maximumPopoverHeight: CGFloat = 560,
        showsRoles: Bool = true
    ) {
        self.init(
            presentation: presentation,
            layout: layout,
            maximumPopoverHeight: maximumPopoverHeight,
            showsRoles: showsRoles
        ) {
            EmptyView()
        }
    }
}

struct MemberProfilePopover<Footer: View>: View {
    static var preferredWidth: CGFloat { 330 }

    let member: Member
    let profile: UserProfile?
    let isLoading: Bool
    let errorMessage: String?
    var layout: ProfilePresentationLayout = .popover
    var maximumPopoverHeight: CGFloat = 560
    var showsRoles = true
    let footer: Footer

    @Environment(\.stablePopoverPresentationContext)
    private var popoverPresentationContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        Group {
            switch layout {
            case .popover:
                profileContent
                    .frame(
                        width: width,
                        height: min(
                            contentHeight + surfaceInset * 2,
                            maximumPopoverHeight
                        )
                    )
                    .background { popoverBackground }
            case .inspector:
                profileContent
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                    .background { inspectorBackground }
            }
        }
        .onPreferenceChange(ProfileContentHeightKey.self) { newHeight in
            guard newHeight.isFinite, newHeight > 0 else { return }
            contentHeight = max(250, newHeight)
        }
    }

    private var profileContent: some View {
        ZStack(alignment: .top) {
            if !profileThemeHexes.isEmpty {
                ConcentricRectangle(
                    cornerRadius: innerCornerRadius,
                    style: .continuous
                )
                    .fill(ProfilePalette.innerSurfaceOverlay(for: colorScheme))
                    .padding(surfaceInset)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ProfileHeroSection(
                        member: member,
                        profile: profile,
                        themeHexes: profileThemeHexes,
                        avatarCutoutColor: ProfilePalette.innerSurfaceColor(
                            themeHexes: profileThemeHexes,
                            colorScheme: colorScheme
                        ),
                        topCornerRadius: layout == .popover ? 16 : 0,
                        statusBubbleWidth: statusBubbleWidth,
                        animatesRemoteMedia: animatesRemoteMedia
                    )
                    .zIndex(10)

                    if isLoading {
                        HStack(spacing: 9) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading full profile…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 18)
                    }

                    if let profile {
                        ProfileMutualSummary(
                            guilds: profile.mutualGuilds,
                            friends: profile.mutualFriends,
                            mutualFriendCount: profile.mutualFriendsCount,
                            layout: layout
                        )
                        if let bio = profile.bio, !bio.isEmpty {
                            ProfileAboutSection(bio: bio)
                        }
                        if showsRoles, !profile.roles.isEmpty {
                            ProfileRolesSection(roles: profile.roles)
                                .id(profile.id)
                        }
                        if !profile.connectedAccounts.isEmpty {
                            ProfileConnectionsSection(accounts: profile.connectedAccounts)
                        }
                    }

                    footer
                }
                .padding(.bottom, 14)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ProfileContentHeightKey.self, value: proxy.size.height)
                    }
                }
            }
            .scrollIndicators(contentHeight > maximumPopoverHeight ? .visible : .hidden)
            .padding(surfaceInset)

            if let effect = profile?.effect {
                ProfileEffectOverlay(
                    effect: effect,
                    animates: animatesRemoteMedia
                )
                    .zIndex(100)
            }
        }
    }

    @ViewBuilder
    private var popoverBackground: some View {
        if profileThemeHexes.count >= 2 {
            LinearGradient(
                colors: profileThemeHexes.prefix(2).map(Color.init(hex:)),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var inspectorBackground: some View {
        if profileThemeHexes.count >= 2 {
            LinearGradient(
                colors: profileThemeHexes.prefix(2).map(Color.init(hex:)),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(nsColor: .controlBackgroundColor).opacity(0.62)
        }
    }

    private var profileThemeHexes: [UInt32] {
        profile?.themeHexes ?? []
    }

    private var animatesRemoteMedia: Bool {
        popoverPresentationContext?.hasFinishedPresenting ?? true
    }

    private var surfaceInset: CGFloat {
        layout == .popover ? 3 : 0
    }

    private var innerCornerRadius: CGFloat {
        layout == .popover ? 16 : 0
    }

    private var width: CGFloat {
        Self.preferredWidth
    }

    private var statusBubbleWidth: CGFloat {
        guard layout == .inspector else { return 194 }
        let leadingAnchor: CGFloat = 97
        let trailingInset: CGFloat = 16
        let bubbleHorizontalPadding: CGFloat = 22
        return max(
            80,
            ChatChromeMetrics.memberListWidth
                - leadingAnchor
                - trailingInset
                - bubbleHorizontalPadding
        )
    }
}

private struct ProfileContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 320
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ProfileHeroSection: View {
    let member: Member
    let profile: UserProfile?
    let themeHexes: [UInt32]
    let avatarCutoutColor: Color
    let topCornerRadius: CGFloat
    let statusBubbleWidth: CGFloat
    let animatesRemoteMedia: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileBanner(
                url: profile?.bannerURL,
                accentHex: profile?.accentHex,
                themeHexes: themeHexes,
                topCornerRadius: topCornerRadius,
                animates: animatesRemoteMedia
            )
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(.black)
                        .frame(width: 84.4, height: 84.4)
                        .offset(x: 16, y: 58)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()

            HStack(alignment: .bottom, spacing: 6) {
                AvatarPresenceView(
                    status: profile?.status ?? member.status,
                    avatarSize: 70,
                    indicatorSize: 15
                ) {
                    DecoratedAvatarView(
                        name: profile?.displayName ?? member.user.displayName,
                        avatarURL: profile?.avatarURL ?? member.guildAvatarURL ?? member.user.avatarURL,
                        decorationURL: profile?.user.avatarDecorationURL ?? member.user.avatarDecorationURL,
                        size: 70,
                        animatesDecoration: animatesRemoteMedia
                    )
                    .padding(3)
                }
                .offset(y: -34)

                Spacer(minLength: 0)
            }
            .frame(height: 44)
            .padding(.horizontal, 16)

            ProfileIdentitySection(
                displayName: profile?.displayName ?? member.user.displayName,
                username: profile?.user.username ?? member.user.username,
                pronouns: profile?.pronouns,
                legacyUsername: profile?.legacyUsername,
                nameStyle: profile?.user.displayNameStyle ?? member.user.displayNameStyle,
                primaryGuildIdentity: profile?.user.primaryGuild ?? member.user.primaryGuild,
                isBot: profile?.user.isBot ?? member.user.isBot,
                badges: profile?.badges ?? [],
                premiumSince: profile?.premiumSince,
                premiumGuildSince: profile?.premiumGuildSince
            )
            .padding(.horizontal, 16)
        }
        .overlay(alignment: .topLeading) {
            if let customStatus = profile?.customStatus ?? member.customStatus, !customStatus.isEmpty {
                ProfileStatusThoughtDots(surfaceColor: avatarCutoutColor)
                    .offset(x: 82, y: 106)
                    .allowsHitTesting(false)

                ProfileStatusBubble(
                    text: customStatus,
                    surfaceColor: avatarCutoutColor,
                    width: statusBubbleWidth
                )
                    .offset(x: 97, y: 118)
            }
        }
    }
}

private struct ProfileStatusBubble: View {
    let text: String
    let surfaceColor: Color
    let width: CGFloat
    @State private var isBubbleHovering = false
    @State private var isTextHovering = false

    var body: some View {
        let isExpanded = isBubbleHovering || isTextHovering

        ProfileStatusTextView(
            source: text,
            isExpanded: isExpanded,
            onHoverChange: { isTextHovering = $0 }
        )
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .background(surfaceColor, in: ConcentricRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                ConcentricRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.14), lineWidth: 1)
            }
            .contentShape(ConcentricRectangle(cornerRadius: 14, style: .continuous))
            .onHover { isBubbleHovering = $0 }
            .animation(.snappy(duration: 0.16), value: isExpanded)
            .help(displayText)
            .accessibilityLabel("Custom status: \(displayText)")
            .zIndex(2)
    }

    private var displayText: String {
        text.replacingOccurrences(
            of: #"<a?:([A-Za-z0-9_~]+):[0-9]+>"#,
            with: ":$1:",
            options: .regularExpression
        )
    }
}

private struct ProfileStatusThoughtDots: View {
    let surfaceColor: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(surfaceColor)
                .frame(width: 6, height: 6)
                .offset(x: 1, y: 1)
            Circle()
                .fill(surfaceColor)
                .frame(width: 10, height: 10)
                .offset(x: 8, y: 8)
        }
        .frame(width: 18, height: 18)
    }
}

private struct ProfileBanner: View {
    let url: URL?
    let accentHex: UInt32?
    let themeHexes: [UInt32]
    let topCornerRadius: CGFloat
    let animates: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = ProfileBannerLayout.constrainedWidth(proxy.size.width)

            ZStack {
                LinearGradient(
                    colors: ProfilePalette.banner(themeHexes: themeHexes, accentHex: accentHex),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let url {
                    AnimatedRemoteImage(
                        url: url,
                        animates: animates,
                        maximumPixelDimension: 600,
                        contentMode: .fill,
                        accessibilityCategory: .decoration
                    )
                    .frame(width: width, height: ProfileBannerLayout.height)
                    .clipped()
                }
            }
            .frame(width: width, height: ProfileBannerLayout.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ProfileBannerLayout.height)
        .clipShape(
            ConcentricRectangle(
                topLeadingCorner: .concentric(
                    minimum: .fixed(topCornerRadius)
                ),
                topTrailingCorner: .concentric(
                    minimum: .fixed(topCornerRadius)
                ),
                bottomLeadingCorner: .fixed(0),
                bottomTrailingCorner: .fixed(0)
            )
        )
    }
}

nonisolated enum ProfileBannerLayout {
    static let height: CGFloat = 112

    static func constrainedWidth(_ proposedWidth: CGFloat) -> CGFloat {
        guard proposedWidth.isFinite else { return 0 }
        return max(0, proposedWidth)
    }
}

private struct ProfileIdentitySection: View {
    let displayName: String
    let username: String
    let pronouns: String?
    let legacyUsername: String?
    let nameStyle: DisplayNameStyle?
    let primaryGuildIdentity: PrimaryGuildIdentity?
    let isBot: Bool
    let badges: [ProfileBadge]
    let premiumSince: Date?
    let premiumGuildSince: Date?

    var body: some View {
        let hasPronouns = pronouns?.isEmpty == false

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(nameGradient)
                    .textSelection(.enabled)
                    .tint(SakuraCordAccentColor.color)
                if isBot {
                    Text("APP")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(.indigo, in: ConcentricRectangle(cornerRadius: 5))
                }
            }
            HStack(spacing: 6) {
                CopyableProfileUsername(
                    username: username,
                    usesSeparatorSlot: hasPronouns
                )
                    .layoutPriority(1)
                if let pronouns, !pronouns.isEmpty {
                    Text(pronouns)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let primaryGuildIdentity, let tag = primaryGuildIdentity.tag, !tag.isEmpty {
                    ProfileGuildIdentity(identity: primaryGuildIdentity, tag: tag)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            if !badges.isEmpty {
                ProfileBadgesRow(
                    badges: badges,
                    legacyUsername: legacyUsername,
                    premiumSince: premiumSince,
                    premiumGuildSince: premiumGuildSince
                )
                .padding(.top, 3)
            }
        }
    }

    private var nameGradient: LinearGradient {
        let colors = nameStyle?.colors.map(Color.init(hex:)) ?? []
        return LinearGradient(
            colors: colors.isEmpty ? [.primary] : colors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct CopyableProfileUsername: View {
    let username: String
    let usesSeparatorSlot: Bool

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        let isActive = isHovering || didCopy

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(username, forType: .string)
            didCopy = true
        } label: {
            HStack(spacing: 4) {
                Text(username)
                    .lineLimit(1)
                if usesSeparatorSlot {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .opacity(isActive ? 0 : 1)
                        .overlay {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .opacity(isActive ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .frame(width: 12)
                } else if isActive {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .font(.callout)
            .foregroundStyle(isActive ? .primary : .secondary)
            .background {
                ConcentricRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.09 : 0))
                    .padding(.horizontal, -5)
                    .padding(.vertical, -2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: didCopy)
        .help(didCopy ? "Username copied" : "Copy username")
        .accessibilityLabel("Username \(username)")
        .accessibilityHint("Copies the username")
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

private struct ProfileBadgesRow: View {
    let badges: [ProfileBadge]
    let legacyUsername: String?
    let premiumSince: Date?
    let premiumGuildSince: Date?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(badges) { badge in
                ProfileBadgeIcon(
                    badge: badge,
                    legacyUsername: legacyUsername,
                    premiumSince: premiumSince,
                    premiumGuildSince: premiumGuildSince
                )
            }
        }
    }
}

private struct ProfileBadgeIcon: View {
    let badge: ProfileBadge
    let legacyUsername: String?
    let premiumSince: Date?
    let premiumGuildSince: Date?
    @State private var isShowingDetails = false

    var body: some View {
        Group {
            if let iconURL = badge.iconURL {
                AsyncImage(url: iconURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().controlSize(.mini)
                }
            } else {
                Image(systemName: isNitroBadge ? "bolt.fill" : "checkmark.seal.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.cyan)
            }
        }
        .frame(width: 23, height: 23)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { isShowingDetails = $0 }
        .nativeHoverPopover(isPresented: $isShowingDetails) {
            Text(helpText)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private var normalizedBadgeID: String {
        badge.id.lowercased()
    }

    private var normalizedDescription: String {
        badge.description.lowercased()
    }

    private var isNitroBadge: Bool {
        normalizedBadgeID == "nitro"
            || normalizedBadgeID.hasPrefix("premium")
            || normalizedDescription.contains("nitro")
    }

    private var isBoostBadge: Bool {
        normalizedBadgeID.contains("guild_booster")
            || normalizedBadgeID.contains("guild_boost")
            || normalizedDescription.contains("server boost")
    }

    private var isLegacyUsernameBadge: Bool {
        normalizedBadgeID.contains("legacy_username")
            || normalizedDescription.contains("originally known")
    }

    private var helpText: String {
        var description = badge.description
        if isLegacyUsernameBadge, let legacyUsername, !legacyUsername.isEmpty {
            description = description.replacingOccurrences(of: "{USERNAME}", with: legacyUsername)
        }
        var lines = [description]
        if isNitroBadge, let premiumSince, !description.localizedCaseInsensitiveContains("since") {
            lines.append("Nitro subscriber since \(premiumSince.formatted(.dateTime.month(.wide).year()))")
        }
        if isBoostBadge, let premiumGuildSince, !description.localizedCaseInsensitiveContains("since") {
            lines.append("Boosting this server since \(premiumGuildSince.formatted(.dateTime.month(.wide).year()))")
        }
        if isLegacyUsernameBadge,
           let legacyUsername,
           !legacyUsername.isEmpty,
           !description.localizedCaseInsensitiveContains(legacyUsername)
        {
            lines.append("Originally known as \(legacyUsername)")
        }
        return lines.joined(separator: " • ")
    }
}

private struct ProfileMutualSummary: View {
    let guilds: [MutualGuild]
    let friends: [User]
    let mutualFriendCount: Int
    let layout: ProfilePresentationLayout

    @State private var presentedList: MutualList?

    var body: some View {
        if !guilds.isEmpty || mutualFriendCount > 0 {
            HStack(spacing: layout == .inspector ? 8 : 14) {
                if !guilds.isEmpty {
                    Button {
                        presentedList = .servers
                    } label: {
                        Label(countLabel(guilds.count, singular: "Mutual Server", plural: "Mutual Servers"), systemImage: "server.rack")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                if mutualFriendCount > 0 {
                    Button {
                        presentedList = .friends
                    } label: {
                        Label(countLabel(mutualFriendCount, singular: "Mutual Friend", plural: "Mutual Friends"), systemImage: "person.2.fill")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(
                layout == .inspector
                    ? .caption.weight(.medium)
                    : .callout.weight(.medium)
            )
            .foregroundStyle(.secondary)
            .padding(.horizontal, layout == .inspector ? 14 : 16)
            .popover(item: $presentedList, arrowEdge: .trailing) { list in
                switch list {
                case .servers:
                    ProfileMutualGuildsList(guilds: guilds)
                case .friends:
                    ProfileMutualFriendsList(friends: friends, totalCount: mutualFriendCount)
                }
            }
        }
    }

    private func countLabel(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private enum MutualList: String, Identifiable {
        case servers, friends
        var id: String {
            rawValue
        }
    }
}

private struct ProfileAboutSection: View {
    let bio: String?

    var body: some View {
        if let bio, !bio.isEmpty {
            ProfileRichTextView(source: bio)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProfileRolesSection: View {
    let roles: [GuildRole]
    @State private var isExpanded = false

    private var normalizedRoles: [ProfileRoleItem] {
        roles.compactMap { role in
            let name = ProfileRolePresentation.normalizedName(role.name)
            guard !name.isEmpty else { return nil }
            return ProfileRoleItem(role: role, name: name)
        }
    }

    private var visibleRoles: ArraySlice<ProfileRoleItem> {
        isExpanded
            ? normalizedRoles[...]
            : normalizedRoles.prefix(ProfileRolePresentation.collapsedLimit)
    }

    private var hiddenCount: Int {
        max(0, normalizedRoles.count - visibleRoles.count)
    }

    var body: some View {
        ProfileRoleFlowLayout(spacing: 6) {
            ForEach(visibleRoles) { item in
                RoleChip(item: item)
            }
            if hiddenCount > 0 {
                RoleExpansionButton(label: "+\(hiddenCount)") {
                    isExpanded = true
                }
                .help("Show \(hiddenCount) more roles")
            } else if isExpanded, normalizedRoles.count > ProfileRolePresentation.collapsedLimit {
                RoleExpansionButton(systemImage: "chevron.left") {
                    isExpanded = false
                }
                .help("Collapse roles")
            }
        }
        .animation(.snappy(duration: 0.18), value: isExpanded)
        .padding(.horizontal, 16)
    }
}

private struct RoleChip: View {
    let item: ProfileRoleItem

    var body: some View {
        HStack(spacing: 6) {
            RoleColorIndicator(colorHex: item.role.colorHex, size: 10)
            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.black.opacity(0.2), in: ConcentricRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            ConcentricRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
        .help(item.name)
    }
}

private struct RoleExpansionButton: View {
    let label: String?
    let systemImage: String?
    let action: () -> Void
    @State private var isHovering = false

    init(label: String, action: @escaping () -> Void) {
        self.label = label
        systemImage = nil
        self.action = action
    }

    init(systemImage: String, action: @escaping () -> Void) {
        label = nil
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .font(.callout.weight(.medium))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(isHovering ? Color.primary.opacity(0.12) : .black.opacity(0.16), in: ConcentricRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            ConcentricRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(isHovering ? 0.16 : 0.09), lineWidth: 1)
        }
        .onHover { isHovering = $0 }
    }
}

struct ProfileRoleItem: Identifiable {
    var id: RoleID {
        role.id
    }

    let role: GuildRole
    let name: String
}

enum ProfileRolePresentation {
    static let collapsedLimit = 5

    static func normalizedName(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"<a?:[A-Za-z0-9_~]+:[0-9]+>"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct ProfileRoleFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let availableWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var horizontalOffset: CGFloat = 0
        var verticalOffset: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if horizontalOffset > 0, horizontalOffset + size.width > availableWidth {
                horizontalOffset = 0
                verticalOffset += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: horizontalOffset, y: verticalOffset))
            horizontalOffset += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, horizontalOffset - spacing)
        }

        let width = availableWidth.isFinite ? availableWidth : usedWidth
        return (CGSize(width: width, height: verticalOffset + rowHeight), origins)
    }
}

private struct ProfileMutualGuildsList: View {
    let guilds: [MutualGuild]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileMutualListHeader(title: "Mutual Servers", count: guilds.count)
            Divider()
            ScrollView {
                VStack(spacing: 9) {
                    ForEach(guilds) { guild in
                        HStack(spacing: 10) {
                            AvatarView(name: guild.name, url: guild.iconURL, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(guild.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if let nickname = guild.nickname, !nickname.isEmpty {
                                    Text(nickname).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 320, height: ProfileMutualListMetrics.height(for: guilds.count))
    }
}

private struct ProfileMutualFriendsList: View {
    let friends: [User]
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileMutualListHeader(title: "Mutual Friends", count: totalCount)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(friends) { friend in
                        HStack(spacing: 10) {
                            AvatarView(name: friend.displayName, url: friend.avatarURL, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(friend.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(friend.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    if totalCount > friends.count {
                        Text("Discord returned \(friends.count) of \(totalCount) mutual friends.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 320, height: ProfileMutualListMetrics.height(for: max(totalCount, friends.count)))
    }
}

private struct ProfileMutualListHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(count, format: .number)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private enum ProfileMutualListMetrics {
    static func height(for count: Int) -> CGFloat {
        min(430, max(112, 61 + CGFloat(count) * 47))
    }
}

private struct ProfileConnectionsSection: View {
    let accounts: [ConnectedAccount]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(accounts) { account in
                    ProfileConnectionIcon(account: account)
                }
            }
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .padding(.horizontal, 16)
    }
}

private struct ProfileConnectionIcon: View {
    let account: ConnectedAccount
    @State private var isHovered = false

    var body: some View {
        Group {
            if let profileURL = account.profileURL {
                Link(destination: profileURL) { logo }
                    .buttonStyle(.plain)
            } else {
                logo
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(account.name)
        .nativeHoverPopover(isPresented: $isHovered) {
            Text(account.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .accessibilityLabel("\(account.name), \(ConnectionBrand.displayName(for: account.type))")
    }

    private var logo: some View {
        ConnectionLogo(type: account.type)
            .frame(width: 30, height: 30)
    }
}

private struct ConnectionLogo: View {
    let type: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let logo = ConnectionBrand.image(for: type, colorScheme: colorScheme) {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: type == "domain" ? "globe" : "link")
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(.secondary)
        }
    }
}

nonisolated enum ProfileEffectLayout {
    // Some profile-effect products omit geometry from every layer. Discord's
    // fully specified products use this canvas, and dimensionless layers use
    // the same coordinate space rather than the profile view's live height.
    static let defaultCanvasSize = CGSize(width: 450, height: 880)

    static func designWidth(for animations: [ProfileEffectAnimation]) -> CGFloat {
        let maximumRightEdge = animations.compactMap { animation -> CGFloat? in
            guard let width = animation.width, width > 0 else { return nil }
            return CGFloat(animation.positionX + width)
        }.max() ?? 0
        return max(defaultCanvasSize.width, maximumRightEdge)
    }

    static func frames(
        for animations: [ProfileEffectAnimation],
        containerWidth: CGFloat
    ) -> [CGRect] {
        guard containerWidth.isFinite, containerWidth > 0 else { return [] }
        let designWidth = designWidth(for: animations)
        return animations.map { animation in
            frame(
                for: animation,
                designWidth: designWidth,
                containerWidth: containerWidth
            )
        }
    }

    static func frame(
        for animation: ProfileEffectAnimation,
        designWidth: CGFloat,
        containerWidth: CGFloat
    ) -> CGRect {
        let scale = containerWidth / designWidth
        return CGRect(
            x: CGFloat(animation.positionX) * scale,
            y: CGFloat(animation.positionY) * scale,
            width: CGFloat(animation.width ?? Int(defaultCanvasSize.width)) * scale,
            height: CGFloat(animation.height ?? Int(defaultCanvasSize.height)) * scale
        )
    }
}

private struct ProfileEffectOverlay: View {
    let effect: ProfileEffect
    let animates: Bool

    var body: some View {
        GeometryReader { proxy in
            if !effect.animations.isEmpty {
                let designWidth = ProfileEffectLayout.designWidth(for: effect.animations)
                ZStack(alignment: .topLeading) {
                    ForEach(effect.animations) { animation in
                        let frame = ProfileEffectLayout.frame(
                            for: animation,
                            designWidth: designWidth,
                            containerWidth: proxy.size.width
                        )
                        AnimatedRemoteImage(
                            url: animation.sourceURL,
                            animates: animates,
                            isLooping: animation.isLooping,
                            accessibilityCategory: .decoration
                        )
                            .frame(
                                width: frame.width,
                                height: frame.height
                            )
                            .offset(
                                x: frame.minX,
                                y: frame.minY
                            )
                            .zIndex(Double(animation.zIndex))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
            } else if let url = effect.reducedMotionURL {
                AnimatedRemoteImage(
                    url: url,
                    animates: animates,
                    accessibilityCategory: .decoration
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else if let url = effect.staticURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityLabel(effect.accessibilityLabel ?? "Profile effect")
    }
}

private struct ProfileGuildIdentity: View {
    let identity: PrimaryGuildIdentity
    let tag: String

    var body: some View {
        HStack(spacing: 5) {
            if let badgeURL = identity.badgeURL {
                AsyncImage(url: badgeURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 18, height: 18)
            }
            Text(tag)
                .font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.28), in: ConcentricRectangle(cornerRadius: 7, style: .continuous))
    }
}

private enum ProfilePalette {
    private static let innerSurfaceThemeAmount = 0.36

    static func colors(themeHexes: [UInt32], accentHex: UInt32?) -> [Color] {
        if themeHexes.count >= 2 {
            return themeHexes.prefix(2).map(Color.init(hex:))
        }
        if let accentHex {
            return [Color(hex: accentHex).opacity(0.72), Color(hex: accentHex).opacity(0.32)]
        }
        return [Color(hex: 0x202225), Color(hex: 0x2B2D31)]
    }

    static func banner(themeHexes: [UInt32], accentHex: UInt32?) -> [Color] {
        if let accentHex {
            return [Color(hex: accentHex), Color(hex: accentHex).opacity(0.6)]
        }
        return colors(themeHexes: themeHexes, accentHex: accentHex).reversed()
    }

    static func innerSurfaceOverlay(for colorScheme: ColorScheme) -> Color {
        let base = colorScheme == .dark ? Color.black : Color.white
        return base.opacity(1 - innerSurfaceThemeAmount)
    }

    static func innerSurfaceColor(themeHexes: [UInt32], colorScheme: ColorScheme) -> Color {
        guard let first = themeHexes.first else {
            return Color(nsColor: .windowBackgroundColor)
        }
        let base: UInt32 = colorScheme == .dark ? 0x000000 : 0xFFFFFF
        return Color(hex: blend(first, with: base, colorAmount: innerSurfaceThemeAmount))
    }

    private static func blend(_ color: UInt32, with base: UInt32, colorAmount: Double) -> UInt32 {
        func channel(_ value: UInt32, shift: UInt32) -> Double {
            Double((value >> shift) & 0xFF)
        }
        func mixed(_ colorChannel: Double, _ baseChannel: Double) -> UInt32 {
            UInt32((colorChannel * colorAmount + baseChannel * (1 - colorAmount)).rounded())
        }
        let red = mixed(channel(color, shift: 16), channel(base, shift: 16))
        let green = mixed(channel(color, shift: 8), channel(base, shift: 8))
        let blue = mixed(channel(color, shift: 0), channel(base, shift: 0))
        return (red << 16) | (green << 8) | blue
    }
}
