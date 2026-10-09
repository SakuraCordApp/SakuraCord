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
                ScrollView {
                    AddFriendView(model: model)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                FriendsListView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(HumanCaptchaPresentation(store: friends.captcha))
        .onAppear { model.loadRelationshipsIfNeeded(for: model.friendsSection) }
        .onDisappear { friends.captcha.cancel() }
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
        let projection = model.friendsProjection
        let query = model.friendsSearchText
        NativeMemberListView(
            sections: projection.displaySections, customEmojiURLsByID: model.customEmojiURLsByID,
            profilePresentation: nil, isProfilePresented: false,
            selectMember: { member in
                guard let row = model.friends.row(for: member.id) else { return }
                if row.relationship.type == .friend {
                    model.openDirectMessage(with: row.user)
                } else if row.relationship.type == .incomingRequest, row.relationship.note != nil,
                          !model.friends.revealedRequestIDs.contains(row.id) {
                    model.friends.revealRequest(row.id)
                } else { model.showFriendProfile(row) }
            },
            dismissProfile: {}, runsPerformanceAutoScroll: false, viewportIdentity: nil,
            presentation: NativeMemberListPresentation(
                roleColorDisplay: .hidden, dimsOfflineMembers: false,
                presenceHiddenUserIDs: projection.pendingIDs, trailingAccessoryWidth: 90
            ),
            rowAccessory: { member in
                AnyView(Group {
                    if let row = model.friends.row(for: member.id) {
                        FriendRowControls(model: model, row: row)
                    }
                })
            },
            rowMenu: { member in
                guard let row = model.friends.row(for: member.id) else { return nil }
                return FriendRowControls(model: model, row: row).nativeMenu()
            },
            rowAccessibilityActions: { member in
                guard let row = model.friends.row(for: member.id) else { return [] }
                return FriendRowControls(model: model, row: row).accessibilityActions()
            },
            contentIdentity: "friends-\(model.friendsSection)-\(query)"
        )
        // Like the message timeline, let rows pass beneath the native toolbar.
        // NSScrollView supplies the initial inset for the overlapping title bar.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if projection.count == 0 {
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

private struct FriendRowControls: View {
    let model: AppModel
    let row: FriendRow
    private var isPending: Bool { model.friends.pendingUserIDs.contains(row.id) }

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            if isPending { ProgressView().controlSize(.small) }
            actions.disabled(isPending)
        }
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

    private var menuActions: [NicknameMenuAction] {
        var actions = [NicknameMenuAction(title: "Profile", systemImage: "person.crop.circle") { model.showFriendProfile(row) }]
        if row.relationship.type == .friend {
            actions.append(.init(title: "Message", systemImage: "bubble.left") { model.openDirectMessage(with: row.user) })
            actions += model.nicknameMenuActions(for: row.user, in: nil)
            actions.append(.init(title: "Remove Friend", systemImage: "person.badge.minus") { model.friends.confirmation = .removeFriend(row.user) })
        } else if row.relationship.type == .incomingRequest {
            if row.relationship.note != nil {
                actions.append(.init(title: "View Request", systemImage: "text.bubble") { model.friends.revealRequest(row.id) })
            }
            actions.append(.init(title: "Accept", systemImage: "checkmark") { model.acceptFriendRequest(from: row.user) })
            actions.append(.init(title: "Ignore", systemImage: "xmark") { model.removeRelationship(with: row.user, as: .declineIncomingRequest) })
        } else if row.relationship.type == .outgoingRequest {
            actions.append(.init(title: "Cancel Request", systemImage: "xmark") { model.removeRelationship(with: row.user, as: .cancelOutgoingRequest) })
        }
        actions.append(.init(title: "Block", systemImage: "hand.raised") { model.friends.confirmation = .block(row.user) })
        actions.append(.init(title: "Copy User ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.user.id.description, forType: .string)
        })
        return actions
    }

    @ViewBuilder private var menuItems: some View {
        ForEach(menuActions, id: \.title) { action in
            Button(action.title, systemImage: action.systemImage, action: action.perform)
                .disabled(isPending)
        }
    }

    func accessibilityActions() -> [NSAccessibilityCustomAction] {
        menuActions.map { action in
            NSAccessibilityCustomAction(name: action.title) {
                guard !model.friends.pendingUserIDs.contains(row.id), model.isFriendsPresented else { return false }
                action.perform()
                return true
            }
        }
    }

    func nativeMenu() -> NSMenu? {
        let menu = NicknameContextMenu.menu(for: menuActions)
        if isPending { menu?.items.forEach { $0.isEnabled = false } }
        return menu
    }
}

private struct AddFriendView: View {
    let model: AppModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var friends = model.friends
        let canSend = !friends.addFriendText.isEmpty && !friends.isSendingRequest
            && friends.addFriendNote.utf16.count <= FriendRequestNote.maximumLength
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
                    .disabled(friends.isSendingRequest)
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

            VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                HStack {
                    Text("Personalize your request (Optional)")
                    Spacer()
                    Text("\(friends.addFriendNote.utf16.count)/\(FriendRequestNote.maximumLength)")
                        .monospacedDigit()
                        .foregroundStyle(friends.addFriendNote.utf16.count > FriendRequestNote.maximumLength ? Color.red : .secondary)
                }
                .font(.interface(.callout))
                TextField("Say something about yourself", text: $friends.addFriendNote, axis: .vertical)
                    .lineLimit(2 ... 3)
                    .textFieldStyle(.plain)
                    .padding(InterfaceScale.metric(14))
                    .background(.quaternary.opacity(0.5), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous))
                    .accessibilityLabel("Personalize your request")
                    .disabled(friends.isSendingRequest)
                Text("Your note will also appear in the DM if you become friends.")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, InterfaceScale.metric(12))

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
