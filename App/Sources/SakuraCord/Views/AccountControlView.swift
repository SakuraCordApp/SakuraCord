import AppKit
import SakuraCordModels
import SwiftUI

nonisolated enum SidebarAccountControlMetrics {
    static var capsuleHeight: CGFloat { ChatChromeMetrics.controlHeight }
    static var cornerRadius: CGFloat { capsuleHeight / 2 }
    static var contentInset: CGFloat { InterfaceScale.metric(8) }
    static var avatarSize: CGFloat { InterfaceScale.metric(32) }
    static var settingsIconSize: CGFloat { InterfaceScale.metric(14) }
    static var settingsDiameter: CGFloat { InterfaceScale.metric(30) }
    static var settingsInset: CGFloat { (capsuleHeight - settingsDiameter) / 2 }
    static var surfaceSpacing: CGFloat { InterfaceScale.metric(6) }

    static func bottomInset(for appearance: ComposerBarAppearance) -> CGFloat {
        let composerHeight = appearance == .defaultStyle
            ? ChatChromeMetrics.composerControlHeight
            : ChatChromeMetrics.controlHeight
        return ChatChromeMetrics.composerWindowInset - (capsuleHeight - composerHeight) / 2
    }

    static func settingsCornerRadius(for appearance: ComposerBarAppearance) -> CGFloat {
        appearance == .defaultStyle ? settingsDiameter / 2 : 9
    }

    static func shape(for appearance: ComposerBarAppearance) -> RoundedRectangle {
        RoundedRectangle(
            cornerRadius: appearance == .defaultStyle
                ? cornerRadius
                : ChatChromeMetrics.composerMinimumCornerRadius,
            style: .continuous
        )
    }
}

struct AccountControlView: View {
    let voiceModel: AppModel
    let user: User?
    let connectionState: ConnectionState
    let currentStatus: PresenceStatus
    let isAuthenticated: Bool
    let isOfflineTesting: Bool
    let connectAccount: () -> Void
    let updateStatus: (PresenceStatus) async -> Void

    var body: some View {
        GlassEffectContainer(spacing: SidebarAccountControlMetrics.surfaceSpacing) {
            VStack(spacing: SidebarAccountControlMetrics.surfaceSpacing) {
                if let session = voiceModel.embeddedActivities.dockedSession {
                    EmbeddedActivitySidebarPanel(model: voiceModel, session: session)
                }
                if voiceModel.activeVoiceChannel != nil {
                    VoiceSidebarControlPanel(model: voiceModel) {
                        guard let channelID = voiceModel.activeVoiceChannel?.id else {
                            return
                        }
                        voiceModel.navigate(to: channelID)
                    }
                }

                CurrentUserCapsule(
                    model: voiceModel,
                    user: user.map(voiceModel.cosmeticPolicy.user),
                    displayName: displayName,
                    subtitle: accountSubtitle,
                    currentStatus: currentStatus,
                    isAuthenticated: isAuthenticated,
                    isOfflineTesting: isOfflineTesting,
                    connectAccount: connectAccount,
                    updateStatus: updateStatus
                )
            }
        }
        .padding(.horizontal, InterfaceScale.metric(8))
        .padding(
            .bottom,
            SidebarAccountControlMetrics.bottomInset(
                for: voiceModel.appearanceSettings.composerBarAppearance
            )
        )
    }

    private var displayName: String {
        user?.displayName ?? (isAuthenticated ? "Discord Account" : "Connect Account")
    }

    private var accountSubtitle: String {
        if user != nil {
            return currentStatus.label
        }
        return isOfflineTesting
            ? "Mock data • networking disabled"
            : (isAuthenticated ? connectionState.rawValue : "Sign in to Discord")
    }
}

