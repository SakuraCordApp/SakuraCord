import AppKit
import DiscordProtocol
import SakuraCordModels
import SwiftUI

/// The Direct Messages home. Sections live in the window toolbar; this view
/// owns the list, the Add Friend form and relationship confirmations.
struct FriendsView: View {
    let model: AppModel

    var body: some View {
        let friends = model.friends
        Group {
            if model.friendsSection == .addFriend {
                AddFriendView(model: model)
            } else {
                FriendsListView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(HumanCaptchaPresentation(store: friends.captcha))
        .alert(
            confirmationTitle(friends.confirmation),
            isPresented: Binding(get: { friends.confirmation != nil }, set: { if !$0 { friends.confirmation = nil } }),
            presenting: friends.confirmation
        ) { confirmation in
            Button(confirmationAction(confirmation), role: confirmationRole(confirmation)) {
                model.confirmFriendsAction(confirmation)
            }
            Button("Cancel", role: .cancel) { friends.confirmation = nil }
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { friends.actionError != nil }, set: { if !$0 { friends.actionError = nil } })
        ) {
            Button("OK", role: .cancel) { friends.actionError = nil }
        } message: {
            Text(friends.actionError ?? "")
        }
    }

    // Official stable633029 copy for removal and blocking.
    private func confirmationTitle(_ confirmation: FriendsConfirmation?) -> String {
        switch confirmation {
        case .removeFriend(let user): "Remove ‘\(model.friendDisplayName(user))’"
        case .block(let user): "Block \(model.friendDisplayName(user))?"
        case .acceptStranger: "Accept Friend Request?"
        case nil: ""
        }
    }

    private func confirmationMessage(_ confirmation: FriendsConfirmation) -> String {
        switch confirmation {
        case .removeFriend(let user):
            "Are you sure you want to remove \(model.friendDisplayName(user)) from your friends?"
        case .block(let user):
            "Are you sure you want to block \(model.friendDisplayName(user))? Blocking this user will also remove them from your friends list."
        case .acceptStranger(let user):
            "Discord wants you to confirm that you know \(model.friendDisplayName(user)) before accepting their request."
        }
    }

    private func confirmationAction(_ confirmation: FriendsConfirmation) -> String {
        switch confirmation {
        case .removeFriend: "Remove Friend"
        case .block: "Block"
        case .acceptStranger: "Accept"
        }
    }

    private func confirmationRole(_ confirmation: FriendsConfirmation) -> ButtonRole? {
        switch confirmation {
        case .removeFriend, .block: .destructive
        case .acceptStranger: nil
        }
    }
}

extension AppModel {
    func friendDisplayName(_ user: User) -> String {
        friendNickname(for: user.id) ?? user.displayName
    }
}

private struct FriendsListView: View {
    let model: AppModel

    var body: some View {
        let groups = model.friendsListGroups()
        let query = model.friendsSearchText
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        FriendRowView(model: model, row: row, isPending: model.friends.pendingUserIDs.contains(row.id))
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(
                                top: InterfaceScale.metric(2), leading: InterfaceScale.metric(12),
                                bottom: InterfaceScale.metric(2), trailing: InterfaceScale.metric(12)
                            ))
                    }
                } header: {
                    Text(group.title)
                        .font(.interface(.subheadline).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if groups.allSatisfy(\.rows.isEmpty) {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    emptyState
                }
            }
        }
    }

    // Official stable633029 empty-state copy.
    @ViewBuilder private var emptyState: some View {
        switch model.friendsSection {
        case .pending:
            ContentUnavailableView(
                "No pending friends", systemImage: "person.crop.circle.badge.clock",
                description: Text("There are no pending friend requests. Here’s Wumpus for now.")
            )
        case .online, .all, .addFriend:
            ContentUnavailableView {
                Label("No one’s around", systemImage: "person.2")
            } description: {
                Text("Wumpus is waiting on friends. You don’t have to though!")
            } actions: {
                Button("Add Friend") { model.selectFriendsSection(.addFriend) }
                    .buttonStyle(.glassProminent)
                    .tint(SakuraCordAccentColor.color)
            }
        }
    }
}

