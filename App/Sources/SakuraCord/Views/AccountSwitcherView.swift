import SwiftUI

struct AccountSwitcherView: View {
    let model: AppModel
    let showsCancel: Bool
    var accountActivated: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsLogin = false
    @State private var switchingAccountID: String?
    @State private var loggingOutAccountID: String?
    @State private var accountPendingLogout: SavedAccount?
    @State private var backgroundAnimationStart = Date()

    var body: some View {
        ZStack {
            authenticationBackdrop

            GeometryReader { geometry in
                ScrollView {
                    SakuraCordAuthenticationCard {
                        VStack(alignment: .leading, spacing: 26) {
                            header
                            accountList
                            addAccountButton
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 72)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }

            windowDragRegion

            if showsCancel {
                SakuraCordAuthenticationCloseButton { dismiss() }
                    .padding(20)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topTrailing
                    )
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .preferredColorScheme(.dark)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task {
            backgroundAnimationStart = Date()
            await model.refreshSavedAccounts()
        }
        .sheet(isPresented: $showsLogin) {
            DiscordLoginView(
                showsCancel: true,
                networkingEnabled: !model.isDiscordNetworkingDisabled
            ) { credential in
                let connected = await model.connectPendingAuthenticatedAccount(
                    credential,
                    preservesInteractivePresentation: true
                )
                if connected {
                    accountActivated()
                }
                return connected
                    ? nil
                    : (model.errorMessage
                        ?? "Discord account bootstrap failed for an unknown reason.")
            }
        }
        .confirmationDialog(
            "Log out of \(accountPendingLogout?.resolvedDisplayName ?? "this account")?",
            isPresented: pendingLogoutBinding
        ) {
            Button("Log Out", role: .destructive) {
                guard let account = accountPendingLogout else { return }
                accountPendingLogout = nil
                logOut(account)
            }
            Button("Cancel", role: .cancel) {
                accountPendingLogout = nil
            }
        } message: {
            Text("SakuraCord will remove this account's saved session from macOS Keychain.")
        }
    }

    private var authenticationBackdrop: some View {
        GeometryReader { geometry in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: reduceMotion
                )
            ) { timeline in
                let elapsed = reduceMotion
                    ? 0
                    : timeline.date.timeIntervalSince(backgroundAnimationStart)
                ZStack {
                    SakuraCordAuroraBackdrop(elapsed: elapsed)
                    SakuraCordSakuraPetalField(
                        elapsed: elapsed,
                        size: geometry.size
                    )
                    .accessibilityHidden(true)
                }
            }
        }
        .ignoresSafeArea()
    }

    private var windowDragRegion: some View {
        VStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .frame(height: 52)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manage accounts.")
                .font(.title.bold())
                .foregroundStyle(.white)
            Text("Switch between saved sessions or add another Discord account.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.68))
        }
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.savedAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.075))
                        .frame(height: 1)
                        .padding(.leading, 76)
                }
                accountRow(account)
            }
        }
        .background(
            Color(hex: 0x130F17).opacity(0.64),
            in: ConcentricRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            ConcentricRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private func accountRow(_ account: SavedAccount) -> some View {
        let isActive = account.accountID == model.activeAccountID
        let isSwitching = account.accountID == switchingAccountID
        let isLoggingOut = account.accountID == loggingOutAccountID
        return HStack(spacing: 14) {
            AvatarView(
                name: account.resolvedDisplayName,
                url: account.avatarURL,
                size: 48,
                maximumPixelDimension: 96,
                animates: false
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(account.resolvedDisplayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(isActive ? "Current account" : account.resolvedSubtitle)
                    .font(.callout)
                    .foregroundStyle(
                        isActive
                            ? Color(hex: 0xFF8BB6)
                            : .white.opacity(0.58)
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isSwitching {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(hex: 0xFF8BB6))
                    .frame(width: 78)
            } else if isActive {
                Color.clear
                    .frame(width: 78, height: 1)
                    .accessibilityHidden(true)
            } else {
                Button("Switch") {
                    switchToAccount(account)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(Color(hex: 0xFF8BB6))
                .disabled(switchingAccountID != nil)
                .frame(width: 78)
            }

            if isLoggingOut {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(hex: 0xFF8BB6))
                    .frame(width: 28)
            } else {
                AccountOptionsMenuControl(
                    isEnabled: switchingAccountID == nil
                        && loggingOutAccountID == nil
                ) {
                    accountPendingLogout = account
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
        .accessibilityElement(children: .contain)
    }

    private var addAccountButton: some View {
        Button {
            showsLogin = true
        } label: {
            Label(
                "Add an account",
                systemImage: "person.crop.circle.badge.plus"
            )
        }
        .buttonStyle(SakuraCordAuthPrimaryButtonStyle())
        .disabled(switchingAccountID != nil || loggingOutAccountID != nil)
        .opacity(switchingAccountID == nil && loggingOutAccountID == nil ? 1 : 0.45)
    }

    private var pendingLogoutBinding: Binding<Bool> {
        Binding(
            get: { accountPendingLogout != nil },
            set: { isPresented in
                if !isPresented {
                    accountPendingLogout = nil
                }
            }
        )
    }

    private func switchToAccount(_ account: SavedAccount) {
        guard switchingAccountID == nil, loggingOutAccountID == nil else { return }
        switchingAccountID = account.accountID
        Task {
            let connected = await model.switchAccount(to: account.accountID)
            switchingAccountID = nil
            if connected {
                accountActivated()
                dismiss()
            }
        }
    }

    private func logOut(_ account: SavedAccount) {
        guard switchingAccountID == nil, loggingOutAccountID == nil else { return }
        loggingOutAccountID = account.accountID
        Task {
            await model.logout(accountID: account.accountID)
            loggingOutAccountID = nil
        }
    }
}

private struct AccountOptionsMenuControl: View {
    let isEnabled: Bool
    let logOut: () -> Void
    @State private var isHovering = false

    var body: some View {
        NativeAccountOptionsButton(isEnabled: isEnabled, logOut: logOut)
            .frame(width: 28, height: 28)
            .background(
                isHovering && isEnabled
                    ? Color.primary.opacity(0.14)
                    : .clear,
                in: ConcentricRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                Image(systemName: "ellipsis")
                    .symbolVariant(.none)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .allowsHitTesting(false)
            }
            .contentShape(
                ConcentricRectangle(cornerRadius: 7, style: .continuous)
            )
            .onHover { isHovering = $0 }
            .opacity(isEnabled ? 1 : 0.45)
            .help("Account options")
            .accessibilityLabel("Account options")
    }
}

private struct NativeAccountOptionsButton: NSViewRepresentable {
    let isEnabled: Bool
    let logOut: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(logOut: logOut)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setAccessibilityLabel("Account options")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.logOut = logOut
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var logOut: () -> Void

        init(logOut: @escaping () -> Void) {
            self.logOut = logOut
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            let item = NSMenuItem(
                title: "Log Out",
                action: #selector(logOutSelected),
                keyEquivalent: ""
            )
            item.target = self
            ContextMenuItemSupport.configure(
                item,
                title: "Log Out",
                systemImage: "rectangle.portrait.and.arrow.right",
                isDestructive: true
            )
            menu.addItem(item)
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: -4),
                in: sender
            )
        }

        @objc private func logOutSelected() {
            logOut()
        }
    }
}