private struct CurrentUserCapsule: View {
    let model: AppModel
    let user: User?
    let displayName: String
    let subtitle: String
    let currentStatus: PresenceStatus
    let isAuthenticated: Bool
    let isOfflineTesting: Bool
    let connectAccount: () -> Void
    let updateStatus: (PresenceStatus) async -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var isMainHovering = false
    @State private var isSettingsHovering = false
    @State private var isYouPopoverPresented = false
    @State private var profileRequestID: UUID?

    var body: some View {
        let appearance = model.appearanceSettings.composerBarAppearance
        let height = SidebarAccountControlMetrics.capsuleHeight
        let shape = SidebarAccountControlMetrics.shape(for: appearance)

        ZStack {
            if let nameplate = user?.nameplate {
                NameplateBackground(
                    nameplate: nameplate,
                    isAnimated: isProfileHovering
                )
                .opacity(
                    NameplatePresentationPolicy.opacity(
                        isHovered: isProfileHovering
                    )
                )
            }

            Color.primary.opacity(isProfileHovering ? 0.09 : 0)
                .allowsHitTesting(false)

            Button(action: presentYouPopover) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    accountAvatar

                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayName)
                            .font(.interfaceSystem(
                                size: InterfaceTypographyMetrics.interfaceTextSize,
                                weight: .semibold
                            ))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.interfaceSystem(
                                size: max(
                                    10,
                                    InterfaceTypographyMetrics.interfaceTextSize - 2
                                )
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: InterfaceScale.metric(4))
                }
                .padding(.leading, SidebarAccountControlMetrics.contentInset)
                .padding(
                    .trailing,
                    SidebarAccountControlMetrics.settingsDiameter
                        + SidebarAccountControlMetrics.settingsInset
                        + SidebarAccountControlMetrics.contentInset
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: height,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onModalHover { isMainHovering = $0 }
            .stableMemberProfilePopover(isPresented: $isYouPopoverPresented) {
                youPopover
            }

            ComposerActionButton(
                icon: Image(systemName: "gearshape.fill"),
                help: "Settings",
                iconSize: SidebarAccountControlMetrics.settingsIconSize,
                size: SidebarAccountControlMetrics.settingsDiameter,
                appearance: appearance,
                cornerRadius: SidebarAccountControlMetrics.settingsCornerRadius(for: appearance),
                onHoverChanged: { isSettingsHovering = $0 },
                action: { openSettings() }
            )
            .accessibilityLabel("Settings")
            .padding(.trailing, SidebarAccountControlMetrics.settingsInset)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .trailing
            )
        }
        .frame(height: height)
        .containerShape(shape)
        .clipShape(shape)
        .contentShape(shape)
        .glassEffect(.regular, in: shape)
        .animation(.snappy(duration: 0.16), value: isProfileHovering)
        .onChange(of: isYouPopoverPresented) { _, isPresented in
            guard !isPresented, let profileRequestID else { return }
            model.dismissContextualProfile(requestID: profileRequestID)
            self.profileRequestID = nil
        }
        .accessibilityElement(children: .contain)
    }

    private var isProfileHovering: Bool {
        isMainHovering && !isSettingsHovering
    }

    private var accountAvatar: some View {
        AvatarPresenceView(
            status: currentStatus,
            avatarSize: SidebarAccountControlMetrics.avatarSize,
            indicatorSize: InterfaceScale.metric(10)
        ) {
            DecoratedAvatarView(
                name: displayName,
                avatarURL: user?.avatarURL,
                decorationURL: user?.avatarDecorationURL,
                size: SidebarAccountControlMetrics.avatarSize,
                playback: .hover(isProfileHovering)
            )
        }
        .frame(
            width: SidebarAccountControlMetrics.avatarSize,
            height: SidebarAccountControlMetrics.avatarSize
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), \(currentStatus.label)")
    }

    @ViewBuilder
    private var youPopover: some View {
        if let profileRequestID,
           let presentation = model.liveProfilePresentation(for: .contextual),
           presentation.requestID == profileRequestID
        {
            ProfilePresentationContent(
                presentation: presentation,
                layout: .popover,
                maximumPopoverHeight: InterfaceScale.metric(720),
                showsRoles: false,
                openProfile: model.expandProfile,
                userMenu: { UserContextMenu.make(for: presentation.member.user, context: .init(guildID: presentation.guildID), model: model) },
                sendMessage: nil,
            footer: {
                YouPopoverOptions(
                    currentStatus: currentStatus,
                    isStatusEnabled: isAuthenticated && !isOfflineTesting,
                    isAccountSwitchingEnabled: !isOfflineTesting,
                    savedAccounts: model.savedAccounts,
                    activeAccountID: model.activeAccountID,
                    updateStatus: updateStatus,
                    switchAccount: { accountID in
                        await model.switchAccount(to: accountID)
                    },
                    manageAccounts: {
                        isYouPopoverPresented = false
                        connectAccount()
                    },
                    accountActivated: {
                        isYouPopoverPresented = false
                    }
                )
            })
            .environment(\.profileCosmeticPolicy, model.cosmeticPolicy)
            .environment(\.serverTagCardModel, model)
        } else {
            ProgressView("Loading profile…")
                .padding(InterfaceScale.metric(24))
                .frame(width: MemberProfilePopover<EmptyView>.preferredWidth)
        }
    }

    private func presentYouPopover() {
        if isYouPopoverPresented {
            isYouPopoverPresented = false
            return
        }
        guard let user else {
            connectAccount()
            return
        }
        let member = model.membersByID[user.id]
            ?? Member(user: user, roleName: "You", status: currentStatus)
        profileRequestID = model.presentProfile(
            for: member,
            in: model.selectedGuildID,
            destination: .contextual
        )
        isYouPopoverPresented = true
    }
}

