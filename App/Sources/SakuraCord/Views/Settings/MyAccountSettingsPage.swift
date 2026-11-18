import SakuraCordModels
import SwiftUI

struct MyAccountSettingsPage: View {
    let model: AppModel
    let account: SavedAccount?
    let state: SettingsViewState
    @State private var accountState: AccountSettingsState
    @State private var navigationPath: [AccountSettingsDestination] = []

    init(model: AppModel, account: SavedAccount?, state: SettingsViewState) {
        self.model = model
        self.account = account
        self.state = state
        _accountState = State(initialValue: AccountSettingsState(model: model))
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SettingsPageForm(page: .myAccount, state: state) {
                Section {
                    if let account {
                        SettingsAccountIdentityHeader(account: account)
                    } else {
                        ContentUnavailableView(
                            "No Account",
                            systemImage: "person.crop.circle.badge.xmark",
                            description: Text("Sign in to view your account.", bundle: #bundle)
                        )
                    }
                }

                if let details = accountState.details {
                    AccountInformationSection(details: details, state: state)
                } else {
                    Section {
                        if let error = accountState.detailsError {
                            AccountSettingsRetryRow(message: error) {
                                await accountState.loadDetails()
                            }
                        } else {
                            ProgressView("Loading account information…")
                                .controlSize(.small)
                        }
                    } header: {
                        Text("Account Info", bundle: #bundle)
                    }
                }

                Section {
                    LabeledContent {
                        if let details = accountState.details {
                            Text(details.isMFAEnabled ? "Enabled" : "Disabled", bundle: #bundle)
                        } else {
                            Text("Unavailable", bundle: #bundle)
                        }
                    } label: {
                        Text("Multi-Factor Authentication", bundle: #bundle)
                    }
                    .settingsControlAnchor(.accountMFA, state: state)

                    NavigationLink(value: AccountSettingsDestination.devices) {
                        LabeledContent {
                            if let devices = accountState.devices {
                                Text("\(devices.count) devices", bundle: #bundle)
                            } else if accountState.isLoadingDevices {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Unavailable", bundle: #bundle)
                            }
                        } label: {
                            Text("Logged-in Devices", bundle: #bundle)
                        }
                    }
                    .settingsControlAnchor(.accountDevices, state: state)
                }
            }
            .navigationDestination(for: AccountSettingsDestination.self) { _ in
                AccountDevicesSettingsPage(accountState: accountState)
            }
        }
        .task { await accountState.load() }
        .onChange(of: model.profileInvalidationRevision) {
            Task { await accountState.loadDetails() }
        }
        .settingsNavigationPathResetOnReveal($navigationPath, page: .myAccount, state: state)
    }
}

private enum AccountSettingsDestination: Hashable {
    case devices
}

private struct AccountInformationSection: View {
    let details: AccountDetails
    let state: SettingsViewState

    var body: some View {
        Section {
            LabeledContent("Username", value: details.username)
                .settingsControlAnchor(.accountUsername, state: state)
            AccountContactRow(
                title: "Email", value: details.email,
                emptyLabel: "No email address added"
            )
            .settingsControlAnchor(.accountEmail, state: state)
            AccountContactRow(
                title: "Phone Number", value: details.phoneNumber,
                emptyLabel: "No phone number added"
            )
            .settingsControlAnchor(.accountPhone, state: state)
        } header: {
            Text("Account Info", bundle: #bundle)
        }
    }
}

private struct AccountContactRow: View {
    let title: LocalizedStringKey
    let value: String?
    let emptyLabel: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(16)) {
            Text(title, bundle: #bundle)
                .fixedSize()
            Spacer(minLength: 0)
            if let value {
                AccountContactValue(title: title, value: value)
                    // A replacement value starts concealed in its very first render.
                    .id(value)
            } else {
                Text(emptyLabel, bundle: #bundle)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AccountContactValue: View {
    let title: LocalizedStringKey
    let value: String
    @State private var isRevealed = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .blur(radius: isRevealed ? 0 : 5)
                .padding(.horizontal, InterfaceScale.metric(6))
                .padding(.vertical, InterfaceScale.metric(3))
                .background(.primary.opacity(isHovered ? 0.06 : 0), in: .rect(cornerRadius: InterfaceScale.metric(5)))
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .onModalHover { isHovered = $0 }
        .help(Text(isRevealed ? "Click to conceal" : "Click to reveal", bundle: #bundle))
        .accessibilityLabel(Text(title, bundle: #bundle))
        .accessibilityValue(isRevealed ? Text(value) : Text("Hidden", bundle: #bundle))
        .accessibilityHint(Text(isRevealed ? "Click to conceal" : "Click to reveal", bundle: #bundle))
        .privacySensitive()
        .transition(.identity)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
        .onDisappear { isRevealed = false }
    }
}

struct AccountSettingsRetryRow: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        HStack {
            Text(message).foregroundStyle(.secondary)
            Spacer()
            Button("Retry") { Task { await retry() } }
        }
    }
}

private struct SettingsAccountIdentityHeader: View {
    let account: SavedAccount

    var body: some View {
        HStack(spacing: InterfaceScale.metric(14)) {
            AvatarView(
                name: account.resolvedDisplayName,
                url: account.resolvedAvatarURL,
                size: InterfaceScale.metric(56),
                maximumPixelDimension: 140
            )

            VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
                Text(account.resolvedDisplayName)
                    .font(.interface(.title3).weight(.semibold))
                    .lineLimit(1)
                Text(account.resolvedSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, InterfaceScale.metric(4))
        .accessibilityElement(children: .combine)
    }
}
