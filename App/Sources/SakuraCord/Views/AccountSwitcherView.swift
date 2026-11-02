import SwiftUI

struct AccountSwitcherView: View {
    let model: AppModel
    let showsCancel: Bool
    var accountActivated: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var showsLogin = false
    @State private var switchingAccountID: String?
    @State private var loggingOutAccountID: String?
    @State private var accountPendingLogout: SavedAccount?

    var body: some View {
        ZStack {
            SakuraCordSignInBackdrop()
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    GlassEffectContainer {
                        SakuraCordAuthenticationCard {
                            VStack(alignment: .leading, spacing: InterfaceScale.metric(26)) {
                                header
                                accountList
                                addAccountButton
                            }
                        }
                    }
                    .frame(maxWidth: InterfaceScale.metric(620))
                    .padding(.horizontal, InterfaceScale.metric(34))
                    .padding(.vertical, InterfaceScale.metric(72))
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }

            windowDragRegion

            if showsCancel {
                SakuraCordAuthenticationCloseButton { dismiss() }
                    .padding(InterfaceScale.metric(20))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topTrailing
                    )
            }
        }
        .frame(minWidth: InterfaceScale.metric(860), minHeight: InterfaceScale.metric(600))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task { await model.refreshSavedAccounts() }
        .sheet(isPresented: $showsLogin) {
            DiscordLoginView(
                showsCancel: true,
                networkingEnabled: !model.isDiscordNetworkingDisabled,
                // Allow importing a fresh session for accounts Discord rejected.
                savedAccountIDs: Set(
                    model.savedAccounts.filter { !$0.requiresSignIn }.map(\.accountID)
                )
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

    private var windowDragRegion: some View {
        VStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .frame(height: InterfaceScale.metric(52))
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            Text("Manage accounts")
                .font(.interface(.title).bold())
                .foregroundStyle(.primary)
            Text("Switch between saved sessions or add another Discord account.")
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
        }
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.savedAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.72))
                        .frame(height: 1)
                        .padding(.leading, InterfaceScale.metric(76))
                }
                accountRow(account)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous)
                .stroke(.primary.opacity(0.11), lineWidth: 1)
        }
    }

    private func accountRow(_ account: SavedAccount) -> some View {
        let isActive = account.accountID == model.activeAccountID
        let isSwitching = account.accountID == switchingAccountID
        let isLoggingOut = account.accountID == loggingOutAccountID
        return HStack(spacing: InterfaceScale.metric(14)) {
            AvatarView(
                name: account.resolvedDisplayName,
                url: account.avatarURL,
                size: InterfaceScale.metric(48),
                maximumPixelDimension: 96,
                animates: false
            )

            VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
                Text(account.resolvedDisplayName)
                    .font(.interface(.body).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(isActive ? "Current account" : account.resolvedSubtitle)
                    .font(.interface(.callout))
                    .foregroundStyle(
                        isActive
                            ? SakuraCordAccentColor.color
                            : Color.secondary
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: InterfaceScale.metric(12))

            if isSwitching {
                Text("Switching…")
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
                    .frame(width: InterfaceScale.metric(78))
            } else if isActive {
                Color.clear
                    .frame(width: InterfaceScale.metric(78), height: 1)
                    .accessibilityHidden(true)
            } else {
                Button(account.requiresSignIn ? "Log in" : "Switch") {
                    if account.requiresSignIn {
                        showsLogin = true
                    } else {
                        switchToAccount(account)
                    }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(SakuraCordAccentColor.color)
                .disabled(switchingAccountID != nil)
                .frame(width: InterfaceScale.metric(78))
            }

            AccountOptionsMenuControl(
                isEnabled: switchingAccountID == nil && loggingOutAccountID == nil
            ) {
                accountPendingLogout = account
            }
        }
        .padding(.horizontal, InterfaceScale.metric(18))
        .frame(height: InterfaceScale.metric(76))
        .authenticationLoading(isSwitching || isLoggingOut, in: RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous))
        .accessibilityValue(isLoggingOut ? "Logging out" : isSwitching ? "Switching account" : "")
        .accessibilityElement(children: .contain)
    }

    private var addAccountButton: some View {
        Button {
            showsLogin = true
        } label: {
            Label(
                "Add an account…",
                systemImage: "person.crop.circle.badge.plus"
            )
            .font(.interface(.body).weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(34))
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(SakuraCordAccentColor.color)
        .disabled(switchingAccountID != nil || loggingOutAccountID != nil)
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
        let dismissesManagerImmediately = showsCancel
        if dismissesManagerImmediately {
            accountActivated()
            dismiss()
        }
        Task {
            let connected = await model.switchAccount(to: account.accountID)
            switchingAccountID = nil
            if connected, !dismissesManagerImmediately {
                accountActivated()
                // This picker is the main window's content. The model switches
                // it to the workspace; dismissing here would close that window.
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

    var body: some View {
        NativeAccountOptionsButton(isEnabled: isEnabled, logOut: logOut)
            .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
            .overlay {
                Image(systemName: "ellipsis")
                    .font(.interface(.body).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
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
                title: "Log Out…",
                action: #selector(logOutSelected),
                keyEquivalent: ""
            )
            item.target = self
            ContextMenuItemSupport.configure(
                item,
                title: "Log Out…",
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