private struct YouPopoverOptions: View {
    let currentStatus: PresenceStatus
    let isStatusEnabled: Bool
    let isAccountSwitchingEnabled: Bool
    let savedAccounts: [SavedAccount]
    let activeAccountID: String?
    let updateStatus: (PresenceStatus) async -> Void
    let switchAccount: (String) async -> Bool
    let manageAccounts: () -> Void
    let accountActivated: () -> Void

    @State private var isStatusPopoverPresented = false
    @State private var isAccountPopoverPresented = false

    var body: some View {
        VStack(spacing: InterfaceScale.metric(4)) {
            Divider()
                .padding(.horizontal, InterfaceScale.metric(8))
                .padding(.bottom, InterfaceScale.metric(4))

            Button {
                isStatusPopoverPresented.toggle()
            } label: {
                PopoverDisclosureRowLabel(height: InterfaceScale.metric(38)) {
                    PresenceIndicator(status: currentStatus, size: InterfaceScale.metric(13))
                        .frame(width: InterfaceScale.metric(18))
                    Text(currentStatus.label)
                }
            }
            .buttonStyle(PopoverRowButtonStyle())
            .disabled(!isStatusEnabled)
            .opacity(isStatusEnabled ? 1 : 0.45)
            .escapeDismissiblePopover(
                isPresented: $isStatusPopoverPresented,
                arrowEdge: .trailing
            ) {
                StatusSelectionPopover(
                    currentStatus: currentStatus,
                    updateStatus: updateStatus
                )
            }

            Button {
                isAccountPopoverPresented.toggle()
            } label: {
                PopoverDisclosureRowLabel(height: InterfaceScale.metric(38)) {
                    Image(systemName: "person.crop.circle")
                        .frame(width: InterfaceScale.metric(18))
                    Text("Switch Accounts")
                }
            }
            .buttonStyle(PopoverRowButtonStyle())
            .disabled(!isAccountSwitchingEnabled)
            .opacity(isAccountSwitchingEnabled ? 1 : 0.45)
            .escapeDismissiblePopover(
                isPresented: $isAccountPopoverPresented,
                arrowEdge: .trailing
            ) {
                AccountSelectionPopover(
                    savedAccounts: savedAccounts,
                    activeAccountID: activeAccountID,
                    switchAccount: switchAccount,
                    manageAccounts: manageAccounts,
                    accountActivated: accountActivated
                )
            }
        }
        .font(.interface(.callout))
        .padding(.horizontal, InterfaceScale.metric(10))
        .padding(.top, InterfaceScale.metric(2))
    }
}