private struct FriendRowView: View {
    let model: AppModel
    let row: FriendRow
    let isPending: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            AvatarPresenceView(
                status: row.relationship.type == .friend ? row.presence.status : nil,
                avatarSize: InterfaceScale.metric(36),
                indicatorSize: InterfaceScale.metric(36) * 0.3,
                isMobile: row.presence.showsMobileIndicator
            ) {
                AvatarView(name: row.name, url: row.user.avatarURL, size: InterfaceScale.metric(36), animates: true, isHovered: isHovered)
            }

            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                HStack(spacing: InterfaceScale.metric(6)) {
                    Text(row.name)
                        .font(.interface(.body).weight(.semibold))
                        .lineLimit(1)
                    if isHovered || row.relationship.type != .friend {
                        Text(row.user.username)
                            .font(.interface(.callout))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                subtitle
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(14), alignment: .leading)
            }

            Spacer(minLength: InterfaceScale.metric(8))

            if isPending {
                ProgressView().controlSize(.small)
            }
            actions
                .disabled(isPending)
        }
        .padding(.horizontal, InterfaceScale.metric(10))
        .frame(minHeight: InterfaceScale.metric(56))
        .background {
            ConcentricRectangle(cornerRadius: InterfaceScale.metric(12), style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        }
        .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(12), style: .continuous))
        .onModalHover { isHovered = $0 }
        .onTapGesture(perform: primaryAction)
        .pointerStyle(.link)
        .contextMenu { menuItems }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: row.relationship.type == .friend ? "Message" : "Profile", primaryAction)
    }

    @ViewBuilder private var subtitle: some View {
        switch row.relationship.type {
        case .incomingRequest:
            secondaryText("Incoming Friend Request")
        case .outgoingRequest:
            secondaryText("Outgoing Friend Request")
        default:
            if let status = row.presence.customStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
                ProfileStatusTextView(source: status, isExpanded: false, fontSize: 12, usesSecondaryColor: true)
                    .frame(maxHeight: InterfaceScale.metric(16))
                    .lineLimit(1)
                    .allowsHitTesting(false)
            } else if let activity = row.presence.activityText, !activity.isEmpty {
                Label(activity, systemImage: row.presence.isListeningToMusic ? "music.note" : "gamecontroller.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                secondaryText(PresenceIndicatorPresentation.accessibilityLabel(for: row.presence.status, isMobile: false))
            }
        }
    }

    private func secondaryText(_ value: String) -> some View {
        Text(value)
            .font(.interface(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder private var actions: some View {
        GlassEffectContainer(spacing: InterfaceScale.metric(6)) {
            HStack(spacing: InterfaceScale.metric(6)) {
                switch row.relationship.type {
                case .incomingRequest:
                    rowButton("Accept", systemImage: "checkmark", tint: .green) {
                        model.acceptFriendRequest(from: row.user)
                    }
                    rowButton("Ignore", systemImage: "xmark") {
                        model.removeRelationship(with: row.user, as: .declineIncomingRequest)
                    }
                case .outgoingRequest:
                    rowButton("Cancel", systemImage: "xmark") {
                        model.removeRelationship(with: row.user, as: .cancelOutgoingRequest)
                    }
                default:
                    rowButton("Message", systemImage: "bubble.left.fill") { model.openDirectMessage(with: row.user) }
                    Menu {
                        menuItems
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                            .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                            .contentShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .help("More")
                }
            }
        }
    }

    private func rowButton(_ title: String, systemImage: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.interface(.callout).weight(.semibold))
                .foregroundStyle(tint ?? .primary)
                .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(title)
    }

    @ViewBuilder private var menuItems: some View {
        Button("Profile", systemImage: "person.crop.circle") { model.showFriendProfile(row) }
        if row.relationship.type == .friend {
            Button("Message", systemImage: "bubble.left") { model.openDirectMessage(with: row.user) }
            ForEach(model.nicknameMenuActions(for: row.user, in: nil), id: \.title) { action in
                Button(action.title, systemImage: action.systemImage, action: action.perform)
            }
        }
        Divider()
        switch row.relationship.type {
        case .friend:
            Button("Remove Friend", systemImage: "person.badge.minus", role: .destructive) {
                model.friends.confirmation = .removeFriend(row.user)
            }
        case .incomingRequest:
            Button("Accept", systemImage: "checkmark") { model.acceptFriendRequest(from: row.user) }
            Button("Ignore", systemImage: "xmark") { model.removeRelationship(with: row.user, as: .declineIncomingRequest) }
        case .outgoingRequest:
            Button("Cancel Request", systemImage: "xmark") { model.removeRelationship(with: row.user, as: .cancelOutgoingRequest) }
        default:
            EmptyView()
        }
        Button("Block", systemImage: "hand.raised", role: .destructive) { model.friends.confirmation = .block(row.user) }
        Divider()
        Button("Copy User ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.user.id.description, forType: .string)
        }
    }

    private func primaryAction() {
        if row.relationship.type == .friend {
            model.openDirectMessage(with: row.user)
        } else {
            model.showFriendProfile(row)
        }
    }
}

private struct AddFriendView: View {
    let model: AppModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var friends = model.friends
        let canSend = !friends.addFriendText.isEmpty && !friends.isSendingRequest
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            Text("Add Friend")
                .font(.interface(.title2).weight(.bold))
            // Official stable633029 add-friend copy.
            Text("You can add friends with their Discord username.")
                .foregroundStyle(.secondary)

            HStack(spacing: InterfaceScale.metric(8)) {
                TextField("Enter a username", text: $friends.addFriendText)
                    .textFieldStyle(.plain)
                    .tint(SakuraCordAccentColor.color)
                    .focused($isFieldFocused)
                    .onSubmit { if canSend { model.sendFriendRequest() } }
                    .onChange(of: friends.addFriendText) { _, value in
                        if value.count > FriendsListPolicy.usernameMaximumLength {
                            friends.addFriendText = String(value.prefix(FriendsListPolicy.usernameMaximumLength))
                        }
                        friends.addFriendError = nil
                        if !value.isEmpty { friends.addFriendSuccess = nil }
                    }
                    .accessibilityLabel("Username")
                    .padding(.leading, InterfaceScale.metric(14))

                Button {
                    model.sendFriendRequest()
                } label: {
                    Text("Send Friend Request")
                        .font(.interface(.callout).weight(.semibold))
                        .opacity(friends.isSendingRequest ? 0 : 1)
                        .overlay { if friends.isSendingRequest { InteractionLoadingDotsView(tone: .onFill) } }
                        .padding(.horizontal, InterfaceScale.metric(14))
                        .frame(height: InterfaceScale.metric(34))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(
                    canSend ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular,
                    in: Capsule()
                )
                .disabled(!canSend)
            }
            .padding(InterfaceScale.metric(6))
            .frame(minHeight: InterfaceScale.metric(46))
            .glassEffect(
                .regular,
                in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(23), style: .continuous)
            )
            .overlay {
                ConcentricRectangle(cornerRadius: InterfaceScale.metric(23), style: .continuous)
                    .stroke(borderColor(friends), lineWidth: 1)
                    .allowsHitTesting(false)
            }

            if let error = friends.addFriendError {
                Text(error)
                    .foregroundStyle(Color(hex: 0xF23F43))
                    .accessibilityAddTraits(.isStaticText)
            } else if let username = friends.addFriendSuccess {
                Text("Success! Your friend request to **\(username)** was sent.")
                    .foregroundStyle(Color(hex: 0x23A55A))
            }
            Spacer(minLength: 0)
        }
        .font(.interface(.body))
        .padding(InterfaceScale.metric(24))
        .frame(maxWidth: InterfaceScale.metric(720), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isFieldFocused = true }
        .onChange(of: friends.addFriendFocusRequest) { _, _ in isFieldFocused = true }
    }

    private func borderColor(_ friends: FriendsState) -> Color {
        if friends.addFriendError != nil { return Color(hex: 0xF23F43) }
        if friends.addFriendSuccess != nil { return Color(hex: 0x23A55A) }
        return isFieldFocused ? SakuraCordAccentColor.color.opacity(0.7) : .clear
    }
}