private struct StatusSelectionPopover: View {
    let currentStatus: PresenceStatus
    let updateStatus: (PresenceStatus) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: InterfaceScale.metric(4)) {
            ForEach(PresenceStatus.allCases.filter { $0 != .offline }, id: \.self) { status in
                Button {
                    Task {
                        await updateStatus(status)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: InterfaceScale.metric(10)) {
                        PresenceIndicator(status: status, size: InterfaceScale.metric(13))
                            .frame(width: InterfaceScale.metric(18))
                        Text(status.label)
                        Spacer()
                        if status == currentStatus {
                            Image(systemName: "checkmark")
                                .foregroundStyle(SakuraCordAccentColor.color)
                        }
                    }
                    .padding(.horizontal, InterfaceScale.metric(8))
                    .frame(maxWidth: .infinity)
                    .frame(height: InterfaceScale.metric(34))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PopoverRowButtonStyle())
            }
        }
        .font(.interface(.callout))
        .padding(InterfaceScale.metric(12))
        .frame(width: InterfaceScale.metric(220))
    }
}

private struct AccountSelectionPopover: View {
    let savedAccounts: [SavedAccount]
    let activeAccountID: String?
    let switchAccount: (String) async -> Bool
    let manageAccounts: () -> Void
    let accountActivated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var switchingAccountID: String?

    var body: some View {
        VStack(spacing: InterfaceScale.metric(4)) {
            if savedAccounts.isEmpty {
                Text("No saved accounts")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(34), alignment: .leading)
                    .padding(.horizontal, InterfaceScale.metric(8))
            } else {
                ForEach(savedAccounts) { account in
                    accountButton(account)
                }
                Divider().padding(.horizontal, InterfaceScale.metric(8))
            }

            Button {
                dismiss()
                manageAccounts()
            } label: {
                Label("Manage Accounts…", systemImage: "person.crop.circle")
                    .padding(.horizontal, InterfaceScale.metric(8))
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(34), alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
        }
        .font(.interface(.callout))
        .padding(InterfaceScale.metric(12))
        .frame(width: InterfaceScale.metric(250))
    }

    private func accountButton(_ account: SavedAccount) -> some View {
        Button {
            guard switchingAccountID == nil,
                  account.accountID != activeAccountID
            else { return }
            guard !account.requiresSignIn else {
                // Switching would end the current session and then fail.
                dismiss()
                manageAccounts()
                return
            }
            switchingAccountID = account.accountID
            Task {
                let switched = await switchAccount(account.accountID)
                switchingAccountID = nil
                guard switched else { return }
                dismiss()
                accountActivated()
            }
        } label: {
            HStack(spacing: InterfaceScale.metric(9)) {
                AvatarView(
                    name: account.resolvedDisplayName,
                    url: account.resolvedAvatarURL,
                    size: InterfaceScale.metric(20),
                    maximumPixelDimension: 40,
                    animates: false
                )
                Text(account.username ?? account.resolvedDisplayName)
                    .lineLimit(1)
                Spacer()
                if account.accountID == activeAccountID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
            }
            .padding(.horizontal, InterfaceScale.metric(8))
            .frame(maxWidth: .infinity)
            .frame(height: InterfaceScale.metric(36))
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
        .disabled(switchingAccountID != nil)
        .authenticationLoading(switchingAccountID == account.accountID, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(8)))
        .accessibilityValue(switchingAccountID == account.accountID ? "Switching account" : "")
    }
}

private extension PresenceStatus {
    var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .dnd: "Do Not Disturb"
        case .invisible: "Invisible"
        case .offline: "Offline"
        }
    }
}
